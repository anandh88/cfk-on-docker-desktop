# Confluent for Kubernetes → Splunk Observability Cloud Integration

This document describes a production-oriented integration between Confluent for
Kubernetes (CFK) and Splunk Observability Cloud.

**Splunk Observability Cloud is the primary target for metrics, infrastructure, and
custom dashboarding in this integration — it is not a log storage platform.** This
is a different Splunk product from Splunk Enterprise / Splunk Cloud Platform (see
`../splunk/README-enterprise.md`), with no shared ingestion or query layer, and it
is important to be precise about what it does and doesn't cover before committing to
it as "the Splunk integration":

- **Metrics, infrastructure visibility, and custom dashboards**: fully native to
  this platform. CFK's Kubernetes resource and JMX metrics land here directly and
  are queried/visualized with SignalFlow.
- **Logs**: **not natively supported.** Splunk Observability Cloud has no log
  storage of its own. Log visibility inside this platform (Log Observer Connect, or
  native OTLP log ingestion) is a query bridge to a separate, real Splunk
  Enterprise / Splunk Cloud Platform deployment — it does not replace one. If your
  organization needs CFK logs visible in Splunk, that requirement is met by
  `../splunk/README-enterprise.md`, either standalone or alongside this document,
  not by this document alone.

Confirming which of these your organization actually needs — metrics/observability,
log search, or both — before starting is the single most important step; the two
Splunk products are provisioned, licensed, and integrated independently of one
another.

## Architecture

- **Metrics**: an OpenTelemetry Collector (DaemonSet, one pod per node) runs two
  categories of receiver: the chart's built-in Kubernetes infrastructure receivers
  (`kubelet_stats`, `host_metrics`, `k8s_cluster`), which populate Splunk
  Observability Cloud's built-in Kubernetes navigator automatically, and a
  `prometheus/cfk` receiver that federates `{namespace="<your CFK namespace>"}`
  from your cluster's Prometheus `/federate` endpoint. Both export via the
  `signalfx` exporter.
- **Dashboards**: metrics arriving through the Prometheus receiver are "custom
  metrics" per Splunk's own documentation — they do not populate any built-in
  dashboard or navigator. CFK-specific dashboards (broker/controller/connect/schema
  registry/control center resource visibility) are created as custom SignalFlow
  charts and dashboards, deployed via the Splunk Observability Cloud REST API.
- **Logs**: out of scope for this document — see above.

```
CFK pods (JMX metrics scraped by your Prometheus)
        │
        │ scrape (ServiceMonitor)
        ▼
   Prometheus ── federate ──► OTel Collector (DaemonSet)
                                      │           │
                          kubelet_stats/host_metrics   prometheus/cfk
                                      │           │
                                      └─────┬─────┘
                                            │ signalfx exporter
                                            ▼
                              Splunk Observability Cloud
                                            │
                                            ├── Built-in Kubernetes navigator
                                            └── Custom SignalFlow dashboards
                                                (posted via REST API)
```

## Splunk Observability Cloud-Side Prerequisites

1. **A realm and org access token.** Every API/ingest endpoint is realm-scoped
   (`https://api.<realm>.observability.splunkcloud.com`,
   `https://ingest.<realm>.observability.splunkcloud.com`) — confirm your org's
   realm before writing any config; it is not always `us1`. Create an access token
   scoped to this integration (Settings → Access Tokens) rather than reusing a
   personal or admin token — it is used for both metric ingestion and the dashboard
   REST API calls below, and should be revocable independently of any individual's
   account.
2. **A cardinality/cost governance decision before the first deploy, not after.**
   Splunk Observability Cloud bills on custom metric time series (MTS). Federating
   an entire namespace with `match[]=['{namespace="<ns>"}']` pulls every series any
   ServiceMonitor produces for that namespace — in practice this includes
   per-topic/per-partition JMX breakouts and cAdvisor/kube-state-metrics resource
   series riding along on the same match, which can reach tens of thousands of
   series for a moderately-sized cluster. Decide up front whether to accept that
   cost or narrow the federate `match[]` to specific metric name patterns (e.g.
   `match[]=['{namespace="<ns>", __name__=~"kafka_server_brokertopicmetrics.*"}']`)
   before deploying to a production-sized cluster — this is materially different
   from the Splunk Enterprise side, where the equivalent cardinality growth is a
   collector memory/CPU concern rather than a direct billing one.
3. **A dashboard group** to hold the CFK dashboards (Dashboards → New → Dashboard
   Group, or created via the REST API alongside the dashboards below).

## Kubernetes-Side Prerequisites

This assumes a real multi-node enterprise Kubernetes cluster (EKS, GKE, AKS,
OpenShift, or on-prem) with CFK already deployed via the Confluent Operator.

- Helm 3.8+
- A Prometheus instance already scraping CFK (via ServiceMonitors matching each CFK
  component), whether that's kube-prometheus-stack, a standalone Prometheus, or your
  platform team's existing observability stack
- Cluster-admin or namespace-scoped RBAC sufficient to install a DaemonSet + its
  ServiceAccount/ClusterRole
- Egress to `https://ingest.<realm>.observability.splunkcloud.com` and
  `https://api.<realm>.observability.splunkcloud.com`

### Deployment

Adjust namespace, release name, realm, and values file path to your environment's
conventions. If you also run the Splunk Cloud Platform collector from
`../splunk/README-enterprise.md` on the same cluster, the release name (not just the
namespace) must differ between the two — some of what this chart creates
(`ClusterRole`, `ClusterRoleBinding`) is cluster-scoped and can collide across
namespaces if release names match.

#### 1. Add the Helm repository

```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update
```

#### 2. Author your values file

```yaml
clusterName: "<your-cluster-name>"
environment: "<your-environment-name>"

splunkObservability:
  realm: "<your-realm>"
  # accessToken: passed via --set at install time, see below.
  tracesEnabled: false   # this integration is metrics-only; enable if/when you add trace instrumentation

gateway:
  enabled: false

agent:
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi     # start here; watch for OOMKilled and re-tune against your cluster's actual federate cardinality
    requests:
      cpu: 200m
      memory: 512Mi
  config:
    receivers:
      kubelet_stats:
        insecure_skip_verify: false   # true only if your kubelet cert has no IP SANs and you have no alternative
      prometheus/cfk:
        config:
          scrape_configs:
            - job_name: cfk-metrics
              honor_labels: true
              scrape_interval: 30s
              metrics_path: /federate
              params:
                # Narrow this to specific metric names before running against a
                # production-sized cluster - see the cardinality/cost note above.
                'match[]': ['{namespace="<your-cfk-namespace>"}']
              static_configs:
                - targets: ['<your-prometheus-service>.<your-monitoring-namespace>.svc.cluster.local:9090']
    service:
      pipelines:
        metrics/cfk:
          receivers: [prometheus/cfk]
          processors: [memory_limiter, batch, resource_detection, resource]
          exporters: [signalfx]
```

#### 3. Install

```bash
helm upgrade --install splunk-otel-collector-o11y \
  splunk-otel-collector-chart/splunk-otel-collector \
  --namespace splunk-o11y-otel --create-namespace \
  --values values-production.yaml \
  --set splunkObservability.accessToken=<YOUR_ACCESS_TOKEN>
```

#### 4. Verify

```bash
kubectl get pods -n splunk-o11y-otel
kubectl logs -n splunk-o11y-otel -l component=otel-collector-agent --tail=200 | grep -i "error\|signalfx"
```

In Splunk Observability Cloud, confirm the metric catalog has picked up your CFK
series:

```bash
curl -s -G "https://api.<your-realm>.observability.splunkcloud.com/v2/metric" \
  -H "X-SF-TOKEN: ${SFX_TOKEN}" \
  --data-urlencode "query=sf_metric:kafka*" \
  --data-urlencode "limit=10"
```

## Deploying Dashboards via the REST API

Unlike Splunk Enterprise's Dashboard Studio, Splunk Observability Cloud has no
single-file dashboard import. Charts and dashboards are independent objects created
via two REST calls, then linked by ID — this is the appropriate method for a CI/CD
pipeline or any automated deployment, requiring no UI steps.

**Create a chart:**

```bash
curl -s -X POST "https://api.<your-realm>.observability.splunkcloud.com/v2/chart" \
  -H "X-SF-TOKEN: ${SFX_TOKEN}" -H "Content-Type: application/json" \
  -d '{
    "name": "Kafka Broker Memory %",
    "description": "container_memory_working_set_bytes / kube_pod_container_resource_limits{resource=memory}, per broker pod.",
    "programText": "a = data(\"container_memory_working_set_bytes\", filter=filter(\"namespace\",\"<your-cfk-namespace>\") and filter(\"pod\",\"<your-broker-pod>\"))\nb = data(\"kube_pod_container_resource_limits\", filter=filter(\"namespace\",\"<your-cfk-namespace>\") and filter(\"pod\",\"<your-broker-pod>\") and filter(\"resource\",\"memory\") and filter(\"container\",\"kafka\"))\n(a/b*100).publish(label=\"Memory %\")\n",
    "options": {
      "type": "SingleValue",
      "colorBy": "Dimension",
      "secondaryVisualization": "Radial"
    }
  }'
```

The response includes the new chart's `id`. Note the real field names on
`options` — `secondaryVisualization`, `maximumPrecision`, `timestampHidden` — do not
match the casing used in some third-party Terraform provider documentation; confirm
against a live `GET /v2/chart/{id}` response before scripting a large batch of
these.

**Assemble a dashboard from chart IDs:**

```bash
curl -s -X POST "https://api.<your-realm>.observability.splunkcloud.com/v2/dashboard" \
  -H "X-SF-TOKEN: ${SFX_TOKEN}" -H "Content-Type: application/json" \
  -d '{
    "name": "Kafka Broker Resources",
    "groupId": "<YOUR_DASHBOARD_GROUP_ID>",
    "charts": [
      {"chartId": "<CHART_ID_FROM_ABOVE>", "row": 0, "column": 0, "width": 4, "height": 1}
    ],
    "filters": {"time": {"start": "-15m", "end": "Now"}}
  }'
```

**Update an existing chart's query or options** (in place, same ID — this is how a
dashboard-as-code pipeline pushes changes without re-linking every dashboard that
references it):

```bash
curl -s -X PUT "https://api.<your-realm>.observability.splunkcloud.com/v2/chart/<CHART_ID>" \
  -H "X-SF-TOKEN: ${SFX_TOKEN}" -H "Content-Type: application/json" \
  -d '{ ... same body shape as the create call, with the corrected programText/options ... }'
```

Repeat the chart-then-dashboard sequence for each dashboard your organization needs.
Validate `programText` against your own metric catalog and dimension names first
(`GET /v2/metric` and `GET /v2/metrictimeseries`, both shown above) rather than
assuming a metric name or dimension key from another environment carries over
unchanged — Prometheus label names, ServiceMonitor relabeling rules, and even
whether a given metric is federate-visible at all can differ by cluster.

## Reference

- [Splunk OTel Collector Helm chart](https://github.com/signalfx/splunk-otel-collector-chart)
- [Splunk Observability Cloud — Get started](https://help.splunk.com/en/splunk-observability-cloud/get-started)
- [SignalFlow analytics reference](https://help.splunk.com/en/splunk-observability-cloud/create-dashboards-and-charts/create-charts/functions-reference)
- [Metric types in Observability Cloud](https://help.splunk.com/en/splunk-observability-cloud/manage-data/metrics-metadata-and-events/metrics-events-and-metadata/metric-types)
- [Log Observer Connect](https://help.splunk.com/en/splunk-observability-cloud/observability-data/logs/log-observer-connect)
