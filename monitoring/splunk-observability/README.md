# Confluent for Kubernetes → Splunk Observability Cloud

Deliverables for the Splunk Observability Cloud integration — the counterpart to
[`../splunk/`](../splunk/), which covers Splunk Cloud Platform (indexes, SPL,
Dashboard Studio). These are different Splunk products with almost nothing shared at
the ingestion/dashboarding layer; see `../splunk/README-enterprise.md` for the
architecture-level explanation of why, and the notes below for what's been verified
so far in this specific environment.

## Org details (this trial)

- Realm: `us1`
- Org: Psyncopate Technologies (trial)
- Login: https://app.us1.observability.splunkcloud.com

## Deployment

Installed as its own Helm release, separate from the existing Splunk Cloud collector,
so both run side by side on this single-node cluster without colliding:

- Release: `splunk-otel-collector-o11y`
- Namespace: `splunk-o11y-otel`
- Chart: `splunk-otel-collector-chart/splunk-otel-collector` (same chart as the
  Splunk Cloud side — `github.com/signalfx/splunk-otel-collector-chart` is the
  shared distribution for both products; only the destination config differs)

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

## What's actually running right now

Both layers are in now: the collector's default Kubernetes infrastructure receivers
(`kubelet_stats`, `k8s_cluster`, etc.), confirmed populating the built-in Kubernetes
navigator in Splunk Observability Cloud, **and** a `prometheus/cfk` receiver +
`metrics/cfk` pipeline federating CFK's metrics off kube-prometheus-stack's
Prometheus, the same pattern already proven on the Splunk Cloud collector — see
issue 5 below for the one real problem this second pipeline caused and how it was
fixed.

## Real issues found and fixed getting here (not obvious from the docs)

1. **The wizard-generated `helm install` command collides with the existing Splunk
   Cloud collector if run as-is.** It has no `--namespace` flag and uses the release
   name `splunk-otel-collector` — identical to the existing Splunk Cloud release.
   Some of what this chart creates is cluster-scoped (`ClusterRole`,
   `ClusterRoleBinding`), which can collide across namespaces since those aren't
   namespaced objects; the release name has to differ, not just the namespace, to
   guarantee no collision. Fixed by installing as `splunk-otel-collector-o11y`.

2. **Agent DaemonSet pod stuck `Pending`: "didn't have free ports for the requested
   pod ports."** Both collectors' agent DaemonSets bind `hostPort` 4317/4318 (OTLP)
   unconditionally — this is baked into the chart template and is **independent of
   `agent.hostNetwork`** (turning that off did not fix it; a common assumption that
   turned out wrong). With traces enabled by default, it also binds Jaeger
   (14250/14268) and Zipkin (9411) hostPorts, none of which we need since this
   integration doesn't do local app instrumentation. Fixed by setting
   `splunkObservability.tracesEnabled: false` (drops the Jaeger/Zipkin ports) and
   explicitly nulling the OTLP ports (`agent.ports.otlp: null`,
   `agent.ports.otlp-http: null` — the chart's own values.yaml documents this exact
   pattern: "to disable a port set `agent.ports.<name>: null`").

3. **`kubelet_stats` receiver failing every scrape**:
   `x509: cannot validate certificate for <node-ip> because it doesn't contain any
   IP SANs`. Same root cause class as the Splunk Cloud HEC endpoint's internal CA
   issue, just on the receiving side this time — Docker Desktop's kubelet presents a
   self-signed cert with no IP SANs for its own node IP. Without fixing this, no
   pod/container CPU or memory metrics would reach the built-in Kubernetes
   navigator at all. Fixed via `agent.config.receivers.kubelet_stats.insecure_skip_verify: true`.

4. **Benign, left as-is**: `kube-scheduler` (`:10259`), `kube-proxy` (`:10249`), and
   `kube-controller-manager` (`:10257`) all refuse the receiver_creator's scrape
   attempts. Docker Desktop's single-node control plane doesn't expose these the
   way a real multi-node cluster would — matches the same call already made on the
   Grafana/Prometheus side of this repo (control-plane metrics disabled there too).
   Not a CFK or Observability Cloud-specific concern.

5. **Agent OOMKilled (`exitCode 137`) within a minute of adding the `prometheus/cfk`
   federate receiver.** Measured directly, not guessed: the federated
   `{namespace="confluent"}` match returns ~107k series / ~48MB per scrape — every
   CFK component's JMX percentile families and per-topic/per-instance breakouts,
   plus cAdvisor/kube-state-metrics riding along on the same match. This is the
   identical cardinality problem already hit and fixed on the Splunk Cloud
   collector (`../splunk/otel-collector-values.docker-desktop.yaml`). Fixed the
   same way: raised `agent.resources.limits.memory` from the chart's 500Mi default
   to 1Gi. Confirmed stable afterward (0 restarts across multiple scrape cycles,
   no error/OOM log lines). Narrowing the federate `match[]` is the real fix if
   this keeps growing with the cluster — raising the memory ceiling again is not
   a durable answer.

Verified working: the `signalfx` exporter is synchronizing host metadata with zero
errors, confirming the token/realm/export path is genuinely functional end to end.
The `prometheus/cfk` receiver is running and scraping successfully, but per the open
question below, none of this lands in built-in Observability Cloud content yet.

## Open questions, not yet resolved

- **Logs**: Splunk Observability Cloud has no native log storage of its own — every
  path (Log Observer Connect, or the newer native OTLP log ingestion) terminates in
  a real Splunk Enterprise/Cloud Platform deployment. If logs need to be visible
  here, that's the existing Splunk Cloud pipeline plus a Log Observer Connect setup
  on top, not a replacement for it. Still waiting on confirmation of whether that's
  actually in scope for this demo.
- **Dashboards — 6 of 7 done.** Confirmed via Splunk's own docs: metrics arriving
  through a Prometheus receiver (the federate pattern used here) are "custom
  metrics, not supported by built-in content," so none of this was ever going to
  show up in the built-in Kubernetes navigator or any other built-in dashboard —
  genuine custom chart/dashboard authoring was always required. Done: the 5
  Memory/CPU/JVM-Heap "Resources" dashboards (Broker/Connect/Schema Registry/
  KRaft/Control Center — 63 charts) plus the Kafka Cluster and Connect Cluster
  dashboards (cluster health, throughput, worker resources, connector/task
  metrics — 65 more charts), all mirroring the equivalent
  `../splunk/dashboards/*.json` files panel-for-panel — see
  [`dashboards/README.md`](dashboards/README.md) for the full list, links, and
  SPL→SignalFlow translation notes. Built via raw REST API JSON
  (`POST /v2/chart` / `POST /v2/dashboard`), not `terraform-provider-signalfx` —
  the earlier plan to use Terraform was superseded once the actual REST payloads
  turned out to be straightforward to author directly, matching how the Splunk
  Cloud side's dashboards are just JSON files too. **Not yet ported**:
  `Enterprise_Tiered_Observability_splunk.json`, a cross-cutting rollup spanning
  metrics already verified while building the other 6 — reassembly, not fresh
  verification work.
