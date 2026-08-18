# Amazon Managed Prometheus & Grafana Configuration

This folder contains the configurations needed to run the Confluent monitoring dashboards with **Amazon Managed Service for Prometheus (AMP)** and **Amazon Managed Grafana (AMG)**, replacing the self-hosted kube-prometheus-stack Grafana and Prometheus instances.

## Architecture

```
JMX MBeans (Confluent components)
  → [connect.yaml / CFK JMX Exporter rules]
    → Prometheus metrics on :7778
      → [prometheus-remote-write.yaml scrape configs + remote_write]
        → Amazon Managed Prometheus (AMP workspace)
          → [grafana-datasource.yaml settings]
            → Amazon Managed Grafana (AMG workspace)
              → Dashboard JSON files (monitoring/dashboards/)
```

## Files

| File | Description |
|------|-------------|
| `prometheus-remote-write.yaml` | Scrape configs for all Confluent components and remote-write configuration reference for sending metrics to AMP. Used by Prometheus or ADOT Collector. |
| `grafana-datasource.yaml` | **Reference file** (not a Kubernetes resource). Documents the datasource settings to configure in Amazon Managed Grafana so the dashboard JSON files work without modification. |
| `alertrules.yaml` | Prometheus alert rule groups for Amazon Managed Prometheus. Deployed via `aws amp create-rule-groups-namespace` CLI. Uses standard Prometheus alerting rule format. |

## Prerequisites

- An EKS cluster
- An [Amazon Managed Service for Prometheus](https://docs.aws.amazon.com/prometheus/latest/userguide/what-is-Amazon-Managed-Service-Prometheus.html) (AMP) workspace
- An [Amazon Managed Grafana](https://docs.aws.amazon.com/grafana/latest/userguide/what-is-Amazon-Managed-Service-Grafana.html) (AMG) workspace linked to the AMP workspace
- CFK-deployed Confluent components with JMX Exporter rules configured (e.g., `metrics.prometheus.rules` in `connect.yaml`)
- IAM roles configured for metric ingestion and querying (see IAM section below)

## IAM Configuration

### Metric ingestion (Prometheus / ADOT → AMP)

The scraping component needs an IAM role with the `AmazonPrometheusRemoteWriteAccess` policy. Attach this using [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html):

```bash
# Create the IRSA for the Prometheus service account
eksctl create iamserviceaccount \
  --name prometheus-server \
  --namespace monitoring \
  --cluster <EKS_CLUSTER_NAME> \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess \
  --approve
```

### Metric querying (AMG → AMP)

The AMG workspace IAM role needs the `AmazonPrometheusQueryAccess` policy. This is typically configured when linking the AMP workspace to AMG through the AWS Console.

## Setup

### 1. Configure metric scraping and remote write

There are two approaches to get metrics into AMP:

**Option A — Prometheus with remote-write (Recommended for migration)**

Keep the kube-prometheus-stack Helm chart but add `remoteWrite` to the Helm values. Add the following to `prometheus-values.yaml` under `prometheus.prometheusSpec`:

```yaml
prometheus:
  prometheusSpec:
    remoteWrite:
      - url: "https://aps-workspaces.<AWS_REGION>.amazonaws.com/workspaces/<AMP_WORKSPACE_ID>/api/v1/remote_write"
        sigv4:
          region: <AWS_REGION>
        queueConfig:
          maxSamplesPerSend: 1000
          maxShards: 200
          capacity: 2500
```

The existing `additionalScrapeConfigs` in `prometheus-values.yaml` continue to work — Prometheus scrapes locally and forwards to AMP.

**Option B — ADOT Collector (AWS-native)**

Deploy the [AWS Distro for OpenTelemetry (ADOT) Collector](https://docs.aws.amazon.com/eks/latest/userguide/opentelemetry.html) as a replacement for Prometheus. Use the scrape configs from `prometheus-remote-write.yaml` in the ADOT Collector's Prometheus receiver configuration.

### 2. Configure the Grafana datasource

Amazon Managed Grafana does **not** run inside the cluster. Configure the Prometheus datasource through one of the following methods:

**Option A — AWS Console (Recommended)**

1. Open the AMG workspace in the AWS Console
2. Go to **Data sources > Configure in Grafana**
3. Select **Amazon Managed Service for Prometheus**
4. Select your AMP workspace
5. After provisioning, open the Grafana UI and update the datasource UID to `prometheus`:
   - Go to **Configuration > Data Sources**
   - Click the AMP datasource
   - Set the UID to `prometheus`
   - Click **Save & Test**

**Option B — Grafana UI (Manual)**

1. Go to **Configuration > Data Sources > Add data source > Prometheus**
2. Set the fields as documented in `grafana-datasource.yaml`
3. Enable **SigV4 auth** and set the Default Region to your AWS region
4. The UID **must** be set to `prometheus` to match the dashboard references
5. Click **Save & Test**

**Option C — Grafana API**

```bash
curl -X POST https://<AMG_WORKSPACE_ENDPOINT>/api/datasources \
  -H "Authorization: Bearer <API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus",
    "type": "prometheus",
    "uid": "prometheus",
    "url": "https://aps-workspaces.<AWS_REGION>.amazonaws.com/workspaces/<AMP_WORKSPACE_ID>",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "timeInterval": "15s",
      "httpMethod": "POST",
      "sigV4Auth": true,
      "sigV4AuthType": "default",
      "sigV4Region": "<AWS_REGION>"
    }
  }'
```

### 3. Import dashboards

Import the dashboard JSON files from `monitoring/dashboards/` into Amazon Managed Grafana:

- **Grafana UI**: Dashboards > Import > Upload JSON file

No modifications to the dashboard files are needed as long as the datasource UID is set to `prometheus`.

## Verifying metrics ingestion

After configuring scraping and remote write, verify that metrics are flowing by running this query in Amazon Managed Grafana's **Explore** tab:

```promql
{__name__=~"kafka_connect.*", job="kafka-connect"}
```

If no results appear, check:

1. The Prometheus or ADOT Collector pod logs for remote-write errors
2. That the IRSA role has `AmazonPrometheusRemoteWriteAccess` permissions
3. That the Confluent pods are exposing JMX metrics on port `7778`
4. Network policies are not blocking scraping from the `monitoring` namespace to the `confluent` namespace

## Troubleshooting

### Dashboards show "N/A"

- Verify the datasource UID is set to `prometheus` in Amazon Managed Grafana (Configuration > Data Sources)
- Confirm metrics are being ingested (see verification step above)

### Missing metrics (e.g. `kafka_connect_connect_worker_metrics_connector_total_task_count`)

Check the actual metric names available in AMP:

```promql
{__name__=~"kafka_connect.*task_count.*", job="kafka-connect"}
```

If the metric name differs, update the dashboard JSON queries to match.

### Template variables not populating

The dashboard template variables (env, cluster_id, instance, connector) all depend on the `kafka_connect_connect_worker_metrics_connector_total_task_count` metric. If this metric is missing or named differently, all dropdowns will be empty and panels will show "N/A".

### Remote write errors (403 / 401)

- Verify the IRSA annotation on the Prometheus service account: `kubectl describe sa prometheus-server -n monitoring`
- Confirm the IAM role trust policy allows the EKS OIDC provider
- Check the AMP workspace ID and region in the remote-write URL
