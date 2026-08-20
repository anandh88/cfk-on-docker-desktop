# Confluent for Kubernetes → Splunk Enterprise Integration

This document describes a production-oriented integration between Confluent for
Kubernetes (CFK) and a Splunk Enterprise / Splunk Cloud deployment.

**Splunk is the primary observability target for this integration.**
The data flow is one-directional — CFK's logs and metrics are pushed into Splunk.
Prometheus is used only as the metrics *source* the pipeline federates from (most
enterprise Kubernetes platforms already run one for cluster-level scraping); if your
organization has no independent need for Prometheus/Grafana, the metrics pipeline can
instead be pointed at a direct Prometheus deployment stood up solely to feed Splunk.

## Architecture

- **Logs**: an OpenTelemetry Collector (DaemonSet, one pod per node) tails CFK
  container logs from `/var/log/pods`, enriches them with Kubernetes metadata, and
  forwards them to Splunk via HEC as events.
- **Metrics**: the same collector's `prometheus/cfk` receiver federates
  `{namespace="<your CFK namespace>"}` from your cluster's Prometheus `/federate`
  endpoint and forwards it to Splunk via HEC as metrics.
- **Dashboards**: Splunk Dashboard Studio JSON definitions, deployed via the Splunk
  REST API.

```
CFK pods (logs on disk, JMX metrics on :7778)
        │                              │
        │ file tail                    │ scrape (ServiceMonitor)
        ▼                              ▼
  OTel Collector (DaemonSet)  ◄── federate ── Prometheus
        │
        │ HEC (events + metrics)
        ▼
     Splunk Enterprise / Splunk Cloud
        │
        └── Dashboard Studio dashboards (posted via REST API)
```

## Splunk-Side Prerequisites

1. **Dedicated indexes** — do not default to `main`. Create:

   - `cfk_logs` (event-type index) for CFK log data
   - `cfk_metrics` (metrics-type index) for CFK metric data — this **must** be created
     as a metrics-type index (Splunk Web → Settings → Indexes → New Index → Index
     Data Type: **Metrics**); an event-type index silently rejects metric-formatted
     HEC payloads with no useful error.

   Reusing an existing shared index is only appropriate if your organization's data
   governance/retention tiering requires it (e.g. a single "platform-logs" index with
   consistent retention/access controls across all infrastructure sources) — in that
   case, use `sourcetype` (below) as the field you filter and route on instead of the
   index.
2. **A namespaced sourcetype** — pick one that follows your org's
   `<vendor>:<product>:<data-type>` convention, e.g.:

   - `cfk:log` for all CFK log events (simplest, adequate for most teams)
   - or, if your team wants finer per-component field extraction:
     `cfk:kafka:log`, `cfk:connect:log`, `cfk:schemaregistry:log`, etc. — this needs an
     OTel `transform` processor keyed on the `k8s.pod.labels.app` (or equivalent)
     resource attribute to set `sourcetype` dynamically per component; add it to the
     collector config below if you want the finer grain.
3. **HEC token** — create it scoped to exactly the two indexes above (Settings → Data
   Inputs → HTTP Event Collector → New Token), with:

   - Allowed indexes: `cfk_logs`, `cfk_metrics`
   - Default index: `cfk_logs`
   - Sourcetype: your chosen value from (2)
   - Indexer acknowledgement: your org's standard for infrastructure telemetry
     (enable it if you need delivery guarantees over throughput)
4. **Dashboard deployment credentials** — a Splunk auth token (preferred) or
   service account with capability to write dashboards in the target app context
   (`admin_all_objects`, or a role scoped to `write` on `data/ui/views` in that app).
   Do not reuse the HEC token for this — HEC tokens can only submit data, not manage
   dashboard objects.

## Kubernetes-Side Prerequisites

This assumes a real multi-node enterprise Kubernetes cluster (EKS, GKE, AKS,
OpenShift, or on-prem) with CFK already deployed via the Confluent Operator, and
egress to your Splunk HEC endpoint (typically `:8088`, TLS-terminated with a
certificate your cluster's trust store recognizes — if your Splunk instance presents
an internally-issued cert, distribute the CA to the collector via a mounted secret
rather than disabling TLS verification).

- Helm 3.8+
- A Prometheus instance already scraping CFK (via ServiceMonitors matching each CFK
  component), whether that's kube-prometheus-stack, a standalone Prometheus, or your
  platform team's existing observability stack
- Cluster-admin or namespace-scoped RBAC sufficient to install a DaemonSet + its
  ServiceAccount/ClusterRole

### Deployment

Adjust namespace, release name, and values file path to your environment's
conventions.

### 1. Create the namespace and the HEC token secret

```bash
kubectl create namespace splunk-otel

kubectl create secret generic splunk-hec \
  --from-literal=splunk_platform_hec_token=<YOUR_HEC_TOKEN> \
  --namespace splunk-otel
```

The secret must exist before the Helm install below — the collector reads it at pod
startup and will fail to come up if it's missing. Key name must be exactly
`splunk_platform_hec_token`; that's the chart's own convention
(`splunk-otel-collector-chart`'s documented "provide tokens as a secret" pattern), not
an arbitrary choice.

### 2. Add the Helm repository

```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update
```

### 3. Author your values file

```yaml
clusterName: "<your-cluster-name>"
distribution: "eks"   # or "gke", "aks", "openshift", or "" for generic/on-prem

splunkPlatform:
  endpoint: "https://<your-splunk-host>:8088/services/collector/event"
  index: "cfk_logs"
  sourcetype: "cfk:log"
  insecureSkipVerify: false   # true only if you have no alternative to a self-signed/internal CA
  maxConnections: 200
  timeout: 10s

secret:
  create: false
  name: "splunk-hec"

agent:
  enabled: true
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi
    requests:
      cpu: 200m
      memory: 512Mi
  config:
    receivers:
      prometheus/cfk:
        config:
          scrape_configs:
            - job_name: cfk-metrics
              honor_labels: true
              scrape_interval: 30s
              metrics_path: /federate
              params:
                'match[]': ['{namespace="<your-cfk-namespace>"}']
              static_configs:
                - targets: ['<your-prometheus-service>.<your-monitoring-namespace>.svc.cluster.local:9090']
    exporters:
      splunk_hec/cfk_metrics:
        endpoint: "https://<your-splunk-host>:8088/services/collector/event"
        token: "${SPLUNK_PLATFORM_HEC_TOKEN}"
        index: cfk_metrics
        source: kubernetes
        sourcetype: cfk:log
        tls:
          insecure_skip_verify: false
    service:
      pipelines:
        metrics/cfk:
          receivers: [prometheus/cfk]
          processors: [memory_limiter, batch, resource_detection, resource]
          exporters: [splunk_hec/cfk_metrics]
```

### 4. Install

```bash
helm upgrade --install splunk-otel-collector \
  splunk-otel-collector-chart/splunk-otel-collector \
  --namespace splunk-otel \
  --values values-production.yaml
```

### 5. Verify

```bash
kubectl get pods -n splunk-otel
kubectl logs -n splunk-otel -l app=splunk-otel-collector-agent --tail=200 | grep -i "splunk_hec\|export"
```

In Splunk:

```spl
index=cfk_logs sourcetype="cfk:log" | stats count
| mstats count(_value) WHERE index=cfk_metrics span=1m
```

## Deploying Dashboards Remotely via the Splunk REST API

Dashboard Studio dashboards are stored as `views` objects. Posting one doesn't
require Splunk Web at all — this is the appropriate method for a CI/CD pipeline or
any automated deployment, letting you push these dashboards into your Splunk instance
without manual UI steps.

The REST API does **not** accept the raw dashboard JSON directly — it expects the
JSON wrapped in a small XML shell inside a `<definition>` CDATA block. This is
Splunk's own documented format
(`docs/manage-dashboards/create-a-dashboard-using-rest-api-endpoints`).

**Create a new dashboard:**

```bash
DASHBOARD_JSON=$(cat dashboards/Kafka_splunk.json)

curl -k \
  -H "Authorization: Bearer ${SPLUNK_AUTH_TOKEN}" \
  "https://<your-splunk-host>:8089/servicesNS/nobody/search/data/ui/views" \
  --data-urlencode "name=cfk_kafka_cluster" \
  --data-urlencode "eai:data=<dashboard version=\"2\">
    <label>Confluent Kafka Cluster</label>
    <description>CFK Kafka broker/controller observability</description>
    <definition><![CDATA[${DASHBOARD_JSON}]]></definition>
  </dashboard>"
```

**Update an existing dashboard** (append the dashboard's name to the endpoint path):

```bash
curl -k \
  -H "Authorization: Bearer ${SPLUNK_AUTH_TOKEN}" \
  "https://<your-splunk-host>:8089/servicesNS/nobody/search/data/ui/views/cfk_kafka_cluster" \
  --data-urlencode "eai:data=<dashboard version=\"2\">
    <label>Confluent Kafka Cluster</label>
    <definition><![CDATA[${DASHBOARD_JSON}]]></definition>
  </dashboard>"
```

`-u admin:password` basic auth also works in place of the bearer token if your
environment doesn't use Splunk auth tokens, but a scoped token is the appropriate
choice for an automated deployment — it can be revoked independently of any human
account. The account or token needs write capability on `data/ui/views` in the target
app context (`search` in the examples above; use whatever app your organization
standardizes dashboards under).

Repeat for each dashboard file in `dashboards/`, giving each a unique `name`.

## Reference

- [Splunk OTel Collector Helm chart](https://github.com/signalfx/splunk-otel-collector-chart)
- [Splunk: Create a dashboard using REST API endpoints](https://help.splunk.com/en/splunk-enterprise/create-dashboards-and-reports/dashboard-studio/9.4/manage-dashboards/create-a-dashboard-using-rest-api-endpoints)
- [Splunk HEC metrics format](https://docs.splunk.com/Documentation/Splunk/latest/Metrics/GetMetricsInOther)
- [`mstats` command reference](https://docs.splunk.com/Documentation/Splunk/latest/SearchReference/Mstats)
