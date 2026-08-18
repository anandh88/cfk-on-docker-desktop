# Confluent Platform on Kubernetes (Docker Desktop)

A complete Confluent Platform deployment using Confluent for Kubernetes (CFK) operator, with integrated Prometheus/Grafana monitoring.

## Deployment Variants

This repository uses branches to separate deployment configurations:

| Branch | Description |
|--------|-------------|
| **`main`** (this branch) | Basic deployment: no authentication, no TLS — suitable for quick local testing |
| **`feature/cfk-ldap`** | Full security: LDAP authentication, MDS/RBAC authorization, and TLS encryption |

> **You are on `main`.** This branch deploys Confluent Platform without authentication or TLS, keeping things simple for local development and testing. If you need LDAP/RBAC security and TLS, switch to the [`feature/cfk-ldap`](../../tree/feature/cfk-ldap) branch.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Components](#components)
- [Prerequisites](#prerequisites)
- [Step 1: Environment Setup](#step-1-environment-setup)
- [Step 2: Deploy Confluent Platform](#step-2-deploy-confluent-platform)
- [Step 3: Verify Deployment](#step-3-verify-deployment)
- [Step 4: Access Services](#step-4-access-services)
- [Step 5: Deploy Sample Connectors](#step-5-deploy-sample-connectors)
- [Step 6: Deploy ksqlDB Examples](#step-6-deploy-ksqldb-examples)
- [Teardown](#teardown)
- [Monitoring Architecture](#monitoring-architecture)
- [Project Structure](#project-structure)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              Kubernetes Cluster                                 │
│                            (Docker Desktop / k8s)                               │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                        Confluent Namespace                              │    │
│  │                                                                         │    │
│  │  ┌────────────────────────┐    ┌────────────────────────────────────┐   │    │
│  │  │  KRaft Controller      │    │              Kafka Brokers         │   │    │
│  │  │    (3 replicas)        │◄──►│              (3 replicas)          │   │    │
│  │  │                        │    │                                    │   │    │
│  │  │  - kraftcontroller-0   │    │     - kafka-0                      │   │    │
│  │  │  - kraftcontroller-1   │    │     - kafka-1                      │   │    │
│  │  │  - kraftcontroller-2   │    |     - kafka-2                      │   │    │
│  │  └────────────────────────┘    └────────────────────────────────────┘   │    │
│  │                                      │                                  │    │
│  │           ┌──────────────────────────┼───────────────────┌──────────┐   │    │
│  │           │                          │                   │          │   │    │
│  │           ▼                          ▼                   ▼          │   │    │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐  │   │    │
│  │  │ Schema Registry │    │  Kafka Connect  │    │     ksqlDB      │  │   │    │
│  │  │   (1 replica)   │    │   (1 replica)   │    │   (1 replica)   │  │   │    │
│  │  └─────────────────┘    └─────────────────┘    └─────────────────┘  │   │    │
│  │                                                                     │   │    │
│  │           ┌──────────────────────────┌──────────────────────────────┘   │    │
│  │           |                          |                                  │    │
│  │           |                          |                                  │    │
│  │           ▼                          ▼                                  │    │
│  │  ┌─────────────────┐    ┌─────────────────┐                             │    │
│  │  │   REST Proxy    │    │ Control Center  │                             │    │
│  │  │   (1 replica)   │    │   (1 replica)   │                             │    │
│  │  └─────────────────┘    └─────────────────┘                             │    │
│  │                                                                         │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                       Monitoring Namespace                              │    │
│  │                                                                         │    │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐      │    │
│  │  │   Prometheus    │───►│     Grafana     │    │  Alertmanager   │      │    │
│  │  │                 │    │                 │    │                 │      │    │
│  │  └─────────────────┘    └─────────────────┘    └─────────────────┘      │    │
│  │                                                                         │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Replicas | Description |
|-----------|----------|-------------|
| KRaft Controller | 3 | Metadata management (replaces ZooKeeper) |
| Kafka Broker | 3 | Message broker cluster |
| Schema Registry | 1 | Schema management for Avro/JSON/Protobuf |
| Kafka Connect | 1 | Data integration framework |
| ksqlDB | 1 | Streaming SQL engine |
| REST Proxy | 1 | RESTful interface to Kafka |
| Control Center | 1 | Management and monitoring UI |

---

## Prerequisites

### Required Software

1. **Docker Desktop** with Kubernetes enabled
   - Download from: https://www.docker.com/products/docker-desktop/
   - Enable Kubernetes: Docker Desktop → Settings → Kubernetes → Enable Kubernetes

2. **kubectl CLI**
   ```bash
   # macOS
   brew install kubectl

   # Verify installation
   kubectl version --client
   ```

3. **Helm CLI**
   ```bash
   # macOS
   brew install helm

   # Verify installation
   helm version
   ```

4. **jq** (for JSON processing)
   ```bash
   # macOS
   brew install jq
   ```

### Resource Requirements

Allocate sufficient resources to Docker Desktop:

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 4 cores | 6+ cores |
| Memory | 12 GB | 16+ GB |
| Disk | 30 GB | 50+ GB |

**To configure:** Docker Desktop → Settings → Resources → Advanced

### Verify Prerequisites

```bash
# Check kubectl is connected to Docker Desktop
kubectl cluster-info

# Expected output should show kubernetes control plane running
# Example: Kubernetes control plane is running at https://kubernetes.docker.internal:6443
```

---

## Step 1: Environment Setup

### 1.1 Clone the Repository

```bash
git clone git@ssh.dev.azure.com:v3/Psyncopate-Internal/Confluent/cfk-on-docker-desktop.git
cd cfk-on-docker-desktop
```

### 1.2 Make Scripts Executable

```bash
chmod +x scripts/*.sh
chmod +x connectors/*.sh
```

---

## Step 2: Deploy Confluent Platform

### Option A: Automated Deployment (Recommended)

Run the setup script to deploy everything:

```bash
./scripts/setup.sh
```

This script will:
1. Add the Confluent Helm repository
2. Create the `confluent` namespace
3. Install the CFK (Confluent for Kubernetes) operator
4. Deploy KRaft controllers (wait for ready)
5. Deploy Kafka brokers (wait for ready)
6. Deploy Schema Registry, Connect, ksqlDB, REST Proxy, Control Center
7. Deploy Prometheus & Grafana with pre-configured dashboards

### Option B: Manual Step-by-Step Deployment

If you prefer to deploy components individually:

#### 2.1 Install CFK Operator

```bash
# Add Confluent Helm repository
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

# Create namespace
kubectl apply -f namespace.yaml

# Install CFK operator
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace confluent \
  --set namespaced=false \
  --wait

# Verify operator is running
kubectl wait --for=condition=ready pod -l app=confluent-operator -n confluent --timeout=180s
```

#### 2.2 Deploy KRaft Controllers

```bash
kubectl apply -f kraftcontroller.yaml

# Wait for KRaft controllers to be ready (this may take 2-3 minutes)
kubectl wait --for=condition=ready pod -l app=kraftcontroller -n confluent --timeout=300s
```

#### 2.3 Deploy Kafka Brokers

```bash
kubectl apply -f kafka.yaml

# Wait for Kafka brokers to be ready (this may take 2-3 minutes)
kubectl wait --for=condition=ready pod -l app=kafka -n confluent --timeout=300s
```

#### 2.4 Deploy Supporting Components

```bash
# Schema Registry
kubectl apply -f schemaregistry.yaml
kubectl wait --for=condition=ready pod -l app=schemaregistry -n confluent --timeout=180s

# Kafka Connect
kubectl apply -f connect.yaml
kubectl wait --for=condition=ready pod -l app=connect -n confluent --timeout=300s

# ksqlDB
kubectl apply -f ksqldb.yaml
kubectl wait --for=condition=ready pod -l app=ksqldb -n confluent --timeout=180s

# REST Proxy
kubectl apply -f kafkarestproxy.yaml
kubectl wait --for=condition=ready pod -l app=kafkarestproxy -n confluent --timeout=180s

# Control Center
kubectl apply -f controlcenter.yaml
kubectl wait --for=condition=ready pod -l app=controlcenter -n confluent --timeout=300s
```

#### 2.5 Deploy Monitoring Stack

```bash
./scripts/deploy-monitoring.sh
```

---

## Step 3: Verify Deployment

### 3.1 Quick Health Check

For a fast, at-a-glance status of all components:

```bash
./scripts/health-check.sh
```

This shows pod status, connector status, and resource summary with colored indicators.

### 3.2 Full Validation (Recommended)

Run the comprehensive validation script to verify all components and API endpoints:

```bash
./scripts/validate.sh
```

This script checks:
- Kubernetes cluster connectivity
- All Confluent Platform pods (KRaft, Kafka, Schema Registry, Connect, ksqlDB, REST Proxy, Control Center)
- API endpoints for each service
- Monitoring stack (Prometheus, Grafana, Alertmanager)

### 3.3 Manual Check - All Pods Running

```bash
kubectl get pods -n confluent
```

Expected output (all pods should show `Running` status):

```
NAME                                  READY   STATUS    RESTARTS   AGE
confluent-operator-xxxxxxxxxx-xxxxx   1/1     Running   0          5m
connect-0                             1/1     Running   0          3m
controlcenter-0                       1/1     Running   0          2m
kafka-0                               1/1     Running   0          4m
kafka-1                               1/1     Running   0          4m
kafka-2                               1/1     Running   0          4m
kafkarestproxy-0                      1/1     Running   0          2m
kraftcontroller-0                     1/1     Running   0          5m
kraftcontroller-1                     1/1     Running   0          5m
kraftcontroller-2                     1/1     Running   0          5m
ksqldb-0                              1/1     Running   0          3m
schemaregistry-0                      1/1     Running   0          3m
```

### 3.4 Check Monitoring Pods

```bash
kubectl get pods -n monitoring
```

### 3.5 Check Services

```bash
kubectl get svc -n confluent
kubectl get svc -n monitoring
```

---

## Step 4: Access Services

Open multiple terminal windows/tabs for port forwarding:

### 4.1 Control Center (Confluent UI)

```bash
kubectl port-forward svc/controlcenter -n confluent 9021:9021
```

Open in browser: **http://localhost:9021**

### 4.2 Grafana (Monitoring Dashboards)

```bash
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open in browser: **http://localhost:3000**
- **Username:** admin
- **Password:** admin

### 4.3 Prometheus (Metrics)

```bash
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

### 4.4 Kafka Connect Metrics Endpoint

```bash
./scripts/port-forward-connect-metrics.sh
```

Open in browser: **http://localhost:7778/metrics**

Use this when validating the raw Kafka Connect metrics that Datadog should scrape.

Open in browser: **http://localhost:9090**

### 4.4 Schema Registry

```bash
kubectl port-forward svc/schemaregistry -n confluent 8081:8081
```

Test: `curl http://localhost:8081/subjects`

### 4.5 Kafka Connect REST API

```bash
kubectl port-forward svc/connect -n confluent 8083:8083
```

Test: `curl http://localhost:8083/connectors`

### 4.6 ksqlDB

```bash
kubectl port-forward svc/ksqldb -n confluent 8088:8088
```

### 4.7 REST Proxy

```bash
kubectl port-forward svc/kafkarestproxy -n confluent 8082:8082
```

---

## Step 5: Deploy Sample Connectors

This project includes a sample data pipeline: **Datagen → Kafka → MySQL**

```
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│  Datagen        │      │   Kafka Topic   │      │     MySQL       │
│  Connector      │─────►│    "Orders"     │─────►│   orders table  │
│  (Source)       │      │                 │      │   (Sink)        │
└─────────────────┘      └─────────────────┘      └─────────────────┘
```

```bash
# Start Connect port-forward
kubectl port-forward svc/connect -n confluent 8083:8083

# Deploy connectors (in a new terminal)
./connectors/deploy-connectors.sh

# Verify
curl http://localhost:8083/connectors | jq .
```

See [connectors/README.md](connectors/README.md) for detailed documentation, including MySQL setup, manual deployment, connector operations, and troubleshooting.

---

## Step 6: Deploy ksqlDB Examples

This project includes ksqlDB examples demonstrating stream processing with the Orders data.

### 6.1 Deploy ksqlDB Objects

```bash
# Start port-forward to ksqlDB
kubectl port-forward svc/ksqldb -n confluent 8088:8088 &

# Deploy streams and tables
./ksqldb/deploy-ksqldb-objects.sh
```

### 6.2 Interactive ksqlDB CLI

```bash
kubectl exec -it ksqldb-0 -n confluent -- ksql http://localhost:8088
```

### 6.3 Example Queries

**Push Query (streaming):**
```sql
SELECT * FROM orders_stream EMIT CHANGES;
```

**Pull Query (point-in-time):**
```sql
SELECT * FROM orders_by_state WHERE state = 'California';
```

### Objects Created

| Type | Name | Description |
|------|------|-------------|
| Stream | `orders_stream` | Raw orders from Kafka topic |
| Stream | `orders_flat` | Flattened address fields |
| Table | `orders_by_state` | Aggregation by state |
| Table | `orders_by_item` | Aggregation by item |
| Table | `orders_per_minute` | 1-minute tumbling window |
| Table | `orders_rolling_5min` | 5-minute hopping window |

See `ksqldb/README.md` for detailed documentation.

---

## Teardown

### Complete Teardown

To remove all Confluent Platform components and monitoring:

```bash
./scripts/destroy.sh
```

This will:
1. Teardown monitoring stack (Prometheus, Grafana)
2. Delete all Confluent components in reverse order
3. Delete Persistent Volume Claims
4. Uninstall CFK operator
5. Delete the confluent namespace

### Partial Teardown

```bash
# Teardown monitoring only
./scripts/teardown-monitoring.sh

# Teardown specific component
kubectl delete -f controlcenter.yaml
```

---

## Monitoring Architecture

This project provisions **two independent monitoring stacks** from the same `./scripts/deploy-monitoring.sh` script — Grafana is always installed; Datadog is optional and additive.

```
Confluent Components (:7778)  →  Prometheus (scrapes metrics)  →  Grafana (8 dashboards, always deployed)
                                                                →  Alertmanager (18 alert rules)

Confluent Components (JMX :7203 / pod annotations)  →  Datadog Agent (optional, DEPLOY_DATADOG=true + DD_API_KEY)
```

- **Grafana/Prometheus** (`monitoring` namespace) is installed unconditionally by `deploy-monitoring.sh` via `kube-prometheus-stack`, with all 8 dashboards loaded as ConfigMaps. Nothing about the Datadog integration disables or replaces this stack.
- **Datadog Agent** (`datadog-agent` namespace) is installed afterwards, only if `DEPLOY_DATADOG=true` (the default) **and** a `DD_API_KEY` is supplied (env var or interactive prompt). Set `DEPLOY_DATADOG=false` to skip it entirely — Grafana deployment is unaffected either way.

See [monitoring/monitoring-guide.md](monitoring/monitoring-guide.md) for the full Grafana/Prometheus guide (dashboards, alert rules, key metrics, PromQL cheat sheet, and multi-platform setup for Docker Desktop, Azure, AWS, GCP), and [docs/datadog-confluent-platform-integration.md](docs/datadog-confluent-platform-integration.md) for the Datadog setup.

---

## Project Structure

```
cfk-on-docker-desktop/
├── docs/
│   └── kafka-cli-cheatsheet.md  # Kafka CLI quick reference
├── scripts/
│   ├── README.md                # Scripts documentation & guide
│   ├── setup.sh                 # Deploy everything (main script)
│   ├── destroy.sh               # Teardown everything
│   ├── deploy-monitoring.sh     # Deploy monitoring only
│   ├── teardown-monitoring.sh   # Teardown monitoring only
│   ├── validate.sh              # Validate all components and APIs
│   └── health-check.sh          # Quick status overview
├── monitoring/
│   ├── prometheus-values.yaml   # Prometheus/Grafana helm values
│   ├── alertrules.yaml          # Alertmanager rules
│   └── dashboards/              # Grafana dashboard JSON files
│       ├── Kafka_grafana.json
│       ├── Connect_grafana.json
│       ├── Kafka_Broker_Resources_grafana.json
│       ├── Kafka_Connect_Resources_grafana.json
│       ├── Schema_Registry_Resources_grafana.json
│       ├── ksqlDB_Resources_grafana.json
│       ├── Control_Center_Resources_grafana.json
│       ├── KRaft_Controller_Resources_grafana.json
│       └── REST_Proxy_Resources_grafana.json
├── connectors/
│   ├── README.md                # Connector documentation & guide
│   ├── datagen-orders.json      # Datagen source connector config
│   ├── jdbc-sink-orders.json    # JDBC Sink connector config
│   ├── deploy-connectors.sh     # Script to deploy connectors
│   └── mysql-db-scripts/
│       └── orders-table.sql     # SQL script to create MySQL table
├── ksqldb/
│   ├── 01-create-orders-stream.sql    # Create base stream
│   ├── 02-create-orders-flat-stream.sql # Flatten nested fields
│   ├── 03-create-aggregations.sql     # Aggregation tables
│   ├── 04-example-queries.sql         # Push/pull query examples
│   ├── deploy-ksqldb-objects.sh       # Deploy script
│   └── README.md                      # ksqlDB documentation
├── namespace.yaml               # Confluent namespace
├── kraftcontroller.yaml         # KRaft controller CR
├── kafka.yaml                   # Kafka broker CR
├── schemaregistry.yaml          # Schema Registry CR
├── connect.yaml                 # Kafka Connect CR
├── ksqldb.yaml                  # ksqlDB CR
├── kafkarestproxy.yaml          # REST Proxy CR
├── controlcenter.yaml           # Control Center CR
└── README.md                    # This file
```

---

## Troubleshooting

### Pods Not Starting

```bash
# Check pod events
kubectl describe pod <pod-name> -n confluent

# Check pod logs
kubectl logs <pod-name> -n confluent

# Check all events in namespace
kubectl get events -n confluent --sort-by='.lastTimestamp'
```

### Resource Constraints (OOMKilled)

If pods are being OOMKilled:

1. Increase Docker Desktop resources (Settings → Resources)
2. Or reduce replica counts in YAML files:
   ```yaml
   spec:
     replicas: 1  # Reduce from 3 to 1 for testing
   ```

### Metrics Not Showing in Grafana

1. Check Prometheus targets:
   - Open http://localhost:9090/targets
   - Verify all targets show "UP" status

2. Check if pods expose metrics:
   ```bash
   kubectl exec -n confluent kafka-0 -- curl -s http://localhost:7778/metrics | head
   ```

3. Check scrape config:
   ```bash
   kubectl get secret prometheus-kube-prometheus-prometheus-scrape-config -n monitoring -o yaml
   ```

### Connect Metrics Target Down

The Connect metrics endpoint may have slower response times. If you see "context deadline exceeded":

1. The Prometheus scrape config includes a 30-second timeout
2. Verify Connect pod is healthy:
   ```bash
   kubectl get pods -n confluent -l app=connect
   kubectl logs connect-0 -n confluent
   ```

### Connector Failures

```bash
# Check connector status
curl http://localhost:8083/connectors/datagen-orders/status | jq .

# Check connector tasks
curl http://localhost:8083/connectors/datagen-orders/tasks/0/status | jq .

# Restart failed connector
curl -X POST http://localhost:8083/connectors/datagen-orders/restart

# Delete and recreate connector
curl -X DELETE http://localhost:8083/connectors/datagen-orders
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @connectors/datagen-orders.json
```

### MySQL Connection Issues (JDBC Sink)

1. Ensure MySQL is running:
   ```bash
   mysql -u admin -padmin -e "SELECT 1;"
   ```

2. Verify `host.docker.internal` resolves from within Kubernetes:
   ```bash
   kubectl exec -n confluent connect-0 -- ping -c 1 host.docker.internal
   ```

3. Check connector logs:
   ```bash
   kubectl logs connect-0 -n confluent | grep -i jdbc
   ```

### Namespace Stuck Terminating

If namespace deletion hangs:

```bash
# Check what's blocking
kubectl get namespace confluent -o yaml

# Force remove finalizers
kubectl get namespace confluent -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/confluent/finalize" -f -
```

---

## Quick Reference Commands

See [docs/kafka-cli-cheatsheet.md](docs/kafka-cli-cheatsheet.md) for a comprehensive Kafka CLI reference.

```bash
# Check all Confluent pods
kubectl get pods -n confluent

# Check all Monitoring pods
kubectl get pods -n monitoring

# Port forward all services (run in separate terminals)
kubectl port-forward svc/controlcenter -n confluent 9021:9021
kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
kubectl port-forward svc/connect -n confluent 8083:8083

# Produce test message
kubectl exec -n confluent kafka-0 -- kafka-console-producer --bootstrap-server kafka:9092 --topic test

# Consume messages
kubectl exec -n confluent kafka-0 -- kafka-console-consumer --bootstrap-server kafka:9092 --topic test --from-beginning

# List topics
kubectl exec -n confluent kafka-0 -- kafka-topics --bootstrap-server kafka:9092 --list

# Describe topic
kubectl exec -n confluent kafka-0 -- kafka-topics --bootstrap-server kafka:9092 --describe --topic Orders
```

---

## License

This project is for demonstration and POC purposes.
