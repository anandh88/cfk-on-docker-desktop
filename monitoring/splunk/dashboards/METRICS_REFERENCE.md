# CFK → Splunk metrics reference

Verified directly against the live cluster on 2026-08-20 (Prometheus `/api/v1/query`,
the CFK ServiceMonitor manifests, cAdvisor, and kube-state-metrics) — not guessed.
Use this before writing/fixing any `mstats` query in these dashboards, instead of
re-running the whole diagnostic chain per panel.

## The one rule that matters: which metrics carry `env`/`cluster`

The OTel collector's `prometheus/cfk` receiver federates everything Prometheus
scrapes for `{namespace="confluent"}` verbatim (`honor_labels: true`), so whatever
labels a metric has *in Prometheus* is exactly what it has in Splunk. Three
different ServiceMonitors feed this:

| Source | ServiceMonitor | `relabelings` | Has `env`/`cluster`? |
|---|---|---|---|
| CFK JMX metrics (`kafka_*`, `jvm_*`, `process_*`) | `kafka-broker`, `connect`, `controlcenter`, `kraftcontroller`, `schemaregistry`, `kafkarestproxy`, `ksqldb` (monitoring ns) | explicit `env=local-poc`, `cluster=docker-desktop`, `namespace=confluent` | **Yes** |
| cAdvisor (`container_*`) | `prometheus-kube-prometheus-kubelet`, `/metrics/cadvisor` endpoint | same explicit `env`/`cluster` relabeling, patched in manually | **Yes** |
| kube-state-metrics (`kube_*`) | `prometheus-kube-state-metrics` | **none** | **No — never filter these by `env=`/`cluster=`, only `namespace=`** |

Filtering a `kube_*` metric by `env="$env$" cluster="$cluster$"` silently returns
zero rows — no error, just an empty/blank panel. This is the root cause behind
every "###"/"No search results" panel that turned out not to be a data-availability
problem in this file (Memory Limit, CPU Limit, PVC Capacity, Disk Usage %, and the
missing "Limit"/"pvc_requested_capacity" series in the resource-vs-limit charts).

**Rule: for `kube_pod_container_resource_limits` and
`kube_persistentvolumeclaim_resource_requests_storage_bytes`, filter only on
`namespace=` (+ whatever metric-specific dims like `pod=`, `resource=`, `container=`,
`persistentvolumeclaim=`) — never add `env=`/`cluster=`.**

## Other things that cost real debugging time — check these before assuming a metric is missing

- **cAdvisor's `container` label is `""` (empty) on this cluster**, not the actual
  container name, for `container_memory_working_set_bytes` /
  `container_cpu_usage_seconds_total`. Only `kube_pod_container_resource_limits`
  (kube-state-metrics) carries a real `container="kafka"` value. Scope cAdvisor
  queries by `pod=` alone.
- **`sum(_value)` vs `avg(_value)` when bucketing with `span=`:** the federate
  scrape interval is 30s, so a `span=1m` bucket often holds 2 raw samples. Summing
  a point-in-time gauge/counter reading inflates it non-physically (jagged,
  sawtooth-looking charts). Always use `avg(_value)` for these, never `sum`.
- **Counter-reset guard on rate-from-counter calcs:** `container_cpu_usage_seconds_total`
  and `jvm_gc_collection_seconds_sum` are monotonic counters; a pod restart resets
  them to 0. Any `streamstats`-based delta/rate calc needs
  `AND value>=prev_value` in the `eval`, else a restart produces a large negative
  "rate".
- **Gauge (`splunk.singlevalueradial`) `majorValue` field-picking is unreliable**
  when the result table still has a `BY <field>` grouping column alongside
  `value` — it can grab the grouping field's string instead of the number. Drop
  the grouping field (`| fields - value`) and pin `"majorValueField": "value"`
  explicitly in the visualization options.
- **The real Kafka log-size metric is `kafka_log_log_value` with `name="Size"`**,
  not `kafka_log_log_size` (which doesn't exist — confirmed against all 8393 live
  metric names). Other `name=`-dimensioned metrics in this family: `LogEndOffset`,
  `LogStartOffset`, `NumLogSegments`, `TierSize`, `TotalSize`.

## Metric name spelling: verified clean

Every other `metric_name="..."` string used across all 8 dashboard files
(96 distinct names) was checked against the live metric list and matches exactly.
`kafka_log_log_size` was the only misspelling found.
