# Azure Managed Prometheus & Grafana Configuration

This folder contains the configurations needed to run the Confluent monitoring dashboards with **Azure Managed Prometheus** and **Azure Managed Grafana**, replacing the self-hosted kube-prometheus-stack Grafana and Prometheus instances.

## Architecture

```
JMX MBeans (Confluent components)
  → [connect.yaml / CFK JMX Exporter rules]
    → Prometheus metrics on :7778
      → [ama-metrics-prometheus-config.yaml]
        → Azure Managed Prometheus (Azure Monitor workspace)
          → [grafana-datasource.yaml settings]
            → Azure Managed Grafana
              → Dashboard JSON files (monitoring/dashboards/)
```

## Files

| File | Description |
|------|-------------|
| `ama-metrics-prometheus-config.yaml` | Kubernetes ConfigMap for the Azure Monitor agent (`ama-metrics`) to scrape JMX metrics from all Confluent components. Applied with `kubectl apply`. |
| `grafana-datasource.yaml` | **Reference file** (not a Kubernetes resource). Documents the datasource settings to configure in Azure Managed Grafana so the dashboard JSON files work without modification. |
| `alertrules.yaml` | Prometheus alert rule groups for Azure Managed Prometheus. Deployed via Azure CLI (`az monitor account prometheus-rule-group create`) or Azure Portal. Uses ISO 8601 durations and numeric severity levels. |

## Prerequisites

- An AKS cluster with [Azure Monitor managed service for Prometheus](https://learn.microsoft.com/en-us/azure/azure-monitor/essentials/prometheus-metrics-overview) enabled
- An [Azure Managed Grafana](https://learn.microsoft.com/en-us/azure/managed-grafana/overview) instance linked to the Azure Monitor workspace
- The Azure Monitor agent (`ama-metrics`) deployed on the AKS cluster
- CFK-deployed Confluent components with JMX Exporter rules configured (e.g., `metrics.prometheus.rules` in `connect.yaml`)

## Setup

### 1. Configure metric scraping

Update the targets in `ama-metrics-prometheus-config.yaml` to match your environment (hostnames, replica counts, namespace), then apply:

```bash
kubectl apply -f monitoring/azure/ama-metrics-prometheus-config.yaml
```

The `ama-metrics` agent in `kube-system` will automatically pick up the new scrape config. Allow a few minutes for metrics to appear in the Azure Monitor workspace.

### 2. Configure the Grafana datasource

Azure Managed Grafana does **not** use a Kubernetes sidecar to discover datasources. Configure the Prometheus datasource through one of the following methods:

**Option A — Azure Portal (Recommended)**

Link your Azure Monitor workspace to the Managed Grafana instance. This auto-provisions the datasource. After linking, update the datasource UID to `prometheus`:

1. Open Azure Managed Grafana UI
2. Go to **Configuration > Data Sources**
3. Click the auto-provisioned Prometheus datasource
4. Under **Settings**, set the UID to `prometheus`
5. Click **Save & Test**

**Option B — Grafana UI (Manual)**

1. Go to **Configuration > Data Sources > Add data source > Prometheus**
2. Set the fields as documented in `grafana-datasource.yaml`
3. The UID **must** be set to `prometheus` to match the dashboard references
4. Click **Save & Test**

**Option C — Grafana API**

```bash
curl -X POST https://<GRAFANA_ENDPOINT>/api/datasources \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "uid": "prometheus",
    "url": "https://<AZURE_MONITOR_WORKSPACE_ID>.prometheus.monitor.azure.com",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "timeInterval": "15s",
      "httpMethod": "POST"
    }
  }'
```

### 3. Import dashboards

Import the dashboard JSON files from `monitoring/dashboards/` into Azure Managed Grafana:

- **Azure Portal**: Managed Grafana resource > Dashboards > Import > Upload JSON
- **Grafana UI**: Dashboards > Import > Upload JSON file

No modifications to the dashboard files are needed as long as the datasource UID is set to `prometheus`.

## Verifying metrics ingestion

After applying the scrape config, verify that metrics are flowing by running this query in Azure Managed Grafana's **Explore** tab:

```promql
{__name__=~"kafka_connect.*", job="kafka-connect"}
```

If no results appear, check:

1. The `ama-metrics` pod logs in `kube-system` for scrape errors
2. That the Confluent pods are exposing JMX metrics on port `7778`
3. Network policies are not blocking scraping from `kube-system` to the `confluent` namespace

## Troubleshooting

### Dashboards show "N/A"

- Verify the datasource UID is set to `prometheus` in Azure Managed Grafana (Configuration > Data Sources)
- Confirm metrics are being ingested (see verification step above)

### Missing metrics (e.g. `kafka_connect_connect_worker_metrics_connector_total_task_count`)

Azure Managed Prometheus may sanitize metric names. Check the actual metric names available:

```promql
{__name__=~"kafka_connect.*task_count.*", job="kafka-connect"}
```

If the metric name differs, update the dashboard JSON queries to match.

### Template variables not populating

The dashboard template variables (env, cluster_id, instance, connector) all depend on the `kafka_connect_connect_worker_metrics_connector_total_task_count` metric. If this metric is missing or named differently, all dropdowns will be empty and panels will show "N/A".
