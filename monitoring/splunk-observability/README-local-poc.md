# Splunk Observability Cloud Integration

Metrics **and** custom dashboards integration with Splunk Observability Cloud for
Confluent Platform. This is a different Splunk product from
[`../splunk/`](../splunk/) (Splunk Cloud Platform) — different ingestion (realm +
access token vs HEC + index), different query language (SignalFlow vs SPL), and no
native log storage of its own. See `../splunk/README-enterprise.md` for the
architecture-level explanation of why these are separate products; this doc covers
what's actually running and verified in this environment.

## Architecture

- **Metrics**: Prometheus/Grafana stays the system of record (unchanged). The same
  Prometheus instance is federated (`/federate`, scoped to `namespace="confluent"`)
  by a second, independent OTel Collector agent and forwarded to Splunk Observability
  Cloud via the `signalfx` exporter, so the JMX and Kubernetes-resource series behind
  [`../dashboards/`](../dashboards/) land here too.
- **Built-in infrastructure visibility**: the same collector's default receivers
  (`kubelet_stats`, `host_metrics`, `k8s_cluster`) populate Splunk Observability
  Cloud's built-in Kubernetes navigator — this part needs no custom dashboard work.
- **Logs**: **not covered by this pipeline.** Splunk Observability Cloud has no
  native log storage — every path (Log Observer Connect, or native OTLP log
  ingestion) terminates in a real Splunk Enterprise/Cloud Platform deployment. If
  logs need to be visible here, that's the existing `../splunk/` pipeline plus a Log
  Observer Connect setup on top, not a replacement for it.
- **Dashboards**: SignalFlow-based custom dashboards, created directly via the
  Splunk Observability Cloud REST API (`POST /v2/chart`, `POST /v2/dashboard`) — see
  [`../dashboards/README.md`](../dashboards/README.md).
- **Scope**: Kafka broker, KRaft controller, Schema Registry, Connect, and Control
  Center resource metrics (Memory/CPU/JVM Heap + component-specific domain metrics).
  REST Proxy and ksqlDB are not yet covered.

## Prerequisites

Everything below is on the **Splunk Observability Cloud side** — none of it can be
scripted from Kubernetes.

1. **A Splunk Observability Cloud account** (trial or paid) with a known **realm**
   (this org: `us1`) and access to the **Data Management → OpenTelemetry** setup
   wizard (`https://app.<realm>.observability.splunkcloud.com`).
2. **An org access token**, created via the wizard's install-configuration step (or
   Settings → Access Tokens). Keep the value handy — it's passed in at deploy time
   via `--set`, not stored anywhere in version control. The same token is reused for
   both the collector's metrics export and the dashboard REST API calls below.
3. That's it — unlike the Splunk Cloud side, there's no index or sourcetype to
   provision up front; Observability Cloud creates metric time series on first
   ingest.

The Kubernetes side (namespace, Helm repo, the collector itself) is all in the
commands below.

## Deployment

Installed as its **own** Helm release, in its **own** namespace, deliberately
separate from the Splunk Cloud collector in `../splunk/` so the two run side by side
on this cluster without colliding — see Troubleshooting below for why that
separation has to be by release name, not just namespace.

```bash
kubectl create namespace splunk-o11y-otel

helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update

helm upgrade --install splunk-otel-collector-o11y \
  --namespace splunk-o11y-otel \
  --values otel-collector-values.docker-desktop.yaml \
  --set splunkObservability.accessToken=<YOUR_TOKEN> \
  splunk-otel-collector-chart/splunk-otel-collector
```

The access token isn't stored in the values file or anywhere in this repo — same
practice as the Splunk Cloud side's HEC token. Pass it via `--set` at deploy time.

### Verify deployment

```bash
kubectl get pods -n splunk-o11y-otel
kubectl logs -n splunk-o11y-otel -l component=otel-collector-agent --tail=200 | grep -i "error\|signalfx"
```

**Important — CFK must actually be running for the `prometheus/cfk` pipeline to
produce anything.** The built-in Kubernetes navigator will populate regardless (it
reads directly off the kubelet), but the CFK-specific dashboards have nothing to
show until `confluent` and `monitoring` (Prometheus) are both up.

## Configuration

See `otel-collector-values.docker-desktop.yaml` for the full annotated values file.
The short version:

- `splunkObservability.realm` / `tracesEnabled: false` — this integration is
  metrics-only; traces were never wired up (no local app sends OTLP/Jaeger/Zipkin
  here).
- `agent.ports.otlp` / `otlp-http: null` — disabled; see issue 2 below.
- `agent.config.receivers.kubelet_stats.insecure_skip_verify: true` — see issue 3
  below.
- `agent.config.receivers.prometheus/cfk` + `service.pipelines.metrics/cfk` — the
  federate receiver/pipeline, added as a new pipeline key rather than editing the
  chart's existing `metrics` pipeline (Helm's `--set`/values-merge can't append to
  an existing array, but adding a sibling map key is additive and safe).
- `agent.resources.limits.memory: 1Gi` — bumped from the chart's 500Mi default; see
  issue 5 below.

## Real issues found and fixed getting here (not obvious from the docs)

### 1. The wizard-generated `helm install` command collides with the Splunk Cloud collector

It has no `--namespace` flag and uses the release name `splunk-otel-collector` —
identical to the Splunk Cloud release. Some of what this chart creates is
cluster-scoped (`ClusterRole`, `ClusterRoleBinding`), which can collide across
namespaces since those aren't namespaced objects; the release name has to differ,
not just the namespace, to guarantee no collision. Fixed by installing as
`splunk-otel-collector-o11y`.

### 2. Agent DaemonSet pod stuck `Pending`: "didn't have free ports for the requested pod ports"

Both collectors' agent DaemonSets bind `hostPort` 4317/4318 (OTLP) unconditionally —
baked into the chart template and **independent of `agent.hostNetwork`** (turning
that off alone does not fix it — a reasonable-looking assumption that turned out
wrong). With traces enabled by default, it also binds Jaeger (14250/14268) and
Zipkin (9411) hostPorts. Fixed by setting `splunkObservability.tracesEnabled: false`
(drops the Jaeger/Zipkin ports) plus explicitly nulling the OTLP ports
(`agent.ports.otlp: null`, `agent.ports.otlp-http: null` — the chart's own
`values.yaml` documents this exact pattern: "to disable a port set
`agent.ports.<name>: null`").

### 3. `kubelet_stats` receiver failing every scrape

`x509: cannot validate certificate for <node-ip> because it doesn't contain any IP
SANs`. Docker Desktop's kubelet presents a self-signed cert with no IP SANs for its
own node IP. Without fixing this, no pod/container CPU or memory metrics reach the
built-in Kubernetes navigator at all. Fixed via
`agent.config.receivers.kubelet_stats.insecure_skip_verify: true`.

### 4. Benign, left as-is: control-plane scrape failures

`kube-scheduler` (`:10259`), `kube-proxy` (`:10249`), and `kube-controller-manager`
(`:10257`) all refuse the receiver_creator's scrape attempts. Docker Desktop's
single-node control plane doesn't expose these the way a real multi-node cluster
would — matches the same call already made on the Grafana/Prometheus side of this
repo (control-plane metrics disabled there too). Not a CFK or Observability Cloud
concern.

### 5. Agent OOMKilled (`exitCode 137`) within a minute of adding the `prometheus/cfk` receiver

Measured directly, not guessed: the federated `{namespace="confluent"}` match
returns ~107k series / ~48MB per scrape — every CFK component's JMX percentile
families and per-topic/per-instance breakouts, plus cAdvisor/kube-state-metrics
riding along on the same match. Identical cardinality problem already hit and fixed
on the Splunk Cloud collector (`../splunk/otel-collector-values.docker-desktop.yaml`).
Fixed the same way: raised `agent.resources.limits.memory` from the chart's 500Mi
default to 1Gi. Confirmed stable afterward — 0 restarts across multiple scrape
cycles, no error/OOM log lines. Narrowing the federate `match[]` is the real fix if
this keeps growing with the cluster; raising the memory ceiling again is not a
durable answer.

### 6. `.rate()` producing impossible values on federated counter metrics

Building the dashboards below, SignalFlow's `.rate()` method — the documented way
to turn a cumulative counter into a per-second rate — produced a single unlabeled
series spiking to 700+ "cores" on a 12-core machine for
`container_cpu_usage_seconds_total`. Cross-checked directly against Prometheus's own
`rate(...)` on the same series over the same window, which returned sane per-pod
figures (0.02–0.3 cores) — and the real `kube_pod_container_resource_limits` values
for these pods (0.5–4 cores) ruled out "tiny limits" as an innocent explanation.
Root cause: the `/federate` endpoint strips Prometheus `TYPE` metadata, so this
metric arrives registered as a `GAUGE` in Splunk Observability Cloud's metric
catalog rather than a counter — `.rate()`'s internal normalization apparently
doesn't handle that combination cleanly against this federate scrape's cadence.
Fixed by computing the rate manually instead: `(raw - raw.timeshift('2m')) / 120` —
an explicit delta over a known window, with no dependence on `.rate()`'s internal
assumptions. Used everywhere a rate-from-counter is needed across the dashboards
below (CPU usage, GC time, Schema Registry counters).

### 7. Every `%` gauge (Memory/CPU/JVM Heap/Disk Usage) rendered blank

Chart creation only validates SignalFlow *syntax* — it doesn't confirm the result
actually renders anything, and every one of these gauges sat blank in the live
dashboards despite creating without error. Root cause, confirmed via
`GET /v2/metrictimeseries`, not guessed: the two metrics being divided in each
ratio come from different scrape sources (e.g. `container_memory_working_set_bytes`
from cAdvisor vs `kube_pod_container_resource_limits` from kube-state-metrics) and
carry completely different "extra" dimensions (`server.address`, `id`, `uid`,
`unit`, ...) even once both are filtered to the same pod. SignalFlow's `a/b` join
matches on those extra dimensions, finds nothing in common, and silently returns no
data instead of erroring. Fixed by calling `.sum()` (no `by`) on both sides before
dividing — safe here since each side is already filtered to exactly one real
series, so this only strips the mismatched noise dimensions, not real data.

### 8. Gauges still blank after fixing issue 7 — a second, unrelated bug

`colorBy: "Dimension"` (the option used on every other chart in this repo) renders
nothing at all for a `SingleValue` chart with `secondaryVisualization: "Radial"` —
the gauge visualization requires `colorBy: "Scale"` plus an explicit `colorScale2`
(a list of banded ranges) to know how to draw its arc at all. Confirmed by
creating one real test chart and switching it live between configurations while
checking the actual render, not inferred from documentation — none describing this
requirement could be found. While fixing this, also added green/amber/red color
banding to the gauges (a follow-up ask) using `colorScale2` with `paletteIndex`
values `18`/`6`/`16` for <70%/70–90%/≥90% — also confirmed live, since no
authoritative palette-index-to-color mapping could be found either. Once the
gauges actually rendered, the separate `Usage (GB)`/`Limit (GB)`/`Usage (cores)`/
`Limit (cores)`/`Used (GB)`/`Max (GB)` single-value tiles that used to sit next to
each one were removed (30 charts across the 5 dashboards) — a rendering gauge
conveys allocated-vs-used on its own, and the raw GB/core values are still visible
in each section's "Usage vs Limit" line chart.

### 9. Layout: every gauge sat alone in its own row with dead space beside it

A side effect of fix 8 — once each resource-type section dropped from 4 charts
(line + gauge + 2 tiles) to 2 (line + gauge), the original packer (line charts
always full-width, single-values always packed 3-per-row underneath) put a lone
gauge by itself with nothing to its right. Fixed by pairing each line chart with
the single-value immediately following it, side by side in the same row (line
width 8, gauge width 4) — any leftover single-value still packs 3-per-row, and any
leftover line packs 2-per-row at width 6 instead of sitting full-width alone.

### 10. A plain (non-radial) `colorScale2` needs the opposite bound shape from a gauge's

Building the Kafka/Connect Cluster dashboards' health-status singlevalues (Active
Controllers, Offline Partitions, etc.), reusing the Resources gauges' fully-closed
`colorScale2` bounds (`{"gte": 0, "lt": 70, ...}` style, covering a fixed 0–100
range) failed with `"Missing open ended range(s)"` on a chart that had no
`secondaryVisualization: "Radial"` set. The Radial gauges need closed bounds
spanning their full dial range; a plain `SingleValue` needs the opposite — open-
ended outer bounds (`{"lte": 0, ...}` / `{"gt": 0, ...}`, no upper/lower limit at
the extremes) — confirmed live before applying broadly, same as every other
`colorScale2` discovery.

### 11. SignalFlow rejects a program that binds the same variable name twice

Concatenating two independently-built rate-delta snippets (e.g. Broker Network
Throughput's bytes-in and bytes-out, each declaring a local `raw`) into one
chart's `programText` produced `"scope contains multiple bindings of 'raw' of
type 'NAME'"`. Fixed by giving each snippet a unique variable name (`raw_in`/
`raw_out`) whenever more than one rate calculation is combined in a single
program — caught on the second chart of the batch, not after a full blind run.

Verified working end to end: the `signalfx` exporter synchronizes host metadata with
zero errors, and the `prometheus/cfk` receiver scrapes successfully.

## Validation

1. **Collector pods running**: `kubectl get pods -n splunk-o11y-otel`
2. **No export errors in logs**:
   `kubectl logs -n splunk-o11y-otel -l component=otel-collector-agent | grep -i error`
3. **Built-in Kubernetes navigator populated**: Splunk Observability Cloud →
   Infrastructure → Kubernetes — pods/nodes for this cluster should appear within a
   couple of minutes of the collector coming up.
4. **CFK metrics flowing**: search the metric catalog (Metrics Finder, or
   `GET /v2/metric?query=sf_metric:kafka*` with the org token) for
   `kafka_server_brokertopicmetrics_messagesinpersec_count` or similar — should
   return results once CFK and Prometheus are both running.
5. **Dashboards populated**: open any dashboard link below — panels should show live
   data within the dashboard's default `-15m` window.

## Dashboards

Seven dashboards (128 charts total), mirroring the equivalent
[`../splunk/dashboards/*.json`](../splunk/dashboards/) files panel-for-panel,
translated from SPL to SignalFlow. Full detail, links, and the SPL→SignalFlow
translation notes (rate-calculation caveats, gauge chart-type mapping, what's
deliberately not reproduced) live in
[`../dashboards/README.md`](../dashboards/README.md) — the short version:

**Resources tier** (Memory/CPU/JVM Heap, one dashboard per component):
- **Kafka Broker Resources** — Memory/CPU/JVM Heap/GC/Threads + Disk I/O, Disk Usage
  %, PVC Capacity, Log Directory Usage vs PVC.
- **Kafka Connect Resources** — Memory/CPU/JVM Heap/GC/Threads.
- **Schema Registry Resources** — Memory/CPU/JVM Heap/GC/Threads + Leader Role, Node
  Count, Registrations/Deletions Rate, Schemas Created by Format, API Success/Failure
  Rate, TLS Certificate Expiry.
- **KRaft Controller Resources** — Memory/CPU/JVM Heap/GC/Threads + Current
  Leader/Vote/Epoch, Metadata Error Count, High Watermark/Log End Offset,
  Commit/Election Latency, Append/Fetch Records Rate.
- **Control Center Resources** — Memory/CPU/JVM Heap/GC/Threads.

**Cluster tier** (health, throughput, worker/connector-level metrics):
- **Kafka Cluster** — Active Controllers, Brokers Online, Offline/Under-Replicated/
  Under-Min-ISR Partitions, Unclean Leader Election Rate, broker throughput, errors,
  CPU/JVM/GC/disk, cluster-wide message rate, consumer group lag, Produce/Consumer-
  Fetch tail latency (all percentiles).
- **Kafka Connect Cluster** — task counts/status, worker CPU/JVM/GC, worker network/
  IO/auth metrics, rebalance activity, per-connector-task batch/offset/error/source/
  sink record metrics (this last group shows "No Data" right now — zero connectors
  are deployed on this cluster, confirmed via `curl :8083/connectors` → `[]`; built
  anyway for full parity, will populate once a real connector exists).

Not yet ported: `Enterprise_Tiered_Observability_splunk.json`, a cross-cutting rollup
spanning metrics already verified while building the other 6 — reassembly, not
fresh verification work.

`../dashboards/build_resources_dashboards.py` generated the original 93 Resources
charts + 5 dashboards, and `../dashboards/build_functional_dashboards.py` generated
the Kafka/Connect Cluster charts + 2 dashboards, both via the REST API (not
idempotent — re-running either creates new chart
objects rather than updating the existing ones; see that file's own docstring).
30 of those were later deleted (see issues 7 and 8 below) once the % gauges were
fixed to actually render, leaving 63.

## Troubleshooting

### Agent pod `Pending`, "didn't have free ports for the requested pod ports"

See issue 2 above — check for a release-name/hostPort collision with another
collector on the same node:

```bash
kubectl get daemonset -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' | grep splunk
kubectl describe pod -n splunk-o11y-otel -l component=otel-collector-agent | grep -A5 Events
```

### `kubelet_stats` scrape errors in agent logs

```bash
kubectl logs -n splunk-o11y-otel -l component=otel-collector-agent | grep -i "x509\|kubelet_stats"
```

If it mentions "doesn't contain any IP SANs", see issue 3 above.

### Agent pod repeatedly `OOMKilled`

```bash
kubectl get pod -n splunk-o11y-otel -l component=otel-collector-agent -o jsonpath='{.items[0].status.containerStatuses[0].lastState}'
```

`"reason":"OOMKilled"` after adding/widening the `prometheus/cfk` federate match
means the scrape's cardinality has outgrown the current memory limit — see issue 5.
Measure the actual scrape size before just raising the limit again:

```bash
kubectl run curl-check --rm -i --restart=Never --image=curlimages/curl -n confluent -- \
  sh -c 'curl -s -G "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/federate" --data-urlencode "match[]={namespace=\"confluent\"}" -o /tmp/o.txt -w "size=%{size_download}\n" && wc -l /tmp/o.txt'
```

### A dashboard panel shows no data or an obviously wrong value

1. Confirm the metric exists in this org's catalog:
   `curl -s -G "https://api.<realm>.observability.splunkcloud.com/v2/metric" -H "X-SF-TOKEN: <token>" --data-urlencode "query=sf_metric:<name>*"`
2. Confirm the dimension values you're filtering on are real, not assumed — pull one
   live sample:
   `curl -s -G "https://api.<realm>.observability.splunkcloud.com/v2/metrictimeseries" -H "X-SF-TOKEN: <token>" --data-urlencode "query=sf_metric:<name>" --data-urlencode "limit=1"`
3. If the panel is a rate calculation and the numbers look implausible (impossibly
   large, or a single unlabeled series where you expected several), suspect
   `.rate()` first — see issue 6 above.

## References

- [Splunk OTel Collector Helm chart](https://github.com/signalfx/splunk-otel-collector-chart)
- [Splunk Observability Cloud — Get started](https://help.splunk.com/en/splunk-observability-cloud/get-started)
- [SignalFlow analytics reference](https://help.splunk.com/en/splunk-observability-cloud/create-dashboards-and-charts/create-charts/functions-reference)
- [Metric types in Observability Cloud](https://help.splunk.com/en/splunk-observability-cloud/manage-data/metrics-metadata-and-events/metrics-events-and-metadata/metric-types)
