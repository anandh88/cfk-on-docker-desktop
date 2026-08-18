# Kafka Connect on AKS — Datadog Setup Guide

**Audience:** Developer deploying CFK Kafka Connect on AKS (3-pod cluster) with Datadog JMX metrics and log forwarding.

---

## How It Works

```
Connect pods (3 replicas)
  └─ JMX port 7203 (bound to pod IP)
       └─ Datadog DaemonSet agent (one per node, jmx image tag)
            ├─ confluent_platform check  →  JMX metrics  →  Datadog dashboards
            └─ container log tail        →  log forwarding →  Datadog Log Explorer
```

Autodiscovery drives everything. The Datadog agent reads `ad.datadoghq.com/*` annotations
on each Connect pod and automatically sets up both JMX collection and log forwarding.
No static config files on the agent side are needed.

---

## Section 1 — Metrics (Dashboarding)

### 1.1 connect.yaml changes

**Required additions to `connect.yaml`:**

- `ad.datadoghq.com/connect.check_names` — tells Datadog which check to run
- `ad.datadoghq.com/connect.init_configs` — JMX check configuration
- `ad.datadoghq.com/connect.instances` — JMX connection details and tags
- `envVars` (`MY_POD_IP` + `_JAVA_OPTIONS`) — overrides CFK's hardcoded JMX hostname
- `configOverrides.jvm` — opens JMX to the pod network
- Internal k8s DNS in `dependencies`

**Metrics annotations :**

```yaml
podTemplate:
  labels:
    env: dev                           # set to your environment name
    service: kafka-connect
    component: connect
    team: data-platform
  annotations:
    ad.datadoghq.com/connect.check_names: '["confluent_platform"]'
    ad.datadoghq.com/connect.init_configs: '[{"is_jmx": true, "collect_default_metrics": true, "service_check_prefix": "confluent", "new_gc_metrics": true, "collect_default_jvm_metrics": true}]'
    ad.datadoghq.com/connect.instances: '[{"jmx_url":"service:jmx:rmi://%%host%%:7203/jndi/rmi://%%host%%:7203/jmxrmi","name":"connect_instance","tags":["component:connect","env:dev","service:kafka-connect","team:data-platform"]}]'
```

> **Optional — `max_returned_metrics`:** JMXFetch caps at 350 metrics per instance by default.
> Connect has >350 JMX beans, so without this cap being raised the aggregate
> `connect-worker-metrics` bean gets silently dropped — "Connector Count", "Running Task Count",
> and "Avg Rebalance Time" widgets will show no data. To fix, add `"max_returned_metrics":1000`
> inside the instances JSON:
> ```
> ..., "name":"connect_instance", "max_returned_metrics":1000, "tags":[...]
> ```
> You can confirm truncation by checking `agent status` — if `metric_count` is exactly 350,
> raise this value.

**JMX binding envVars:**

```yaml
    envVars:
      - name: MY_POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
      - name: _JAVA_OPTIONS
        value: "-Djava.rmi.server.hostname=$(MY_POD_IP)"
```

> **Why these envVars are required:** CFK hardcodes `-Djava.rmi.server.hostname=127.0.0.1`
> in its internal `jvm.config`. You cannot override it via `configOverrides.jvm` (CFK blacklists
> that key). `_JAVA_OPTIONS` is processed by the JVM *after* expanding `@jvm.config`, so the
> pod IP wins. Without this, the Datadog agent gets "Connection refused to host: 127.0.0.1".

**JMX open-bind config — copy exactly as-is:**

```yaml
  configOverrides:
    jvm:
      - -Dcom.sun.management.jmxremote.local.only=false
      - -Dcom.sun.management.jmxremote.host=0.0.0.0
    server:
      - config.storage.replication.factor=3
      - offset.storage.replication.factor=3
      - status.storage.replication.factor=3
      - producer.interceptor.classes=io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor
      - consumer.interceptor.classes=io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor
```

---

### 1.2 datadog-agent-values.yaml changes

**Full AKS values manifest:**

```yaml
datadog:
  site: us5.datadoghq.com

  logs:
    enabled: true
    containerCollectAll: false

  apm:
    enabled: false
  processAgent:
    enabled: false

  containerIncludeMetrics: "kube_namespace:confluent"
  containerIncludeLogs: "kube_namespace:confluent"

  jmxfetch:
    enabled: true

  dogstatsd:
    nonLocalTraffic: true

  collectEvents: true

  prometheusScrape:
    enabled: true

  podLabelsAsTags:
    env: env
    service: service
    component: component
    team: team

  remoteConfiguration:
    enabled: false

  orchestratorExplorer:
    enabled: true

clusterAgent:
  enabled: true
  replicas: 2
  createPodDisruptionBudget: true

agents:
  image:
    tagSuffix: jmx
  containers:
    agent:
      env:
        - name: DD_HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DD_KUBERNETES_KUBELET_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
      resources:
        requests:
          cpu: 200m
          memory: 512Mi
        limits:
          cpu: 500m
          memory: 1Gi
```

**Key explanations:**

- **`site`** — your Datadog intake region; keep as-is
- **`logs.enabled: true`** — required to activate container log tailing; without this the `ad.datadoghq.com/connect.logs` annotation on Connect pods is ignored
- **`logs.containerCollectAll: false`** — only pods with the `ad.datadoghq.com/*.logs` annotation forward logs; keeps ingestion scoped to CFK pods
- **`jmxfetch.enabled: true`** — activates JMX collection; the `confluent_platform` check runs only when this is true
- **`kubelet.tlsVerify`** — not set; AKS kubelet certs are signed by the cluster CA so TLS verification passes by default. See Section 6 for the kubelet cert rotation consideration.
- **`containerIncludeMetrics` / `containerIncludeLogs`** — scopes collection to the `confluent` namespace; prevents the agent scraping unrelated pods in other namespaces
- **`podLabelsAsTags`** — maps pod labels (`env`, `service`, `component`, `team`) to Datadog tags; these are the tags the dashboard filter variables rely on
- **`orchestratorExplorer.enabled: true`** — enables live pod/node/deployment topology in Datadog; valuable on multi-node AKS for correlating Connect worker pod health with node state
- **`clusterAgent.enabled: true`** — on multi-node AKS, the Cluster Agent acts as a single proxy to the k8s API so each node agent does not independently query it; also required for cluster-level checks and HPA metrics
- **`clusterAgent.replicas: 2`** — HA for the Cluster Agent itself
- **`agents.image.tagSuffix: jmx`** — the standard Datadog agent image does not ship with JMXFetch; this suffix selects the `agent:latest-jmx` variant; removing it silently breaks all JMX metric collection
- **`DD_HOSTNAME` / `DD_KUBERNETES_KUBELET_HOST`** — passes the node name and host IP into the agent so it can identify itself and locate the kubelet on each AKS node

> The Helm install command is covered in full in **Section 6 — Installing the Datadog Agent on AKS**.

---

### 1.3 Dashboard import

Two JSON files are in `monitoring/datadog/`:

- `cfk-kafka-connect-connector-level-dashboard.json` — **CFK Kafka Connect Connector Level**
- `cfk-kafka-connect-dashboard.json` — **CFK Kafka Connect Enriched**

**Import steps:**

1. Copy file to clipboard: `cat monitoring/datadog/cfk-kafka-connect-connector-level-dashboard.json | pbcopy`
2. In Datadog: **Dashboards → New Dashboard → Configure (gear) → Import dashboard JSON**
3. Paste → confirm
4. Repeat for the second file

---

#### Dashboard 1 — CFK Kafka Connect Connector Level

Widget queries (all scoped to `kube_namespace:confluent, kube_container_name:connect`):

```json
[
  {
    "widget": "Running Connectors",
    "queries": ["count_nonzero(sum:confluent.kafka.connect.worker.connector_running_task_count{kube_namespace:confluent,kube_container_name:connect} by {connector})"]
  },
  {
    "widget": "Failed Connectors",
    "queries": ["count_nonzero(sum:confluent.kafka.connect.worker.connector_failed_task_count{kube_namespace:confluent,kube_container_name:connect} by {connector})"]
  },
  {
    "widget": "Paused Connectors",
    "queries": ["count_nonzero(sum:confluent.kafka.connect.worker.connector_paused_task_count{kube_namespace:confluent,kube_container_name:connect} by {connector})"]
  },
  {
    "widget": "Task Status by Connector",
    "queries": [
      "sum:confluent.kafka.connect.worker.connector_running_task_count{...} by {connector}",
      "sum:confluent.kafka.connect.worker.connector_failed_task_count{...} by {connector}",
      "sum:confluent.kafka.connect.worker.connector_paused_task_count{...} by {connector}"
    ]
  },
  {
    "widget": "Total Tasks by Connector",
    "queries": ["sum:confluent.kafka.connect.worker.connector_total_task_count{...} by {connector}"]
  },
  {
    "widget": "Messages/sec by Connector",
    "queries": ["avg:confluent.kafka.connect.source_task.source_record_write_rate{...} by {connector}"]
  },
  {
    "widget": "Source Active Records by Connector",
    "queries": ["avg:confluent.kafka.connect.source_task.source_record_active_count_avg{...} by {connector}"]
  },
  {
    "widget": "Lag Proxy by Connector",
    "queries": ["avg:confluent.kafka.connect.sink_task.sink_record_active_count_avg{...} by {connector}"]
  },
  {
    "widget": "Put Batch Avg Latency by Connector",
    "queries": ["avg:confluent.kafka.connect.sink_task.put_batch_avg_time_ms{...} by {connector}"]
  },
  {
    "widget": "Put Batch Max Latency by Connector",
    "queries": ["avg:confluent.kafka.connect.sink_task.put_batch_max_time_ms{...} by {connector}"]
  },
  {
    "widget": "Error Rate by Connector",
    "queries": ["avg:confluent.kafka.connect.task_error.total_record_errors{...} by {connector}"]
  },
  {
    "widget": "Retry Rate by Connector",
    "queries": ["avg:confluent.kafka.connect.task_error.total_retries{...} by {connector}"]
  },
  {
    "widget": "DLQ Requests by Connector",
    "queries": ["avg:confluent.kafka.connect.task_error.deadletterqueue_produce_requests{...} by {connector}"]
  },
  {
    "widget": "CPU (Worker)",
    "queries": ["avg:jvm.cpu_load.process{kube_namespace:confluent,kube_container_name:connect}"]
  },
  {
    "widget": "Heap Used (Worker)",
    "queries": ["avg:jvm.heap_memory{kube_namespace:confluent,kube_container_name:connect}"]
  },
  {
    "widget": "Non-Heap Used (Worker)",
    "queries": ["avg:jvm.non_heap_memory{kube_namespace:confluent,kube_container_name:connect}"]
  }
]
```

**Metric explanations:**

- **`confluent.kafka.connect.worker.connector_running_task_count`** — number of running tasks for a connector on this worker; `count_nonzero` on this gives you the count of connectors that have at least one running task
- **`confluent.kafka.connect.worker.connector_failed/paused_task_count`** — same pattern for failed and paused states; non-zero values here need immediate attention
- **`confluent.kafka.connect.worker.connector_total_task_count`** — total assigned tasks per connector; use alongside running count to detect partial failures
- **`confluent.kafka.connect.source_task.source_record_write_rate`** — records per second successfully written to Kafka by a source connector; primary throughput signal
- **`confluent.kafka.connect.source_task.source_record_active_count_avg`** — records produced but not yet acknowledged by Kafka; high values indicate producer backpressure
- **`confluent.kafka.connect.sink_task.sink_record_active_count_avg`** — records read from Kafka but not yet committed to the sink; proxy for consumer lag at the Connect layer
- **`confluent.kafka.connect.sink_task.put_batch_avg/max_time_ms`** — time taken by the sink connector's `put()` call; spikes indicate slow downstream systems (e.g. database)
- **`confluent.kafka.connect.task_error.total_record_errors`** — records that failed processing and were either dropped or sent to DLQ
- **`confluent.kafka.connect.task_error.total_retries`** — retry attempts; high retries with low errors means transient failures are being recovered
- **`confluent.kafka.connect.task_error.deadletterqueue_produce_requests`** — writes to the dead letter queue; any non-zero value means records are being discarded
- **`jvm.cpu_load.process`** — JVM process CPU as a fraction (0–1); from `collect_default_jvm_metrics: true`
- **`jvm.heap_memory`** / **`jvm.non_heap_memory`** — JVM heap and metaspace/code cache usage in bytes; from `collect_default_jvm_metrics: true`

---

#### Dashboard 2 — CFK Kafka Connect Enriched

Widget queries:

```json
[
  {
    "widget": "JVM Heap Used vs Max",
    "queries": [
      "avg:jvm.heap_memory{kube_namespace:confluent,kube_container_name:connect}",
      "avg:jvm.heap_memory_max{kube_namespace:confluent,kube_container_name:connect}"
    ]
  },
  {
    "widget": "JVM Heap Utilization %",
    "queries": ["(avg:jvm.heap_memory{...}/avg:jvm.heap_memory_max{...})*100"]
  },
  {
    "widget": "CPU Load % (Process vs System)",
    "queries": [
      "avg:jvm.cpu_load.process{kube_namespace:confluent,kube_container_name:connect}*100",
      "avg:jvm.cpu_load.system{kube_namespace:confluent,kube_container_name:connect}*100"
    ]
  },
  {
    "widget": "GC Time",
    "queries": [
      "avg:jvm.gc.major_collection_time{kube_namespace:confluent,kube_container_name:connect}",
      "avg:jvm.gc.minor_collection_time{kube_namespace:confluent,kube_container_name:connect}"
    ]
  },
  {
    "widget": "JVM Heap %",
    "queries": ["(avg:jvm.heap_memory{...}/avg:jvm.heap_memory_max{...})*100"]
  },
  {
    "widget": "Thread Count",
    "queries": ["avg:jvm.thread_count{kube_namespace:confluent,kube_container_name:connect}"]
  }
]
```

**Metric explanations:**

- **`jvm.heap_memory`** — current heap used in bytes; comes from `java.lang:type=Memory HeapMemoryUsage.used`
- **`jvm.heap_memory_max`** — max heap configured (`-Xmx`); used as the denominator for heap utilisation %
- **`jvm.heap_memory` / `jvm.heap_memory_max` × 100** — heap utilisation %; above 85% sustained means the JVM is under memory pressure and GC will become more frequent
- **`jvm.cpu_load.process`** — fraction of CPU used by the JVM process (0.0–1.0); multiplied by 100 in the query to display as %
- **`jvm.cpu_load.system`** — fraction of CPU used by the entire node; comparing process vs system reveals whether Connect is the main CPU consumer
- **`jvm.gc.major_collection_time`** — cumulative time spent in G1 Old Generation (full GC) collections in ms; rising values mean heap pressure; from `new_gc_metrics: true`
- **`jvm.gc.minor_collection_time`** — cumulative time in G1 Young Generation (minor GC); expected to be frequent and short; from `new_gc_metrics: true`
- **`jvm.thread_count`** — live JVM threads; Connect creates one thread per task; a spike may indicate a thread leak or task storm
- All JVM metrics are emitted by `collect_default_jvm_metrics: true` in the `init_configs` annotation — no extra JMX config needed

> **Note:** The old `cfk.*` metric names from the Prometheus/JMX-exporter era do not exist in this JMX setup. The dashboard JSON files in `monitoring/datadog/` already use the correct `confluent.*` and `jvm.*` names.

---

## Section 2 — Log Forwarding

### 2.1 connect.yaml changes

**What to change:**

- Update the `env` tag in the logs annotation to match your environment
- Raise log levels from DEBUG to WARN/INFO in `configOverrides.log4j`

**Log forwarding annotation — update `env` tag only:**

```yaml
  annotations:
    ad.datadoghq.com/connect.logs: '[{"source":"kafka-connect","service":"kafka-connect","tags":["component:connect","env:dev","team:data-platform"]}]'
```

- `source: kafka-connect` maps to the built-in Datadog log parsing pipeline for Kafka Connect
- `service` groups logs in Log Explorer and links to APM traces if enabled
- Tags become filter facets in Log Explorer

**Log levels — change for production:**

```yaml
  configOverrides:
    log4j:
      - log4j.logger.org.apache.kafka.connect.runtime.WorkerSourceTask=WARN
      - log4j.logger.org.apache.kafka.connect.runtime.WorkerSinkTask=WARN
      - log4j.logger.org.apache.kafka.connect.runtime.Worker=INFO
```

> DEBUG on 3 pods with real connector traffic generates very high log volume and increases
> Datadog log ingestion cost significantly.

### 2.2 datadog-agent-values.yaml changes

**Nothing changes for log forwarding.** These settings are already correct:

```yaml
datadog:
  logs:
    enabled: true
    containerCollectAll: false   # only pods with ad.datadoghq.com/*.logs annotation forward logs
  containerIncludeLogs: "kube_namespace:confluent"
```

- `containerCollectAll: false` means only pods with the `ad.datadoghq.com/<container>.logs`
  annotation will have logs forwarded — correct for production

---

## Section 3 — AKS-Specific Prerequisites

### Network policy (if enabled on your AKS cluster)

If Azure Network Policy or Calico is active, add an ingress rule allowing the Datadog DaemonSet
pods to reach Connect pods on port 7203:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-datadog-jmx
  namespace: confluent
spec:
  podSelector:
    matchLabels:
      component: connect
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: datadog-agent
      ports:
        - protocol: TCP
          port: 7203
```

---

## Recap — Datadog Agent Values for AKS

```json
[
  { "key": "kubelet.tlsVerify",                      "value": "not set — AKS kubelet certs are CA-signed; see Section 6 for cert rotation detail" },
  { "key": "orchestratorExplorer.enabled",            "value": "true" },
  { "key": "clusterAgent.enabled",                   "value": "true" },
  { "key": "clusterAgent.replicas",                  "value": "2" },
  { "key": "clusterAgent.createPodDisruptionBudget",  "value": "true" },
  { "key": "agents.image.tagSuffix",                 "value": "jmx — required, do not remove" },
  { "key": "logs.enabled",                           "value": "true — required for log forwarding" },
  { "key": "jmxfetch.enabled",                       "value": "true — required for JMX metrics" },
  { "key": "containerIncludeMetrics/Logs",            "value": "kube_namespace:confluent — scopes collection to CFK pods" },
  { "key": "podLabelsAsTags",                        "value": "env/service/component/team — required for dashboard filters" }
]
```

**Key explanations:**

- **`kubelet.tlsVerify`** — not set; AKS kubelet certs are CA-signed so TLS verification works by default. If your cluster does not have kubelet serving certificate rotation enabled, see Section 6 Step 4 for the additional kubelet config required.
- **`orchestratorExplorer.enabled: true`** — sends live pod, node, deployment, and ReplicaSet state to Datadog's infrastructure map; enables correlating Connect worker health with AKS node state.
- **`clusterAgent.enabled: true`** — on multi-node AKS, without the Cluster Agent each node's DaemonSet pod independently queries the Kubernetes API, multiplying load. The Cluster Agent acts as a single proxy for all node agents.
- **`clusterAgent.replicas: 2`** — runs two Cluster Agent pods so one can fail without losing cluster-level metric collection.
- **`clusterAgent.createPodDisruptionBudget: true`** — prevents both Cluster Agent pods being evicted simultaneously during AKS node drains or upgrades.
- **`agents.image.tagSuffix: jmx`** — selects the `agent:latest-jmx` image variant that bundles JMXFetch. The standard image omits JMXFetch entirely; removing this silently breaks all JMX metric collection.
- **`logs.enabled: true`** — activates the log pipeline; the `ad.datadoghq.com/connect.logs` annotation on Connect pods is ignored unless this is true.
- **`jmxfetch.enabled: true`** — activates the JMX check runner; the `confluent_platform` check cannot run without this.
- **`containerIncludeMetrics/Logs`** — restricts collection to the `confluent` namespace; without this the agent scrapes every pod on the node, increasing cost and noise.
- **`podLabelsAsTags`** — promotes pod labels into Datadog tags; the dashboard filter dropdowns depend on these tags being present on every metric.

---

## Section 4 — Verification

Run these after deployment, in order:

```bash
# 1. All 3 Connect pods running
kubectl get pods -n confluent -l component=connect
# Expected: 3/3 Running

# 2. JMX bound to pod IP (not 127.0.0.1)
kubectl logs connect-0 -n confluent | grep "java.rmi.server.hostname"
# Expected: java.rmi.server.hostname=10.x.x.x

# 3. Datadog collecting metrics from connect_instance
DD_POD=$(kubectl get pod -n datadog-agent -l app=datadog,agent.datadoghq.com/component=agent \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -A 6 "connect_instance"
# Expected: metric_count > 0, status: OK
# metric_count exactly 350 = truncation is happening (max_returned_metrics missing)

# 4. No truncation in JMXFetch log
kubectl exec -n datadog-agent $DD_POD -c agent -- sh -c \
  "grep -E 'sending.*connect_instance|Truncating.*connect' /var/log/datadog/jmxfetch.log | tail -5"
# Expected: "sending NNN metrics" with NO "Truncating" line

# 5. Log forwarding active
kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -A 4 "kafka-connect"
# Expected: source: kafka-connect, status: OK
```

---

## Section 5 — Troubleshooting

```json
[
  {
    "symptom": "Connection refused to host: 127.0.0.1 in jmxfetch.log",
    "cause": "_JAVA_OPTIONS envVar missing from connect.yaml podTemplate",
    "fix": "Add MY_POD_IP fieldRef and _JAVA_OPTIONS envVars to podTemplate.envVars"
  },
  {
    "symptom": "agent status shows metric_count: 350 and WARNING Truncating connect_instance",
    "cause": "max_returned_metrics not set; JMXFetch default cap is 350",
    "fix": "Add max_returned_metrics:1000 inside the instances JSON annotation on the Connect pod"
  },
  {
    "symptom": "Connector Count / Running Task Count / Rebalance Time widgets show No data",
    "cause": "Same truncation — aggregate connect-worker-metrics bean falls past position 350",
    "fix": "Same as above: max_returned_metrics:1000"
  },
  {
    "symptom": "Connect pod stuck in Init or CrashLoop during startup — plugin build fails",
    "cause": "archivePath GitHub raw URL unreachable from private AKS VNet",
    "fix": "Upload the connector ZIP to Azure Blob Storage and update archivePath to the blob URL"
  },
  {
    "symptom": "Logs not appearing in Datadog Log Explorer",
    "cause": "datadog.logs.enabled is false in the Helm values",
    "fix": "Set datadog.logs.enabled: true in datadog-agent-values.yaml and redeploy"
  },
  {
    "symptom": "All dashboard widgets show No data after import",
    "cause": "Dashboard JSON still contains old cfk.* Prometheus metric names",
    "fix": "Re-import the updated JSON files from monitoring/datadog/ — cfk.* names do not exist in the JMX setup"
  },
  {
    "symptom": "JMX collecting on one Connect pod but not others",
    "cause": "Datadog DaemonSet not scheduled on all AKS nodes",
    "fix": "Check pod count matches node count: kubectl get pods -n datadog-agent -o wide"
  }
]
```

**Notes:**

- **Entries 2 and 3 (truncation) are the most common cause of empty dashboard widgets.** The diagnostic signal is `metric_count: 350` exactly in `agent status` — JMXFetch silently stops at the cap so the number is always precisely 350, never 351. The aggregate `connect-worker-metrics` bean (which backs "Connector Count", "Running Task Count", and "Avg Rebalance Time") is large and tends to fall past position 350 when per-connector task beans fill the earlier slots. Raising `max_returned_metrics` to 1000 resolves both entries 2 and 3 in one change.

- **Entry 4 applies only to private AKS clusters with restricted egress.** If your cluster uses a private VNet with outbound firewall rules or a UDR (User Defined Route) sending egress through an NVA, the `archivePath` GitHub raw URL (`raw.githubusercontent.com`) will be blocked. Public AKS clusters with standard outbound NAT can reach it directly. If blocked, the Connect pod will hang in `Init` while the connector plugin build fails — check `kubectl logs <connect-pod> -n confluent -c config-init` for the download error.

- **Entry 6 applies specifically when migrating from a Prometheus/JMX-exporter setup to the pure JMX (`confluent_platform` check) setup.** In the old setup, the JMX exporter's relabelling rules injected a `cfk.` prefix, producing metric names like `cfk.kafka.connect.worker.connector_running_task_count`. The `confluent_platform` check bypasses the exporter entirely and writes metrics directly as `confluent.kafka.connect.worker.connector_running_task_count`. Any dashboard JSON that still references `cfk.*` names will show no data — the metric series simply does not exist. Re-import the updated JSON files from `monitoring/datadog/` which use the correct `confluent.*` and `jvm.*` prefixes.

---

## Section 6 — Installing the Datadog Agent on AKS

> **Source:** [Datadog Kubernetes installation](https://docs.datadoghq.com/containers/kubernetes/installation/?tab=helm) and [AKS-specific distributions guide](https://docs.datadoghq.com/containers/kubernetes/distributions/?tab=helm#aks)

### Prerequisites

- `kubectl` connected to your AKS cluster (`az aks get-credentials --resource-group <RG> --name <CLUSTER>`)
- `helm` v3 installed locally
- Datadog API key from [Datadog → Organization Settings → API Keys](https://app.datadoghq.com/organization-settings/api-keys)
- AKS cluster running Kubernetes 1.16+

---

### Step 1 — Check Kubelet certificate rotation status

AKS has two kubelet TLS modes that require different Datadog config. Check which one your cluster uses:

```bash
kubectl get nodes -L kubernetes.azure.com/kubelet-serving-ca
```

- If the `kubernetes.azure.com/kubelet-serving-ca` column shows **`cluster`** for all nodes → certificate rotation is **enabled** (Kubernetes ≥1.27, node pools updated after July 2025). Use **Option A** below.
- If the column is **blank** → certificate rotation is **not enabled**. Use **Option B** below.

---

### Step 2 — Add the Datadog Helm repo

```bash
helm repo add datadog https://helm.datadoghq.com
helm repo update
```

---

### Step 3 — Store the API key as a Kubernetes secret

Never pass the API key as a plain Helm value. Store it as a secret:

```bash
kubectl create namespace datadog-agent

kubectl create secret generic datadog-secret \
  --from-literal api-key=<DATADOG_API_KEY> \
  --namespace datadog-agent
```

Then reference it in `datadog-agent-values.yaml` instead of the inline `apiKey:` field:

```yaml
datadog:
  apiKeyExistingSecret: datadog-secret   # replaces apiKey: ""
  site: us5.datadoghq.com
```

---

### Step 4 — Add the AKS-specific Helm values

#### Option A — Kubelet certificate rotation enabled (recommended path for Kubernetes ≥1.27)

No extra kubelet config needed. Just add `providers.aks.enabled: true`:

```yaml
providers:
  aks:
    enabled: true
```

This sets `DD_ADMISSION_CONTROLLER_ADD_AKS_SELECTORS=true` automatically, which is required for the Admission Controller webhook to reconcile correctly on AKS.

#### Option B — Kubelet certificate rotation NOT enabled

Add the explicit kubelet host and CA path:

```yaml
datadog:
  kubelet:
    host:
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
    hostCAPath: /etc/kubernetes/certs/kubeletserver.crt

providers:
  aks:
    enabled: true
```

> **Warning:** If your cluster is later upgraded and kubelet certificate rotation is enabled automatically, remove the `kubelet.host` and `hostCAPath` settings. Leaving them in causes the agent pod to fail with:
> `MountVolume.SetUp failed for volume "kubelet-ca" : hostPath type check failed: /etc/kubernetes/certs/kubeletserver.crt is not a file`

#### Option C — Custom DNS / Windows nodes (fallback)

If DNS resolution for `spec.nodeName` does not work inside pods (custom VNet DNS or Windows nodes), use `tlsVerify: false` instead. Do **not** combine this with `kubelet.host`:

```yaml
datadog:
  kubelet:
    tlsVerify: false

providers:
  aks:
    enabled: true
```

---

### Step 5 — Merge AKS values into `datadog-agent-values.yaml`

Add the appropriate block from Step 4 into the existing `monitoring/datadog/datadog-agent-values.yaml`. The full merged file (Option A, the standard path) looks like:

```yaml
datadog:
  apiKeyExistingSecret: datadog-secret
  site: us5.datadoghq.com
  clusterName: <your-aks-cluster-name>   # required: dot-separated, lowercase, ≤80 chars

  logs:
    enabled: true
    containerCollectAll: false

  apm:
    enabled: false
  processAgent:
    enabled: false

  containerIncludeMetrics: "kube_namespace:confluent"
  containerIncludeLogs: "kube_namespace:confluent"

  jmxfetch:
    enabled: true

  dogstatsd:
    nonLocalTraffic: true

  collectEvents: true

  prometheusScrape:
    enabled: true

  podLabelsAsTags:
    env: env
    service: service
    component: component
    team: team

  remoteConfiguration:
    enabled: false

  orchestratorExplorer:
    enabled: true

providers:
  aks:
    enabled: true                # AKS-specific: sets admission controller selector

clusterAgent:
  enabled: true
  replicas: 2
  createPodDisruptionBudget: true

agents:
  image:
    tagSuffix: jmx               # required for JMX metric collection
  containers:
    agent:
      env:
        - name: DD_HOSTNAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DD_KUBERNETES_KUBELET_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
      resources:
        requests:
          cpu: 200m
          memory: 512Mi
        limits:
          cpu: 500m
          memory: 1Gi
```

---

### Step 6 — Install with Helm

```bash
export DD_SITE=us5.datadoghq.com

helm upgrade --install datadog datadog/datadog \
  --namespace datadog-agent \
  --values monitoring/datadog/datadog-agent-values.yaml \
  --set datadog.site="$DD_SITE" \
  --wait
```

> **Note:** `apiKey` is no longer passed via `--set` because it is now stored as the `datadog-secret` Kubernetes secret. Do not pass both `apiKeyExistingSecret` and `--set datadog.apiKey` at the same time.

---

### Step 7 — Verify the installation

```bash
# 1. Agent DaemonSet pods — one per node
kubectl get pods -n datadog-agent -o wide
# Expected: one pod per AKS node, all 3/3 Running

# 2. Cluster Agent pods
kubectl get pods -n datadog-agent -l app=datadog-cluster-agent
# Expected: 2 pods Running (replicas: 2)

# 3. Agent can reach kubelet
DD_POD=$(kubectl get pod -n datadog-agent -l app=datadog,agent.datadoghq.com/component=agent \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -E "kubelet|Hostname"
# Expected: no kubelet connection errors

# 4. confluent_platform check is running
kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -A 6 "connect_instance"
# Expected: status: OK, metric_count > 0
```

---

### AKS-specific notes from official docs

- **`providers.aks.enabled: true`** is the AKS-idiomatic way to configure the Datadog agent. It replaces the manual `DD_ADMISSION_CONTROLLER_ADD_AKS_SELECTORS` env var shown in older guides.
- **`clusterName`** is required on AKS — unlike EKS/GKE, AKS does not expose the cluster name to the agent via metadata APIs so it must be set explicitly. It must be lowercase, dot-separated, and ≤80 characters.
- **Docker Hub rate limits:** The Datadog agent image defaults to Docker Hub on some configurations. To avoid pull failures on production AKS, use the Azure ACR mirror by adding `registry: datadoghq.azurecr.io` to `datadog-agent-values.yaml`.
- **Minimum versions:** AKS with Kubernetes 1.27+ and node pools updated after July 2025 will have kubelet certificate rotation enabled. Check with `kubectl get nodes -L kubernetes.azure.com/kubelet-serving-ca` before choosing Option A vs B above.
