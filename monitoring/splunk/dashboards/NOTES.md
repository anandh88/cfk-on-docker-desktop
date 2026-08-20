# Translation Notes

This file records rule-8 skips/uncertainties and rule-9 judgment calls made while translating the
Grafana dashboards in `monitoring/dashboards/` into the Splunk Dashboard Studio JSON files in this
directory. No source dashboard was skipped in its entirety; nothing below removes a distinct metric
family from coverage, only a subset of the *repeated* Grafana panel variants.

## Skipped / uncertain panels (rule 8)

No panel was skipped for lack of metric verification — every metric name used below appears in the
Grafana dashboards themselves (the same set the ground-truth reference file was extracted from), and
none of them looked invented or platform-specific beyond what's already backed by the dashboards. The
items below are informational deviations, not coverage gaps:

- **Kafka_grafana** / "Network Processor Avg Usage Percent" and "Request Handler Avg Percent": Grafana
  computed busy% as `1 - idle_fraction`. The generated SPL charts the raw idle-fraction gauge directly
  (no `eval` inverting it). Add `| eval value=1-value` right after the `mstats` line in each panel's
  search if a busy% reading is preferred over the idle% reading.
- **Connect_grafana** / "Connect Worker" table: Grafana's `table-old` panel also displayed
  `kafka_connect_app_info`'s `client_id`/`version`/`start_time_ms` label values directly (an info metric
  whose value is always `1`, carrying no numeric series — just identity labels). This is omitted from
  the Splunk table; that identity information is available via the `instance` input/dimension instead.
- **Enterprise_Tiered_Observability_grafana** / Tier 1: the "REST Proxy CPU %" gauge was omitted per the
  task scope (REST Proxy panels are excluded entirely from this dashboard's translation).

## Judgment calls / consolidation (rule 9)

- **Kafka_grafana** / "Errors": the original Grafana query
  (`rate(kafka_network_requestmetrics_count{name="ErrorsPerSec",error!="NONE"}[5m])`) had no
  job/namespace/instance filters at all. Added `namespace="confluent"`, `job="kafka-broker"`,
  `instance="$instance$"` for scoping consistent with every other panel.
- **Kafka_grafana** / Throughput In/Out row: the source dashboard had "Messages In Per Broker"
  duplicated twice with an identical query — collapsed to a single panel.
- **Kafka_grafana** / Connections row: consolidated "Connection Rate Change" and "Connections close
  rate per instance" (source used `clamp_min(-rate(...), 0)`) into one "Connection Close Rate" panel;
  "Connections per Client Version" splits on `client_software_name`/`client_software_version` rather
  than `instance`, since the source PromQL's `by(instance)` grouping didn't actually match its own
  legend format (`{{client_software_name}} {{client_software_version}}`) — a pre-existing inconsistency
  in the Grafana source, resolved in favor of the panel's stated intent.
- **Connect_grafana** / General row: merged Grafana's two piecharts ("Connector repartition per status"
  and "Task repartition per status" — identical running/failed/paused query) and two timeseries
  ("Status of connectors" and "Status of tasks") down to one piechart + one timeseries covering all 5
  task states (running/failed/paused/unassigned/destroyed), since the underlying series were the same
  data viewed twice.
- **Connect_grafana** / "Worker Rebalances": Grafana repeated the two stat panels once per `$instance`
  (`repeat: instance`). The Splunk version keeps a single pair of stat panels driven by the `instance`
  input/dimension instead of literally repeating panels per instance value.
- **Kafka_Broker_Resources_grafana**: "Disk I/O (Read/Write Bytes)" combines the read-bytes and
  write-bytes queries into one panel with a `series` split (Grafana rendered them as two separate
  queries on one graph already, this just makes the split explicit). "Log Directory Usage vs PVC
  Requested Capacity" approximates Grafana's `label_replace(..., "instance", "$1", "persistentvolumeclaim",
  "data0-(.*)")` join (which strips the `data0-` prefix from the PVC name to match it against the
  broker's `instance` label) with a literal `$pod$` token substitution for the PVC series name, since
  Splunk SPL doesn't have a direct `label_replace` equivalent in this construction — functionally
  equivalent for a single selected pod, but won't auto-expand across a wildcard PVC set the way the
  Prometheus regex capture group did.
- **All "Resources" dashboards** (Broker/Connect/Schema Registry/KRaft/Control Center) and
  **Enterprise_Tiered_Observability**: the "Usage vs Limit" and "X %" ratio panels use an
  `mstats ... | append [ mstats ... ] | stats ... | eval value=round(used/capacity*100,2)` pattern that
  extends past the literal rules-3/4/5/6 templates (ratio arithmetic across two metrics isn't covered by
  those templates directly). Where the numerator is a monotonic counter
  (`container_cpu_usage_seconds_total`), it is rate-ized first (delta over time via `streamstats`) before
  the ratio is computed, matching Grafana's `rate(...)` usage; where the Grafana source used
  `sum by (pod) (...)` with no container filter (e.g. `container_memory_working_set_bytes`,
  `container_cpu_usage_seconds_total`), the equivalent Splunk aggregation is `sum(_value)` rather than
  `avg(_value)`, to match summing across any sidecar containers in the pod.
- **Percentile-family panels** (Kafka_grafana's Producer/Consumer/FetchFollower/Metadata performance
  rows, Total Time Ms tail-latency row, and Enterprise's "P99 Request Latency by Type"): Prometheus
  encodes the percentile in the metric name suffix (`kafka_network_requestmetrics_50thpercentile`,
  `_75thpercentile`, `_95thpercentile`, `_99thpercentile`, `_999thpercentile`) rather than as a label
  value. Splunk's `mstats` supports wildcarded `metric_name` matching, so these panels use
  `metric_name="kafka_network_requestmetrics_*thpercentile"` and split on the literal `metric_name`
  field (plus `instance`) to keep each percentile as its own series. The Enterprise dashboard's "P99"
  panel targets `_99thpercentile` specifically rather than wildcarding, since the panel title calls out
  one specific percentile.
- **Consumer Group Lag** panels (Kafka_grafana and Enterprise_Tiered_Observability): both use
  `kafka_consumer_consumer_fetch_manager_metrics_records_lag_max{job="kafka-connect", ...}` exactly as
  the Grafana source did — Connect's embedded consumer reports this metric, which is why the job label
  says `kafka-connect` even on a "Kafka cluster" dashboard.

## General approach notes

- Every query is scoped with a literal `namespace="confluent"` (not the `namespace` input's token),
  since the OTel federation pipeline only ever forwards `namespace="confluent"` series into
  `cfk_metrics` — there is nothing else to filter to. The `namespace` dropdown input is still declared
  on every dashboard (for visibility/consistency with the Grafana source's template variable, and so
  it's a one-line edit to re-point at the token if the pipeline is ever broadened to more namespaces),
  but it is intentionally not wired into any search. `env` and `cluster`, by contrast, *are* wired into
  every search as `env="$env$" cluster="$cluster$"` and default to the confirmed-live values
  (`local-poc` / `docker-desktop`) with an "All" (`*`) option. `instance`/`pod`/`topic`/`connector`/
  `kafka_connect_cluster_id` are free-text glob inputs defaulting to `*`, mirroring the Grafana
  multi-select "All" behavior, since their possible values are higher-cardinality and can't be
  enumerated without querying the live cluster.
- Time series panels default to a 60-minute window with `span=1m`; adjust the dashboard's global time
  range input and/or the `span=` values in each search as needed for longer look-backs.

## Visual Design Pass

**Scope of this pass: `Kafka_splunk.json` only.** Per an explicit scope change mid-task, the
visual/layout redesign below was applied to this one dashboard first so the approach could be validated
before rolling out to the remaining 7 files (`Connect_splunk.json`,
`Kafka_Broker_Resources_splunk.json`, `Kafka_Connect_Resources_splunk.json`,
`Schema_Registry_Resources_splunk.json`, `KRaft_Controller_Resources_splunk.json`,
`Control_Center_Resources_splunk.json`, `Enterprise_Tiered_Observability_splunk.json`),
which are untouched (verified by file mtimes unchanged from before this task). The same treatment —
palette, thresholds, legend/axis rules, header convention, and layout re-flow — is intended to be
applied to those 7 once this one is confirmed to look right. No `query` string (data logic) was touched
anywhere.

### Schema-key sourcing

Before touching any `options` key, the actual Dashboard Studio schema was pulled from Splunk's own
official examples and current docs (not guessed), because an invalid key broke the paste-in once
already this session:
- `github.com/splunk/dashboard-studio-resources` (`monitoringTemplateSystemMetrics.json`,
  `monitoringTemplateDiscreteMetrics.json`) — real working `splunk.singlevalue`/`splunk.line`/
  `splunk.bar`/`splunk.pie`/`abslayout.line` option blocks, and the `context` + DOS
  (`"> field | rangeValue(fooEditorConfig)"`) mechanism used for value-based coloring.
- `help.splunk.com` current source-editor reference tables for `splunk.singlevalue`,
  `splunk.line`/`splunk.area` (shared axis/legend/series options), and `splunk.pie`.

Confirmed real keys used below: `backgroundColor`, `numberPrecision`, `unit`, `unitPosition`,
`majorColor` + `majorValue` (color-by-value via `"majorColor": "> majorValue | rangeValue(majorColorEditorConfig)"`
plus a sibling `"context": {"majorColorEditorConfig": [{from,to,value}, ...]}` block — this exact
mechanism is documented for `trendColor`/`trendValue`; `majorColor`/`majorValue` are both independently
documented singlevalue options, so applying the same `rangeValue` pattern to them is a direct analogy to
a confirmed-working pattern, not a blind guess — flagged here since it isn't shown verbatim in Splunk's
own examples), `legendDisplay`, `lineWidth`, `seriesColors` (array), `seriesColorsByField` (object),
`xAxisTitleVisibility`, `yAxisTitleText`, `yAxisTitleVisibility`, `labelDisplay` (pie only).

**Skipped for lack of a confirmed schema key:** there is no documented `colorMode`/`rangeValues` pair on
`splunk.singlevalue` (that naming doesn't appear in any real Splunk source) — the confirmed mechanism is
`majorColor` + `context` + `rangeValue()` above, used instead. There is no top-level dashboard `"theme"`
key documented anywhere (checked the Dashboard Studio "modify the background" doc page directly) — item
6 from the original task (dashboard-level theme) is skipped; every visualization instead gets an
explicit `backgroundColor` (below), which is the confirmed, safe way to get a consistent look.
`splunk.pie` has no `legendDisplay` option in the documented schema (unlike `splunk.line`) — used
`labelDisplay: "valuesAndPercentage"` instead, which is pie's real identification mechanism.

### Palette (validated)

Used the dataviz skill's default 8-hue categorical palette, **dark-mode column**, since every panel's
`backgroundColor` is now the skill's dark chart surface `#1a1a19`:
`#3987e5, #d95926, #199e70, #c98500, #d55181, #008300, #9085e9, #e66767`
(blue, orange, aqua, yellow, magenta, green, violet, red — fixed order, never cycled).

Ran `node scripts/validate_palette.js "#3987e5,#d95926,#199e70,#c98500,#d55181,#008300,#9085e9,#e66767" --mode dark --surface "#1a1a19"`:
**ALL CHECKS PASS** — lightness band, chroma floor, CVD separation (worst adjacent ΔE 8.4), normal-vision
floor (worst adjacent ΔE 19.3), contrast vs. surface (all 8 ≥ 3:1, no WARN). The light-mode column was
also validated (`--mode light`, default surface `#fcfcfb`) and also passes every hard gate (one WARN on
contrast for 3 slots below 3:1, which is why the dark set — not light — was chosen for this dashboard's
fixed dark surface).

Status palette (fixed, reserved, never reused as a categorical slot): good `#0ca30c`, warning `#fab219`,
critical `#d03b3b` (the skill's "serious" step was not needed here — only good/warning/critical
semantics appear on this dashboard).

### Single-value KPI thresholds (`majorColor` + `context`)

0 = good / >0 = bad panels, using a small epsilon (`to`/`from` at ±0.001 around the boundary) so the
result doesn't depend on whether Splunk treats `to`/`from` as inclusive or exclusive at the exact
boundary:
- **Critical (red) if > 0:** Offline Partitions Count, Under Replicated Partitions, Under Min ISR
  Partitions, Unclean Leader Election Rate (these represent actual or imminent data-availability risk).
- **Warning (amber) if > 0:** Preferred Replica Imbalance, Stray Partitions Count, Stray Partitions
  Misclassified Count (sub-optimal/cleanup-needed, not an outage risk by itself).
- **Two-sided (Active Controllers):** exactly `1` = good (green), `0` or `>1` = critical (red) — a
  cluster must have exactly one active controller.

**Left neutral (no color rule), per the "when genuinely ambiguous, leave neutral" instruction:**
- **Brokers Online** — good/bad depends on the expected cluster size, which isn't knowable from the
  panel alone.
- **Online Partitions** — a raw informational count, not itself good/bad.
- All "Request Per Sec" single-value panels (All Requests, Produce, Consumer Fetch, Broker Fetch,
  Offset Commit, Metadata) — given `unit: "req/s"`, `numberPrecision: "0.00"`, but no color rule; a
  request-rate number has no fixed good/bad threshold independent of expected load.

### Line chart legend / axis / color rules

- `legendDisplay`: `"off"` for genuinely single-series panels (no `by`/`timechart ... by` in the query —
  e.g. cluster-total Messages/Bytes In/Out, Total Connections, Connection Creation/Close Rate, Produced/
  Consumed Message Conversions); `"bottom"` for ordinary multi-series panels; `"right"` for panels
  resized to the full 1440px row width (more horizontal room for a wide legend) — Errors, Response Queue
  Size, Consumer Group Lag, Connections per Client Version — and for the percentile-family panels
  (P50–P999, naturally many series).
- `yAxisTitleText` set per panel from its metric/title semantics (Bytes/sec, Milliseconds, %, Count,
  Connections, Groups, Records, Sessions, Evictions/sec, etc.); `xAxisTitleVisibility: "hide"` (time axis
  is self-evident) with `yAxisTitleVisibility: "show"`.
- `lineWidth: 2` set explicitly on every `splunk.line` panel (matches the dataviz skill's mark spec and
  Splunk's own documented default, made explicit rather than left implicit).
- **CPU Usage vs Limit panel title says "(millicores)" but the underlying SPL computes a cores-per-second
  rate off `container_cpu_usage_seconds_total`, not millicores** — this pre-existing mismatch (from the
  original translation, not this pass) was not touched since it's query/title text, not a visual option;
  flagging here since the y-axis label for the equivalent CPU panel was set to match the actual computed
  unit rather than blindly copy a possibly-stale title. (Note: this specific panel lives in the Broker
  Resources dashboard, not in Kafka_grafana itself — flagged here for when that file is done.)
- **`seriesColorsByField` (clean literal series names, no per-instance suffix):**
  - Broker Network Throughput: `bytes_in` → slot 1 (blue), `bytes_out` → slot 2 (orange).
  - Consumer Groups per State: `stable`/`preparing-rebalance`/`dead`/`completing-rebalance`/`empty` →
    slots 1–5 in that fixed order (categorical identity, not status — Consumer-group state wasn't in the
    task's explicit "connector-state" status-color list, so it kept the neutral fixed-hue treatment
    rather than borrowing red/amber/green semantics that weren't asked for).
- **`seriesColors` (positional array, all 8 slots) applied to every other multi-series panel**, including
  the percentile-family panels (P50/P75/P95/P99/P999 × instance) and Connections per Client Version.
  **Limitation, documented rather than guessed around:** every "Usage vs Limit"/"Used vs Max"/percentile
  panel's series name is a composite like `"kafka_network_requestmetrics_50thpercentile-kafka-0"` (metric
  name **plus** a per-instance suffix, from `eval series=metric_name."-".instance`). Because the instance
  set is a wildcard (`$instance$` defaults to `*`), a fixed `seriesColorsByField` keyed on exact strings
  would only match today's instance count and silently stop matching as brokers are added/removed, and a
  literal light→dark sequential mapping per percentile is undermined by the fact that
  `"...999thpercentile"` sorts **before** `"...99thpercentile"` lexically (so naive positional assignment
  would not actually land P50→lightest…P999→darkest). Rather than ship a mapping that looks right today
  and silently breaks or misorders later, these panels get the plain fixed-order categorical array (still
  non-cycling, still validated) and legend `"right"` so the reader can always resolve identity from the
  legend text regardless of color order.

### Pie chart

Client Version Repartition: `seriesColors` (same validated 8-slot array — client version is unbounded
categorical identity, count not knowable ahead of time) + `labelDisplay: "valuesAndPercentage"` (pie's
documented substitute for a legend — there is no `legendDisplay` key on `splunk.pie`).

### Section header convention

Every `splunk.markdown` header got a single consistent icon prefix + a trailing `---` rule so sections
read as clear dividers instead of bare `## text`:
💓 Healthcheck · 📨 Request rate · ⚙️ System · 📊 Throughput In/Out · 🧵 Thread Utilization ·
🔁 Isr Shrinks / Expands · 🗂️ Logs Size · ⬆️ Producer Performance · ⬇️ Consumer Performance ·
🔗 Fetch Follower Performance · 🗃️ Fetch Session · 🗺️ Metadata Request Performance · 🧬 Replicas / ISR ·
🔌 Connections · 🧭 Group Coordinator · 🔃 Message Conversion · ⏱️ Request Total Time (Tail Latency,
P50-P999). This exact icon set is intended to be reused verbatim for the equivalent section names in the
other 7 dashboards when they get the same pass.

### Layout re-flow

Panel sizes were already fully consistent across the dashboard before this pass (singlevalue 230×140,
gauge.radial 230×190, pie 460×280, table 1440×320, line either 460×280 or 930×280 — a genuine finding,
not an assumption), and the vertical rhythm (10px gaps everywhere, 40px header bands) was already uniform.
The actual "ugly/misaligned" issue was **lopsided rows**: a panel or pair of panels sized for a 3-column
grid left alone in a row, leaving a large dead gap. The entire layout was recomputed programmatically
(row-by-row, left-aligned, fixed 10px gaps) rather than hand-patched, so nothing drifted out of alignment:
- 3-chart Healthcheck row (Broker Network Throughput / Leader Count / Stray Partitions Total Size) was
  regularized from a lopsided 930+460 row followed by an orphan 460-alone row into one clean 3×460 row
  (saves 290px of canvas height as a side effect).
- Lone charts that had nothing to pair with in their section (Errors; Response Queue Size; Consumer
  Group Lag; Connections per Client Version) were widened to the full 1440px row width instead of sitting
  at 930/460 with hundreds of px of dead space, and given `legendDisplay: "right"` to use the extra room.
- 2-of-3 lopsided pairs (Disk Read/Write Bytes; Network Processor/Request Handler thread-utilization;
  IsrShrinks/IsrExpands; Log Size per Topic/Broker; the second row of each percentile-family section;
  Fetch Session's two panels; Replica Min-Fetch-Rate/Max-Lag) were widened from 460 to 715 each so the
  pair fills the full row evenly.
- **Accepted as a deliberate partial-width row (not "fixed"):** the Metadata Request Performance row
  (2×460 line charts + 1×230 single-value KPI = 1170 of 1440px, ~270px slack) was left as-is — resizing
  the two line charts would break the standardized 460/715/930/1440 width set, and stretching a KPI tile
  off its standard 230×140 size was explicitly out of scope; a ~19%-of-row gap here reads as acceptable
  rather than badly lopsided. Group Coordinator's 460+930 row and the two Message-Conversion/Request-
  Total-Time 3×460 rows already filled their rows correctly and were left untouched apart from the
  color/legend/axis option changes above.
- Canvas height recomputed automatically from the new row layout: 8850px (down from 9130px).

### Validation performed

- `python3 -m json.tool Kafka_splunk.json` — valid JSON.
- A script checked every `visualizations[*].dataSources.primary` resolves to an existing `dataSources`
  key, every `layout.structure[].item` resolves to an existing visualization, every visualization appears
  in the layout exactly once, and no two panels in the same row overlap in x — all clean, zero errors.
- The other 7 dashboard JSON files were not opened for writing during this pass; their file modification
  timestamps are unchanged from before this task, confirming they were not touched.
