# Scripts

This folder contains all the operational scripts for deploying, managing, and monitoring the Confluent Platform on Kubernetes.

## Quick Reference

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `setup.sh` | Deploy everything | First time setup |
| `destroy.sh` | Remove everything | Complete cleanup |
| `validate.sh` | Full health check | After setup or issues |
| `health-check.sh` | Quick status view | Anytime |
| `deploy-monitoring.sh` | Deploy Prometheus/Grafana | Monitoring only |
| `teardown-monitoring.sh` | Remove monitoring | Monitoring cleanup |
| `port-forward-connect-metrics.sh` | Expose Connect metrics locally | Datadog demo / local metrics inspection |

## Script Execution Order

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           TYPICAL WORKFLOW                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   INITIAL SETUP                                                                 │
│   ─────────────                                                                 │
│   1. ./scripts/setup.sh          ◄── Start here! Deploys everything            │
│   2. ./scripts/validate.sh       ◄── Verify everything is working              │
│   3. ./scripts/health-check.sh   ◄── Quick status view                         │
│                                                                                 │
│   DAILY OPERATIONS                                                              │
│   ────────────────                                                              │
│   • ./scripts/health-check.sh    ◄── Quick "is everything OK?" check           │
│   • ./scripts/validate.sh        ◄── Detailed validation when needed           │
│                                                                                 │
│   CLEANUP                                                                       │
│   ───────                                                                       │
│   • ./scripts/destroy.sh         ◄── Remove everything when done               │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Scripts in Detail

### port-forward-connect-metrics.sh - Expose Connect Metrics Locally

**When to use**: Before a Datadog demo or anytime you want to open the Kafka Connect metrics endpoint in a browser.

**Usage**:
```bash
./scripts/port-forward-connect-metrics.sh
```

**Result**:
```bash
http://localhost:7778/metrics
```

Without this port-forward, `localhost:7778` does not reach the Connect pod from your laptop.

---

### setup.sh - Deploy Everything

**When to use**: First time setup or after a complete teardown.

**What it does**:
```
1. Pre-flight checks
   ├── Verify kubectl is installed
   ├── Verify helm is installed
   ├── Verify cluster is accessible
   └── Check for existing installation

2. Install CFK Operator
   ├── Add Confluent Helm repo
   ├── Create 'confluent' namespace
   └── Deploy Confluent for Kubernetes operator

3. Deploy Confluent Platform (in order)
   ├── KRaft Controllers (3 replicas) ─── waits until ready
   ├── Kafka Brokers (3 replicas) ─────── waits until ready
   ├── Schema Registry ────────────────── waits until ready
   ├── Kafka Connect ──────────────────── waits until ready
   ├── ksqlDB ─────────────────────────── waits until ready
   ├── REST Proxy ─────────────────────── waits until ready
   └── Control Center ─────────────────── waits until ready

4. Deploy Monitoring
   └── Calls deploy-monitoring.sh
```

**Usage**:
```bash
./scripts/setup.sh
```

**Expected duration**: 10-15 minutes (depends on image pulls)

**What to do after**:
```bash
# Verify deployment
./scripts/validate.sh

# Access Control Center
kubectl port-forward svc/controlcenter -n confluent 9021:9021
# Open http://localhost:9021
```

---

### destroy.sh - Remove Everything

**When to use**: Complete cleanup when you're done or want to start fresh.

**What it does**:
```
1. Teardown Monitoring
   └── Calls teardown-monitoring.sh

2. Delete Confluent Components (reverse order)
   ├── Control Center
   ├── REST Proxy
   ├── ksqlDB
   ├── Kafka Connect
   ├── Schema Registry
   ├── Kafka Brokers
   └── KRaft Controllers

3. Cleanup
   ├── Wait for pods to terminate
   ├── Force delete stuck pods (if any)
   ├── Delete Persistent Volume Claims
   ├── Uninstall CFK operator
   └── Delete 'confluent' namespace
```

**Usage**:
```bash
./scripts/destroy.sh
```

**⚠️ Warning**: This is destructive! All data in Kafka topics will be lost.

---

### validate.sh - Full Health Check

**When to use**: After setup, after issues, or for thorough verification.

**What it does**:
```
Checks (with pass/fail/warn status):
├── Kubernetes Cluster
│   ├── Cluster connectivity
│   ├── Confluent namespace exists
│   └── Monitoring namespace exists
│
├── CFK Operator
│   └── Operator pod running
│
├── KRaft Controllers
│   └── 3/3 pods running
│
├── Kafka Brokers
│   ├── 3/3 pods running
│   ├── Metrics endpoint responding
│   └── Cluster ID retrievable
│
├── Schema Registry
│   ├── Pod running
│   └── API responding
│
├── Kafka Connect
│   ├── Pod running
│   ├── REST API responding
│   ├── Connector count
│   └── Metrics endpoint responding
│
├── ksqlDB
│   ├── Pod running
│   └── API responding
│
├── REST Proxy
│   ├── Pod running
│   └── API responding
│
├── Control Center
│   ├── Pod running
│   └── UI responding
│
└── Monitoring Stack
    ├── Prometheus running
    ├── Grafana running
    └── Alertmanager running
```

**Usage**:
```bash
./scripts/validate.sh
```

**Output**:
```
╔═══════════════════════════════════════════════════════════════╗
║     Confluent Platform Validation Script                      ║
╚═══════════════════════════════════════════════════════════════╝

════════════════════════════════════════════════════════════
  Kafka Brokers
════════════════════════════════════════════════════════════
  Checking broker pods (expected: 3)... ✓ PASS (3/3 running)
  Checking broker metrics endpoint... ✓ PASS
  ...

════════════════════════════════════════════════════════════
  Validation Summary
════════════════════════════════════════════════════════════

  Passed:   21
  Failed:   0
  Warnings: 1

╔═══════════════════════════════════════════════════════════════╗
║  ✓ All critical checks passed!                               ║
╚═══════════════════════════════════════════════════════════════╝
```

---

### health-check.sh - Quick Status View

**When to use**: Anytime you want a quick overview of system status.

**What it does**:
- Shows pod status with colored indicators (● green = healthy)
- Lists connector status
- Shows resource summary
- Provides quick port-forward commands

**Usage**:
```bash
./scripts/health-check.sh
```

**Output**:
```
╔══════════════════════════════════════════════════════════╗
║         Confluent Platform Health Check                  ║
╚══════════════════════════════════════════════════════════╝
  2024-01-25 15:44:46

Confluent Platform
──────────────────────────────────────────────────
  CFK Operator:             ● 1/1
  KRaft Controllers:        ● 3/3
  Kafka Brokers:            ● 3/3
  Schema Registry:          ● 1/1
  Kafka Connect:            ● 1/1
  ...

Kafka Connectors
──────────────────────────────────────────────────
  datagen-orders:           ● RUNNING
  jdbc-sink-orders:         ● RUNNING

  ● Healthy  ● Warning  ● Failed  ○ Unknown
```

**Difference from validate.sh**:
| health-check.sh | validate.sh |
|-----------------|-------------|
| Quick (~5 sec) | Thorough (~30 sec) |
| Pod status only | API endpoint tests |
| Visual overview | Detailed diagnostics |
| Daily use | Troubleshooting |

---

### deploy-monitoring.sh - Deploy Monitoring Only

**When to use**: If you want to deploy/redeploy monitoring separately.

**What it does**:
```
1. Create 'monitoring' namespace
2. Add Prometheus Helm repo
3. Deploy kube-prometheus-stack
   ├── Prometheus
   ├── Grafana
   └── Alertmanager
4. Apply Confluent ServiceMonitors + create Grafana dashboard ConfigMaps
5. Apply alert rules
6. Datadog Agent (optional, additive — DEPLOY_DATADOG=false to skip)
7. Splunk OTel Collector (optional, additive — DEPLOY_SPLUNK=false to skip)
```

**Usage**:
```bash
./scripts/deploy-monitoring.sh

# Skip the optional add-ons, or provide credentials for them:
DEPLOY_DATADOG=false DEPLOY_SPLUNK=false ./scripts/deploy-monitoring.sh
DD_API_KEY=xxx SPLUNK_HEC_TOKEN=xxx ./scripts/deploy-monitoring.sh
```

**Note**: This is automatically called by `setup.sh`. Use this only if you need to deploy monitoring independently.

Datadog and Splunk are both optional and additive — they default to attempting install
(`DEPLOY_DATADOG`/`DEPLOY_SPLUNK` both default `true`) but skip gracefully with a warning
if their API key/token isn't set (prompted interactively, or set `DD_API_KEY`/
`SPLUNK_HEC_TOKEN` as env vars beforehand). Neither gates the Prometheus/Grafana stack.
Splunk additionally requires a metrics-type index (`cfk_metrics`) created ahead of time on
the Splunk Cloud side — see `monitoring/splunk/README.md` — and its 8 Dashboard Studio
JSON dashboards (`monitoring/splunk/dashboards/`) must be imported by hand, since Splunk
Cloud has no kubectl-equivalent for that step.

---

### teardown-monitoring.sh - Remove Monitoring Only

**When to use**: If you want to remove monitoring without affecting Confluent Platform.

**What it does**:
```
1. Uninstall Datadog Agent (if installed)
2. Uninstall Splunk OTel Collector (if installed) + delete 'splunk-otel' namespace
3. Delete Grafana dashboard ConfigMaps
4. Delete alert rules
5. Uninstall kube-prometheus-stack
6. Delete 'monitoring' namespace
```

Splunk Dashboard Studio dashboards themselves aren't touched — they live in Splunk Cloud,
not this cluster, and are unaffected by tearing down the collector.

**Usage**:
```bash
./scripts/teardown-monitoring.sh
```

---

## Common Scenarios

### Scenario 1: First Time Setup

```bash
# 1. Deploy everything
./scripts/setup.sh

# 2. Verify deployment
./scripts/validate.sh

# 3. Deploy connectors (optional)
kubectl port-forward svc/connect -n confluent 8083:8083 &
./connectors/deploy-connectors.sh

# 4. Deploy ksqlDB objects (optional)
kubectl port-forward svc/ksqldb -n confluent 8088:8088 &
./ksqldb/deploy-ksqldb-objects.sh
```

### Scenario 2: Daily Check

```bash
# Quick status
./scripts/health-check.sh
```

### Scenario 3: Something Seems Wrong

```bash
# Full validation
./scripts/validate.sh

# Check specific pod logs
kubectl logs -n confluent kafka-0
kubectl logs -n confluent connect-0
```

### Scenario 4: Start Fresh

```bash
# Remove everything
./scripts/destroy.sh

# Redeploy
./scripts/setup.sh
```

### Scenario 5: Monitoring Issues Only

```bash
# Remove and redeploy monitoring
./scripts/teardown-monitoring.sh
./scripts/deploy-monitoring.sh
```

---

## Troubleshooting

### Script Fails with "kubectl not found"

Install kubectl:
```bash
# macOS
brew install kubectl
```

### Script Fails with "helm not found"

Install Helm:
```bash
# macOS
brew install helm
```

### Script Hangs on "Waiting for pods"

Check what's happening:
```bash
# See pod status
kubectl get pods -n confluent

# Check events
kubectl get events -n confluent --sort-by='.lastTimestamp'

# Check specific pod
kubectl describe pod <pod-name> -n confluent
```

Common causes:
- Insufficient resources (increase Docker Desktop memory/CPU)
- Image pull issues (check internet connection)
- Previous installation not cleaned up (run `destroy.sh` first)

### Validation Shows Failures

Run health-check first to identify which component:
```bash
./scripts/health-check.sh
```

Then check that component's logs:
```bash
kubectl logs <pod-name> -n confluent
```

### Port-Forward Commands Don't Work

Ensure the pod is running:
```bash
kubectl get pods -n confluent
```

Kill any existing port-forwards:
```bash
pkill -f "port-forward"
```

---

## Script Dependencies

```
setup.sh
└── calls: deploy-monitoring.sh

destroy.sh
└── calls: teardown-monitoring.sh

validate.sh
└── standalone (no dependencies)

health-check.sh
└── standalone (no dependencies)

deploy-monitoring.sh
└── standalone (can be run independently)

teardown-monitoring.sh
└── standalone (can be run independently)
```

---

## Environment Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| Docker Desktop Memory | 12 GB | 16+ GB |
| Docker Desktop CPU | 4 cores | 6+ cores |
| kubectl | v1.25+ | latest |
| helm | v3.10+ | latest |
