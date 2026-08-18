# Confluent for Kubernetes (CFK) Configuration Guide

A comprehensive guide to understanding and configuring the Confluent Platform on Kubernetes using Confluent for Kubernetes (CFK) operator.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Deployment Order](#deployment-order)
3. [YAML Files Reference](#yaml-files-reference)
   - [namespace.yaml](#namespaceyaml)
   - [kraftcontroller.yaml](#kraftcontrolleryaml)
   - [kafka.yaml](#kafkayaml)
   - [schemaregistry.yaml](#schemaregistryyaml)
   - [connect.yaml](#connectyaml)
   - [ksqldb.yaml](#ksqldbyaml)
   - [kafkarestproxy.yaml](#kafkarestproxyyaml)
   - [controlcenter.yaml](#controlcenteryaml)
4. [Common Configuration Patterns](#common-configuration-patterns)
5. [Resource Planning](#resource-planning)
6. [Things to Be Mindful Of](#things-to-be-mindful-of)
7. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         CONFLUENT PLATFORM ARCHITECTURE                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                        CONTROL PLANE                                    │   │
│   │  ┌─────────────────┐                                                    │   │
│   │  │  CFK Operator   │ ◄── Manages all Confluent resources                │   │
│   │  │  (Helm Chart)   │     Watches CRDs, reconciles state                 │   │
│   │  └─────────────────┘                                                    │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                         DATA PLANE                                      │   │
│   │                                                                         │   │
│   │   ┌───────────────────────────────────────────────────────────────┐     │   │
│   │   │                    KAFKA CLUSTER                              │     │   │
│   │   │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐          │     │   │
│   │   │  │   KRaft     │   │   KRaft     │   │   KRaft     │          │     │   │
│   │   │  │ Controller  │   │ Controller  │   │ Controller  │          │     │   │
│   │   │  │     0       │   │     1       │   │     2       │          │     │   │
│   │   │  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘          │     │   │
│   │   │         │                 │                 │                 │     │   │
│   │   │         └────────────┬────┴─────────────────┘                 │     │   │
│   │   │                      │ Raft Consensus                         │     │   │
│   │   │         ┌────────────┴────────────────────┐                   │     │   │
│   │   │         │                                 │                   │     │   │
│   │   │  ┌──────┴──────┐   ┌─────────────┐   ┌───┴───────────┐        │     │   │
│   │   │  │   Kafka     │   │   Kafka     │   │    Kafka      │        │     │   │
│   │   │  │  Broker 0   │   │  Broker 1   │   │   Broker 2    │        │     │   │
│   │   │  └─────────────┘   └─────────────┘   └───────────────┘        │     │   │
│   │   └───────────────────────────────────────────────────────────────┘     │   │
│   │                                                                         │   │
│   │   ┌───────────────────────────────────────────────────────────────┐     │   │
│   │   │                  ECOSYSTEM COMPONENTS                         │     │   │
│   │   │                                                               │     │   │
│   │   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │     │   │
│   │   │  │   Schema     │  │    Kafka     │  │    ksqlDB    │         │     │   │
│   │   │  │  Registry    │  │   Connect    │  │              │         │     │   │
│   │   │  └──────────────┘  └──────────────┘  └──────────────┘         │     │   │
│   │   │                                                               │     │   │
│   │   │  ┌──────────────┐  ┌──────────────┐                           │     │   │
│   │   │  │    REST      │  │   Control    │                           │     │   │
│   │   │  │    Proxy     │  │   Center     │                           │     │   │
│   │   │  └──────────────┘  └──────────────┘                           │     │   │
│   │   └───────────────────────────────────────────────────────────────┘     │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Deployment Order

CFK components must be deployed in a specific order due to dependencies:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           DEPLOYMENT ORDER                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   1. CFK Operator (Helm)          ◄── Must be first                             │
│         │                                                                       │
│         ▼                                                                       │
│   2. Namespace                    ◄── Where components will live                │
│         │                                                                       │
│         ▼                                                                       │
│   3. KRaft Controllers            ◄── Cluster metadata management               │
│         │                              WAIT: All 3 controllers ready            │
│         ▼                                                                       │
│   4. Kafka Brokers                ◄── Core messaging                            │
│         │                              WAIT: All 3 brokers ready                │
│         ▼                                                                       │
│   5. Schema Registry              ◄── Schema management (needs Kafka)           │
│         │                              WAIT: Pod ready                          │
│         ▼                                                                       │
│   6. Kafka Connect                ◄── Connectors (needs Kafka + SR)             │
│         │                              WAIT: Pod ready                          │
│         ▼                                                                       │
│   7. ksqlDB                       ◄── Stream processing (needs Kafka + SR)      │
│         │                              WAIT: Pod ready                          │
│         ▼                                                                       │
│   8. REST Proxy                   ◄── HTTP interface (needs Kafka + SR)         │
│         │                              WAIT: Pod ready                          │
│         ▼                                                                       │
│   9. Control Center               ◄── Management UI (needs all above)           │
│                                        WAIT: Pod ready                          │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Why order matters:**
- KRaft Controllers manage cluster metadata - Kafka can't start without them
- Kafka Brokers are the foundation - all other components need Kafka
- Schema Registry stores schemas - Connect and ksqlDB need it for Avro/JSON Schema
- Control Center monitors everything - needs all components running to display properly

---

## YAML Files Reference

### namespace.yaml

**Purpose**: Creates the Kubernetes namespace where all Confluent components will be deployed.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: confluent
```

**Configuration Breakdown:**

| Field | Value | Description |
|-------|-------|-------------|
| `kind` | `Namespace` | Standard Kubernetes resource |
| `metadata.name` | `confluent` | Name of the namespace |

**Things to be mindful of:**
- All CFK resources must reference this namespace in their `metadata.namespace` field
- Changing the namespace name requires updating ALL other YAML files
- Resource quotas can be applied at the namespace level if needed

---

### kraftcontroller.yaml

**Purpose**: Deploys KRaft (Kafka Raft) controllers that manage cluster metadata. These replace ZooKeeper in modern Kafka deployments.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KRaftController
metadata:
  name: kraftcontroller
  namespace: confluent
spec:
  replicas: 3
  image:
    application: confluentinc/cp-server:7.9.0
    init: confluentinc/confluent-init-container:2.10.0
  dataVolumeCapacity: 1Gi
  podTemplate:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  metrics:
    prometheus:
      rules:
        - pattern: kafka.controller<type=KafkaController, name=(.+)><>Value
          name: kafka_controller_kafkacontroller_$1
          type: GAUGE
          cache: true
        # ... more metric rules
```

**Configuration Breakdown:**

| Field | Value | Why This Value |
|-------|-------|----------------|
| `replicas` | `3` | **Minimum for fault tolerance.** KRaft uses Raft consensus which requires a quorum (majority). With 3 nodes, you can tolerate 1 failure. |
| `image.application` | `cp-server:7.9.0` | The Confluent Platform server image. Controllers and brokers use the same image. |
| `image.init` | `confluent-init-container:2.10.0` | Init container that prepares configuration before the main container starts. |
| `dataVolumeCapacity` | `1Gi` | Storage for controller metadata. Controllers store less data than brokers. |
| `resources.requests.cpu` | `100m` | Minimum CPU guaranteed. Controllers are not CPU-intensive. |
| `resources.requests.memory` | `256Mi` | Minimum memory guaranteed. |
| `resources.limits.cpu` | `500m` | Maximum CPU allowed. |
| `resources.limits.memory` | `512Mi` | Maximum memory allowed. Controllers need less memory than brokers. |

**Metrics Configuration Explained:**

The `metrics.prometheus.rules` section defines how JMX metrics are exposed to Prometheus:

```yaml
- pattern: kafka.controller<type=KafkaController, name=(.+)><>Value
  name: kafka_controller_kafkacontroller_$1
  type: GAUGE
  cache: true
```

- `pattern`: JMX MBean pattern to match (regex with capture groups)
- `name`: Prometheus metric name (uses `$1`, `$2` for captured groups)
- `type`: Prometheus metric type (`GAUGE`, `COUNTER`)
- `cache`: Whether to cache the metric value for performance

**Key Metrics Exposed:**
- `kafka_controller_kafkacontroller_activecontrollercount` - Should be 1 across the cluster
- `kafka_controller_controllerstats_*` - Controller operation statistics
- `kafka_server_raft_metrics_*` - Raft consensus metrics

**Things to be mindful of:**

1. **Never use even numbers for replicas** - Raft consensus needs odd numbers (1, 3, 5) to avoid split-brain scenarios.

2. **Replica count trade-offs:**
   | Replicas | Fault Tolerance | Resource Usage |
   |----------|-----------------|----------------|
   | 1 | None (testing only) | Minimal |
   | 3 | 1 node failure | Moderate |
   | 5 | 2 node failures | Higher |

3. **Storage is persistent** - PersistentVolumeClaims are created automatically. Deleting the KRaftController CR does NOT delete the PVCs by default.

4. **Recovery from total failure** - If all controllers fail simultaneously, you may need to manually recover from backup.

---

### kafka.yaml

**Purpose**: Deploys Kafka brokers that handle message storage and serving.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Kafka
metadata:
  name: kafka
  namespace: confluent
spec:
  replicas: 3
  image:
    application: confluentinc/cp-server:7.9.0
    init: confluentinc/confluent-init-container:2.10.0
  dataVolumeCapacity: 2Gi
  podTemplate:
    resources:
      requests:
        cpu: 100m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1Gi
  configOverrides:
    server:
      - offsets.topic.replication.factor=1
      - transaction.state.log.replication.factor=1
      - transaction.state.log.min.isr=1
      - confluent.license.topic.replication.factor=1
      - confluent.metadata.topic.replication.factor=1
      - confluent.balancer.topic.replication.factor=1
      - confluent.security.event.logger.exporter.kafka.topic.replicas=1
      - confluent.cluster.link.metadata.topic.replication.factor=1
      - default.replication.factor=1
      - min.insync.replicas=1
  metricReporter:
    enabled: true
    bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
  dependencies:
    kRaftController:
      clusterRef:
        name: kraftcontroller
```

**Configuration Breakdown:**

| Field | Value | Why This Value |
|-------|-------|----------------|
| `replicas` | `3` | Standard for fault tolerance. Allows replication factor of 3. |
| `dataVolumeCapacity` | `2Gi` | Storage for message data. **Increase significantly for production.** |
| `resources.limits.memory` | `1Gi` | Kafka is memory-intensive. JVM heap + page cache. |

**Config Overrides Explained:**

```yaml
configOverrides:
  server:
    - offsets.topic.replication.factor=1
    - transaction.state.log.replication.factor=1
    - min.insync.replicas=1
```

These settings are **specifically for local/dev environments** to reduce resource usage:

| Config | Default | Our Value | Why |
|--------|---------|-----------|-----|
| `offsets.topic.replication.factor` | 3 | 1 | `__consumer_offsets` topic - stores consumer group offsets |
| `transaction.state.log.replication.factor` | 3 | 1 | `__transaction_state` topic - for exactly-once semantics |
| `transaction.state.log.min.isr` | 2 | 1 | Minimum in-sync replicas for transaction topic |
| `default.replication.factor` | 1 | 1 | Default for new topics |
| `min.insync.replicas` | 1 | 1 | Minimum replicas that must acknowledge writes |

**CRITICAL FOR PRODUCTION:**
```yaml
# Production values - DO NOT use replication.factor=1 in production!
configOverrides:
  server:
    - offsets.topic.replication.factor=3
    - transaction.state.log.replication.factor=3
    - transaction.state.log.min.isr=2
    - default.replication.factor=3
    - min.insync.replicas=2
```

**Metric Reporter:**
```yaml
metricReporter:
  enabled: true
  bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
```

This enables Confluent Metrics Reporter which sends broker metrics to a `_confluent-metrics` topic. Control Center uses this for monitoring.

**Dependencies:**
```yaml
dependencies:
  kRaftController:
    clusterRef:
      name: kraftcontroller
```

This tells Kafka brokers which KRaft controller cluster to use. The name must match your KRaftController resource name.

**Things to be mindful of:**

1. **Storage sizing** - `dataVolumeCapacity` should be calculated based on:
   - Message retention period
   - Expected throughput
   - Replication factor
   - Formula: `Daily_data × Retention_days × Replication_factor × 1.1 (overhead)`

2. **Memory sizing** - Kafka uses:
   - JVM heap (configured via JVM options, typically 4-6GB)
   - Page cache (OS-level, uses remaining available memory)
   - Rule of thumb: Allocate 2x your expected heap for the pod limit

3. **Port reference:**
   | Port | Protocol | Purpose |
   |------|----------|---------|
   | 9071 | PLAINTEXT | Internal broker communication |
   | 9092 | PLAINTEXT | Client connections (when exposed) |
   | 7778 | HTTP | Prometheus metrics |

---

### schemaregistry.yaml

**Purpose**: Deploys Schema Registry for managing Avro, JSON Schema, and Protobuf schemas.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: SchemaRegistry
metadata:
  name: schemaregistry
  namespace: confluent
spec:
  replicas: 1
  image:
    application: confluentinc/cp-schema-registry:7.9.0
    init: confluentinc/confluent-init-container:2.10.0
  podTemplate:
    resources:
      requests:
        cpu: 50m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  dependencies:
    kafka:
      bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
```

**Configuration Breakdown:**

| Field | Value | Why This Value |
|-------|-------|----------------|
| `replicas` | `1` | Sufficient for dev. Use 2+ for HA in production. |
| `resources.limits.memory` | `512Mi` | Schema Registry is lightweight. |

**Dependencies:**
```yaml
dependencies:
  kafka:
    bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
```

Schema Registry stores schemas in a Kafka topic (`_schemas`). The bootstrap endpoint tells it how to connect to Kafka.

**URL Format:**
`<service-name>.<namespace>.svc.cluster.local:<port>`

- `kafka` - Kubernetes service name
- `confluent` - Namespace
- `svc.cluster.local` - Kubernetes DNS suffix
- `9071` - Internal Kafka port

**Things to be mindful of:**

1. **Schema compatibility** - Schema Registry enforces compatibility rules. Default is `BACKWARD`. Understand the implications:
   | Mode | Description |
   |------|-------------|
   | BACKWARD | New schema can read old data |
   | FORWARD | Old schema can read new data |
   | FULL | Both backward and forward compatible |
   | NONE | No compatibility checking |

2. **No dataVolumeCapacity** - Schema Registry is stateless (from its perspective). All state is in Kafka.

3. **Port reference:**
   | Port | Purpose |
   |------|---------|
   | 8081 | REST API |
   | 7778 | Prometheus metrics |

---

### connect.yaml

**Purpose**: Deploys Kafka Connect for integrating Kafka with external systems.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: Connect
metadata:
  name: connect
  namespace: confluent
spec:
  replicas: 1
  image:
    application: confluentinc/cp-server-connect:7.9.0
    init: confluentinc/confluent-init-container:2.10.0
  build:
    type: onDemand
    onDemand:
      plugins:
        locationType: confluentHub
        confluentHub:
          - name: kafka-connect-datagen
            owner: confluentinc
            version: "0.6.5"
        url:
          - name: kafka-connect-jdbc
            archivePath: https://raw.githubusercontent.com/.../kafka-connect-jdbc-10.9.2-mysql8.zip
            checksum: 1cf7c9bb...
  configOverrides:
    server:
      - config.storage.replication.factor=1
      - offset.storage.replication.factor=1
      - status.storage.replication.factor=1
      - producer.interceptor.classes=io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor
      - consumer.interceptor.classes=io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor
  dependencies:
    kafka:
      bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
    schemaRegistry:
      url: http://schemaregistry.confluent.svc.cluster.local:8081
```

**Configuration Breakdown:**

**Plugin Installation (build section):**

```yaml
build:
  type: onDemand
  onDemand:
    plugins:
      locationType: confluentHub
      confluentHub:
        - name: kafka-connect-datagen
          owner: confluentinc
          version: "0.6.5"
      url:
        - name: kafka-connect-jdbc
          archivePath: https://...
          checksum: 1cf7c9bb...
```

| Field | Description |
|-------|-------------|
| `type: onDemand` | Plugins are installed when the pod starts |
| `confluentHub` | Install from Confluent Hub (official connector repository) |
| `url` | Install from a URL (for custom or modified connectors) |
| `checksum` | SHA-512 checksum for URL downloads (security) |

**Config Overrides:**

```yaml
configOverrides:
  server:
    - config.storage.replication.factor=1    # Topic: connect-configs
    - offset.storage.replication.factor=1    # Topic: connect-offsets
    - status.storage.replication.factor=1    # Topic: connect-status
```

Kafka Connect stores its state in three internal topics. In production, use replication factor of 3.

**Monitoring Interceptors:**
```yaml
- producer.interceptor.classes=io.confluent.monitoring.clients.interceptor.MonitoringProducerInterceptor
- consumer.interceptor.classes=io.confluent.monitoring.clients.interceptor.MonitoringConsumerInterceptor
```

These enable Control Center to monitor Connect's message flow by intercepting all produced/consumed messages.

**Things to be mindful of:**

1. **Plugin management:**
   - `confluentHub` plugins are versioned and verified
   - `url` plugins need checksums for security
   - Plugins are downloaded on EVERY pod restart (consider using a custom image for production)

2. **Resource requirements:**
   - Connect workers are memory-intensive when running many connectors
   - Each connector task uses memory and CPU
   - Start with generous limits and tune based on actual usage

3. **Connector topics:**
   | Topic | Purpose |
   |-------|---------|
   | `connect-configs` | Connector configurations |
   | `connect-offsets` | Source connector offsets |
   | `connect-status` | Connector and task status |

4. **Port reference:**
   | Port | Purpose |
   |------|---------|
   | 8083 | REST API |
   | 7778 | Prometheus metrics |

---

### ksqldb.yaml

**Purpose**: Deploys ksqlDB for stream processing using SQL syntax.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KsqlDB
metadata:
  name: ksqldb
  namespace: confluent
spec:
  replicas: 1
  image:
    application: confluentinc/cp-ksqldb-server:7.9.0
    init: confluentinc/confluent-init-container:2.10.0
  dataVolumeCapacity: 1Gi
  configOverrides:
    server:
      - ksql.internal.topic.replicas=1
      - ksql.streams.replication.factor=1
      - ksql.advertised.listener=http://localhost:8088
  dependencies:
    kafka:
      bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
    schemaRegistry:
      url: http://schemaregistry.confluent.svc.cluster.local:8081
```

**Configuration Breakdown:**

| Field | Value | Why This Value |
|-------|-------|----------------|
| `dataVolumeCapacity` | `1Gi` | For RocksDB state stores (used by aggregations) |

**Config Overrides:**

```yaml
configOverrides:
  server:
    - ksql.internal.topic.replicas=1         # Internal ksqlDB topics
    - ksql.streams.replication.factor=1      # Output topic replication
    - ksql.advertised.listener=http://localhost:8088  # For Control Center UI
```

**IMPORTANT: Advertised Listener**

The `ksql.advertised.listener` setting is critical for Control Center UI access:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     WHY ADVERTISED LISTENER MATTERS                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   Without advertised.listener=http://localhost:8088:                            │
│                                                                                 │
│   [Browser] ──► [Control Center] ──► "Connect to ksqldb.confluent.svc..."       │
│                                               │                                 │
│                                               ▼                                 │
│                                         [Browser tries]                         │
│                                               │                                 │
│                                               ✗ FAILS (can't reach internal URL)│
│                                                                                 │
│   With advertised.listener=http://localhost:8088:                               │
│                                                                                 │
│   [Browser] ──► [Control Center] ──► "Connect to localhost:8088"                │
│                                               │                                 │
│                                               ▼                                 │
│                                    [kubectl port-forward]                       │
│                                               │                                 │
│                                               ▼                                 │
│                                         [ksqlDB Pod]                            │
│                                               │                                 │
│                                               ✓ SUCCESS                         │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

**Things to be mindful of:**

1. **State stores** - ksqlDB uses RocksDB for stateful operations (aggregations, joins). The `dataVolumeCapacity` stores this state.

2. **Query types:**
   | Type | Description | Use Case |
   |------|-------------|----------|
   | Push Query | `EMIT CHANGES` | Continuous streaming results |
   | Pull Query | No `EMIT CHANGES` | Point-in-time lookup |

3. **Port reference:**
   | Port | Purpose |
   |------|---------|
   | 8088 | REST API / CLI |
   | 7778 | Prometheus metrics |

---

### kafkarestproxy.yaml

**Purpose**: Provides HTTP/REST interface to Kafka for non-JVM clients.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: KafkaRestProxy
metadata:
  name: kafkarestproxy
  namespace: confluent
spec:
  replicas: 1
  image:
    application: confluentinc/cp-kafka-rest:7.9.0
    init: confluentinc/confluent-init-container:2.10.0
  podTemplate:
    resources:
      requests:
        cpu: 50m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
  dependencies:
    kafka:
      bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
    schemaRegistry:
      url: http://schemaregistry.confluent.svc.cluster.local:8081
```

**When to use REST Proxy:**
- Clients that can't use native Kafka clients (browsers, shell scripts)
- Quick prototyping and testing
- Environments with firewall restrictions on Kafka protocol

**Things to be mindful of:**

1. **Performance** - REST Proxy adds latency compared to native clients. Not suitable for high-throughput scenarios.

2. **Port reference:**
   | Port | Purpose |
   |------|---------|
   | 8082 | REST API |
   | 7778 | Prometheus metrics |

---

### controlcenter.yaml

**Purpose**: Deploys Confluent Control Center - the management and monitoring UI.

```yaml
apiVersion: platform.confluent.io/v1beta1
kind: ControlCenter
metadata:
  name: controlcenter
  namespace: confluent
spec:
  replicas: 1
  dataVolumeCapacity: 2Gi
  podTemplate:
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi
    probe:
      liveness:
        initialDelaySeconds: 180
        periodSeconds: 30
        timeoutSeconds: 10
        failureThreshold: 10
      readiness:
        initialDelaySeconds: 120
        periodSeconds: 30
        timeoutSeconds: 10
        failureThreshold: 10
  configOverrides:
    server:
      - confluent.controlcenter.internal.topics.replication=1
      - confluent.controlcenter.command.topic.replication=1
      - confluent.monitoring.interceptor.topic.replication=1
      - confluent.metrics.topic.replication=1
      - confluent.controlcenter.ksql.ksqldb.advertised.url=http://localhost:8088
  dependencies:
    kafka:
      bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
    schemaRegistry:
      url: http://schemaregistry.confluent.svc.cluster.local:8081
    connect:
      - name: connect
        url: http://connect.confluent.svc.cluster.local:8083
    ksqldb:
      - name: ksqldb
        url: http://ksqldb.confluent.svc.cluster.local:8088
```

**Configuration Breakdown:**

**Resource Requirements:**
Control Center is the most resource-intensive component:

| Resource | Request | Limit | Why |
|----------|---------|-------|-----|
| CPU | 500m | 2000m | Heavy computation for metrics aggregation |
| Memory | 2Gi | 4Gi | Stores metrics data, serves UI |
| Storage | 2Gi | - | Metrics and state storage |

**Probe Configuration:**
```yaml
probe:
  liveness:
    initialDelaySeconds: 180    # Wait 3 minutes before first check
    periodSeconds: 30           # Check every 30 seconds
    failureThreshold: 10        # Allow 10 failures before restart
```

Control Center takes longer to start than other components. The generous probe settings prevent premature restarts.

**Config Overrides:**

```yaml
configOverrides:
  server:
    - confluent.controlcenter.internal.topics.replication=1
    - confluent.controlcenter.ksql.ksqldb.advertised.url=http://localhost:8088
```

| Config | Purpose |
|--------|---------|
| `*.replication=1` | Reduce resource usage for dev |
| `ksql.ksqldb.advertised.url` | Tell browser where to find ksqlDB |

**Dependencies:**
Control Center connects to ALL other components:

```yaml
dependencies:
  kafka:
    bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
  schemaRegistry:
    url: http://schemaregistry.confluent.svc.cluster.local:8081
  connect:
    - name: connect
      url: http://connect.confluent.svc.cluster.local:8083
  ksqldb:
    - name: ksqldb
      url: http://ksqldb.confluent.svc.cluster.local:8088
```

**Things to be mindful of:**

1. **Browser access** - Requires port-forwarding:
   ```bash
   kubectl port-forward svc/controlcenter -n confluent 9021:9021
   kubectl port-forward svc/ksqldb -n confluent 8088:8088  # For ksqlDB queries
   ```

2. **License** - Control Center requires a Confluent license for production use. Without a license, it runs in evaluation mode with limited features.

3. **Port reference:**
   | Port | Purpose |
   |------|---------|
   | 9021 | Web UI |
   | 7778 | Prometheus metrics |

---

## Common Configuration Patterns

### Image Configuration

All CFK resources follow the same image pattern:

```yaml
image:
  application: confluentinc/cp-<component>:<version>
  init: confluentinc/confluent-init-container:<version>
```

**Version alignment is critical:**
- All Confluent components should use the same version (e.g., `7.9.0`)
- The init container version may differ but should be compatible

### Resource Configuration

```yaml
podTemplate:
  resources:
    requests:
      cpu: <minimum-guaranteed>
      memory: <minimum-guaranteed>
    limits:
      cpu: <maximum-allowed>
      memory: <maximum-allowed>
```

**Best practices:**
- Set requests = what your app typically uses
- Set limits = maximum during peaks
- Memory limits should be 1.5-2x requests for JVM apps

### Dependencies Configuration

```yaml
dependencies:
  kafka:
    bootstrapEndpoint: kafka.confluent.svc.cluster.local:9071
  schemaRegistry:
    url: http://schemaregistry.confluent.svc.cluster.local:8081
```

**URL Format:**
```
<service-name>.<namespace>.svc.cluster.local:<port>
```

### Metrics Configuration

Every CFK component supports Prometheus metrics:

```yaml
metrics:
  prometheus:
    rules:
      - pattern: "some.jmx.mbean<type=X, name=Y><>Value"
        name: metric_name_$1_$2
        type: GAUGE
        labels:
          key: "$1"
```

---

## Resource Planning

### Development/POC Environment (This Repository)

| Component | Replicas | CPU (req/lim) | Memory (req/lim) | Storage |
|-----------|----------|---------------|------------------|---------|
| KRaft Controller | 3 | 100m/500m | 256Mi/512Mi | 1Gi |
| Kafka Broker | 3 | 100m/1000m | 512Mi/1Gi | 2Gi |
| Schema Registry | 1 | 50m/500m | 256Mi/512Mi | - |
| Connect | 1 | 500m/4000m | 1Gi/4Gi | - |
| ksqlDB | 1 | 100m/1000m | 512Mi/1Gi | 1Gi |
| REST Proxy | 1 | 50m/500m | 256Mi/512Mi | - |
| Control Center | 1 | 500m/2000m | 2Gi/4Gi | 2Gi |

**Total: ~4 CPU cores, ~10GB memory minimum**

### Production Environment (Recommended)

| Component | Replicas | CPU (req/lim) | Memory (req/lim) | Storage |
|-----------|----------|---------------|------------------|---------|
| KRaft Controller | 3 | 500m/2000m | 1Gi/2Gi | 10Gi |
| Kafka Broker | 3+ | 2000m/4000m | 6Gi/8Gi | 500Gi+ |
| Schema Registry | 2 | 500m/1000m | 1Gi/2Gi | - |
| Connect | 2+ | 2000m/4000m | 4Gi/8Gi | - |
| ksqlDB | 2+ | 2000m/4000m | 4Gi/8Gi | 50Gi |
| REST Proxy | 2 | 500m/1000m | 1Gi/2Gi | - |
| Control Center | 1 | 2000m/4000m | 6Gi/8Gi | 50Gi |

---

## Things to Be Mindful Of

> For detailed production guidance on these topics and more, see [production-considerations.md](production-considerations.md).

### 1. Replication Factors

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    REPLICATION FACTOR SETTINGS                                  │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   THIS REPOSITORY (Development):          PRODUCTION:                           │
│   ─────────────────────────────          ───────────                            │
│   replication.factor = 1                  replication.factor = 3                │
│   min.insync.replicas = 1                 min.insync.replicas = 2               │
│                                                                                 │
│   ⚠️  DATA LOSS RISK: With RF=1,         ✓ FAULT TOLERANT: Can survive          │
│      any broker failure loses data           1 broker failure                   │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 2. Storage Classes

By default, CFK uses the default storage class. For production:
- Use SSD-backed storage classes
- Ensure storage class supports volume expansion
- Consider separate storage classes for different components

### 3. Network Policies

This repository does not include network policies. For production, consider restricting:
- Inter-component communication
- External access to management ports
- Egress to specific destinations

### 4. Security

This repository uses **PLAINTEXT** (no encryption, no authentication). For production:
- Enable TLS for all communication
- Configure authentication (SASL, mTLS)
- Use Kubernetes secrets for credentials
- Enable RBAC in Kafka

### 5. Persistent Volume Claims

CFK creates PVCs automatically. Be aware:
- PVCs persist after pod deletion
- Deleting a CFK resource does NOT delete PVCs
- Manual cleanup required: `kubectl delete pvc -l app=kafka -n confluent`

### 6. Pod Disruption Budgets

For production, consider adding PDBs to prevent too many pods being unavailable during updates.

---

## Troubleshooting

> See also the [Troubleshooting section in the main README](../README.md#troubleshooting) for additional debugging steps.

### Component Won't Start

1. Check pod status:
   ```bash
   kubectl get pods -n confluent
   kubectl describe pod <pod-name> -n confluent
   ```

2. Check logs:
   ```bash
   kubectl logs <pod-name> -n confluent
   kubectl logs <pod-name> -n confluent -c config-init-container  # Init container
   ```

3. Check events:
   ```bash
   kubectl get events -n confluent --sort-by='.lastTimestamp'
   ```

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| Pod stuck in Pending | Insufficient resources | Increase node resources or reduce requests |
| Pod stuck in ContainerCreating | PVC not bound | Check storage class availability |
| CrashLoopBackOff | Configuration error | Check logs for specific error |
| Kafka can't connect to KRaft | KRaft not ready | Wait for all KRaft pods to be Running |

### Useful Commands

```bash
# Check all Confluent resources
kubectl get confluent -n confluent

# Check specific resource status
kubectl get kafka kafka -n confluent -o yaml | grep -A 20 status:

# Restart a component
kubectl rollout restart statefulset/kafka -n confluent

# Force delete stuck pods
kubectl delete pod <pod-name> -n confluent --force --grace-period=0
```

---

## Next Steps

After understanding the configuration:

1. **Deploy**: Run `./scripts/setup.sh`
2. **Validate**: Run `./scripts/validate.sh`
3. **Monitor**: See [Monitoring Guide](monitoring-guide.md)
4. **Use**: Deploy connectors, create ksqlDB streams
5. **Learn**: Experiment with different configurations

---

*This documentation is part of the CFK on Docker Desktop repository. For issues or contributions, please refer to the main README.*
