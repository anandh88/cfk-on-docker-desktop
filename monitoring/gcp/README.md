# Google Cloud Managed Prometheus & Grafana Configuration

This folder contains the configurations needed to run the Confluent monitoring dashboards with **Google Cloud Managed Service for Prometheus (GMP)** and **Grafana**, replacing the self-hosted kube-prometheus-stack Grafana and Prometheus instances.

## Architecture

```
JMX MBeans (Confluent components)
  → [connect.yaml / CFK JMX Exporter rules]
    → Prometheus metrics on :7778
      → [prometheus-podmonitoring.yaml]
        → Google Cloud Managed Prometheus (Cloud Monitoring)
          → [grafana-datasource.yaml settings]
            → Grafana (self-hosted on GKE or Grafana Cloud)
              → Dashboard JSON files (monitoring/dashboards/)
```

## Files

| File | Description |
|------|-------------|
| `prometheus-podmonitoring.yaml` | GMP `ClusterPodMonitoring` resources for all Confluent components. GKE-native way to define scrape targets — no static hostnames needed. |
| `grafana-datasource.yaml` | **Reference file** (not a Kubernetes resource). Documents the datasource settings to configure in Grafana so the dashboard JSON files work without modification. |
| `alertrules.yaml` | GMP `ClusterRules` resources for Prometheus alerting rules. Applied with `kubectl apply`. Uses GKE-native CRDs evaluated by the GMP managed rule evaluator. |

## Prerequisites

- A GKE cluster with [Google Cloud Managed Service for Prometheus](https://cloud.google.com/stackdriver/docs/managed-prometheus) enabled
- Grafana instance (self-hosted on GKE or Grafana Cloud)
- CFK-deployed Confluent components with JMX Exporter rules configured (e.g., `metrics.prometheus.rules` in `connect.yaml`)
- IAM permissions configured for querying metrics (see IAM section below)

## Key difference from Azure and AWS

GCP uses **`ClusterPodMonitoring`** custom resources instead of ConfigMap-based scrape configs. The GMP managed collection agent (deployed automatically on GKE) watches for these resources and handles scraping. This means:

- No static target hostnames to maintain
- Automatic discovery of new pods as they scale
- No need for a self-hosted Prometheus instance for scraping

## IAM Configuration

### Metric ingestion (GMP agent → Cloud Monitoring)

The GKE default service account or Workload Identity service account needs the `roles/monitoring.metricWriter` IAM role:

```bash
gcloud projects add-iam-policy-binding <GCP_PROJECT_ID> \
  --member="serviceAccount:<GSA_EMAIL>" \
  --role="roles/monitoring.metricWriter"
```

### Metric querying (Grafana → Cloud Monitoring)

The Grafana service account needs the `roles/monitoring.viewer` IAM role:

```bash
gcloud projects add-iam-policy-binding <GCP_PROJECT_ID> \
  --member="serviceAccount:<GRAFANA_GSA_EMAIL>" \
  --role="roles/monitoring.viewer"
```

If running Grafana on GKE with Workload Identity:

```bash
# Create a Kubernetes service account for Grafana
kubectl create serviceaccount grafana -n monitoring

# Bind it to the Google service account
gcloud iam service-accounts add-iam-policy-binding <GRAFANA_GSA_EMAIL> \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:<GCP_PROJECT_ID>.svc.id.goog[monitoring/grafana]"

# Annotate the Kubernetes service account
kubectl annotate serviceaccount grafana \
  -n monitoring \
  iam.gke.io/gcp-service-account=<GRAFANA_GSA_EMAIL>
```

## Setup

### 1. Enable Google Cloud Managed Prometheus

GMP is enabled by default on GKE Autopilot. For GKE Standard, enable it:

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --zone <ZONE> \
  --enable-managed-prometheus
```

### 2. Deploy scrape targets

Apply the `ClusterPodMonitoring` resources to start scraping all Confluent components:

```bash
kubectl apply -f monitoring/gcp/prometheus-podmonitoring.yaml
```

The GMP managed collection agent will automatically discover and scrape the matching pods. Verify the pod labels match your CFK deployment (the defaults use `app: kafka`, `app: connect`, etc.).

### 3. Configure the Grafana datasource

**Option A — Self-hosted Grafana on GKE (Recommended)**

Install Grafana with the [Prometheus data source for GMP](https://cloud.google.com/stackdriver/docs/managed-prometheus/query#grafana):

1. Deploy Grafana on GKE (via Helm or manifest)
2. Go to **Configuration > Data Sources > Add data source > Prometheus**
3. Set the fields as documented in `grafana-datasource.yaml`:
   - URL: `https://monitoring.googleapis.com/v1/projects/<GCP_PROJECT_ID>/location/global/prometheus`
   - Enable **Google Authentication** (uses Workload Identity)
   - Set UID to `prometheus`
4. Click **Save & Test**

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
    "url": "https://monitoring.googleapis.com/v1/projects/<GCP_PROJECT_ID>/location/global/prometheus",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "timeInterval": "15s",
      "httpMethod": "POST"
    }
  }'
```

### 4. Import dashboards

Import the dashboard JSON files from `monitoring/dashboards/` into Grafana:

- **Grafana UI**: Dashboards > Import > Upload JSON file

No modifications to the dashboard files are needed as long as the datasource UID is set to `prometheus`.

**Note on label mapping:** GMP may add or prefix labels differently. If dashboard queries return no data after import, check whether the `job`, `instance`, and `env` labels are preserved as expected. See the troubleshooting section below.

## Verifying metrics ingestion

After applying the PodMonitoring resources, verify that metrics are flowing. You can query from Cloud Monitoring or from Grafana's **Explore** tab:

```promql
{__name__=~"kafka_connect.*", job="kafka-connect"}
```

Or using `gcloud`:

```bash
gcloud monitoring metrics list \
  --project=<GCP_PROJECT_ID> \
  --filter='metric.type=starts_with("prometheus.googleapis.com/kafka_connect")'
```

If no results appear, check:

1. GMP is enabled on the cluster: `gcloud container clusters describe <CLUSTER_NAME> --format="value(monitoringConfig)"`
2. The `ClusterPodMonitoring` resources are created: `kubectl get clusterpodmonitoring`
3. That the Confluent pods have matching labels (`app: kafka`, `app: connect`, etc.)
4. That the Confluent pods are exposing JMX metrics on port `7778`

## Troubleshooting

### Dashboards show "N/A"

- Verify the datasource UID is set to `prometheus` in Grafana (Configuration > Data Sources)
- Confirm metrics are being ingested (see verification step above)

### Missing metrics (e.g. `kafka_connect_connect_worker_metrics_connector_total_task_count`)

GMP stores Prometheus metrics under the `prometheus.googleapis.com` prefix in Cloud Monitoring. When queried via the GMP Prometheus-compatible API, the prefix is stripped. Check the actual metric names:

```promql
{__name__=~"kafka_connect.*task_count.*", job="kafka-connect"}
```

If the metric name differs, update the dashboard JSON queries to match.

### Label mismatches

GMP may add extra labels (e.g., `project_id`, `location`, `cluster`, `namespace`). The `job` label comes from the `ClusterPodMonitoring` resource name by default. If your dashboard queries filter on `job="kafka-connect"`, ensure the `ClusterPodMonitoring` resource name matches or add a `jobLabel` override.

To explicitly set the `job` label, add `targetLabels.fromPod` to the `ClusterPodMonitoring`:

```yaml
spec:
  targetLabels:
    metadata:
      - pod
      - namespace
    fromPod:
      - name: app
        targetLabel: job
```

### Template variables not populating

The dashboard template variables (env, cluster_id, instance, connector) all depend on the `kafka_connect_connect_worker_metrics_connector_total_task_count` metric. If this metric is missing or named differently, all dropdowns will be empty and panels will show "N/A".
