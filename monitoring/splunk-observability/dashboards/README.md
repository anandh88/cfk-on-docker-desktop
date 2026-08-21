# CFK dashboards — Splunk Observability Cloud

Seven dashboards, mirroring the structure and panel coverage of the equivalent files in
[`../../splunk/dashboards/`](../../splunk/dashboards/) — same purpose per dashboard, same
metric families, translated from SPL to SignalFlow.

**File layout**: one combined JSON file per dashboard (`broker-resources.json`,
`kafka-cluster.json`, etc.) — every chart's full definition plus its grid position, all in
one file, matching the Splunk Cloud side's one-file-per-dashboard feel. This is a slight
fiction, worth being explicit about: unlike Dashboard Studio, where a dashboard genuinely
*is* one importable JSON blob, Splunk Observability Cloud has no such API — charts are
independent objects created via `POST /v2/chart`, then referenced by ID from a dashboard
object via `POST /v2/dashboard`. Deploying one of these files still means N chart-creates
+ 1 dashboard-create under the hood (see `build_resources_dashboards.py` /
`build_functional_dashboards.py`); the single file is a readability/review convenience on
top of that reality, not a native import format. `sync_dashboard_files.py` re-pulls a
dashboard's live state back into its file after any manual API patch, so the file never
drifts from what's actually live.

**3 of the 7 are currently unavailable, cause unknown**: `schema-registry-resources`,
`kraft-controller-resources`, and `control-center-resources` were found completely gone
from the org on 2026-08-21 (dashboard *and* every one of their charts return 404) — not
caused by anything in this repo's own scripts (nothing here ever targeted those specific
chart IDs for deletion), and not an org/token-wide issue (the other 4 dashboards, and the
metric catalog itself, were all confirmed still working normally at the same time). Their
last-known-good JSON is preserved in the old scattered format at
`schema-registry-resources/`, `kraft-controller-resources/`, and
`control-center-resources/` (one file per chart + a `dashboard.json`, from before this
directory was consolidated) — recreate them via the same generator functions in
`build_resources_dashboards.py` when ready, then run `sync_dashboard_files.py` against the
result to fold them into the combined-file format like the other 5.

Every metric name and dimension key used below was verified against the live org's metric
catalog (`GET /v2/metric`, `GET /v2/metrictimeseries`) before being written into a
`programText` — not guessed. See the conversation this was built in for the verification
queries; the short version is in `../README.md`.

## Dashboards

| Dashboard | Panels | Covers | Live link |
|---|---|---|---|
| Kafka Broker Resources | 14 | Memory/CPU/JVM Heap gauges + Usage-vs-Limit trends, GC, Threads + Disk I/O, Disk Usage %, PVC Capacity, Log Directory Usage vs PVC | https://app.us1.observability.splunkcloud.com/#/dashboard/HQMnOAUA0Bs |
| Kafka Connect Resources | 8 | Memory/CPU/JVM Heap gauges + Usage-vs-Limit trends, GC, Threads | https://app.us1.observability.splunkcloud.com/#/dashboard/HQMnlVXA4AA |
| Schema Registry Resources | 15 | Memory/CPU/JVM Heap gauges + Usage-vs-Limit trends, GC, Threads + Leader Role, Node Count, Registrations/Deletions, Schemas by Format, API Success/Failure, TLS Cert Expiry | ⚠️ **unavailable** — see below |
| KRaft Controller Resources | 18 | Memory/CPU/JVM Heap gauges + Usage-vs-Limit trends, GC, Threads + Leader/Vote/Epoch, Metadata Error Count, High Watermark/LEO, Commit/Election Latency, Append/Fetch Rate | ⚠️ **unavailable** — see below |
| Control Center Resources | 8 | Memory/CPU/JVM Heap gauges + Usage-vs-Limit trends, GC, Threads | ⚠️ **unavailable** — see below |
| Kafka Cluster | 16 | Cluster health (Active Controllers, Brokers Online, Offline/Under-Replicated/Under-Min-ISR Partitions, Unclean Leader Election Rate), broker throughput, errors, CPU/JVM/GC/disk resources, cluster-wide message rate, consumer group lag, Produce/Consumer-Fetch tail latency (all percentiles) | https://app.us1.observability.splunkcloud.com/#/dashboard/HQM3KmKAwAI |
| Kafka Connect Cluster | 49 | Task counts/status, worker CPU/JVM/GC, worker network/IO/auth metrics, rebalance activity, per-connector-task batch/offset/error/source/sink record metrics | https://app.us1.observability.splunkcloud.com/#/dashboard/HQM38FJA4AA |

128 charts across the 7 dashboards by design (Resources: 63, down from an initial 93 — see
"Fixes applied after first render" below; Kafka/Connect Cluster: 65, straight through with
no post-render issues, since the fixes from the Resources tier were applied proactively
this time instead of discovered after the fact). **Only 87 are live right now** (128 minus
the 41 charts across the 3 missing dashboards below) — see the file-layout note above.

All 7 live in the `CFK - Splunk Observability Cloud POC` dashboard group
([`dashboard-group.json`](dashboard-group.json)).

## Translation notes (SPL → SignalFlow)

- **Ratio/"Usage vs Limit" panels**: two `data()` streams published side by side (line
  charts) or divided into one `(a/b*100)` stream (the `%` single-value panels) — same
  arithmetic as the SPL `append` + `eval value=round(used/capacity*100,2)` pattern, just
  expressed as SignalFlow instead of `mstats`/`eval`.
- **Rate-from-counter panels** (CPU Usage, GC Time, Schema Registry registration/deletion/
  API success-failure counters): SignalFlow's `.rate()` was tried first and found to be
  unreliable against this org's 30s federate-scrape cadence — it produced a single
  unlabeled series spiking to impossible values (700+ "cores" on a 12-core machine; see
  `../otel-collector-values.docker-desktop.yaml` and the CPU chart fix in this repo's
  history). Every rate calculation here instead uses an explicit 2-minute timeshift delta —
  `(raw - raw.timeshift('2m')) / 120` — which doesn't depend on `.rate()`'s internal
  normalization. This is the SignalFlow equivalent of the SPL's `streamstats`-based
  `(value-prev_value)/(_time-prev_time)` delta, with the same counter-reset exposure the
  SPL's `value>=prev_value` guard was written to avoid — not reproduced here (SignalFlow has
  no direct equivalent of that guard), so a pod restart mid-window can show one artificially
  large negative dip. Low risk on this single-instance POC; worth revisiting if this
  template is adapted for a cluster where restarts are more frequent.
- **Already-rate-typed JMX meters** (`kafka_server_raft_metrics_append_records_rate`,
  `fetch_records_rate`): published directly, no delta applied — matches the SPL, which
  didn't rate-ize these either (Kafka's own Yammer `Meter` metrics report already
  computed as events/sec, not as cumulative counters).
- **Legend**: every multi-series line chart sets `onChartLegendOptions.dimensionInLegend =
  "plot_label"`, so the distinct `.publish(label=...)` series (Usage/Limit, Avg/Max,
  Read/Write, etc.) show by name — not `"pod"`, since every chart here is scoped to one
  pod and the series identity comes from the `label=` argument instead.
- **Gauge panels**: Splunk's `splunk.singlevalueradial` maps to a SignalFx `SingleValue`
  chart with `secondaryVisualization: "Radial"` — the closest real equivalent on this
  platform (confirmed via a live test chart + `GET` readback before mass-generating,
  since the field names aren't the same casing/shape as the Terraform provider docs
  imply: it's `secondaryVisualization` / `maximumPrecision` / `timestampHidden`, not
  `secondary_visualization` / `max_precision` / `is_timestamp_hidden`).
- **Section headers** (Splunk's `splunk.markdown` dividers): not reproduced. There's no
  direct per-chart equivalent in this API; panel titles carry the same information.
- **Color thresholds** (the Splunk dashboards' `majorColor`/`context` red/amber/green
  rules on things like Metadata Error Count, Active Controllers): not reproduced for
  those panels — only the resource-percentage gauges (Memory/CPU/JVM Heap/Disk Usage
  %) got banding, see "Fixes applied after first render" below. Straightforward to
  extend to other single-value panels later via the same `colorScale2` mechanism.
- **Single-pod scope**: every panel here is filtered to this POC's one pod per component
  (`kafka-0`, `connect-0`, `schemaregistry-0`, `kraftcontroller-0`, `controlcenter-0`) —
  matching the Splunk dashboards' `$pod$` token defaulting to a single value in practice on
  this single-instance cluster, but hardcoded here rather than templated, since
  Observability Cloud's dashboard-level `filter`/`variable` mechanism works differently
  from Splunk's token substitution. Re-run `build_resources_dashboards.py` with different
  pod names if this is adapted to a multi-broker cluster.

## Fixes applied after first render

Chart creation only validates SignalFlow *syntax*, not whether the result renders or
looks right — three real problems surfaced only once the dashboards were actually
viewed live:

1. **Every `%` gauge (Memory/CPU/JVM Heap/Disk Usage) rendered blank.** Root cause,
   confirmed via `GET /v2/metrictimeseries`, not guessed: the two metrics being
   divided in each ratio come from different scrape sources (e.g.
   `container_memory_working_set_bytes` from cAdvisor vs
   `kube_pod_container_resource_limits` from kube-state-metrics) and carry
   completely different "extra" dimensions (`server.address`, `id`, `uid`, `unit`,
   ...) even once both are filtered to the same pod. SignalFlow's `a/b` join
   matches on those extra dimensions, finds nothing in common, and silently
   returns no data instead of erroring. Fixed by calling `.sum()` (no `by`) on
   both sides before dividing — safe here since each side is already filtered
   down to exactly one real series, so this only strips the mismatched noise
   dimensions, not real data.
2. **Even after fix 1, the gauges were still blank.** A second, independent issue:
   `colorBy: "Dimension"` (the option used on every other chart in this repo)
   renders nothing at all for a `SingleValue` chart with `secondaryVisualization:
   "Radial"` — the gauge visualization requires `colorBy: "Scale"` plus an explicit
   `colorScale2` (a list of green/amber/red-banded ranges) to know how to draw its
   arc at all. Confirmed by creating one real test chart, switching it live between
   configurations, and checking the actual render — not inferred from
   documentation, since none was found describing this requirement. The banding
   thresholds (<70% green, 70–90% amber, ≥90% red) use `paletteIndex` values
   `18`/`6`/`16`, also confirmed live (no authoritative index→color mapping was
   found either). As a result, the separate `Usage (GB)`/`Limit (GB)`/
   `Usage (cores)`/`Limit (cores)`/`Used (GB)`/`Max (GB)` single-value tiles that
   originally sat next to each gauge were removed (30 charts deleted across the 5
   dashboards) — once the gauge actually renders, it conveys allocated-vs-used on
   its own, and the raw GB/core values are still visible in each section's
   "Usage vs Limit" line chart.
3. **Layout: every gauge sat alone in its own row with ~8 columns of dead space
   beside it.** A side effect of fix 2 — once each resource-type section dropped
   from 4 charts (line + gauge + 2 tiles) to 2 (line + gauge), the original packer
   (line charts always full-width 12, single-values always packed 3-per-row 4-wide
   underneath) put a lone gauge by itself with nothing to its right. Fixed by
   pairing each line chart with the single-value immediately following it,
   side by side in the same row (line width 8, gauge width 4) — any single-value
   *not* immediately following a line still packs 3-per-row, and any line *not*
   immediately followed by a single-value packs 2-per-row at width 6 instead of
   sitting full-width alone.

## Kafka Cluster / Connect Cluster (`build_functional_dashboards.py`)

Ports `Kafka_splunk.json` and `Connect_splunk.json` — cluster health, throughput,
worker resources, and per-connector-task metrics, as opposed to the Resources tier's
pure Memory/CPU/JVM Heap focus. Every metric name here was freshly re-verified
against the live catalog (a distinct set from the Resources tier's metrics), and the
fixes already learned from that tier — no `.rate()`, no un-normalized cross-metric
division, `colorBy: "Scale"` for anything colored — were applied proactively rather
than discovered after the fact, so these 65 charts went in clean on the first pass.

Two more real things surfaced building this tier specifically:

1. **Non-radial `colorScale2` needs the opposite bound shape from the Resources
   gauges.** The Resources tier's Radial gauges required fully **closed** outer
   bounds (`{"gte": 0, "lt": 70, ...}` covering 0–100 with no gaps) — a plain
   `SingleValue` *without* `secondaryVisualization: "Radial"` rejects that shape
   outright (`"Missing open ended range(s)"`) and instead requires **open-ended**
   outer bounds (`{"lte": 0, ...}` / `{"gt": 0, ...}`, no upper/lower limit at the
   extremes). Used for the binary and three-state health-status singlevalues here
   (Active Controllers, Offline Partitions, Under Replicated/Min-ISR Partitions,
   Unclean Leader Election Rate) — confirmed live before applying broadly, same as
   every other `colorScale2` discovery.
2. **SignalFlow rejects a program that binds the same variable name twice.**
   Concatenating two independently-built rate-delta snippets (e.g. Broker Network
   Throughput's bytes-in and bytes-out, each of which declares a local `raw`) into
   one chart's `programText` produced `"scope contains multiple bindings of 'raw'
   of type 'NAME'"`. Fixed by giving each snippet a unique variable name
   (`raw_in`/`raw_out`) when multiple rate calculations are combined in a single
   program — caught before the second chart in the batch, not after a full blind run.

**Deliberate scope cuts** (documented, not silently dropped): `splunk.markdown`
section headers (no per-chart equivalent, same as the Resources tier); the "Task
Repartition per Status" `splunk.pie` chart (redundant with the six task-count
single-values it's built from — same judgment call already applied in the source
Splunk Cloud translation per `../../splunk/dashboards/NOTES.md`); and both
`splunk.table` panels (`Connectors (by status, by connector)`, `Connect Worker
Metrics (by instance)`) — both pivot with SPL's `xyseries` into a matrix shape with
no verified List/Heatmap-chart equivalent on this platform, so they're skipped
rather than guessed at.

**Zero live data right now, by design, not a bug**: the Connect Cluster dashboard's
Task Metrics / Task Errors / Source Task / Sink Task sections (23 panels) are scoped
to `connector`/`task` dimensions that only exist once a real connector is deployed —
confirmed via `curl :8083/connectors` returning `[]` on this cluster. These panels
will show "No Data" until a connector actually exists, exactly matching what the
equivalent SPL panels in `Connect_splunk.json` would show against this same cluster
right now. Built anyway for full parity with the source dashboard's coverage.

## Regenerating / updating

Two different tools, two different jobs:

- **`build_resources_dashboards.py`** / **`build_functional_dashboards.py`** create
  dashboards **from scratch** — every `POST /v2/chart` + `POST /v2/dashboard` call,
  from the panel definitions in the script itself. `single_value()` bakes in the
  gauge color-scale fix for every `radial=True` chart, `core_panels()` no longer
  generates the 6 removed tiles per component, and `layout_rows()` pairs each line
  chart with its immediately-following single-value — so both scripts reflect the
  current design, and both now write the combined one-file-per-dashboard output
  described above. **Not idempotent**: re-running either against an org that
  already has these dashboards creates new, duplicate objects rather than updating
  the existing ones — only use them against an empty org (recreating one of the 3
  currently-missing dashboards, for instance).
- **`sync_dashboard_files.py`** goes the other direction — it never creates or
  changes anything live, it only re-pulls a dashboard's current state (every chart,
  fresh via `GET`) back into its combined JSON file. Run this after any manual
  `PUT`/`DELETE` patch against the API (the gauge/layout fixes below were all
  applied this way — targeted one-off patches, not full script re-runs — so this
  is what kept the checked-in files honest afterward).

```bash
export SFX_TOKEN=<your Splunk Observability Cloud access token>

# Create fresh (only against an org that doesn't already have these):
python3 build_resources_dashboards.py
python3 build_functional_dashboards.py

# Re-sync a file with what's actually live, after a manual patch:
python3 sync_dashboard_files.py broker-resources kafka-cluster
python3 sync_dashboard_files.py --all
```

## Not yet done

Per the scoping decision made when this was built: `Enterprise_Tiered_Observability_splunk.json`
(a cross-cutting three-tier rollup of infrastructure/platform/business metrics
spanning both the Resources and Cluster tiers above) is not yet ported. Unlike the
other dashboards when they were started, nothing in its metric set is unverified at
this point — every metric family it references was already confirmed against this
org's catalog while building the Resources and Cluster tiers above; porting it is
mostly a matter of reassembling already-proven queries into a new dashboard, not
fresh verification work.
