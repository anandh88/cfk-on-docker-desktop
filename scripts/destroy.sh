#!/bin/bash
set -u

# Keep script functionality even when PATH is limited or the shell does not expose
# expected coreutils like dirname. Use POSIX-safe path resolution instead.
SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [[ "$SCRIPT_PATH" == */* ]]; then
  SCRIPT_DIR="${SCRIPT_PATH%/*}"
else
  SCRIPT_DIR="."
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" 2>/dev/null && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"

if [ -n "${PROJECT_DIR:-}" ]; then
  cd "$PROJECT_DIR"
fi

# -------------------- Config (env overridable) --------------------
NAMESPACE="${NAMESPACE:-confluent}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
DATADOG_NAMESPACE="${DATADOG_NAMESPACE:-datadog-agent}"
STOP_LOCAL_MYSQL="${STOP_LOCAL_MYSQL:-true}"
MYSQL_SERVICE_NAME="${MYSQL_SERVICE_NAME:-mysql}"
MYSQL_CONTAINER_NAME="${MYSQL_CONTAINER_NAME:-mysql}"

# Ports commonly used by local port-forward sessions in this project
PORT_FORWARD_PORTS=(9021 3000 8081 8083 8088)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "$cmd is not installed or not in PATH"
    return 1
  fi
  return 0
}

ensure_tools() {
  if ! require_cmd kubectl; then
    log_warn "kubectl is unavailable in this shell. The teardown cannot proceed safely."
    exit 0
  fi

  if ! require_cmd helm; then
    log_warn "helm is not installed or not in PATH; Datadog uninstall will be skipped."
  fi

  if ! require_cmd jq; then
    log_warn "jq is not installed; falling back to Python JSON handling where needed"
  fi
}

kill_project_port_forwards() {
  log_info "Stopping local kubectl port-forwards related to this project..."

  # Kill by command pattern first (least noisy for active port-forwards)
  pkill -f "kubectl port-forward.*${NAMESPACE}" 2>/dev/null || true
  pkill -f "kubectl port-forward.*${MONITORING_NAMESPACE}" 2>/dev/null || true
  pkill -f "kubectl port-forward.*controlcenter" 2>/dev/null || true
  pkill -f "kubectl port-forward.*schemaregistry" 2>/dev/null || true
  pkill -f "kubectl port-forward.*connect" 2>/dev/null || true
  pkill -f "kubectl port-forward.*ksqldb" 2>/dev/null || true
  pkill -f "kubectl port-forward.*grafana" 2>/dev/null || true
  pkill -f "kubectl port-forward.*prometheus" 2>/dev/null || true

  # Best-effort cleanup by known local ports
  if command -v lsof &>/dev/null; then
    for p in "${PORT_FORWARD_PORTS[@]}"; do
      for pid in $(lsof -ti tcp:"$p" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null || true
      done
    done
  fi
}

force_finalize_namespace() {
  local ns="$1"
  if ! kubectl get namespace "$ns" &>/dev/null; then
    return 0
  fi

  log_warn "Namespace '$ns' still exists, attempting force finalize..."

  if command -v jq >/dev/null 2>&1; then
    kubectl get namespace "$ns" -o json | \
      jq '.spec.finalizers = []' | \
      kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    kubectl get namespace "$ns" -o json > /tmp/${ns}.namespace.json 2>/dev/null || true
    if [ -s "/tmp/${ns}.namespace.json" ]; then
      python3 - "$ns" <<'PY'
import json, sys
ns = sys.argv[1]
path = f"/tmp/{ns}.namespace.json"
try:
    with open(path) as f:
        data = json.load(f)
    data.setdefault("spec", {})["finalizers"] = []
    with open(path, "w") as f:
        json.dump(data, f)
except Exception:
    pass
PY
      kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f "/tmp/${ns}.namespace.json" 2>/dev/null || true
    fi
  else
    log_warn "Neither jq nor python3 is available; skipping namespace finalizer cleanup for '$ns'"
  fi
}

teardown_local_mysql() {
  if [ "$STOP_LOCAL_MYSQL" != "true" ]; then
    log_info "Skipping local MySQL teardown (STOP_LOCAL_MYSQL=false)"
    return 0
  fi

  log_info "=== Tearing down local MySQL for JDBC sink ==="

  if command -v brew &>/dev/null; then
    if brew services list 2>/dev/null | awk '{print $1}' | grep -qx "$MYSQL_SERVICE_NAME"; then
      log_info "Stopping Homebrew MySQL service: $MYSQL_SERVICE_NAME"
      brew services stop "$MYSQL_SERVICE_NAME" >/dev/null 2>&1 || true
    fi
  fi

  if command -v docker &>/dev/null; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MYSQL_CONTAINER_NAME"; then
      log_info "Stopping/removing Docker MySQL container: $MYSQL_CONTAINER_NAME"
      docker rm -f "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
  fi
}

teardown_datadog_agent() {
  log_info "=== Tearing down Datadog Agent ==="

  if ! kubectl get namespace "$DATADOG_NAMESPACE" &>/dev/null; then
    log_info "Datadog namespace '$DATADOG_NAMESPACE' does not exist, nothing to clean up"
    return 0
  fi

  log_info "Uninstalling Datadog Helm release..."
  helm uninstall datadog -n "$DATADOG_NAMESPACE" 2>/dev/null || true

  log_info "Waiting for Datadog pods to terminate..."
  kubectl wait --for=delete pod --all -n "$DATADOG_NAMESPACE" --timeout=120s 2>/dev/null || true

  remaining_pods=$(kubectl get pods -n "$DATADOG_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "${remaining_pods:-0}" -gt 0 ]; then
    log_warn "Found $remaining_pods remaining Datadog pod(s), force deleting..."
    kubectl delete pods --all -n "$DATADOG_NAMESPACE" --grace-period=0 --force 2>/dev/null || true
    sleep 5
  fi

  log_info "Deleting Datadog namespace..."
  kubectl delete namespace "$DATADOG_NAMESPACE" --ignore-not-found --timeout=120s || true

  count=0
  while kubectl get namespace "$DATADOG_NAMESPACE" &>/dev/null && [ $count -lt 30 ]; do
    sleep 2
    count=$((count + 1))
  done

  force_finalize_namespace "$DATADOG_NAMESPACE"
}

echo ""
echo "=============================================="
echo "  Confluent Platform Destroy"
echo "=============================================="
echo ""

# Required for Kubernetes teardown; if absent, exit cleanly rather than crashing.
ensure_tools

# Stop local forwarders first so teardown logs are clean and no stale local sockets remain.
kill_project_port_forwards
teardown_local_mysql

# Teardown monitoring first
log_info "=== Tearing down Monitoring Stack ==="
if [ -x "$SCRIPT_DIR/teardown-monitoring.sh" ]; then
  "$SCRIPT_DIR/teardown-monitoring.sh" || true
else
  log_warn "teardown-monitoring.sh not found or not executable, skipping monitoring teardown script"
fi

teardown_datadog_agent

echo ""
log_info "=== Tearing down Confluent Platform ==="

# Delete Confluent Platform components in reverse order
log_info "Deleting Control Center..."
kubectl delete -f controlcenter.yaml --ignore-not-found --timeout=60s || true

log_info "Deleting Kafka REST Proxy..."
kubectl delete -f kafkarestproxy.yaml --ignore-not-found --timeout=60s || true

log_info "Deleting Connect..."
kubectl delete -f connect.yaml --ignore-not-found --timeout=60s || true

log_info "Deleting Schema Registry..."
kubectl delete -f schemaregistry.yaml --ignore-not-found --timeout=60s || true

log_info "Deleting Kafka..."
kubectl delete -f kafka.yaml --ignore-not-found --timeout=60s || true

log_info "Deleting KRaft Controller..."
kubectl delete -f kraftcontroller.yaml --ignore-not-found --timeout=60s || true

# Strip finalizers from CFK custom resources that can block namespace deletion
log_info "Removing finalizers from Confluent custom resources..."
for crd in $(kubectl get crds -o name 2>/dev/null | grep confluent | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
  resource_type="${crd%%.*}"
  for item in $(kubectl get "$crd" -n "$NAMESPACE" -o name 2>/dev/null); do
    kubectl patch "$item" -n "$NAMESPACE" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
done

# Delete any remaining Confluent custom resources
log_info "Deleting remaining Confluent custom resources..."
for crd in $(kubectl get crds -o name 2>/dev/null | grep confluent | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
  kubectl delete "$crd" --all -n "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null || true
done

# Wait for all Confluent pods to terminate
log_info "Waiting for Confluent pods to terminate..."
kubectl wait --for=delete pod -l platform.confluent.io/type -n "$NAMESPACE" --timeout=180s 2>/dev/null || true

# Delete any remaining pods
remaining_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining_pods" -gt 0 ]; then
  log_warn "Found $remaining_pods remaining pods, force deleting..."
  kubectl delete pods --all -n "$NAMESPACE" --grace-period=0 --force 2>/dev/null || true
  sleep 10
fi

# Delete PVCs in confluent namespace
log_info "Deleting Persistent Volume Claims..."
kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found || true

# Wait for PVCs to be deleted
kubectl wait --for=delete pvc --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

# Uninstall CFK operator
log_info "Uninstalling CFK operator..."
helm uninstall confluent-operator -n "$NAMESPACE" 2>/dev/null || true

# Wait for operator pods to terminate
kubectl wait --for=delete pod -l app=confluent-operator -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

# Delete the confluent namespace
log_info "Deleting $NAMESPACE namespace..."
kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s || true

# Wait for namespace to be fully deleted
log_info "Waiting for namespace deletion to complete..."
count=0
while kubectl get namespace "$NAMESPACE" &>/dev/null && [ $count -lt 30 ]; do
  sleep 2
  count=$((count + 1))
done

force_finalize_namespace "$NAMESPACE"
sleep 5

# =============================================================================
# PHASE 7: CFK CRDs (cluster-scoped cleanup)
# =============================================================================
echo ""
log_info "=== Phase 7: Deleting CFK Custom Resource Definitions ==="
CFK_CRDS=$(kubectl get crds -o name 2>/dev/null | grep confluent)
if [ -n "$CFK_CRDS" ]; then
  # Strip finalizers from CRDs that may be stuck
  for crd in $CFK_CRDS; do
    kubectl patch "$crd" --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
  # Delete all CFK CRDs
  echo "$CFK_CRDS" | xargs kubectl delete --timeout=60s 2>/dev/null || true
  log_info "CFK CRDs deleted"
else
  log_info "No CFK CRDs found"
fi

# Kill any lingering kubectl port-forward processes
kill_project_port_forwards

echo ""
echo "=============================================="
echo "  Destroy Complete!"
echo "=============================================="
echo ""
log_info "All Confluent Platform and Monitoring resources have been removed."

# Verify cleanup
echo ""
log_info "Verification:"
if kubectl get namespace "$NAMESPACE" &>/dev/null; then
  log_warn "  Confluent namespace: STILL EXISTS"
else
  log_info "  Confluent namespace: DELETED"
fi

if kubectl get namespace "$MONITORING_NAMESPACE" &>/dev/null; then
  log_warn "  Monitoring namespace: STILL EXISTS"
else
  log_info "  Monitoring namespace: DELETED"
fi

cfk_crds=$(kubectl get crds 2>/dev/null | grep -c confluent || true)
if [ "$cfk_crds" -gt 0 ]; then
  log_warn "  CFK CRDs: $cfk_crds REMAINING"
else
  log_info "  CFK CRDs: DELETED"
fi

port_fwd=$(ps aux 2>/dev/null | grep -c "[k]ubectl port-forward" || true)
if [ "$port_fwd" -gt 0 ]; then
  log_warn "  Port-forwards: $port_fwd STILL RUNNING"
else
  log_info "  Port-forwards: NONE"
fi
echo ""
