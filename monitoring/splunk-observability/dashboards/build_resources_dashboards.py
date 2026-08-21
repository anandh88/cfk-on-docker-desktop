#!/usr/bin/env python3
"""
Generates + deploys the 5 CFK "Resources" dashboards in Splunk Observability
Cloud, mirroring monitoring/splunk/dashboards/*_Resources_splunk.json panel
composition and purpose, translated to SignalFlow (verified against the live
metric catalog first - see the conversation, not guessed).

Writes one clean JSON file per chart + one dashboard.json per component into
monitoring/splunk-observability/dashboards/<component>/, then creates the
real objects via the REST API (POST /v2/chart, POST /v2/dashboard) so the
checked-in JSON always matches what's actually live - same discipline as
every other artifact in this repo.

Auth: reads SFX_TOKEN from the environment. Never hardcode the token here.
"""
import json
import os
import sys
import urllib.request
import urllib.error

TOKEN = os.environ["SFX_TOKEN"]
API = "https://api.us1.observability.splunkcloud.com"
OUT_ROOT = "/Users/anandhvasu/Documents/monitoring/cfk-on-docker-desktop-github/monitoring/splunk-observability/dashboards"
GROUP_ID = "HQMTCAaAwAE"  # existing "CFK - Splunk Observability Cloud POC" group


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{API}{path}", data=data, method=method,
                                  headers={"X-SF-TOKEN": TOKEN, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"ERROR {method} {path}: {e.read().decode()}", file=sys.stderr)
        raise


# ---------------------------------------------------------------------------
# SignalFlow program builders
# ---------------------------------------------------------------------------

def f(pairs):
    """('namespace','confluent'), ('pod','kafka-0') -> filter('namespace', 'confluent') and filter('pod', 'kafka-0')"""
    return " and ".join(f"filter('{k}', '{v}')" for k, v in pairs)


def direct(metric, filters, scale=None, label="value"):
    expr = f"data('{metric}', filter={f(filters)})"
    if scale:
        expr = f"({expr} / {scale})"
    return f"{expr}.publish(label='{label}')\n"


def ratio_pct(metric_a, filters_a, metric_b, filters_b, label="value"):
    # .sum() (no `by`) strips every dimension before dividing - required because
    # the two sides of every ratio panel here come from different scrape sources
    # (e.g. cAdvisor vs kube-state-metrics) that carry different "extra" dimensions
    # (server.address, id, uid, unit, ...) even once both are filtered down to the
    # same pod. SignalFlow's arithmetic join matches on those extra dimensions, so
    # without collapsing them first, a/b silently returns no data - confirmed via
    # a live GET /v2/metrictimeseries dimension diff between the two metrics, not
    # guessed. Safe here because each filter already scopes to exactly one series.
    return (
        f"a = data('{metric_a}', filter={f(filters_a)}).sum()\n"
        f"b = data('{metric_b}', filter={f(filters_b)}).sum()\n"
        f"(a/b*100).publish(label='{label}')\n"
    )

def two_line(metric_a, filters_a, label_a, metric_b, filters_b, label_b, scale=None):
    ea = f"data('{metric_a}', filter={f(filters_a)})"
    eb = f"data('{metric_b}', filter={f(filters_b)})"
    if scale:
        ea, eb = f"({ea} / {scale})", f"({eb} / {scale})"
    return f"{ea}.publish(label='{label_a}')\n{eb}.publish(label='{label_b}')\n"

def delta_rate(metric, filters, label="value", window_min=2, pct=False):
    w = f"{window_min}m"
    secs = window_min * 60
    expr = f"((raw - raw.timeshift('{w}')) / {secs})"
    if pct:
        expr = f"({expr} * 100)"
    return (
        f"raw = data('{metric}', filter={f(filters)})\n"
        f"{expr}.publish(label='{label}')\n"
    )

def two_delta(metric_a, filters_a, label_a, metric_b, filters_b, label_b, window_min=2):
    w = f"{window_min}m"
    secs = window_min * 60
    return (
        f"raw_a = data('{metric_a}', filter={f(filters_a)})\n"
        f"((raw_a - raw_a.timeshift('{w}')) / {secs}).publish(label='{label_a}')\n"
        f"raw_b = data('{metric_b}', filter={f(filters_b)})\n"
        f"((raw_b - raw_b.timeshift('{w}')) / {secs}).publish(label='{label_b}')\n"
    )

def three_delta(specs, window_min=2):
    w = f"{window_min}m"
    secs = window_min * 60
    out = []
    for i, (metric, filters, label) in enumerate(specs):
        out.append(f"raw_{i} = data('{metric}', filter={f(filters)})")
        out.append(f"((raw_{i} - raw_{i}.timeshift('{w}')) / {secs}).publish(label='{label}')")
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# Chart JSON shapes
# ---------------------------------------------------------------------------

def line_chart(name, description, program_text, y_label=None, y_min=None, y_max=None):
    axis = {"label": y_label} if y_label else {}
    if y_min is not None:
        axis["min"] = y_min
    if y_max is not None:
        axis["max"] = y_max
    return {
        "name": name,
        "description": description,
        "programText": program_text,
        "options": {
            "type": "TimeSeriesChart",
            "defaultPlotType": "LineChart",
            "colorBy": "Dimension",
            "stacked": False,
            "includeZero": False,
            "axisPrecision": 3,
            "unitPrefix": "Metric",
            "lineChartOptions": {"showDataMarkers": False},
            "onChartLegendOptions": {"showLegend": True, "dimensionInLegend": "plot_label"},
            "programOptions": {"disableSampling": False, "timezone": "UTC"},
            "axes": [axis if axis else None, None],
        },
    }


# Green/amber/red banding for every radial % gauge. paletteIndex values confirmed
# live against the org (18=green, 6=amber, 16=red) - not from any documented
# mapping, since none could be found; verified by creating a real test chart,
# checking its rendered color, and asking for visual confirmation before rolling
# this out to the 16 real gauges.
GAUGE_COLOR_SCALE2 = [
    {"gte": 0, "lt": 70, "paletteIndex": 18},    # green
    {"gte": 70, "lt": 90, "paletteIndex": 6},     # amber
    {"gte": 90, "lte": 100, "paletteIndex": 16},  # red
]


def single_value(name, description, program_text, radial=False):
    options = {
        "type": "SingleValue",
        "unitPrefix": "Metric",
    }
    if radial:
        # colorBy: "Dimension" (the default used elsewhere) renders nothing at all
        # for a Radial secondary visualization - confirmed live: the gauge stayed
        # blank until switched to colorBy: "Scale" + an explicit colorScale2 band
        # list. Not documented anywhere found; discovered by testing a real chart.
        options["colorBy"] = "Scale"
        options["secondaryVisualization"] = "Radial"
        options["colorScale2"] = GAUGE_COLOR_SCALE2
    else:
        options["colorBy"] = "Dimension"
        options["secondaryVisualization"] = "None"
    return {
        "name": name,
        "description": description,
        "programText": program_text,
        "options": options,
    }


# ---------------------------------------------------------------------------
# Per-component core panel set (Memory / CPU / JVM Heap / GC / Threads)
# Mirrors the *_Resources_splunk.json core section exactly.
# ---------------------------------------------------------------------------

def core_panels(pod, container, service_name):
    p = [("namespace", "confluent"), ("pod", pod)]
    mem_filt = p
    mem_limit_filt = [("namespace", "confluent"), ("pod", pod), ("resource", "memory"), ("container", container)]
    cpu_limit_filt = [("namespace", "confluent"), ("pod", pod), ("resource", "cpu"), ("container", container)]
    heap_filt = [("namespace", "confluent"), ("service.name", service_name), ("area", "heap"), ("service.instance.id", pod)]
    gc_filt = [("namespace", "confluent"), ("service.name", service_name), ("service.instance.id", pod)]
    threads_filt = gc_filt

    panels = []
    panels.append(("line", "Container Memory Usage vs Limit (GB)",
        line_chart("Container Memory Usage vs Limit (GB)",
            "container_memory_working_set_bytes vs kube_pod_container_resource_limits{resource=memory}.",
            two_line("container_memory_working_set_bytes", mem_filt, "Usage",
                     "kube_pod_container_resource_limits", mem_limit_filt, "Limit", scale="1024/1024/1024"),
            y_label="GB")))
    # No separate Usage(GB)/Limit(GB) tiles - the gauge below conveys
    # allocated-vs-used on its own (per explicit request; the raw GB values are
    # still visible in the "Usage vs Limit" line chart above).
    panels.append(("sv", "Memory %",
        single_value("Memory %", "container_memory_working_set_bytes / kube_pod_container_resource_limits{resource=memory}, as a percentage.",
            ratio_pct("container_memory_working_set_bytes", mem_filt, "kube_pod_container_resource_limits", mem_limit_filt, "Memory %"),
            radial=True)))

    cpu_vs_limit_program = (
        f"raw = data('container_cpu_usage_seconds_total', filter={f(mem_filt)})\n"
        f"((raw - raw.timeshift('2m')) / 120).publish(label='Usage')\n"
        f"limit = data('kube_pod_container_resource_limits', filter={f(cpu_limit_filt)})\n"
        f"limit.publish(label='Limit')\n"
    )
    panels.append(("line", "CPU Usage vs Limit (cores)",
        line_chart("CPU Usage vs Limit (cores)",
            "container_cpu_usage_seconds_total (2-minute timeshift delta, not .rate() - see repo notes) vs kube_pod_container_resource_limits{resource=cpu}.",
            cpu_vs_limit_program,
            y_label="Cores")))
    panels.append(("sv", "CPU %",
        single_value("CPU %", "CPU cores used (2-minute timeshift delta) / kube_pod_container_resource_limits{resource=cpu}, as a percentage.",
            f"raw = data('container_cpu_usage_seconds_total', filter={f(mem_filt)}).sum()\n"
            f"usage = (raw - raw.timeshift('2m')) / 120\n"
            f"limit = data('kube_pod_container_resource_limits', filter={f(cpu_limit_filt)}).sum()\n"
            f"(usage/limit*100).publish(label='CPU %')\n",
            radial=True)))

    panels.append(("line", "JVM Heap Memory Usage vs Max (GB)",
        line_chart("JVM Heap Memory Usage vs Max (GB)",
            "jvm_memory_bytes_used{area=heap} vs jvm_memory_bytes_max{area=heap}.",
            two_line("jvm_memory_bytes_used", heap_filt, "Usage", "jvm_memory_bytes_max", heap_filt, "Max", scale="1024/1024/1024"),
            y_label="GB")))
    panels.append(("sv", "JVM Heap %",
        single_value("JVM Heap %", "jvm_memory_bytes_used{area=heap} / jvm_memory_bytes_max{area=heap}, as a percentage.",
            ratio_pct("jvm_memory_bytes_used", heap_filt, "jvm_memory_bytes_max", heap_filt, "JVM Heap %"),
            radial=True)))

    panels.append(("line", "GC Time (% of wall-clock)",
        line_chart("GC Time (% of wall-clock)",
            "2-minute timeshift delta of jvm_gc_collection_seconds_sum, as % of wall-clock time.",
            delta_rate("jvm_gc_collection_seconds_sum", gc_filt, label="GC Time %", pct=True),
            y_label="%")))
    panels.append(("sv", "Thread Count",
        single_value("Thread Count", "Raw jvm_threads_current.",
            direct("jvm_threads_current", threads_filt, label="Thread Count"))))

    return panels


# ---------------------------------------------------------------------------
# Component-specific extra panels
# ---------------------------------------------------------------------------

def broker_extra_panels(pod, service_name):
    disk_filt_read = [("namespace", "confluent"), ("service.name", service_name), ("name", "linux-disk-read-bytes"), ("service.instance.id", pod)]
    disk_filt_write = [("namespace", "confluent"), ("service.name", service_name), ("name", "linux-disk-write-bytes"), ("service.instance.id", pod)]
    size_filt = [("namespace", "confluent"), ("service.name", service_name), ("name", "Size"), ("service.instance.id", pod)]
    pvc_filt = [("namespace", "confluent"), ("persistentvolumeclaim", f"data0-{pod}")]

    panels = []
    panels.append(("line", "Disk I/O (Read/Write, MB)",
        line_chart("Disk I/O (Read/Write, MB)", "kafka_server_kafkaserver_value{name=linux-disk-read-bytes|linux-disk-write-bytes}, scaled to MB.",
            two_line("kafka_server_kafkaserver_value", disk_filt_read, "Read", "kafka_server_kafkaserver_value", disk_filt_write, "Write", scale="1024/1024"),
            y_label="MB")))
    panels.append(("sv", "Disk Usage %",
        single_value("Disk Usage %", "kafka_log_log_value{name=Size} / kube_persistentvolumeclaim_resource_requests_storage_bytes, as a percentage.",
            ratio_pct("kafka_log_log_value", size_filt, "kube_persistentvolumeclaim_resource_requests_storage_bytes", pvc_filt, "Disk Usage %"),
            radial=True)))
    panels.append(("sv", "PVC Capacity (GB)",
        single_value("PVC Capacity (GB)", "Raw kube_persistentvolumeclaim_resource_requests_storage_bytes.",
            direct("kube_persistentvolumeclaim_resource_requests_storage_bytes", pvc_filt, scale="1024/1024/1024", label="PVC Capacity (GB)"))))
    panels.append(("sv", "Disk Read (MB)",
        single_value("Disk Read (MB)", "Raw kafka_server_kafkaserver_value{name=linux-disk-read-bytes}.",
            direct("kafka_server_kafkaserver_value", disk_filt_read, scale="1024/1024", label="Disk Read (MB)"))))
    panels.append(("sv", "Disk Write (MB)",
        single_value("Disk Write (MB)", "Raw kafka_server_kafkaserver_value{name=linux-disk-write-bytes}.",
            direct("kafka_server_kafkaserver_value", disk_filt_write, scale="1024/1024", label="Disk Write (MB)"))))
    panels.append(("line", "Log Directory Usage (% of PVC Requested Capacity)",
        line_chart("Log Directory Usage (% of PVC Requested Capacity)", "kafka_log_log_value{name=Size} / kube_persistentvolumeclaim_resource_requests_storage_bytes, over time.",
            ratio_pct("kafka_log_log_value", size_filt, "kube_persistentvolumeclaim_resource_requests_storage_bytes", pvc_filt, "Log Dir Usage %"),
            y_label="%")))
    return panels


def schema_registry_extra_panels(pod, service_name):
    base = [("namespace", "confluent"), ("service.name", service_name), ("service.instance.id", pod)]
    panels = []
    panels.append(("sv", "Leader Role (1=leader/master)",
        single_value("Leader Role (1=leader/master)", "Raw kafka_schema_registry_master_slave_role_master_slave_role.",
            direct("kafka_schema_registry_master_slave_role_master_slave_role", base, label="Leader Role"))))
    panels.append(("sv", "Node Count",
        single_value("Node Count", "Raw kafka_schema_registry_node_count_node_count.",
            direct("kafka_schema_registry_node_count_node_count", base, label="Node Count"))))
    panels.append(("sv", "Leader Initialization Latency (ms)",
        single_value("Leader Initialization Latency (ms)", "Raw kafka_schema_registry_leader_initialization_latency_leader_initialization_latency.",
            direct("kafka_schema_registry_leader_initialization_latency_leader_initialization_latency", base, label="Leader Init Latency (ms)"))))
    panels.append(("line", "Schema Registrations / Deletions Rate",
        line_chart("Schema Registrations / Deletions Rate", "2-minute timeshift delta of registered_count and deleted_count.",
            two_delta("kafka_schema_registry_registered_count_registered_count", base, "Registered",
                      "kafka_schema_registry_deleted_count_deleted_count", base, "Deleted"),
            y_label="Schemas/sec")))
    panels.append(("line", "Schemas Created by Format",
        line_chart("Schemas Created by Format", "2-minute timeshift delta of avro/json/protobuf schemas created.",
            three_delta([
                ("kafka_schema_registry_avro_schemas_created_avro_schemas_created", base, "Avro"),
                ("kafka_schema_registry_json_schemas_created_json_schemas_created", base, "JSON"),
                ("kafka_schema_registry_protobuf_schemas_created_protobuf_schemas_created", base, "Protobuf"),
            ]),
            y_label="Schemas/sec")))
    panels.append(("line", "API Success vs Failure Rate",
        line_chart("API Success vs Failure Rate", "2-minute timeshift delta of api_success_count and api_failure_count.",
            two_delta("kafka_schema_registry_api_success_count_api_success_count", base, "Success",
                      "kafka_schema_registry_api_failure_count_api_failure_count", base, "Failure"),
            y_label="Requests/sec")))
    panels.append(("line", "TLS Certificate Time to Expiry (Keystore / Truststore)",
        line_chart("TLS Certificate Time to Expiry (Keystore / Truststore)", "Raw certificate_expiration_keystore / certificate_expiration_truststore (units as reported by the JMX metric - not independently re-verified here, matches the Splunk Cloud panel's own unlabeled axis).",
            two_line("kafka_schema_registry_certificate_expiration_keystore_certificate_expiration_keystore", base, "Keystore",
                     "kafka_schema_registry_certificate_expiration_truststore_certificate_expiration_truststore", base, "Truststore"))))
    return panels


def kraft_extra_panels(pod, service_name):
    base = [("namespace", "confluent"), ("service.name", service_name), ("service.instance.id", pod)]
    err_filt = [("namespace", "confluent"), ("service.name", service_name), ("name", "MetadataErrorCount"), ("service.instance.id", pod)]
    panels = []
    panels.append(("sv", "Current Leader (node id)",
        single_value("Current Leader (node id)", "Raw kafka_server_raft_metrics_current_leader.",
            direct("kafka_server_raft_metrics_current_leader", base, label="Current Leader"))))
    panels.append(("sv", "Current Vote (node id)",
        single_value("Current Vote (node id)", "Raw kafka_server_raft_metrics_current_vote.",
            direct("kafka_server_raft_metrics_current_vote", base, label="Current Vote"))))
    panels.append(("sv", "Current Epoch",
        single_value("Current Epoch", "Raw kafka_server_raft_metrics_current_epoch.",
            direct("kafka_server_raft_metrics_current_epoch", base, label="Current Epoch"))))
    panels.append(("sv", "Metadata Error Count (should be 0)",
        single_value("Metadata Error Count (should be 0)", "Raw kafka_controller_kafkacontroller_value{name=MetadataErrorCount}.",
            direct("kafka_controller_kafkacontroller_value", err_filt, label="Metadata Error Count"))))
    panels.append(("sv", "Unknown Voter Connections",
        single_value("Unknown Voter Connections", "Raw kafka_server_raft_metrics_number_unknown_voter_connections.",
            direct("kafka_server_raft_metrics_number_unknown_voter_connections", base, label="Unknown Voter Connections"))))
    panels.append(("sv", "Poll Idle Ratio (avg)",
        single_value("Poll Idle Ratio (avg)", "Raw kafka_server_raft_metrics_poll_idle_ratio_avg.",
            direct("kafka_server_raft_metrics_poll_idle_ratio_avg", base, label="Poll Idle Ratio"))))
    panels.append(("line", "High Watermark / Log End Offset",
        line_chart("High Watermark / Log End Offset", "Raw kafka_server_raft_metrics_high_watermark and log_end_offset.",
            two_line("kafka_server_raft_metrics_high_watermark", base, "High Watermark",
                     "kafka_server_raft_metrics_log_end_offset", base, "Log End Offset"))))
    panels.append(("line", "Commit Latency (avg / max)",
        line_chart("Commit Latency (avg / max)", "Raw kafka_server_raft_metrics_commit_latency_avg / _max.",
            two_line("kafka_server_raft_metrics_commit_latency_avg", base, "Avg",
                     "kafka_server_raft_metrics_commit_latency_max", base, "Max"),
            y_label="ms")))
    panels.append(("line", "Election Latency (avg / max)",
        line_chart("Election Latency (avg / max)", "Raw kafka_server_raft_metrics_election_latency_avg / _max.",
            two_line("kafka_server_raft_metrics_election_latency_avg", base, "Avg",
                     "kafka_server_raft_metrics_election_latency_max", base, "Max"),
            y_label="ms")))
    panels.append(("line", "Append / Fetch Records Rate",
        line_chart("Append / Fetch Records Rate", "Raw kafka_server_raft_metrics_append_records_rate / fetch_records_rate (already rate-typed JMX meters, no delta needed).",
            two_line("kafka_server_raft_metrics_append_records_rate", base, "Append",
                     "kafka_server_raft_metrics_fetch_records_rate", base, "Fetch"),
            y_label="Records/sec")))
    return panels


# ---------------------------------------------------------------------------
# Dashboard definitions
# ---------------------------------------------------------------------------

DASHBOARDS = [
    {
        "dir": "broker-resources",
        "title": "CFK Kafka Broker Resources (Docker Desktop)",
        "panels": core_panels("kafka-0", "kafka", "kafka-broker") + broker_extra_panels("kafka-0", "kafka-broker"),
    },
    {
        "dir": "connect-resources",
        "title": "CFK Kafka Connect Resources (Docker Desktop)",
        "panels": core_panels("connect-0", "connect", "kafka-connect"),
    },
    {
        "dir": "schema-registry-resources",
        "title": "CFK Schema Registry Resources (Docker Desktop)",
        "panels": core_panels("schemaregistry-0", "schemaregistry", "schemaregistry") + schema_registry_extra_panels("schemaregistry-0", "schemaregistry"),
    },
    {
        "dir": "kraft-controller-resources",
        "title": "CFK KRaft Controller Resources (Docker Desktop)",
        "panels": core_panels("kraftcontroller-0", "kraftcontroller", "kafka-controller") + kraft_extra_panels("kraftcontroller-0", "kafka-controller"),
    },
    {
        "dir": "control-center-resources",
        "title": "CFK Control Center Resources (Docker Desktop)",
        "panels": core_panels("controlcenter-0", "controlcenter", "controlcenter"),
    },
]


def slugify(title):
    return "".join(c if c.isalnum() else "-" for c in title.lower()).strip("-")


def layout_rows(panels):
    """Pack panels into a 12-col grid. A line chart immediately followed by exactly
    one single-value pairs with it side by side (line width 8 + sv width 4, same
    row) - the "Usage vs Limit" trend + its "%" gauge - rather than stacking them
    with the gauge left-aligned and mostly-empty space beside it (the original
    layout, corrected after live user feedback). Any single-value not immediately
    following a line packs 3-per-row (4x1); any line not immediately followed by a
    single value packs 2-per-row (6x2)."""
    items = [(title, kind == "line") for kind, title, chart in panels]
    n = len(items)

    pair_of = {}
    for idx in range(n):
        _, is_line = items[idx]
        if is_line and idx + 1 < n and not items[idx + 1][1]:
            pair_of[idx] = idx + 1

    layout = []
    row = [0]
    pending_lines, pending_svs = [], []

    def flush_lines():
        j = 0
        while j < len(pending_lines):
            if j + 1 < len(pending_lines):
                layout.append({"title": pending_lines[j], "row": row[0], "column": 0, "width": 6, "height": 2})
                layout.append({"title": pending_lines[j + 1], "row": row[0], "column": 6, "width": 6, "height": 2})
                j += 2
            else:
                layout.append({"title": pending_lines[j], "row": row[0], "column": 0, "width": 12, "height": 2})
                j += 1
            row[0] += 2
        pending_lines.clear()

    def flush_svs():
        col = 0
        any_ = False
        for title in pending_svs:
            layout.append({"title": title, "row": row[0], "column": col, "width": 4, "height": 1})
            col += 4
            any_ = True
            if col >= 12:
                col = 0
                row[0] += 1
        if any_ and col != 0:
            row[0] += 1
        pending_svs.clear()

    idx = 0
    while idx < n:
        if idx in pair_of:
            flush_svs()
            flush_lines()
            line_title = items[idx][0]
            sv_title = items[pair_of[idx]][0]
            layout.append({"title": line_title, "row": row[0], "column": 0, "width": 8, "height": 2})
            layout.append({"title": sv_title, "row": row[0], "column": 8, "width": 4, "height": 2})
            row[0] += 2
            idx += 2
        elif items[idx][1]:
            flush_svs()
            pending_lines.append(items[idx][0])
            idx += 1
        else:
            flush_lines()
            pending_svs.append(items[idx][0])
            idx += 1

    flush_svs()
    flush_lines()
    return layout


def main():
    """Creates each dashboard fresh (POST every chart + the dashboard) and writes
    ONE combined JSON file per dashboard - {dashboardGroupId, dashboard, charts:
    [...with each chart's own "layout" merged in]} - matching the Splunk Cloud
    side's one-file-per-dashboard feel. Not idempotent: re-running this against
    an org that already has these dashboards creates new, duplicate chart/
    dashboard objects rather than updating the existing ones."""
    for dboard in DASHBOARDS:
        panels = dboard["panels"]
        chart_ids = {}
        chart_json_by_title = {}
        print(f"\n=== {dboard['title']} ({len(panels)} panels) ===")
        for kind, title, chart_json in panels:
            resp = api("POST", "/v2/chart", chart_json)
            chart_ids[title] = resp["id"]
            chart_json_by_title[title] = chart_json
            print(f"  [{resp['id']}] {title}")

        layout = layout_rows(panels)
        dash_charts = []
        for item in layout:
            dash_charts.append({
                "chartId": chart_ids[item["title"]],
                "row": item["row"], "column": item["column"],
                "width": item["width"], "height": item["height"],
            })
        dashboard_body = {
            "name": dboard["title"],
            "groupId": GROUP_ID,
            "charts": dash_charts,
            "filters": {"time": {"start": "-15m", "end": "Now"}},
        }
        resp = api("POST", "/v2/dashboard", dashboard_body)
        dash_id = resp["id"]
        dash_url = f"https://app.us1.observability.splunkcloud.com/#/dashboard/{dash_id}"

        combined = {
            "dashboardGroupId": GROUP_ID,
            "dashboard": {"id": dash_id, "name": dboard["title"], "url": dash_url,
                          "timeRange": dashboard_body["filters"]["time"]},
            "charts": [
                {
                    "id": chart_ids[item["title"]],
                    "name": chart_json_by_title[item["title"]]["name"],
                    "description": chart_json_by_title[item["title"]]["description"],
                    "programText": chart_json_by_title[item["title"]]["programText"],
                    "options": chart_json_by_title[item["title"]]["options"],
                    "layout": {"row": item["row"], "column": item["column"],
                               "width": item["width"], "height": item["height"]},
                }
                for item in layout
            ],
        }
        out_path = os.path.join(OUT_ROOT, f"{dboard['dir']}.json")
        with open(out_path, "w") as fh:
            json.dump(combined, fh, indent=2)
            fh.write("\n")
        print(f"  DASHBOARD: {dash_url}")
        print(f"  WROTE: {out_path}")


if __name__ == "__main__":
    main()
