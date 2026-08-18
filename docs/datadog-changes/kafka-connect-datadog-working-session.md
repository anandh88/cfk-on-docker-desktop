# Kafka Connect — Datadog Monitoring Working Session

**Scope:** Step-by-step guide to enable JMX metrics and log forwarding for CFK Kafka Connect on AKS.  
**Assumptions:** CFK is deployed and all Connect pods are Running. Datadog Agent is installed in the AKS cluster via Helm.

---

## Pre-flight check

```bash
# Confirm CFK Connect pods are healthy
kubectl get pods -n confluent -l component=connect
# All pods must be Running before you start

# Confirm Datadog DaemonSet is running on every node
kubectl get pods -n datadog-agent -l app=datadog -o wide
# Pod count must equal node count
```

---

## Step 1 — Edit connect.yaml

Four additions are required. Apply all of them before running `kubectl apply`.

### 1a. Pod labels

Set `env` to the actual environment name. The other three values are fixed:

```yaml
podTemplate:
  labels:
    env: dev          # change to: dev / staging / prod
    service: standard-connect
    component: connect
    team: eda-ibte
```

### 1b. Autodiscovery annotations

Add all three under `podTemplate.annotations`. Replace `env:dev` inside the instances and logs JSON to match your environment label:

```yaml
    annotations:
      ad.datadoghq.com/connect.check_names: '["confluent_platform"]'
      ad.datadoghq.com/connect.init_configs: '[{"is_jmx": true, "collect_default_metrics": true, "service_check_prefix": "confluent", "new_gc_metrics": true, "collect_default_jvm_metrics": true}]'
      ad.datadoghq.com/connect.instances: '[{"jmx_url":"service:jmx:rmi://%%host%%:7203/jndi/rmi://%%host%%:7203/jmxrmi","name":"connect_instance","tags":["component:connect","env:dev","service:standard-connect","team:eda-ibte"]}]'
      ad.datadoghq.com/connect.logs: '[{"source":"kafka-connect","service":"standard-connect","tags":["component:connect","env:dev","team:eda-ibte"]}]'
```

> **Optional — raise the JMX metric cap:** JMXFetch caps at 350 metrics per instance by default.
> Connect has >350 JMX beans so the aggregate `connect-worker-metrics` bean can be silently
> dropped. If after Step 4 you see `metric_count: 350` exactly in `agent status`, add
> `"max_returned_metrics":1000` inside the instances JSON (before the `"tags"` key):
> ```
> ..., "name":"connect_instance", "max_returned_metrics":1000, "tags":[...]
> ```

### 1c. envVars

Add under `podTemplate`. These override CFK's hardcoded `java.rmi.server.hostname=127.0.0.1`
so the Datadog agent can reach JMX from outside the pod:

```yaml
    envVars:
      - name: MY_POD_IP
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
      - name: _JAVA_OPTIONS
        value: "-Djava.rmi.server.hostname=$(MY_POD_IP)"
```

### 1d. configOverrides

Add/merge under `spec`. The `jvm` block opens JMX to non-localhost connections.
The `log4j` block prevents a DEBUG log flood on a multi-pod production cluster:

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
    log4j:
      - log4j.logger.org.apache.kafka.connect.runtime.WorkerSourceTask=INFO
      - log4j.logger.org.apache.kafka.connect.runtime.WorkerSinkTask=INFO
      - log4j.logger.org.apache.kafka.connect.runtime.Worker=INFO
```

---

## Step 2 — Verify / update datadog-agent-values.yaml

The Datadog Agent Helm values must have the following settings active for JMX metrics and log
forwarding to work. If the agent is already deployed, check the current values and patch if
anything is missing.

### Required settings

```yaml
datadog:
  site: us5.datadoghq.com          # set to your Datadog site

  logs:
    enabled: true                  # REQUIRED — activates log pipeline
    containerCollectAll: false     # only pods with ad.datadoghq.com/*.logs annotation forward logs

  jmxfetch:
    enabled: true                  # REQUIRED — activates the confluent_platform JMX check

  containerIncludeMetrics: "kube_namespace:confluent"
  containerIncludeLogs: "kube_namespace:confluent"

  podLabelsAsTags:
    env: env
    service: service
    component: component
    team: team

  orchestratorExplorer:
    enabled: true

clusterAgent:
  enabled: true
  replicas: 2
  createPodDisruptionBudget: true

agents:
  image:
    tagSuffix: jmx                 # REQUIRED — selects the agent:latest-jmx image with JMXFetch bundled
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
```

**Key settings that directly affect Connect monitoring:**

| Setting | Why it matters for Connect |
|---|---|
| `logs.enabled: true` | Without this the `ad.datadoghq.com/connect.logs` annotation is silently ignored |
| `jmxfetch.enabled: true` | Without this the `confluent_platform` check never runs, no JMX metrics collected |
| `agents.image.tagSuffix: jmx` | Standard agent image has no JMXFetch binary; removing this breaks all JMX collection with no error message |
| `podLabelsAsTags` | Promotes the `service`, `component`, `team`, `env` pod labels to Datadog tags; the dashboard `$env`/`$service` filter dropdowns depend on these |
| `containerIncludeMetrics/Logs` | Scopes collection to the `confluent` namespace; prevents the agent scraping every pod on the node |

### Check current values

```bash
helm get values datadog -n datadog-agent
```

### Apply changes (if needed)

```bash
helm upgrade datadog datadog/datadog \
  --namespace datadog-agent \
  --reuse-values \
  --values monitoring/datadog/datadog-agent-values.yaml
```

> `--reuse-values` carries over all existing settings; only keys present in the values file are
> overridden. Use this when patching a live agent to avoid resetting unrelated config.

---

## Step 3 — Apply the connect.yaml manifest

```bash
kubectl apply -f connect.yaml
```

Watch the rolling restart complete before proceeding:

```bash
kubectl rollout status statefulset/connect -n confluent
```

---

## Step 4 — Verify JMX is bound to the pod IP

```bash
kubectl logs connect-0 -n confluent | grep "java.rmi.server.hostname"
```

**Expected:**
```
java.rmi.server.hostname=10.x.x.x
```

If you see `127.0.0.1` — the `_JAVA_OPTIONS` envVar was not picked up. Check that `envVars` is nested under `podTemplate`, not directly under `spec`.

---

## Step 5 — Verify Datadog is collecting JMX metrics

```bash
DD_POD=$(kubectl get pod -n datadog-agent -l app=datadog,agent.datadoghq.com/component=agent \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -A 8 "connect_instance"
```

**Expected:**
```
connect_instance
  metric_count: 180    ← any non-zero number that is NOT exactly 350
  service_check_count: 1
  status: OK
```

| Result | Cause | Fix |
|---|---|---|
| `status: CRITICAL` — "Connection refused to host: 127.0.0.1" | Step 3 failed — envVars not applied | Confirm `envVars` block placement and re-apply |
| `metric_count: 350` exactly | JMXFetch truncation — aggregate bean dropped | Add `"max_returned_metrics":1000` to instances annotation, re-apply |
| Section missing entirely | Autodiscovery annotations not seen by agent | Confirm pods restarted after apply; check annotation syntax with `kubectl describe pod connect-0 -n confluent` |

---

## Step 6 — Verify log forwarding

```bash
kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -A 5 "kafka-connect"
```

**Expected:**
```
  source: kafka-connect
  status: OK
```

If this section is missing — `datadog.logs.enabled` is `false` in your Datadog Helm values. Set it to `true` and run `helm upgrade`.

---

## Step 7 — Import dashboards

Two JSON files are in `monitoring/datadog/`:

| File | Dashboard name |
|---|---|
| `cfk-kafka-connect-dashboard.json` | CFK Kafka Connect Enriched (JVM / worker-level) |
| `cfk-kafka-connect-connector-level-dashboard.json` | CFK Kafka Connect Connector Level (per-connector tasks / throughput / errors) |

**Import steps:**

```bash
# Copy first file to clipboard (macOS)
cat monitoring/datadog/cfk-kafka-connect-dashboard.json | pbcopy
```

1. In Datadog: **Dashboards → New Dashboard → gear icon (top right) → Import dashboard JSON**
2. Paste → confirm
3. Repeat for the second file

After import, set the `$env` template variable to match your `env` label value (e.g. `dev`).

---

## Step 8 — Smoke test the dashboards

Allow 2–3 minutes for the agent to collect after the Connect pods are Running.

**CFK Kafka Connect Enriched:**
- JVM Heap Used — line per pod
- Process CPU % — shows activity
- Thread Count — non-zero

**CFK Kafka Connect Connector Level:**
- Running Connectors — non-zero if connectors are deployed
- Source/Sink throughput — non-zero if connectors are actively processing

If all widgets are empty but Step 4 showed `status: OK`:
1. The `$env` filter doesn't match — click the dropdown and check what values are available
2. Verify pod labels were applied: `kubectl get pod connect-0 -n confluent --show-labels`

---

## Step 9 — Install the Confluent Platform integration tile in Datadog

The `confluent_platform` check is bundled in the Datadog Agent (no extra package needed), but
the **integration tile** must be enabled in the Datadog SaaS UI to unlock the out-of-the-box
dashboards and service check monitors that ship with it.

### What the tile provides

- The **Confluent Platform Overview** dashboard (pre-built, covers all 7 components)
- The `confluent.can_connect` service check monitor template
- The integration listed under **Installed Integrations** in your org

> The tile does not change any agent config — metrics are already flowing from the
> autodiscovery annotations added in Step 1. The tile install is a one-time UI action per
> Datadog organisation.

### Steps

1. In Datadog, go to **Integrations → Integration list** (or use the direct URL for your site,
   e.g. `https://us5.datadoghq.com/integrations/confluent-platform`).

2. Search for **Confluent Platform** and open the tile.

3. Click **Install Integration** (top right of the tile). The button changes to
   **Uninstall Integration** once active.

4. Switch to the **Configure** tab inside the tile. You will see:
   - A note that for containerized environments, autodiscovery annotations are used (which you
     have already added in Step 1 — nothing else to configure here).
   - A link to the sample `confluent_platform.d/conf.yaml` for reference.

5. Click **Done**.

### Verify the tile is active

In **Integrations → Integration list**, filter by **Installed** — **Confluent Platform** should
appear in the list.

Alternatively, check in the Datadog Agent on any pod:

```bash
DD_POD=$(kubectl get pod -n datadog-agent -l app=datadog,agent.datadoghq.com/component=agent \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n datadog-agent $DD_POD -c agent -- agent status 2>/dev/null \
  | grep -A 4 "confluent_platform"
```

Expected:
```
JMXFetch
========
  Initialized checks
  ==================
    confluent_platform
      instance_name : connect_instance
      metric_count  : 180
      status        : OK
```

### Service check — confluent.can_connect

Once the tile is installed, Datadog creates a service check named `confluent.can_connect`. It
reports:

| Status | Meaning |
|---|---|
| `OK` | Agent connected to the JMX endpoint and collected metrics |
| `WARNING` | Agent connected but collected zero metrics |
| `CRITICAL` | Agent could not connect to the JMX endpoint |

To create a monitor on this service check:
1. **Monitors → New Monitor → Service Check**
2. Select `confluent.can_connect`
3. Scope to `kube_namespace:confluent` and `component:connect`
4. Alert when status is `CRITICAL` for 2 consecutive checks

---

## Summary of changes and why

| What | Location in connect.yaml | Why |
|---|---|---|
| Pod labels (`env`, `service`, `component`, `team`) | `podTemplate.labels` | Promoted to Datadog tags via `podLabelsAsTags`; power the dashboard filter dropdowns |
| `check_names` annotation | `podTemplate.annotations` | Tells the agent to run the `confluent_platform` JMX check |
| `init_configs` annotation | `podTemplate.annotations` | JMX check configuration — enables default metrics, JVM metrics, GC metrics |
| `instances` annotation | `podTemplate.annotations` | JMX connection URL, instance name, and tags sent on every metric |
| `logs` annotation | `podTemplate.annotations` | Activates log forwarding; `source:kafka-connect` maps to Datadog's built-in log parsing pipeline |
| `MY_POD_IP` + `_JAVA_OPTIONS` envVars | `podTemplate.envVars` | CFK hardcodes `java.rmi.server.hostname=127.0.0.1`; `_JAVA_OPTIONS` is the only way to override it |
| `configOverrides.jvm` | `spec.configOverrides` | Opens JMX to non-localhost so the Datadog DaemonSet pod (on the same node) can connect |
| `configOverrides.log4j` | `spec.configOverrides` | Reduces log level from DEBUG to WARN/INFO to avoid high log ingestion cost on 3+ pods |
