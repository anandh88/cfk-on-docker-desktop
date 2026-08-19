# Monitoring Guide for Confluent Platform on Kubernetes

A comprehensive guide to understanding and using the monitoring stack for Confluent Platform deployed with Confluent for Kubernetes (CFK). Written for developers and operators who are new to Prometheus, Grafana, and Kafka monitoring.

---

## Table of Contents

1. [Background: What is Monitoring and Why Do We Need It?](#background-what-is-monitoring-and-why-do-we-need-it)
2. [The Building Blocks](#the-building-blocks)
3. [Monitoring Architecture Overview](#monitoring-architecture-overview)
4. [How Metrics Flow: From JVM to Dashboard](#how-metrics-flow-from-jvm-to-dashboard)
5. [Folder Structure](#folder-structure)
6. [Platform-Specific Setup](#platform-specific-setup)
   - [Docker Desktop (Local Development)](#docker-desktop-local-development)
   - [Azure (AKS)](#azure-aks)
   - [AWS (EKS)](#aws-eks)
   - [GCP (GKE)](#gcp-gke)
7. [Prometheus Configuration (Docker Desktop)](#prometheus-configuration-docker-desktop)
8. [Dashboards](#dashboards)
9. [Alert Rules](#alert-rules)
10. [Key Metrics to Watch](#key-metrics-to-watch)
11. [PromQL: Querying Metrics](#promql-querying-metrics)
12. [Troubleshooting](#troubleshooting)
13. [Adding Custom Alerts](#adding-custom-alerts)
14. [Monitoring Cheat Sheet](#monitoring-cheat-sheet)

---

## Background: What is Monitoring and Why Do We Need It?

When you run Confluent Platform (Kafka, Connect, Schema Registry, etc.) in Kubernetes, you need visibility into what's happening inside your cluster. Monitoring answers questions like:

- Are all my Kafka brokers running?
- Is a connector task failing?
- Is consumer lag growing?
- Is a pod running out of memory?

Without monitoring, you're flying blind. Problems go undetected until users report them. With monitoring, you see issues in real time and get alerted before they become outages.

### The Three Pillars

Monitoring typically involves three things:

1. **Metrics collection** - Gathering numeric measurements (CPU usage, message throughput, error counts) at regular intervals
2. **Visualization** - Displaying those metrics as graphs and dashboards so humans can understand them
3. **Alerting** - Automatically notifying someone when a metric crosses a threshold (e.g., "broker is down")

---

## The Building Blocks

### What is Prometheus?

Prometheus is an open-source time-series database built for monitoring. Think of it as a specialized database that stores numbers over time.

**How it works:**
- Prometheus **pulls** (scrapes) metrics from your applications every N seconds
- Each application exposes an HTTP endpoint (e.g., `http://kafka-0:7778/metrics`) that returns metrics in a simple text format
- Prometheus stores these metrics with timestamps so you can query historical data
- It has a query language called **PromQL** for analyzing metrics
- It evaluates **alert rules** and fires alerts when conditions are met

**What a metric looks like:**
```
kafka_server_brokertopicmetrics_messagesinpersec_count{topic="Orders", instance="kafka-0"} 1523.4
```
This says: "On kafka-0, the Orders topic is receiving 1523.4 messages per second."

### What is Grafana?

Grafana is a visualization platform. It connects to Prometheus (and other data sources) and lets you build dashboards with graphs, tables, and gauges.

**Key concepts:**
- **Datasource** - Where Grafana gets its data from (in our case, Prometheus). Configured with a `uid` that dashboards reference.
- **Dashboard** - A collection of panels (graphs, tables) that visualize related metrics
- **Panel** - A single visualization (graph, gauge, table) within a dashboard
- **Template variable** - A dropdown at the top of a dashboard that lets you filter by environment, instance, connector, etc.

### What is Alertmanager?

Alertmanager handles alerts fired by Prometheus. It:
- Groups similar alerts together (so you don't get 100 separate notifications)
- Routes alerts to the right team or channel (Slack, PagerDuty, email)
- Supports silencing (temporarily suppressing known alerts during maintenance)

### What is the CFK Prometheus endpoint?

Kafka and other Confluent components are Java applications. Java exposes internal metrics via **JMX** (Java Management Extensions), while CFK provides the JMX-to-Prometheus mapping and endpoint:

1. Reads JMX MBeans from inside the JVM
2. Converts them into Prometheus text format using CFK's default mapping
3. Serves them on an HTTP endpoint (port `7778`)

**Example conversion:**
```
JMX MBean:
  kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec

         ↓ CFK-managed default mapping ↓

Prometheus metric:
  kafka_server_brokertopicmetrics_count{name="MessagesInPerSec"} 1523.4
```

The active CRDs intentionally do not declare `metrics.prometheus.rules`. Prometheus discovers
the endpoint through ServiceMonitors under `monitoring/docker-desktop-k8s/`, which select
CFK-generated Services by their stable `type` label and scrape the named `prometheus` port.

---

## Monitoring Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                           MONITORING ARCHITECTURE                                        │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│   CONFLUENT NAMESPACE                         MONITORING NAMESPACE                       │
│   ══════════════════                          ════════════════════                       │
│                                                                                          │
│   ┌─────────────────┐                                                                    │
│   │  KRaft          │ :7778 ─────────────────────────────────┐                           │
│   │  Controllers    │ (Prometheus metrics)                    │                          │
│   └─────────────────┘                                         │                          │
│                                                               │                          │
│   ┌─────────────────┐                                         │    ┌─────────────────┐   │
│   │  Kafka          │ :7778 ──────────────────────────────────┼───►│   PROMETHEUS    │   │
│   │  Brokers        │                                         │    │                 │   │
│   └─────────────────┘                                         │    │  • Scrapes      │   │
│                                                               │    │    metrics      │   │
│   ┌─────────────────┐                                         │    │  • Stores       │   │
│   │  Schema         │ :7778 ──────────────────────────────────┤    │    time-series  │   │
│   │  Registry       │                                         │    │  • Evaluates    │   │
│   └─────────────────┘                                         │    │    alert rules  │   │
│                                                               │    │                 │   │
│   ┌─────────────────┐                                         │    └────────┬────────┘   │
│   │  Kafka          │ :7778 ──────────────────────────────────┤             │            │
│   │  Connect        │                                         │             │            │
│   └─────────────────┘                                         │             ▼            │
│                                                               │    ┌─────────────────┐   │
│   ┌─────────────────┐                                         │    │   GRAFANA       │   │
│   │  ksqlDB         │ :7778 ──────────────────────────────────┤    │                 │   │
│   │                 │                                         │    │  • Visualizes   │   │
│   └─────────────────┘                                         │    │    metrics      │   │
│                                                               │    │  • Dashboards   │   │
│   ┌─────────────────┐                                         │    │  • Exploration  │   │
│   │  REST           │ :7778 ──────────────────────────────────┤    │                 │   │
│   │  Proxy          │                                         │    └─────────────────┘   │
│   └─────────────────┘                                         │                          │
│                                                               │             ▲            │
│   ┌─────────────────┐                                         │             │            │
│   │  Control        │ :7778 ──────────────────────────────────┘    ┌────────┴────────┐   │
│   │  Center         │                                              │  ALERTMANAGER   │   │
│   └─────────────────┘                                              │                 │   │
│                                                                    │  • Routes       │   │
│                                                                    │    alerts       │   │
│                                                                    │  • Sends        │   │
│                                                                    │    notifications│   │
│                                                                    └─────────────────┘   │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## How Metrics Flow: From JVM to Dashboard

Understanding the full pipeline helps you debug when something shows "N/A":

```
┌──────────────────────────────────────────────────────────────────────────┐
│                       METRICS FLOW PIPELINE                              │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  STEP 1: METRIC GENERATION (inside the pod)                              │
│  ══════════════════════════════════════════                              │
│                                                                          │
│  Kafka/Connect/SR/ksqlDB application code                                │
│        │                                                                 │
│        ▼                                                                 │
│  JMX MBeans (Java-native metric objects)                                 │
│        │                                                                 │
│        ▼                                                                 │
│  JMX Exporter (converts via pattern rules in component YAML)             │
│        │                                                                 │
│        ▼                                                                 │
│  Prometheus metrics on :7778/metrics                                     │
│                                                                          │
│  If something is wrong here → metrics are missing entirely               │
│  Check: metrics.prometheus.rules in component YAML                       │
│                                                                          │
│                                                                          │
│  STEP 2: METRIC COLLECTION (scraping)                                    │
│  ════════════════════════════════════                                    │
│                                                                          │
│  A scraper pulls metrics from :7778 every 15 seconds.                    │
│  The scraper varies by platform:                                         │
│                                                                          │
│    Docker Desktop  → Self-hosted Prometheus (kube-prometheus-stack)       │
│    Azure (AKS)     → Azure Monitor agent (ama-metrics)                   │
│    AWS (EKS)       → Prometheus with remote-write / ADOT Collector        │
│    GCP (GKE)       → GMP managed collection agent                        │
│                                                                          │
│  The scraper needs to know WHERE to scrape (targets):                    │
│                                                                          │
│    Docker Desktop  → prometheus-values.yaml (additionalScrapeConfigs)    │
│    Azure (AKS)     → ama-metrics-prometheus-config.yaml (ConfigMap)      │
│    AWS (EKS)       → prometheus-remote-write.yaml (scrape_configs)       │
│    GCP (GKE)       → prometheus-podmonitoring.yaml (ClusterPodMonitoring)│
│                                                                          │
│  If something is wrong here → Prometheus has no data                     │
│  Check: target hostnames, port, namespace, network policies              │
│                                                                          │
│                                                                          │
│  STEP 3: METRIC STORAGE                                                  │
│  ═════════════════════                                                   │
│                                                                          │
│  Metrics are stored in a time-series database:                           │
│                                                                          │
│    Docker Desktop  → Local Prometheus TSDB                               │
│    Azure (AKS)     → Azure Monitor workspace                             │
│    AWS (EKS)       → Amazon Managed Prometheus workspace                 │
│    GCP (GKE)       → Google Cloud Monitoring                             │
│                                                                          │
│                                                                          │
│  STEP 4: VISUALIZATION (Grafana)                                         │
│  ═══════════════════════════════                                         │
│                                                                          │
│  Grafana queries the metric store and renders dashboards.                │
│  It needs a DATASOURCE configured to point to the metric store.          │
│                                                                          │
│  All dashboard JSON files in this repo reference:                        │
│    "datasource": { "uid": "prometheus" }                                 │
│                                                                          │
│  The datasource in Grafana MUST have uid = "prometheus"                  │
│  or dashboards will show "N/A".                                          │
│                                                                          │
│    Docker Desktop  → Auto-provisioned by Helm chart sidecar              │
│    Azure (AKS)     → Configure in Azure Managed Grafana (see README)     │
│    AWS (EKS)       → Configure in Amazon Managed Grafana (see README)    │
│    GCP (GKE)       → Configure in self-hosted Grafana (see README)       │
│                                                                          │
│  If dashboards show "N/A" → check datasource uid first                   │
│                                                                          │
│                                                                          │
│  STEP 5: ALERTING                                                        │
│  ════════════════                                                        │
│                                                                          │
│  Alert rules evaluate PromQL expressions on a schedule.                  │
│  When a condition is true for a specified duration, an alert fires.      │
│                                                                          │
│    Docker Desktop  → PrometheusRule CRD (alertrules.yaml)                │
│    Azure (AKS)     → Azure Prometheus rule groups (alertrules.yaml)      │
│    AWS (EKS)       → AMP rule groups via AWS CLI (alertrules.yaml)       │
│    GCP (GKE)       → ClusterRules CRD (alertrules.yaml)                 │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

**The most common debugging shortcut:** If dashboards show "N/A", work backwards through the pipeline:
1. Is the datasource UID set to `prometheus`?
2. Are metrics in the metric store? (test a query in Grafana Explore)
3. Is the scraper running and reaching the targets?
4. Is port 7778 responding on the pod?

---

## Folder Structure

```
monitoring/
├── dashboards/                         # Shared across ALL platforms
│   ├── Kafka_grafana.json              # Kafka operational metrics
│   ├── Connect_grafana.json            # Connect operational metrics
│   ├── Kafka_Broker_Resources_grafana.json
│   ├── Kafka_Connect_Resources_grafana.json
│   ├── Schema_Registry_Resources_grafana.json
│   ├── ksqlDB_Resources_grafana.json
│   ├── KRaft_Controller_Resources_grafana.json
│   ├── REST_Proxy_Resources_grafana.json
│   └── Control_Center_Resources_grafana.json
│
├── docker-desktop-k8s/                 # Local development (Docker Desktop)
│   ├── prometheus-values.yaml          #   Helm values for kube-prometheus-stack
│   └── alertrules.yaml                 #   PrometheusRule CRD for alerting
│
├── azure/                              # Azure (AKS + Managed Prometheus + Managed Grafana)
│   ├── README.md                       #   Setup guide
│   ├── ama-metrics-prometheus-config.yaml  # ConfigMap for Azure Monitor agent scraping
│   ├── grafana-datasource.yaml         #   Reference: datasource settings for Managed Grafana
│   └── alertrules.yaml                 #   Azure Prometheus rule groups
│
├── aws/                                # AWS (EKS + Amazon Managed Prometheus + Managed Grafana)
│   ├── README.md                       #   Setup guide
│   ├── prometheus-remote-write.yaml    #   Scrape configs + remote-write reference
│   ├── grafana-datasource.yaml         #   Reference: datasource settings for Managed Grafana
│   └── alertrules.yaml                 #   AMP rule groups (standard Prometheus format)
│
├── gcp/                                # GCP (GKE + Google Cloud Managed Prometheus + Grafana)
│   ├── README.md                       #   Setup guide
│   ├── prometheus-podmonitoring.yaml   #   ClusterPodMonitoring CRDs for GMP
│   ├── grafana-datasource.yaml         #   Reference: datasource settings for Grafana
│   └── alertrules.yaml                 #   ClusterRules CRDs for GMP
│
└── monitoring-guide.md                 # This file
```

**Key design principle:** The `dashboards/` folder is shared across all platforms. The same JSON files work everywhere as long as the Grafana datasource has `uid: prometheus`. Each platform folder contains only the platform-specific plumbing to get metrics from pods into the metric store.

### Environment Labels

Each platform tags metrics with an `env` label so dashboards can filter by environment:

| Platform | env label | Purpose |
|----------|-----------|---------|
| Docker Desktop | `local-poc` | Local development and proof of concept |
| Azure (AKS) | `dev-aks` | Development on Azure Kubernetes Service |
| AWS (EKS) | `dev-eks` | Development on Elastic Kubernetes Service |
| GCP (GKE) | `dev-gke` | Development on Google Kubernetes Engine |

---

## Platform-Specific Setup

### Docker Desktop (Local Development)

This is the simplest setup. Everything runs inside your local Kubernetes cluster.

**Architecture:**
```
Confluent pods (:7778)
  → Self-hosted Prometheus (scrapes every 15s)
    → Self-hosted Grafana (queries Prometheus)
    → Self-hosted Alertmanager (receives alerts)
```

**Components deployed:** kube-prometheus-stack Helm chart (bundles Prometheus + Grafana + Alertmanager)

**Setup:** The `scripts/setup.sh` script handles everything automatically, including:
1. Installing the kube-prometheus-stack with `docker-desktop-k8s/prometheus-values.yaml`
2. Creating dashboard ConfigMaps from `dashboards/`
3. Applying alert rules from `docker-desktop-k8s/alertrules.yaml`

**Teardown:** `scripts/destroy.sh` removes everything, including monitoring.

**Manual commands:**
```bash
# Deploy monitoring only
scripts/deploy-monitoring.sh

# Tear down monitoring only
scripts/teardown-monitoring.sh
```

**Access:**

| Component | Command | URL | Credentials |
|-----------|---------|-----|-------------|
| Grafana | `kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80` | http://localhost:3000 | admin / admin |
| Prometheus | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090` | http://localhost:9090 | None |
| Alertmanager | `kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n monitoring 9093:9093` | http://localhost:9093 | None |

**How dashboards are loaded (Docker Desktop only):**

On Docker Desktop, dashboards are loaded into Grafana automatically via a **sidecar** container:

1. `deploy-monitoring.sh` creates a Kubernetes ConfigMap for each dashboard JSON file
2. Each ConfigMap is labeled with `grafana_dashboard: "1"`
3. A sidecar container running alongside Grafana watches for ConfigMaps with that label
4. When it finds one, it loads the JSON into Grafana as a dashboard

This is configured in `docker-desktop-k8s/prometheus-values.yaml`:
```yaml
grafana:
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
      label: grafana_dashboard
      labelValue: "1"
    datasources:
      enabled: true    # Auto-provisions the Prometheus datasource
```

On cloud platforms (Azure, AWS, GCP), dashboards are imported manually into the managed Grafana service via its UI.

### Azure (AKS)

See `azure/README.md` for full setup instructions.

**Architecture:**
```
Confluent pods (:7778)
  → Azure Monitor agent (ama-metrics, scrapes via ConfigMap config)
    → Azure Monitor workspace (stores metrics)
      → Azure Managed Grafana (queries workspace)
```

**Key differences from Docker Desktop:**
- No self-hosted Prometheus or Grafana — Azure manages both
- Scrape targets defined in a ConfigMap (`ama-metrics-prometheus-config.yaml`) in `kube-system` namespace
- Datasource configured via Azure Portal (link workspace to Grafana), not Helm
- Alert rules deployed via `az` CLI, not `kubectl apply`
- Dashboards imported via Grafana UI, not ConfigMaps

### AWS (EKS)

See `aws/README.md` for full setup instructions.

**Architecture:**
```
Confluent pods (:7778)
  → Prometheus with remote-write (or ADOT Collector)
    → Amazon Managed Prometheus (AMP workspace)
      → Amazon Managed Grafana (AMG workspace)
```

**Key differences from Docker Desktop:**
- You can keep the self-hosted Prometheus for scraping, but add `remoteWrite` to forward metrics to AMP
- Alternatively, use AWS ADOT Collector as a drop-in replacement
- Authentication uses **SigV4** and **IAM Roles for Service Accounts (IRSA)**
- Alert rules uploaded via `aws amp create-rule-groups-namespace` CLI
- Dashboards imported via Grafana UI

### GCP (GKE)

See `gcp/README.md` for full setup instructions.

**Architecture:**
```
Confluent pods (:7778)
  → GMP managed collection agent (scrapes via ClusterPodMonitoring CRDs)
    → Google Cloud Monitoring (stores metrics)
      → Grafana (self-hosted on GKE, or Grafana Cloud)
```

**Key differences from Docker Desktop:**
- Uses **ClusterPodMonitoring** CRDs instead of static scrape configs — automatically discovers pods by label
- No static hostnames to maintain; scaling pods are auto-discovered
- Authentication uses **Workload Identity**
- Alert rules use **ClusterRules** CRDs, applied with `kubectl apply`
- Google Cloud does not offer a managed Grafana; use self-hosted or Grafana Cloud

---

## Prometheus Configuration (Docker Desktop)

This section covers the Prometheus scrape configuration in detail. On cloud platforms, equivalent configuration is done via each platform's native tooling (see platform-specific sections above).

### prometheus-values.yaml Explained

```yaml
prometheus:
  prometheusSpec:
    # Allow Prometheus to discover all ServiceMonitors/PodMonitors
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

    # Custom scrape configurations for Confluent components
    additionalScrapeConfigs:
      # ... scrape jobs
```

### Scrape Configuration Deep Dive

Each Confluent component has a scrape job:

```yaml
# Kafka Brokers Scrape Configuration
- job_name: 'kafka-broker'
  static_configs:
    - targets:
      - kafka-0.kafka.confluent.svc.cluster.local:7778
      - kafka-1.kafka.confluent.svc.cluster.local:7778
      - kafka-2.kafka.confluent.svc.cluster.local:7778
  relabel_configs:
    # Extract pod name for instance label
    - source_labels: [__address__]
      regex: '(.+)\.kafka\.confluent\.svc\.cluster\.local:.+'
      target_label: instance
      replacement: '${1}'
    # Add environment label
    - target_label: env
      replacement: 'local-poc'
```

**Understanding the Target Format:**

```
kafka-0.kafka.confluent.svc.cluster.local:7778
  │      │      │        │             │
  │      │      │        │             └── Port (Prometheus metrics)
  │      │      │        └── Kubernetes DNS suffix
  │      │      └── Namespace
  │      └── Service name (headless)
  └── Pod name
```

### Scrape Jobs Summary

| Job Name | Targets | Port | Purpose |
|----------|---------|------|---------|
| `kafka-broker` | kafka-0, kafka-1, kafka-2 | 7778 | Broker metrics |
| `kafka-controller` | kraftcontroller-0, -1, -2 | 7778 | KRaft metrics |
| `kafka-connect` | Kubernetes SD (auto-discover) | 7778 | Connect metrics |
| `schemaregistry` | schemaregistry-0 | 7778 | Schema Registry metrics |
| `ksqldb` | ksqldb-0 | 7778 | ksqlDB metrics |
| `kafkarestproxy` | kafkarestproxy-0 | 7778 | REST Proxy metrics |
| `controlcenter` | controlcenter-0 | 7778 | Control Center metrics |

### Relabel Configurations

Relabeling transforms labels before metrics are stored:

```yaml
relabel_configs:
  # Keep only pods with specific label
  - source_labels: [__meta_kubernetes_pod_label_app]
    regex: connect
    action: keep

  # Set instance label from pod name
  - source_labels: [__meta_kubernetes_pod_name]
    target_label: instance

  # Add static label
  - target_label: env
    replacement: 'local-poc'
```

**Common relabel actions:**

| Action | Description |
|--------|-------------|
| `keep` | Only keep targets matching regex |
| `drop` | Drop targets matching regex |
| `replace` | Replace label value |
| `labelmap` | Map multiple labels |

---

## Dashboards

### Available Dashboards

All dashboards live in `monitoring/dashboards/` and are shared across all platforms.

| Dashboard | File | What it Shows |
|-----------|------|---------------|
| Kafka Metrics | `Kafka_grafana.json` | Throughput, latency, request rates, topic-level metrics |
| Kafka Broker Resources | `Kafka_Broker_Resources_grafana.json` | CPU, memory, disk, network, JVM for brokers |
| Connect Metrics | `Connect_grafana.json` | Connector status, task counts, error rates, throughput |
| Connect Resources | `Kafka_Connect_Resources_grafana.json` | CPU, memory, JVM for Connect workers |
| Schema Registry | `Schema_Registry_Resources_grafana.json` | CPU, memory, JVM for Schema Registry |
| ksqlDB | `ksqlDB_Resources_grafana.json` | CPU, memory, JVM for ksqlDB |
| KRaft Controller | `KRaft_Controller_Resources_grafana.json` | CPU, memory, JVM for KRaft controllers |
| REST Proxy | `REST_Proxy_Resources_grafana.json` | CPU, memory, JVM for REST Proxy |
| Control Center | `Control_Center_Resources_grafana.json` | CPU, memory, JVM for Control Center |

### Template Variables (Dropdowns)

Most dashboards have dropdowns at the top for filtering:

| Variable | What it Filters | Populated From |
|----------|----------------|----------------|
| `env` | Environment (local-poc, dev-aks, etc.) | `env` label on metrics |
| `kafka_connect_cluster_id` | Connect cluster | `kafka_connect_cluster_id` label |
| `instance` | Specific pod | `instance` label |
| `connector` | Specific connector | `connector` label |

These variables are populated by querying the metric `kafka_connect_connect_worker_metrics_connector_total_task_count`. If this metric is missing, **all dropdowns will be empty** and panels will show "N/A".

### Datasource Requirement

Every dashboard panel references the datasource as:
```json
"datasource": {
  "type": "prometheus",
  "uid": "prometheus"
}
```

The Grafana datasource **must** have `uid: prometheus` or all panels show "N/A". This is the single most common issue when setting up dashboards on a new platform.

### Key Panels to Watch

**Kafka Broker Dashboard:**

| Panel | What it Shows | What to Look For |
|-------|---------------|------------------|
| Messages In/Out | Throughput | Consistent with expected load |
| Bytes In/Out | Network traffic | Not hitting network limits |
| Request Latency | Response times | p99 < 100ms typically |
| Under Replicated Partitions | Replication health | Should be 0 |
| Offline Partitions | Partition availability | Should be 0 |
| Active Controller | Cluster leadership | Exactly 1 |

**Kafka Connect Dashboard:**

| Panel | What it Shows | What to Look For |
|-------|---------------|------------------|
| Connector Status | Running/Failed/Paused | All should be Running |
| Task Status | Per-connector tasks | All should be Running |
| Record Rate | Throughput | Consistent, not dropping |
| Error Rate | Processing errors | Should be near 0 |

---

## Alert Rules

### What is an Alert Rule?

An alert rule is a PromQL expression that Prometheus (or its managed equivalent) evaluates on a schedule. When the expression returns a result (is "true") for longer than a specified duration, the alert **fires**.

Example:
```yaml
- alert: KafkaBrokerDown
  expr: up{job="kafka-broker"} == 0    # Is any broker's scrape target down?
  for: 30s                              # Must be down for 30 seconds before firing
  labels:
    severity: critical                  # Used for routing (PagerDuty vs Slack vs email)
  annotations:
    summary: "Kafka broker {{ $labels.instance }} is down"
```

**Reading this rule:** "If the `up` metric for any `kafka-broker` target equals 0 for more than 30 seconds, fire a critical alert saying which broker is down."

### Alert Rule Format by Platform

The same alerts are defined in each platform folder, but in the native format for that platform:

| Platform | File | Format | Deploy |
|----------|------|--------|--------|
| Docker Desktop | `docker-desktop-k8s/alertrules.yaml` | `PrometheusRule` CRD (monitoring.coreos.com/v1) | `kubectl apply` |
| Azure | `azure/alertrules.yaml` | Azure Prometheus rule groups (ISO 8601 durations) | `az monitor account prometheus-rule-group create` |
| AWS | `aws/alertrules.yaml` | Standard Prometheus YAML | `aws amp create-rule-groups-namespace` |
| GCP | `gcp/alertrules.yaml` | `ClusterRules` CRD (monitoring.googleapis.com/v1) | `kubectl apply` |

### Alert Groups

All platforms define the same 17 alerts across 6 groups:

**Kafka Brokers (9 alerts)**

| Alert | Severity | Fires When | Why it Matters |
|-------|----------|------------|----------------|
| ActiveControllerCountNotOne | page | Controller count != 1 | No controller = no partition leadership changes; > 1 = split-brain |
| OfflinePartitionCount | page | Any partition offline | Clients can't read/write to those partitions |
| UncleanLeaderElections | page | Unclean election occurs | Potential data loss — a replica with missing data became leader |
| UnderReplicatedPartitions | page | Replicas not in sync | If the leader fails, data loss is possible |
| UnderMinIsrPartitionCount | page | Below min.insync.replicas | Producers with acks=all will fail |
| KafkaBrokerCountChanged | warning | Fewer brokers than expected | A broker has gone down or failed to start |
| KafkaBrokerDown | critical | Any broker unreachable | Direct broker failure |
| KafkaHighRequestLatency | warning | p99 latency > 1 second | Brokers overloaded or network issues |
| KafkaRequestHandlerIdleLow | warning | Handler idle < 30% | Brokers are saturated — need more capacity |

**Kafka Consumers (2 alerts)**

| Alert | Severity | Fires When | Why it Matters |
|-------|----------|------------|----------------|
| KafkaConsumerLagHigh | warning | Lag > 10,000 messages | Consumers falling behind — may indicate processing issues |
| KafkaConsumerLagGrowing | warning | Lag growing over time | Problem is getting worse, not recovering |

**Kafka Connect (4 alerts)**

| Alert | Severity | Fires When | Why it Matters |
|-------|----------|------------|----------------|
| KafkaConnectDown | critical | Worker is unreachable | No connectors will run |
| KafkaConnectTaskFailed | critical | Any task in FAILED state | Data pipeline is broken |
| KafkaConnectorNotRunning | warning | Connector not in RUNNING state | Could be paused or degraded |
| KafkaConnectNoConnectors | info | Zero connectors deployed | May indicate a configuration issue |

**JVM Health (2 alerts)**

| Alert | Severity | Fires When | Why it Matters |
|-------|----------|------------|----------------|
| JvmHeapUsageHigh | warning | Heap usage > 90% | OOM crash imminent if load increases |
| JvmGcFrequent | warning | GC running > 0.5/sec | Application is spending too much time in garbage collection |

**Schema Registry (1 alert)**

| Alert | Severity | Fires When | Why it Matters |
|-------|----------|------------|----------------|
| SchemaRegistryDown | critical | Schema Registry unreachable | Producers/consumers using schemas will fail |

**ksqlDB (1 alert)**

| Alert | Severity | Fires When | Why it Matters |
|-------|----------|------------|----------------|
| KsqlDBDown | critical | ksqlDB unreachable | Streaming queries will stop processing |

### Severity Levels

| Severity | Meaning | Typical Response |
|----------|---------|------------------|
| `page` | Data loss or availability risk | Page on-call immediately |
| `critical` | Service is down | Investigate now |
| `warning` | Degraded performance | Investigate within hours |
| `info` | Informational | Review during business hours |

---

## Key Metrics to Watch

### Cluster Health (Always Monitor)

| Metric | Expected | Problem If |
|--------|----------|------------|
| `kafka_controller_kafkacontroller_activecontrollercount` | 1 | != 1 (no controller or split-brain) |
| `kafka_controller_kafkacontroller_offlinepartitionscount` | 0 | > 0 (data unavailable) |
| `kafka_server_replicamanager_underreplicatedpartitions` | 0 | > 0 (replication lag) |
| `up{job="kafka-broker"}` | 1 for each broker | 0 (broker down) |

### Performance

| Metric | Expected | Problem If |
|--------|----------|------------|
| `kafka_network_requestmetrics_totaltimems` (p99) | < 100ms | > 1000ms (broker overloaded) |
| `kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent` | > 0.7 (70% idle) | < 0.3 (handlers saturated) |

### Connect

| Metric | Expected | Problem If |
|--------|----------|------------|
| `kafka_connect_connect_worker_metrics_connector_total_task_count` | > 0 | 0 or missing (no connectors or JMX issue) |
| `kafka_connect_connector_task_status{status="failed"}` | 0 | > 0 (tasks failing) |

### JVM

| Metric | Expected | Problem If |
|--------|----------|------------|
| `jvm_memory_bytes_used{area="heap"} / jvm_memory_bytes_max{area="heap"}` | < 0.8 | > 0.9 (OOM risk) |
| `rate(jvm_gc_collection_seconds_count[5m])` | < 0.3/sec | > 0.5/sec (excessive GC) |

### Warning Metrics (Watch Closely)

| Metric | Normal Range | Action if Outside |
|--------|--------------|-------------------|
| Consumer Lag | Depends on use case | Investigate slow consumers |
| JVM Heap Usage | < 80% | Increase heap or reduce load |
| Disk Usage | < 80% | Add storage or reduce retention |
| Network I/O | < 80% of capacity | Add brokers |

---

## PromQL: Querying Metrics

PromQL is Prometheus's query language. You use it in Grafana's Explore tab, in Prometheus's UI, and in alert rule expressions.

### Basic Patterns

```promql
# Simple metric lookup
up{job="kafka-broker"}

# Filter by label
kafka_server_brokertopicmetrics_messagesinpersec_count{topic="Orders"}

# Rate of change per second (for counters)
rate(kafka_server_brokertopicmetrics_messagesinpersec_count[5m])

# Sum across all instances
sum(rate(kafka_server_brokertopicmetrics_messagesinpersec_count[5m]))

# Group by a label
sum by (topic) (rate(kafka_server_brokertopicmetrics_bytesinpersec_count[5m]))

# Top 3 by value
topk(3, sum by (instance) (rate(kafka_server_brokertopicmetrics_bytesinpersec_count[5m])))

# Percentage
(jvm_memory_bytes_used{area="heap"} / jvm_memory_bytes_max{area="heap"}) * 100

# Change over time window
delta(kafka_server_fetcherlagmetrics_consumerlag[5m])
```

### Useful Queries

**Is everything up?**
```promql
up{job=~"kafka-broker|kafka-connect|schemaregistry|ksqldb"}
```

**Messages per second across all brokers:**
```promql
sum(rate(kafka_server_brokertopicmetrics_messagesinpersec_count[5m]))
```

**Consumer lag by topic:**
```promql
sum by (topic) (kafka_server_fetcherlagmetrics_consumerlag)
```

**Connect worker task count:**
```promql
kafka_connect_connect_worker_metrics_connector_total_task_count
```

**JVM heap usage as percentage:**
```promql
(jvm_memory_bytes_used{area="heap"} / jvm_memory_bytes_max{area="heap"}) * 100
```

---

## Troubleshooting

### Dashboards Show "N/A"

This is the most common issue. Work through these checks in order:

**1. Check the datasource UID**

In Grafana, go to Configuration > Data Sources. The Prometheus datasource must have `uid: prometheus`. This is the most common cause of "N/A" on cloud platforms.

**2. Check if metrics exist**

In Grafana's Explore tab (or Prometheus UI), run:
```promql
up{job="kafka-broker"}
```
If this returns nothing, the problem is in scraping, not the dashboard.

**3. Check if the scraper is reaching targets**

Docker Desktop:
```bash
# Open Prometheus targets page
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
# Visit http://localhost:9090/targets - look for DOWN targets
```

Azure:
```bash
# Check ama-metrics pod logs
kubectl logs -n kube-system -l rsName=ama-metrics
```

**4. Check if port 7778 is responding**

```bash
kubectl exec kafka-0 -n confluent -- curl -s localhost:7778/metrics | head -20
```

If this returns nothing or errors, the JMX Exporter isn't configured. Check `metrics.prometheus.rules` in the component YAML.

### Template Variables Not Populating

Dashboard dropdowns (env, instance, connector) depend on the metric:
```
kafka_connect_connect_worker_metrics_connector_total_task_count
```

If this metric doesn't exist:
- All dropdowns will be empty
- All panels show "N/A"

Run this in Grafana Explore to check:
```promql
{__name__=~"kafka_connect.*task_count.*", job="kafka-connect"}
```

If the metric has a different name (cloud providers may sanitize names), update the dashboard queries to match.

### Alerts Not Firing

**Docker Desktop:**
1. Check rules are loaded: http://localhost:9090/rules
2. Test the expression: http://localhost:9090/graph
3. Verify the `PrometheusRule` has `release: prometheus` label (required for discovery)

**Cloud platforms:**
- Azure: Check rule group status in Azure Portal > Azure Monitor > Prometheus rule groups
- AWS: `aws amp describe-rule-groups-namespace --workspace-id <ID> --name confluent-platform-alerts`
- GCP: `kubectl get clusterrules`

### Missing Specific Metrics

```bash
# List all metrics a pod exposes
kubectl exec kafka-0 -n confluent -- curl -s localhost:7778/metrics | grep "^kafka_"

# Search for a specific metric
kubectl exec kafka-0 -n confluent -- curl -s localhost:7778/metrics | grep "connector_total_task_count"
```

If the metric isn't in the output, the JMX Exporter rule pattern doesn't match the MBean. Check `metrics.prometheus.rules` in the component YAML.

### Quick Health Check Script

```bash
# All monitoring pods running?
kubectl get pods -n monitoring

# All Confluent pods running?
kubectl get pods -n confluent

# All scrape targets up? (Docker Desktop only)
curl -s localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Any alerts firing? (Docker Desktop only)
curl -s localhost:9090/api/v1/alerts | \
  jq '.data.alerts[] | select(.state=="firing")'
```

---

## Adding Custom Alerts

To add a new alert, edit the `alertrules.yaml` in the appropriate platform folder.

**Example: Alert when a specific topic has zero throughput**

```yaml
- alert: OrdersTopicNoThroughput
  expr: sum(rate(kafka_server_brokertopicmetrics_messagesinpersec_count{topic="Orders"}[5m])) == 0
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "Orders topic has zero throughput"
    description: "No messages have been produced to the Orders topic for 10 minutes."
```

**Deploy:**

| Platform | Command |
|----------|---------|
| Docker Desktop | `kubectl apply -f monitoring/docker-desktop-k8s/alertrules.yaml` |
| Azure | `az monitor account prometheus-rule-group create ...` (see azure/README.md) |
| AWS | `aws amp put-rule-groups-namespace ...` (see aws/README.md) |
| GCP | `kubectl apply -f monitoring/gcp/alertrules.yaml` |

---

## Monitoring Cheat Sheet

### Quick Health Check

```bash
# All monitoring pods running?
kubectl get pods -n monitoring

# All scrape targets up? (Docker Desktop only)
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'

# Any alerts firing? (Docker Desktop only)
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'
```

### Useful PromQL Queries

```promql
# Cluster health summary
kafka_controller_kafkacontroller_offlinepartitionscount +
kafka_server_replicamanager_underreplicatedpartitions

# Broker throughput ranking
topk(3, sum by (instance) (rate(kafka_server_brokertopicmetrics_bytesinpersec_count[5m])))

# Connect connector status
kafka_connect_connector_status

# ksqlDB query count
io_confluent_ksql_metrics_ksql_engine_query_stats_num_active_queries
```

### Emergency Procedures

**If Prometheus is down:**
```bash
# Check pod status
kubectl get pods -n monitoring -l app=prometheus

# Check logs
kubectl logs -n monitoring -l app=prometheus

# Restart
kubectl rollout restart statefulset prometheus-kube-prometheus-prometheus -n monitoring
```

**If metrics are missing:**
```bash
# Verify component is exporting metrics
kubectl port-forward kafka-0 -n confluent 7778:7778
curl localhost:7778/metrics | head -50

# Check Prometheus scrape config
kubectl get prometheus -n monitoring -o yaml | grep -A 50 additionalScrapeConfigs
```

---

## Summary

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                           MONITORING SUMMARY                                             │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                          │
│  WHAT WE MONITOR                                                                         │
│  ═══════════════                                                                         │
│  • All Confluent Platform components (Kafka, Connect, SR, ksqlDB, etc.)                  │
│  • JVM metrics (heap, GC, threads)                                                       │
│  • Operational metrics (throughput, latency, errors)                                     │
│                                                                                          │
│  HOW WE MONITOR                                                                          │
│  ═══════════════                                                                         │
│  • JMX Exporter converts JMX → Prometheus format (port 7778)                             │
│  • Prometheus (or managed equivalent) scrapes all components every 15-30 seconds         │
│  • Grafana visualizes metrics in dashboards                                              │
│  • Alertmanager routes alerts to receivers                                               │
│                                                                                          │
│  KEY FILES                                                                               │
│  ═════════                                                                               │
│  • monitoring/docker-desktop-k8s/prometheus-values.yaml  - Scrape configuration          │
│  • monitoring/docker-desktop-k8s/alertrules.yaml         - Alert definitions             │
│  • monitoring/dashboards/*.json                          - Grafana dashboards (shared)   │
│  • monitoring/azure/  monitoring/aws/  monitoring/gcp/   - Cloud platform configs        │
│                                                                                          │
│  ACCESS POINTS (Docker Desktop)                                                          │
│  ═════════════════════════════                                                           │
│  • Grafana:      kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80       │
│  • Prometheus:   kubectl port-forward svc/prometheus-...prometheus -n monitoring 9090    │
│  • Alertmanager: kubectl port-forward svc/prometheus-...alertmanager -n monitoring 9093  │
│                                                                                          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```
