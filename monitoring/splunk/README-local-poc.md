# Splunk Log + Metrics Integration

Logs **and** metrics integration with Splunk Cloud for Confluent Platform (Flink logs also
supported; Flink is not currently deployed in this cluster).

## Architecture

- **Metrics**: Prometheus/Grafana stays the system of record (unchanged). The same
  Prometheus instance is additionally federated (`/federate`, scoped to
  `namespace="confluent"`) by the OTel Collector agent and forwarded to Splunk Cloud as
  HEC metrics, so the JMX and Kubernetes-resource series behind
  [monitoring/dashboards/](../dashboards/) land in Splunk too.
- **Logs**: Collected via OpenTelemetry Collector (DaemonSet), forwarded to Splunk
  Cloud HEC as events.
- **Scope**: All CFK components (Kafka, KRaft, Schema Registry, Connect, Control
  Center, REST Proxy) + Flink workloads.
- **Dashboards**: Splunk Dashboard Studio JSON translations of the existing Grafana
  dashboards, sourcing metrics from the `cfk_metrics` index via `mstats`.

## Prerequisites

Everything below is on the **Splunk Cloud side** — none of it can be scripted from
Kubernetes, since it happens in Splunk Web / the Splunk REST API.

1. **Splunk Cloud trial account** with HEC enabled
2. **HEC token** created (Settings → Data Inputs → HTTP Event Collector → New Token) —
   settings used here: sourcetype `stash_hec`, default index `main`, indexer
   acknowledgement off. Keep the token value handy — it's passed in at deploy time as
   `SPLUNK_HEC_TOKEN` (see Deployment below), not stored anywhere in version control.
3. **HEC endpoint**: `https://prd-p-1qc41.splunkcloud.com:8088/services/collector/event`
   - Verified live 2026-08-19 (`.../services/collector/health` → `{"text":"HEC is
     healthy"}`). Note the stack id is **`1qc41`** (single "c") — a wrong value with
     `1qcc41` (double "c") doesn't resolve in DNS at all and will silently drop every
     export. Don't take this endpoint on faith either — Splunk Web → **Settings →
     Data Inputs → HTTP Event Collector → Global Settings** shows the authoritative
     URI for your stack.
   - This stack's cert on `:8088` is issued by Splunk's own internal CA
     (`SplunkCommonCA`), not a publicly-trusted one, so `insecureSkipVerify: true` is
     required or every export fails TLS verification. Already set in
     `otel-collector-values.docker-desktop.yaml`.
4. **A metrics-type index for the metrics pipeline**, e.g. `cfk_metrics`: Splunk Web →
   **Settings → Indexes → New Index → Index Data Type: Metrics**. None of the trial's
   default indexes (`history`, `lastchanceindex`, `main`, `summary`) are metrics
   indexes, and HEC metrics ingestion requires one. Then edit the HEC token (Settings
   → Data Inputs → HTTP Event Collector → your token → Edit) and add `cfk_metrics` to
   its allowed indexes.

The Kubernetes side (namespace, HEC token secret, Helm repo, the collector itself) is
fully automated — see Deployment below.

## Deployment

The HEC token is provided to the collector as a Kubernetes Secret (`splunk-hec`, key
`splunk_platform_hec_token`) rather than via `--set` or a plaintext value in the
values file — `--set` would land the token in `helm get values`/release history in
the clear. This is the chart's own documented pattern
(`docs/advanced-configuration.md#provide-tokens-as-a-secret`), wired up in
`otel-collector-values.docker-desktop.yaml` via `secret.create: false` /
`secret.name: splunk-hec`. The secret has to exist in the `splunk-otel` namespace
*before* the Helm install runs, or the collector pods will fail to start with a
missing-secret error.

### Automated (recommended)

`scripts/deploy-monitoring.sh` deploys this collector as one of two optional,
additive stages (alongside Datadog) after Prometheus/Grafana. It creates the
`splunk-otel` namespace, creates/updates the `splunk-hec` secret from
`$SPLUNK_HEC_TOKEN`, adds the Helm repo, and installs/upgrades the release using this
directory's values file:

```bash
export SPLUNK_HEC_TOKEN=<your HEC token>
./scripts/deploy-monitoring.sh
# or, if you only want Splunk (skip Datadog):
DEPLOY_DATADOG=false SPLUNK_HEC_TOKEN=<your HEC token> ./scripts/deploy-monitoring.sh
```

If `SPLUNK_HEC_TOKEN` isn't set, the script prompts for it interactively (hidden
input) or — non-interactively — skips the Splunk stage with a warning and leaves the
rest of the deploy unaffected. Set `DEPLOY_SPLUNK=false` to suppress that warning if
you don't want Splunk at all. Tearing down is symmetric:
`scripts/teardown-monitoring.sh` uninstalls the release and deletes the `splunk-otel`
namespace (which takes the secret with it).

### Manual (equivalent, for standalone use)

```bash
kubectl create namespace splunk-otel

# Create the HEC token secret BEFORE installing the chart — the collector pods read
# it at startup and will fail if it doesn't exist yet. Key name must be exactly
# 'splunk_platform_hec_token'; that's the chart's own convention, not arbitrary.
kubectl create secret generic splunk-hec \
  --from-literal=splunk_platform_hec_token=<YOUR_HEC_TOKEN> \
  -n splunk-otel

helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update

helm upgrade --install splunk-otel-collector \
  splunk-otel-collector-chart/splunk-otel-collector \
  -n splunk-otel \
  -f monitoring/splunk/otel-collector-values.docker-desktop.yaml
```

### Verify deployment

```bash
# Check DaemonSet pods (agent = logs + metrics scrape, k8s-cluster-receiver = cluster-level metrics)
kubectl get pods -n splunk-otel
kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent --tail=20

# Watch specifically for export errors (as opposed to harmless "file not found" noise
# from rotated/deleted log files the collector briefly still has a stale reference to):
kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent --tail=200 | grep -i "splunk_hec\|export"

# From Splunk: query logs
# index=main sourcetype=stash_hec | stats count
# index=main sourcetype=stash_hec k8s.pod.labels.app=kafka | head 10

# From Splunk: query metrics
# | mstats count(_value) WHERE index=cfk_metrics span=1m
# | mstats avg(kafka_server_brokertopicmetrics_messagesinpersec_count) WHERE index=cfk_metrics namespace=confluent
```

**Important — CFK must actually be running for any of this to produce data.**
`confluent` and `monitoring` namespaces are empty until `scripts/setup.sh` (or
`scripts/deploy-monitoring.sh` for monitoring alone) has been run; there's no
log/metric source to forward otherwise. This Splunk pipeline is independent
infrastructure and can be brought up before, after, or alongside CFK — it just has
nothing to send until CFK and the Prometheus/Grafana stack are up.

## Configuration

See `otel-collector-values.docker-desktop.yaml` for:
- Log receiver (`file_log`, tails `/var/log/pods` via hostPath, chart default)
- Metrics receiver (`prometheus/cfk`, federates `namespace="confluent"` series from
  kube-prometheus-stack's Prometheus — see
  `monitoring/docker-desktop-k8s/*-servicemonitor.yaml` for what's actually being
  scraped upstream)
- Processors (K8s metadata enrichment for logs, resource attributes for both signals)
- HEC exporters: `splunk_hec/platform_logs` (events, index `main`) and
  `splunk_hec/cfk_metrics` (metrics, index `cfk_metrics`)
- Two independent `service.pipelines` entries (`logs`, `metrics/cfk`) sharing one
  collector
- DaemonSet topology (1 per node, Docker Desktop = 1 pod)

## Validation

1. **Collector pods running**: `kubectl get pods -n splunk-otel`
2. **No export errors in logs**: `kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent | grep -i "splunk_hec\|export"`
3. **Logs in Splunk**: Query `index=main sourcetype=stash_hec k8s.namespace.name="confluent" k8s.pod.labels.app="kafka" | head 5`
4. **Metrics in Splunk**: Query `| mstats count(_value) WHERE index=cfk_metrics span=1m` — should show a steady 30s-interval count once CFK + Prometheus are running
5. **Grafana unchanged**: Verify metrics still flowing in existing Grafana dashboards

## Querying CFK Logs in Splunk

**The query to fetch all CFK logs:**

```spl
index=main sourcetype=stash_hec k8s.namespace.name="confluent"
```

`index=main` and `sourcetype=stash_hec` come straight from the HEC token's settings
(see Prerequisites above) — every event this pipeline sends lands there, so both are
required, not optional filters. `k8s.namespace.name="confluent"` narrows it to CFK
specifically (this pipeline also carries Flink logs, under
`k8s.namespace.name="flink-jobs"`, if deployed).

### Scoping to one component

Use `k8s.pod.labels.app` to filter to a single CFK component:

| Component | `k8s.pod.labels.app` | `k8s.namespace.name` |
|---|---|---|
| Kafka broker | `kafka` | `confluent` |
| KRaft controller | `kraftcontroller` | `confluent` |
| Schema Registry | `schemaregistry` | `confluent` |
| Connect | `connect` | `confluent` |
| Control Center | `controlcenter` | `confluent` |
| REST Proxy | `kafkarestproxy` | `confluent` |
| Flink (JobManager/TaskManager) | `<job-name>` | `flink-jobs` |

```spl
# Kafka broker logs only
index=main sourcetype=stash_hec k8s.namespace.name="confluent" k8s.pod.labels.app="kafka"

# Flink TaskManager logs
index=main sourcetype=stash_hec k8s.namespace.name="flink-jobs" k8s.pod.labels.component="taskmanager"

# Errors/warnings across all of CFK
index=main sourcetype=stash_hec k8s.namespace.name="confluent" (ERROR OR WARN) | head 20
```

> **Logs vs. metrics dimension naming differs.** These log queries filter on the raw
> Kubernetes pod label `k8s.pod.labels.app` (`kafka`, `connect`, etc.). The metrics
> dashboards filter on `service.name` instead (`kafka-broker`, `kafka-connect`,
> etc.) — a byproduct of the OTel Prometheus receiver renaming the Prometheus `job`
> label on ingest. Don't reuse one convention for the other; see
> `dashboards/METRICS_REFERENCE.md` for the metrics side.

## Troubleshooting

### Collector pods stuck in `CrashLoopBackOff`

```bash
kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent
```

Common issues:
- Secret `splunk-hec` not found in the `splunk-otel` namespace, or wrong key name
  (must be exactly `splunk_platform_hec_token` — see Deployment above)
- HEC endpoint unreachable (network/firewall)
- Invalid HEC token (expired or disabled in Splunk)

### No logs appearing in Splunk

1. Verify Collector is running: `kubectl get pods -n splunk-otel`
2. Check for errors: `kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent`
3. Verify HEC token is valid in Splunk Cloud UI (Settings → Data Inputs → HTTP Event Collector)
4. Check Splunk HEC global settings: SSL enabled, port 8088
5. Query `index=main sourcetype=stash_hec` in Splunk (may need to wait 30-60s for first logs)
6. `dial tcp: lookup <host> ... no such host` in the exporter logs means the endpoint
   hostname is wrong — reconfirm it in Splunk Web (Settings → Data Inputs → HTTP
   Event Collector → Global Settings), it's easy to typo the stack id.

### No metrics appearing in Splunk

1. Confirm `cfk_metrics` exists as a **metrics-type** index and is in the HEC token's
   allowed indexes list (event-type indexes silently reject metric-formatted HEC
   payloads).
2. Confirm CFK and the `monitoring` namespace's Prometheus are actually running
   (`kubectl get pods -n confluent -n monitoring`) — the `prometheus/cfk` receiver
   federates from Prometheus, so if Prometheus itself has nothing scraped, there's
   nothing to federate.
3. Check the federate scrape is reaching Prometheus:
   `kubectl exec -n splunk-otel <agent-pod> -- wget -qO- 'http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090/federate?match[]={namespace="confluent"}' | head`
4. Check exporter errors:
   `kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent | grep splunk_hec/cfk_metrics`

### Metrics missing from Grafana

This pipeline is additive and read-only against Prometheus (federation, not
remote-write) — it cannot affect Grafana. If Grafana dashboards show no data:
- Prometheus not scraping (check ServiceMonitors)
- Not a Splunk issue — check [monitoring/monitoring-guide.md](../monitoring-guide.md) instead

## Dashboards

Splunk Dashboard Studio JSON translations of the `monitoring/dashboards/` Grafana
dashboards live in [`dashboards/`](dashboards/). See `dashboards/NOTES.md` for
translation judgment calls and caveats, and `dashboards/METRICS_REFERENCE.md` for the
dimension rules that cost real debugging time to work out (which metrics carry
`env`/`cluster`, cAdvisor's empty `container` label on this cluster, `sum` vs `avg`
bucketing, counter-reset guards, gauge field-selection) — check it before touching
any `mstats` query in these dashboards.

### Importing a dashboard

1. In Splunk Web, go to **Dashboards** → **Create New Dashboard**.
2. Choose **Dashboard Studio**, then **Grid** or **Absolute** layout (either works —
   the JSON declares its own `"layout": {"type": "absolute", ...}`).
3. Once the editor opens, switch to the **Source** view (top toolbar).
4. Delete the placeholder JSON and paste in the contents of the desired
   `*_splunk.json` file below.
5. Click **Save**.
6. Confirm the `cfk_metrics` index exists as a metrics-type index and is populated
   (see Validation above) before expecting data in the panels.

Every dashboard's inputs default `namespace`/`env`/`cluster` to the confirmed-live
values in this environment (`confluent` / `local-poc` / `docker-desktop`) with an
"All" option; the higher-cardinality inputs (`instance`, `pod`, `topic`, `connector`,
`kafka_connect_cluster_id`) are free-text glob fields — most default to a component's
own pod prefix (e.g. `kafka-*`, `connect-*`) rather than a bare `*`, so the dashboard
is scoped to its own component out of the box. Adjust these, and the dashboard's
global time range picker, to match your data.

### What each dashboard covers

**Kafka_splunk.json** — Curated Kafka cluster observability: cluster health (active
controllers, brokers online, under-replicated/under-min-ISR/offline partitions,
unclean leader election rate), broker network throughput and cluster-wide message
rate, producer/consumer-fetch tail latency (P50–P999 via wildcarded
`kafka_network_requestmetrics_*thpercentile` metric names), CPU/JVM/GC/disk resource
usage, error rate by type, and consumer group lag.

**Connect_splunk.json** — Connector/task counts and status, worker system resources
(CPU/JVM/GC), a per-connector task-count table, worker-level network/IO/auth metrics,
rebalance activity, and per-connector-task batch size, offset commit, running ratio,
error/retry/DLQ, source record, and sink record metrics — all filterable by the
`connector` and `instance` inputs.

**Kafka_Broker_Resources_splunk.json** — Per-pod container memory/CPU gauges
(allocated vs. consumed, color-coded) alongside GB/core-scaled usage-vs-limit trend
charts, disk I/O and PVC capacity (with a disk-usage gauge and a log-directory-usage
percentage trend for capacity forecasting), and JVM heap/GC/thread metrics for Kafka
broker pods.

**Kafka_Connect_Resources_splunk.json** — Same gauge + resource-trend pattern for
Connect worker pods (memory/CPU gauges, GB/core-scaled usage-vs-limit charts, JVM
heap/GC/thread metrics).

**Schema_Registry_Resources_splunk.json** — Same gauge + resource-trend pattern for
Schema Registry pods, plus a domain-metrics section: leader/master role, node count,
leader initialization latency, schema registration/deletion rate, schemas-created-by-
format (Avro/JSON/Protobuf) breakdown, API success vs failure rate, and TLS
keystore/truststore certificate expiry.

**KRaft_Controller_Resources_splunk.json** — Container memory/CPU/JVM resource
panels plus a Raft/quorum-metrics section: current leader/vote/epoch, metadata error
count, unknown voter connections, poll idle ratio, high watermark vs log end offset,
commit/election latency (avg/max), and append/fetch record rate.

**Control_Center_Resources_splunk.json** — Container memory/CPU/JVM resource panels
for Control Center pods — no additional domain-metrics section, since the source
dashboard doesn't have one.

**Enterprise_Tiered_Observability_splunk.json** — Cross-cutting three-tier rollup.
Tier 1 (infrastructure): CPU and memory allocated-vs-consumed gauges per component,
plus CPU/memory/JVM heap/GC trend charts, across Kafka, Connect, Schema Registry,
Control Center, and KRaft Controller pods only (the CFK operator, ksqlDB, and REST
Proxy are explicitly excluded). Tier 2 (platform): controller/partition health,
broker saturation (request handler idle %), P99 request latency by request type,
KRaft quorum health, Connect task status, Schema Registry leadership. Tier 3
(business): per-topic message rate, consumer group lag, connector data quality
(errors/retries/DLQ, expressed as rates), sink write latency, source record
production rate, and per-topic log size.

### Query patterns worth knowing before editing any dashboard

- **Rate panels**: any panel translating a rate over a monotonic counter (bytes
  in/out, request counts, GC time, connector errors, etc.) uses an `mstats
  avg(_value)` bucketed by `span=1m`, followed by a `streamstats` delta-over-time
  with a counter-reset guard (`value>=prev_value`, since a pod restart resets the
  counter to 0 and would otherwise produce a large negative "rate"), then
  `timechart`. Use `avg`, not `sum`, when bucketing — the federate scrape interval
  (30s) is denser than a 1-minute bucket, so summing duplicate raw samples within a
  bucket inflates a point-in-time value non-physically; this shows up visually as a
  jagged, sawtooth-shaped chart.
- **Ratio panels** (Usage vs Limit, CPU/Memory/JVM Heap %, gauges) use an `mstats` →
  `append` → `stats` → `eval` division pattern, since Splunk doesn't have a direct
  equivalent to a single PromQL expression dividing two metrics. The gauge
  visualization (`splunk.singlevalueradial`) picks its displayed field ambiguously by
  default when the result table still has a grouping column alongside the computed
  ratio — drop the grouping field and pin `"majorValueField": "value"` explicitly to
  avoid it silently displaying the wrong field.
- **`kube_*`-prefixed metrics** (`kube_pod_container_resource_limits`,
  `kube_persistentvolumeclaim_resource_requests_storage_bytes`) never carry
  `env`/`cluster` — their ServiceMonitor has no relabeling for those dimensions,
  unlike CFK's own ServiceMonitors and the kubelet's cAdvisor endpoint. Filter these
  by `namespace=` and their own metric-specific dimensions only.
- **Layout**: panels are laid out on a computed absolute grid grouped and ordered to
  match each source dashboard's rows/sections; it is not a pixel-for-pixel
  recreation of the original Grafana layout, but panel grouping and order are
  preserved.

See `dashboards/NOTES.md` for translation judgment calls and panel-consolidation
decisions, and `dashboards/METRICS_REFERENCE.md` for the full dimension reference.

## References

- [Splunk OTel Collector Helm Chart](https://github.com/signalfx/splunk-otel-collector-chart)
- [OpenTelemetry Collector Documentation](https://opentelemetry.io/docs/collector/)
- [Splunk HEC Metrics format](https://docs.splunk.com/Documentation/Splunk/latest/Metrics/GetMetricsInOther)
- [`mstats` command reference](https://docs.splunk.com/Documentation/Splunk/latest/SearchReference/Mstats)
