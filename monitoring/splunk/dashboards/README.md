# Splunk Dashboard Studio Dashboards

Splunk Dashboard Studio JSON translations of the Grafana dashboards in
[`monitoring/dashboards/`](../../dashboards/), sourcing data from the `cfk_metrics` Splunk metrics
index populated by the OTel collector pipeline described in [`../README.md`](../README.md) and
[`../otel-collector-values.docker-desktop.yaml`](../otel-collector-values.docker-desktop.yaml) (an OTel
collector's `prometheus/cfk` receiver federating from kube-prometheus-stack's Prometheus, scoped to
`namespace="confluent"`). `ksqlDB_Resources_grafana.json` and `REST_Proxy_Resources_grafana.json` are
out of scope and were not translated.

## Importing a dashboard

1. In Splunk Web, go to **Dashboards** → **Create New Dashboard**.
2. Choose **Dashboard Studio**, then **Grid** or **Absolute** layout (either works — the JSON declares
   its own `"layout": {"type": "absolute", ...}`).
3. Once the editor opens, switch to the **Source** view (top toolbar).
4. Delete the placeholder JSON and paste in the contents of the desired `*_splunk.json` file below.
5. Click **Save**.
6. Confirm the `cfk_metrics` index exists as a metrics-type index and is populated (see
   `../README.md` → Validation) before expecting data in the panels.

Every dashboard's inputs default `namespace`/`env`/`cluster` to the confirmed-live values in this
environment (`confluent` / `local-poc` / `docker-desktop`) with an "All" option; the higher-cardinality
inputs (`instance`, `pod`, `topic`, `connector`, `kafka_connect_cluster_id`) are free-text glob fields
defaulting to `*`. Adjust these, and the dashboard's global time range picker, to match your data.

## Dashboards

### Kafka_splunk.json (76 panels)
Translated from `Kafka_grafana.json` ("Confluent Kafka Cluster"). Broker/controller cluster health
(active controllers, online/offline/under-replicated/under-min-ISR/stray partitions), request rates,
system resources (CPU/JVM/GC/disk), broker throughput in/out, thread utilization, ISR shrink/expand
churn, log size, producer/consumer/fetch-follower percentile latencies (P50–P999, via wildcarded
`kafka_network_requestmetrics_*thpercentile` metric names), fetch session cache, replica/ISR fetch
state, connections, consumer group coordinator state, message conversion counts, and a client-version
piechart. Rate panels use the `mstats` → `streamstats` delta → `timechart` pattern described in
NOTES.md; a few panels were consolidated where the Grafana source had literal duplicates or
inconsistent grouping — see NOTES.md for the full list.

### Connect_splunk.json (52 panels)
Translated from `Connect_grafana.json` ("Confluent Kafka Connect Cluster"). Connector/task counts and
status (a merged piechart + timeseries covering all 5 task states), worker system resources
(CPU/JVM/GC), a per-connector task-count table, worker-level network/IO/auth metrics, rebalance
activity, and per-connector-task batch size, offset commit, running ratio, error/retry/DLQ, source
record, and sink record metrics — all filterable by the `connector` and `instance` inputs. See
NOTES.md for the piechart/timeseries consolidation and the "Connect Worker" table's omission of the
non-numeric `kafka_connect_app_info` identity labels.

### Kafka_Broker_Resources_splunk.json (19 panels)
Translated from `Kafka_Broker_Resources_grafana.json`. Per-pod container memory and CPU usage vs
Kubernetes limits (with %-gauges), disk I/O and PVC capacity, and JVM heap/GC/thread metrics for Kafka
broker pods, plus a capacity-forecasting panel comparing log directory usage against PVC requested
capacity. CPU ratio panels rate-ize `container_cpu_usage_seconds_total` before computing the
usage/limit percentage (it's a monotonic counter, not a gauge) — see NOTES.md.

### Kafka_Connect_Resources_splunk.json (14 panels)
Translated from `Kafka_Connect_Resources_grafana.json`. Per-pod container memory/CPU usage vs limits
and JVM heap/GC/thread metrics for Kafka Connect worker pods. Same ratio-panel pattern as the broker
resources dashboard.

### Schema_Registry_Resources_splunk.json (21 panels)
Translated from `Schema_Registry_Resources_grafana.json`. Container memory/CPU/JVM resource panels
plus a Schema Registry domain-metrics section: leader/master role, node count, leader initialization
latency, schema registration/deletion rate, schemas-created-by-format (Avro/JSON/Protobuf) breakdown,
API success vs failure rate, and TLS keystore/truststore certificate expiry.

### KRaft_Controller_Resources_splunk.json (24 panels)
Translated from `KRaft_Controller_Resources_grafana.json`. Container memory/CPU/JVM resource panels
plus a Raft/quorum-metrics section: current leader/vote/epoch, metadata error count, unknown voter
connections, poll idle ratio, high watermark vs log end offset, commit/election latency (avg/max), and
append/fetch record rate.

### Control_Center_Resources_splunk.json (14 panels)
Translated from `Control_Center_Resources_grafana.json`. Container memory/CPU/JVM resource panels for
Control Center pods — no additional domain-metrics section in the source dashboard.

### Enterprise_Tiered_Observability_splunk.json (24 panels)
Translated from `Enterprise_Tiered_Observability_grafana.json` ("Enterprise Confluent Observability
(Tier 1/2/3)"), with all ksqlDB- and REST-Proxy-specific panels removed per scope (only the "REST Proxy
CPU %" gauge needed removal; no ksqlDB-specific panels were present in the source). Tier 1
(infrastructure): per-component CPU%/memory/JVM heap/GC across Kafka, Connect, Schema Registry, Control
Center, and KRaft Controller pods. Tier 2 (platform): controller/partition health, broker saturation
(request handler idle%), P99 request latency by request type, KRaft quorum health, Connect task status,
Schema Registry leadership. Tier 3 (business): per-topic message rate, consumer group lag, connector
data quality (errors/retries/DLQ), sink write latency, source record production rate, and per-topic log
size.

## Caveats

- **Rate pattern**: every panel translating a Grafana `rate()`/`irate()` over a monotonic counter uses
  the `mstats sum(_value)` → `streamstats` delta-over-time → `timechart` pattern (rule 3 in the
  translation spec), rather than a plain `mstats` sum, so per-second rates are computed correctly from
  cumulative counter values.
- **Ratio panels** (Usage vs Limit, CPU/Memory/JVM Heap %) extend past the plain gauge/rate templates
  with an `mstats` → `append` → `stats` → `eval` division pattern, since Splunk doesn't have a direct
  equivalent to a single PromQL expression dividing two metrics. See NOTES.md for details, including
  where a counter numerator (CPU) is rate-ized before the ratio is computed.
- **Skipped/uncertain panels and consolidation judgment calls**: see
  [`NOTES.md`](NOTES.md) for the complete list — nothing was skipped for lack of a verified metric name;
  the items there are either informational calculation notes or panel consolidations where the Grafana
  source had literal duplicates, inconsistent groupings, or per-instance panel repetition that doesn't
  translate 1:1 into Dashboard Studio's static panel model.
- **Layout**: panels are laid out via a simple auto-flow grid (absolute positioning) grouped and ordered
  to match each source dashboard's rows/sections; it is not a pixel-for-pixel recreation of the Grafana
  layout, but panel grouping and order are preserved.
