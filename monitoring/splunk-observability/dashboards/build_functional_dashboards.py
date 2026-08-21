#!/usr/bin/env python3
"""
Ports Kafka_splunk.json (cluster health/throughput/latency) and Connect_splunk.json
(connector/task status, worker resources, task-level metrics) to Splunk Observability
Cloud, applying the same standards as build_resources_dashboards.py:
  - every metric name verified against the live catalog before use
  - counters converted via (raw - raw.timeshift('2m'))/120, never .rate()
  - gauges use colorBy=Scale + colorScale2, never colorBy=Dimension
  - layout pairs each line with an immediately-following single-value

Deliberate scope cuts (documented, not silent): splunk.markdown headers (no
per-chart equivalent), splunk.pie (redundant with the single-value tiles it
duplicates), splunk.table x2 (no verified List/Heatmap-equivalent schema for an
xyseries-pivoted matrix - flagged rather than guessed).

Connector/task-scoped panels (Task Metrics, Task Errors, Source/Sink Task Metrics
sections) are built and deployed even though this cluster currently has zero
connectors configured (`curl :8083/connectors` -> `[]`, confirmed live) - they will
show "No Data" until a real connector exists, exactly like the equivalent SPL
panels in Connect_splunk.json against this same cluster right now. Not a bug.
"""
import json
import os
import sys

sys.path.insert(0, "/Users/anandhvasu/Documents/monitoring/cfk-on-docker-desktop-github/monitoring/splunk-observability/dashboards")
import build_resources_dashboards as b

OUT_ROOT = "/Users/anandhvasu/Documents/monitoring/cfk-on-docker-desktop-github/monitoring/splunk-observability/dashboards"
GROUP_ID = "HQMTCAaAwAE"

f = b.f
direct = b.direct
two_line = b.two_line
delta_rate = b.delta_rate
line_chart = b.line_chart
single_value = b.single_value
api = b.api


def health_binary(name, description, program_text):
    """0 = good (green), > 0 = bad (red). Used for Offline Partitions, Under
    Replicated/Min-ISR Partitions, Unclean Leader Election Rate - matches the
    thresholds already documented for the equivalent Splunk Cloud panels.
    Outer bounds must be open-ended here (no secondaryVisualization: Radial) -
    confirmed live: a plain SingleValue's colorScale2 rejects closed outer
    bounds ("Missing open ended range(s)"), the opposite of the Radial gauges'
    requirement (which reject open ends) - both discovered by testing, not
    documented anywhere found."""
    return {
        "name": name, "description": description, "programText": program_text,
        "options": {
            "type": "SingleValue", "colorBy": "Scale", "unitPrefix": "Metric",
            "colorScale2": [
                {"lte": 0, "paletteIndex": 18},   # green
                {"gt": 0, "paletteIndex": 16},    # red
            ],
        },
    }


def health_exactly_one(name, description, program_text):
    """Exactly 1 = good (green); 0 or >=2 = bad (red). Active Controllers."""
    return {
        "name": name, "description": description, "programText": program_text,
        "options": {
            "type": "SingleValue", "colorBy": "Scale", "unitPrefix": "Metric",
            "colorScale2": [
                {"lt": 1, "paletteIndex": 16},           # red
                {"gte": 1, "lt": 2, "paletteIndex": 18},  # green
                {"gte": 2, "paletteIndex": 16},           # red
            ],
        },
    }


def count_series(metric, filters, label="value"):
    return f"data('{metric}', filter={f(filters)}).count().publish(label='{label}')\n"


def sum_delta_rate(metric, filters, label="value", window_min=1, var="raw"):
    """Same as delta_rate but with .sum() first (cluster/topic-wide totals, where
    the source metric legitimately has multiple underlying series to add - e.g.
    per-topic BytesInPerSec summed to a cluster total). `var` must be unique
    within a program when concatenating more than one of these calls together -
    SignalFlow rejects a program that binds the same name twice."""
    w = f"{window_min}m"
    secs = window_min * 60
    return (
        f"{var} = data('{metric}', filter={f(filters)}).sum()\n"
        f"(({var} - {var}.timeshift('{w}')) / {secs}).publish(label='{label}')\n"
    )


def sum_direct(metric, filters, label="value"):
    return f"data('{metric}', filter={f(filters)}).sum().publish(label='{label}')\n"


# ---------------------------------------------------------------------------
# Kafka_splunk.json -> kafka-cluster
# ---------------------------------------------------------------------------

def kafka_cluster_panels():
    ns = [("namespace", "confluent")]
    broker = ns + [("service.name", "kafka-broker")]
    controller = ns + [("service.name", "kafka-controller")]

    panels = []
    panels.append(("sv", "Active Controllers",
        health_exactly_one("Active Controllers",
            "kafka_controller_kafkacontroller_value{name=ActiveControllerCount}. Exactly 1 is healthy; 0 or 2+ indicates a split-brain or leaderless controller.",
            direct("kafka_controller_kafkacontroller_value", controller + [("name", "ActiveControllerCount")], label="Active Controllers"))))
    panels.append(("sv", "Brokers Online",
        single_value("Brokers Online", "Distinct count of broker instances reporting kafka_server_replicamanager_value{name=LeaderCount}.",
            count_series("kafka_server_replicamanager_value", broker + [("name", "LeaderCount")], label="Brokers Online"))))
    panels.append(("sv", "Unclean Leader Election Rate",
        health_binary("Unclean Leader Election Rate", "kafka_controller_controllerstats_oneminuterate{name=UncleanLeaderElectionsPerSec} - already a computed rate (Yammer Meter), used directly.",
            direct("kafka_controller_controllerstats_oneminuterate", controller + [("name", "UncleanLeaderElectionsPerSec")], label="Unclean Leader Election Rate"))))
    panels.append(("sv", "Under Replicated Partitions",
        health_binary("Under Replicated Partitions", "Sum of kafka_server_replicamanager_value{name=UnderReplicatedPartitions} across brokers.",
            sum_direct("kafka_server_replicamanager_value", broker + [("name", "UnderReplicatedPartitions")], label="Under Replicated Partitions"))))
    panels.append(("sv", "Under Min ISR Partitions",
        health_binary("Under Min ISR Partitions", "Sum of kafka_server_replicamanager_value{name=UnderMinIsrPartitionCount} across brokers.",
            sum_direct("kafka_server_replicamanager_value", broker + [("name", "UnderMinIsrPartitionCount")], label="Under Min ISR Partitions"))))
    panels.append(("sv", "Offline Partitions Count",
        health_binary("Offline Partitions Count", "Sum of kafka_controller_kafkacontroller_value{name=OfflinePartitionsCount} across controllers.",
            sum_direct("kafka_controller_kafkacontroller_value", controller + [("name", "OfflinePartitionsCount")], label="Offline Partitions Count"))))

    panels.append(("line", "Broker Network Throughput",
        line_chart("Broker Network Throughput", "kafka_server_brokertopicmetrics_count{name=BytesInPerSec|BytesOutPerSec}, cluster-wide, 2-minute timeshift delta (not .rate()).",
            sum_delta_rate("kafka_server_brokertopicmetrics_count", broker + [("name", "BytesInPerSec")], label="bytes_in", window_min=2, var="raw_in")
            + sum_delta_rate("kafka_server_brokertopicmetrics_count", broker + [("name", "BytesOutPerSec")], label="bytes_out", window_min=2, var="raw_out"),
            y_label="Bytes/sec")))
    panels.append(("line", "Errors",
        line_chart("Errors", "kafka_network_requestmetrics_count{name=ErrorsPerSec, error!=NONE}, by error type, 2-minute timeshift delta.",
            f"raw = data('kafka_network_requestmetrics_count', filter={f(ns + [('name','ErrorsPerSec'), ('service.name','kafka-broker')])}).sum(by=['error'])\n"
            f"((raw - raw.timeshift('2m')) / 120).publish(label='Errors')\n",
            y_label="Errors/sec")))
    panels.append(("line", "CPU Usage %",
        line_chart("CPU Usage %", "process_cpu_seconds_total, by broker instance, 2-minute timeshift delta * 100.",
            f"raw = data('process_cpu_seconds_total', filter={f(broker)}).sum(by=['service.instance.id'])\n"
            f"(((raw - raw.timeshift('2m')) / 120) * 100).publish(label='CPU Usage %')\n",
            y_label="%")))
    panels.append(("line", "JVM Memory Used",
        line_chart("JVM Memory Used", "jvm_memory_bytes_used vs jvm_memory_bytes_max{area=heap}, by broker instance.",
            f"data('jvm_memory_bytes_used', filter={f(broker)}).sum(by=['service.instance.id']).publish(label='Used')\n"
            f"data('jvm_memory_bytes_max', filter={f(broker + [('area','heap')])}).sum(by=['service.instance.id']).publish(label='Max Heap')\n",
            y_label="Bytes")))
    panels.append(("line", "Time Spent in GC",
        line_chart("Time Spent in GC", "jvm_gc_collection_seconds_sum, by broker instance, 2-minute timeshift delta.",
            f"raw = data('jvm_gc_collection_seconds_sum', filter={f(broker)}).sum(by=['service.instance.id'])\n"
            f"((raw - raw.timeshift('2m')) / 120).publish(label='GC Time')\n",
            y_label="sec/sec")))
    panels.append(("line", "Linux Disk Write Bytes",
        line_chart("Linux Disk Write Bytes", "kafka_server_kafkaserver_value{name=linux-disk-write-bytes}, by broker instance, 2-minute timeshift delta.",
            f"raw = data('kafka_server_kafkaserver_value', filter={f(broker + [('name','linux-disk-write-bytes')])}).sum(by=['service.instance.id'])\n"
            f"((raw - raw.timeshift('2m')) / 120).publish(label='Disk Write Bytes/sec')\n",
            y_label="Bytes/sec")))
    panels.append(("line", "Messages In (cluster total)",
        line_chart("Messages In (cluster total)", "kafka_server_brokertopicmetrics_count{name=MessagesInPerSec}, cluster-wide, 2-minute timeshift delta.",
            sum_delta_rate("kafka_server_brokertopicmetrics_count", broker + [("name", "MessagesInPerSec")], label="Messages In/sec", window_min=2),
            y_label="Messages/sec")))
    panels.append(("line", "Consumer Group Lag (records, max)",
        line_chart("Consumer Group Lag (records, max)", "kafka_consumer_consumer_fetch_manager_metrics_records_lag_max, by client_id/topic/partition (reported under job=kafka-connect - Connect's embedded consumer).",
            f"data('kafka_consumer_consumer_fetch_manager_metrics_records_lag_max', filter={f(ns + [('service.name','kafka-connect')])}).sum(by=['client_id','topic','partition']).publish(label='Consumer Group Lag')\n",
            y_label="Records")))
    panels.append(("line", "Produce - Total Time Ms (all percentiles)",
        line_chart("Produce - Total Time Ms (all percentiles)", "kafka_network_requestmetrics_*thpercentile{name=TotalTimeMs, request=Produce} - wildcarded metric name, one series per percentile.",
            f"data('kafka_network_requestmetrics_*thpercentile', filter={f(broker + [('name','TotalTimeMs'), ('request','Produce')])}).publish(label='Produce Total Time Ms')\n",
            y_label="ms")))
    panels.append(("line", "Consumer Fetch - Total Time Ms (all percentiles)",
        line_chart("Consumer Fetch - Total Time Ms (all percentiles)", "kafka_network_requestmetrics_*thpercentile{name=TotalTimeMs, request=FetchConsumer}.",
            f"data('kafka_network_requestmetrics_*thpercentile', filter={f(broker + [('name','TotalTimeMs'), ('request','FetchConsumer')])}).publish(label='Fetch Consumer Total Time Ms')\n",
            y_label="ms")))

    return panels


# ---------------------------------------------------------------------------
# Connect_splunk.json -> connect-cluster
# ---------------------------------------------------------------------------

def connect_cluster_panels():
    ns = [("namespace", "confluent")]
    connect = ns + [("service.name", "kafka-connect")]

    panels = []
    for title, metric in [
        ("Tasks Total", "kafka_connect_connect_worker_metrics_connector_total_task_count"),
        ("Tasks Running", "kafka_connect_connect_worker_metrics_connector_running_task_count"),
        ("Tasks Paused", "kafka_connect_connect_worker_metrics_connector_paused_task_count"),
        ("Tasks Failed", "kafka_connect_connect_worker_metrics_connector_failed_task_count"),
        ("Tasks Unassigned", "kafka_connect_connect_worker_metrics_connector_unassigned_task_count"),
        ("Tasks Destroyed", "kafka_connect_connect_worker_metrics_connector_destroyed_task_count"),
    ]:
        if title == "Tasks Failed":
            panels.append(("sv", title, health_binary(title, f"Sum of {metric} across connectors.",
                sum_direct(metric, connect, label=title))))
        else:
            panels.append(("sv", title, single_value(title, f"Sum of {metric} across connectors.",
                sum_direct(metric, connect, label=title))))
    # Splunk's "Task Repartition per Status" pie chart is deliberately not
    # reproduced - it's the same 5 counts above, viewed as a pie instead of tiles.
    panels.append(("line", "Status of Tasks Over Time",
        line_chart("Status of Tasks Over Time", "The 5 task-status counts above, summed across connectors, over time.",
            "".join(
                f"data('{metric}', filter={f(connect)}).sum().publish(label='{label}')\n"
                for label, metric in [
                    ("running", "kafka_connect_connect_worker_metrics_connector_running_task_count"),
                    ("failed", "kafka_connect_connect_worker_metrics_connector_failed_task_count"),
                    ("paused", "kafka_connect_connect_worker_metrics_connector_paused_task_count"),
                    ("unassigned", "kafka_connect_connect_worker_metrics_connector_unassigned_task_count"),
                    ("destroyed", "kafka_connect_connect_worker_metrics_connector_destroyed_task_count"),
                ]
            ),
            y_label="Tasks")))

    panels.append(("line", "CPU Usage",
        line_chart("CPU Usage", "process_cpu_seconds_total, by worker instance, 2-minute timeshift delta.",
            f"raw = data('process_cpu_seconds_total', filter={f(connect)}).sum(by=['service.instance.id'])\n"
            f"((raw - raw.timeshift('2m')) / 120).publish(label='CPU Usage')\n",
            y_label="Cores")))
    panels.append(("line", "JVM Memory Used",
        line_chart("JVM Memory Used", "jvm_memory_bytes_used vs jvm_memory_bytes_max{area=heap}, by worker instance.",
            f"data('jvm_memory_bytes_used', filter={f(connect)}).sum(by=['service.instance.id']).publish(label='Used')\n"
            f"data('jvm_memory_bytes_max', filter={f(connect + [('area','heap')])}).sum(by=['service.instance.id']).publish(label='Max Heap')\n",
            y_label="Bytes")))
    panels.append(("line", "JVM GC Time",
        line_chart("JVM GC Time", "jvm_gc_collection_seconds_sum, by worker instance, 2-minute timeshift delta.",
            f"raw = data('jvm_gc_collection_seconds_sum', filter={f(connect)}).sum(by=['service.instance.id'])\n"
            f"((raw - raw.timeshift('2m')) / 120).publish(label='GC Time')\n",
            y_label="sec/sec")))

    # "Connectors (by status, by connector)" and "Connect Worker Metrics (by
    # instance)" tables are deliberately not reproduced - both use SPL's
    # xyseries to pivot into a matrix, and no List/Heatmap chart schema for that
    # shape has been verified on this platform. Flagged as a scope cut, not
    # silently dropped.

    for title, metric in [
        ("Network IO Rate", "kafka_connect_connect_metrics_network_io_rate"),
        ("Incoming Byte Rate", "kafka_connect_connect_metrics_incoming_byte_rate"),
        ("Outgoing Byte Rate", "kafka_connect_connect_metrics_outgoing_byte_rate"),
        ("Current Active Connections", "kafka_connect_connect_metrics_connection_count"),
        ("Failed Authentication Connections", "kafka_connect_connect_metrics_failed_authentication_total"),
        ("Successful Authentication Rate", "kafka_connect_connect_metrics_successful_authentication_rate"),
        ("IO Ratio", "kafka_connect_connect_metrics_io_ratio"),
        ("Responses Received and Sent", "kafka_connect_connect_metrics_response_rate"),
        ("Average Number of Requests", "kafka_connect_connect_metrics_request_rate"),
    ]:
        panels.append(("line", title,
            line_chart(title, f"{metric}, by worker instance + client_id.",
                f"data('{metric}', filter={f(connect)}).sum(by=['service.instance.id','client_id']).publish(label='{title}')\n")))

    panels.append(("sv", "Total Number of Rebalances",
        single_value("Total Number of Rebalances", "Raw kafka_connect_connect_worker_rebalance_metrics_completed_rebalances_total.",
            direct("kafka_connect_connect_worker_rebalance_metrics_completed_rebalances_total", connect, label="Total Rebalances"))))
    panels.append(("sv", "Time Since Last Rebalance (ms)",
        single_value("Time Since Last Rebalance (ms)", "Raw kafka_connect_connect_worker_rebalance_metrics_time_since_last_rebalance_ms.",
            direct("kafka_connect_connect_worker_rebalance_metrics_time_since_last_rebalance_ms", connect, label="Time Since Last Rebalance"))))
    panels.append(("line", "Rebalance Average Time (ms)",
        line_chart("Rebalance Average Time (ms)", "kafka_connect_connect_worker_rebalance_metrics_rebalance_avg_time_ms, by worker instance.",
            f"data('kafka_connect_connect_worker_rebalance_metrics_rebalance_avg_time_ms', filter={f(connect)}).sum(by=['service.instance.id']).publish(label='Rebalance Avg Time')\n",
            y_label="ms")))

    # Task Metrics / Task Errors / Source Task / Sink Task sections: connector +
    # task scoped, zero live series right now (no connectors deployed - confirmed
    # via `curl :8083/connectors` -> `[]`), built anyway for full parity with the
    # source dashboard; will populate once a real connector/task exists.
    task_metrics = [
        ("Batch Size Average", "kafka_connect_connector_task_metrics_batch_size_avg", None),
        ("Batch Size Max", "kafka_connect_connector_task_metrics_batch_size_max", None),
        ("Offset Commit Success Percentage", "kafka_connect_connector_task_metrics_offset_commit_success_percentage", "%"),
        ("Offset Commit Average Time (ms)", "kafka_connect_connector_task_metrics_offset_commit_avg_time_ms", "ms"),
        ("Running Ratio", "kafka_connect_connector_task_metrics_running_ratio", None),
    ]
    for title, metric, y_label in task_metrics:
        panels.append(("line", title,
            line_chart(title, f"{metric}, by connector+task. Currently no live data - zero connectors deployed on this cluster.",
                f"data('{metric}', filter={f(connect)}).sum(by=['connector','task']).publish(label='{title}')\n",
                y_label=y_label)))

    task_errors = [
        ("Total Record Failures", "kafka_connect_task_error_metrics_total_record_failures"),
        ("Total Record Errors", "kafka_connect_task_error_metrics_total_record_errors"),
        ("Total Records Skipped", "kafka_connect_task_error_metrics_total_records_skipped"),
        ("Total Errors Logged", "kafka_connect_task_error_metrics_total_errors_logged"),
        ("Total Retries", "kafka_connect_task_error_metrics_total_retries"),
        ("Dead Letter Queue Produce Requests", "kafka_connect_task_error_metrics_deadletterqueue_produce_requests"),
        ("Dead Letter Queue Produce Failures", "kafka_connect_task_error_metrics_deadletterqueue_produce_failures"),
    ]
    for title, metric in task_errors:
        panels.append(("line", title,
            line_chart(title, f"{metric}, by connector+task. Currently no live data - zero connectors deployed on this cluster.",
                f"data('{metric}', filter={f(connect)}).sum(by=['connector','task']).publish(label='{title}')\n")))

    source_task = [
        ("Source Record Write Rate", "kafka_connect_source_task_metrics_source_record_write_rate"),
        ("Source Record Poll Rate", "kafka_connect_source_task_metrics_source_record_poll_rate"),
        ("Source Record Active Count Average", "kafka_connect_source_task_metrics_source_record_active_count_avg"),
        ("Source Record Active Count Max", "kafka_connect_source_task_metrics_source_record_active_count_max"),
        ("Poll Batch Average Time (ms)", "kafka_connect_source_task_metrics_poll_batch_avg_time_ms"),
        ("Poll Batch Max Time (ms)", "kafka_connect_source_task_metrics_poll_batch_max_time_ms"),
    ]
    for title, metric in source_task:
        panels.append(("line", title,
            line_chart(title, f"{metric}, by connector+task. Currently no live data - zero connectors deployed on this cluster.",
                f"data('{metric}', filter={f(connect + [('task', '*')])}).sum(by=['connector','task']).publish(label='{title}')\n")))

    sink_task = [
        ("Sink Record Read Rate", "kafka_connect_sink_task_metrics_sink_record_read_rate"),
        ("Sink Record Send Rate", "kafka_connect_sink_task_metrics_sink_record_send_rate"),
        ("Sink Record Active Count Average", "kafka_connect_sink_task_metrics_sink_record_active_count_avg"),
        ("Sink Record Active Count Max", "kafka_connect_sink_task_metrics_sink_record_active_count_max"),
        ("Offset Commit Completion Rate", "kafka_connect_sink_task_metrics_offset_commit_completion_rate"),
        ("Offset Commit Skip Rate", "kafka_connect_sink_task_metrics_offset_commit_skip_rate"),
        ("Put Batch Average Time (ms)", "kafka_connect_sink_task_metrics_put_batch_avg_time_ms"),
        ("Put Batch Max Time (ms)", "kafka_connect_sink_task_metrics_put_batch_max_time_ms"),
        ("Partition Count", "kafka_connect_sink_task_metrics_partition_count"),
    ]
    for title, metric in sink_task:
        panels.append(("line", title,
            line_chart(title, f"{metric}, by connector+task. Currently no live data - zero connectors deployed on this cluster.",
                f"data('{metric}', filter={f(connect + [('task', '*')])}).sum(by=['connector','task']).publish(label='{title}')\n")))

    return panels


DASHBOARDS = [
    {"dir": "kafka-cluster", "title": "CFK Kafka Cluster (Docker Desktop)", "panels": kafka_cluster_panels()},
    {"dir": "connect-cluster", "title": "CFK Kafka Connect Cluster (Docker Desktop)", "panels": connect_cluster_panels()},
]


def main():
    """Same one-combined-file-per-dashboard approach as
    build_resources_dashboards.py.main() - see its docstring."""
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

        layout = b.layout_rows(panels)
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
