# Datadog Setup Issues - Analysis

Based on the PDF guide "Connect Datadog Monitoring JMX auto discovery and Datadog Datastreams setup" compared to your current configuration, here are the critical issues:

---

## 🔴 **MAJOR ISSUE #1: Wrong Datadog Check Type for Connect**

### What You Have (INCORRECT)
```yaml
annotations:
  ad.datadoghq.com/connect.check_names: '["openmetrics"]'
  ad.datadoghq.com/connect.init_configs: '[{}]'
  ad.datadoghq.com/connect.instances: '[{"openmetrics_endpoint":"http://%%host%%:7778/metrics",...}]'
```

### What You Should Have (per PDF)
```yaml
annotations:
  ad.datadoghq.com/connect.check_names: '["confluent_platform"]'
  ad.datadoghq.com/connect.init_configs: |
    [
      {
        "is_jmx": true,
        "collect_default_metrics": true,
        "service_check_prefix": "confluent",
        "new_gc_metrics": true,
        "collect_default_jvm_metrics": true
      }
    ]
  ad.datadoghq.com/connect.instances: |
    [
      {
        "host": "%%host%%",
        "port": 7203
      }
    ]
```

### Why This Matters
- You're using **OpenMetrics autodiscovery** instead of **JMX autodiscovery**
- OpenMetrics scrapes port **7778** (Prometheus metrics endpoint)
- JMX should use port **7203** (native JMX port)
- The `confluent_platform` check is the **official Datadog integration** for Confluent Platform that includes:
  - JVM metrics (garbage collection, heap memory, thread count)
  - Default JMX metrics
  - Confluent-specific metrics
- Your current setup MISSES all the default JVM metrics that the official integration provides

---

## 🔴 **MAJOR ISSUE #2: Static JMX Configuration in values.yaml is Redundant & Wrong**

### Current Approach in values.yaml
```yaml
confd:
  confluent_platform.yaml: |-
    init_config:
    instances:
      - host: connect.confluent.svc.cluster.local
        port: 7203
        name: connect_instance
```

### The Problem
- You have **static JMX configs** for each service in the Helm values
- But you're NOT using **pod-level autodiscovery annotations** properly
- These static configs won't automatically pick up Connect pod replicas or new deployments
- You're mixing two approaches:
  1. **Static discovery** (via Helm values) - old approach
  2. **Autodiscovery** (via pod annotations) - should be the primary approach

### Why This is Wrong
The PDF guide shows autodiscovery should be done via **pod annotations**, not static Helm values. The static approach is inflexible and doesn't scale.

---

## 🔴 **MAJOR ISSUE #3: Missing JMX Configuration in Connect CFK Manifest**

### What the PDF Shows
```yaml
jvm:
  - "-javaagent:/usr/share/java/dd-java-agent/dd-java-agent.jar"
  - "-Ddd.profiling.enabled=true"
  - "-Ddd.logs.injection=true"
  - "-Ddd.service=connect-ibm-mq-appeng"
  - "-Ddd.env=dev"
  - "-Ddd.version=1.0"
  - "-Ddd.agent.host=datadog-agent.datadog.svc.cluster.local"
```

### Your Current Setup
- No `jvm` overrides found in `connect.yaml`
- No Datadog Java agent injection
- No datastreams monitoring setup
- No environment/service tags for APM

### Why This Matters
If you want **datastreams monitoring** (which tracks data flow through your Kafka Connect pipelines), you MUST:
1. Inject the `dd-java-agent.jar` via JVM args
2. Enable APM (`DD_APM_ENABLED=true` in datadog-agent)
3. Expose port 8126 (APM port) on the Datadog agent
4. Add service/environment/version labels for proper tracing

---

## 🟡 **ISSUE #4: Datadog Agent Configuration Missing APM/Datastreams Support**

### Your Current values.yaml
```yaml
apm:
  enabled: false
```

### What You Need for Datastreams
```yaml
apm:
  enabled: true
```

Also missing:
- APM port exposure (8126)
- Service configuration for tracing
- Environment/version tags

---

## 🟡 **ISSUE #5: Incomplete Helm Installation Command**

### What the PDF Shows
```bash
helm install datadog -f values.yaml \
  --set datadog.apiKeyExistingSecret=datadog-secret \
  datadog/datadog
```

### Your Current Approach
Using Helm values file but no record of cluster agent or proper namespace setup shown in current files.

---

## Summary of What Went Wrong

| Issue | Current | Should Be | Impact |
|-------|---------|-----------|--------|
| Check Type | `openmetrics` | `confluent_platform` | Missing JVM metrics, default metrics |
| JMX Port | 7778 (Prometheus) | 7203 (JMX) | Wrong endpoint entirely |
| Discovery Method | Mixed (static + autodiscovery) | Autodiscovery only via annotations | Not scalable, inflexible |
| Java Agent | Not present | Should be injected via JVM args | No datastreams/APM tracing |
| APM | Disabled | Should be enabled | Can't trace data flow through pipelines |
| Configuration Approach | Static Helm configs | Pod annotations + pod overrides | Not following Datadog best practices |

---

## Recommended Actions

1. **Update Connect pod annotations** - Change from OpenMetrics to JMX autodiscovery
2. **Remove static configs** from Helm values (let autodiscovery handle it)
3. **Add JVM agent injection** to Connect spec if you want datastreams monitoring
4. **Enable APM** in Datadog agent values.yaml
5. **Update Datadog agent to image with JMX support** (`latest-jmx` tag as shown in PDF)
6. **Re-deploy** in order: Datadog agent → Connect → Test

