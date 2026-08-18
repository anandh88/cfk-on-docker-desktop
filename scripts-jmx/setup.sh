#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="${NAMESPACE:-confluent}"
KUBECTL_WAIT_TIMEOUT="${KUBECTL_WAIT_TIMEOUT:-600}"
DEPLOY_DATADOG="${DEPLOY_DATADOG:-true}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$PROJECT_DIR/manifests-jmx-no-prometheus-20260617-135249}"

# Keep a fixed order to satisfy component dependencies.
MANIFEST_FILES=(
  "kraftcontroller.yaml"
  "kafka.yaml"
  "schemaregistry.yaml"
  "connect.yaml"
  "kafkarestproxy.yaml"
  "controlcenter.yaml"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

die() { log_error "$1"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed or not in PATH"
}

wait_for_pods() {
  local selector="$1"
  local timeout="$2"
  local ns="${3:-$NAMESPACE}"

  log_info "Waiting for pods with selector: $selector (ns=$ns) to be created..."
  local count=0
  local max_wait=60
  while [ $count -lt $max_wait ]; do
    local pod_count
    pod_count=$(kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${pod_count:-0}" -gt 0 ]; then
      break
    fi
    sleep 5
    count=$((count + 1))
  done

  if [ $count -ge $max_wait ]; then
    kubectl get pods -n "$ns" --show-labels || true
    die "Timeout waiting for pods with selector '$selector' to be created"
  fi

  log_info "Waiting for pods with selector: $selector (ns=$ns) to become ready..."
  if ! kubectl wait --for=condition=ready pod -l "$selector" -n "$ns" --timeout="${timeout}s"; then
    kubectl get pods -n "$ns" -l "$selector" -o wide || true
    die "Pods not ready for selector '$selector'"
  fi
}

check_manifests() {
  [ -d "$MANIFESTS_DIR" ] || die "MANIFESTS_DIR does not exist: $MANIFESTS_DIR"
  for file in "${MANIFEST_FILES[@]}"; do
    [ -f "$MANIFESTS_DIR/$file" ] || die "Missing manifest: $MANIFESTS_DIR/$file"
  done
}

ensure_namespace() {
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
}

echo ""
echo "=============================================="
echo "  Confluent Platform Setup (JMX Manifests)"
echo "=============================================="
echo ""

require_cmd kubectl
require_cmd helm

kubectl cluster-info >/dev/null 2>&1 || die "Cannot connect to Kubernetes cluster"

check_manifests
ensure_namespace

if [ -f "$PROJECT_DIR/namespace.yaml" ]; then
  kubectl apply -f "$PROJECT_DIR/namespace.yaml"
fi

log_info "Installing/upgrading Confluent for Kubernetes operator..."
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace "$NAMESPACE" \
  --set namespaced=false \
  --wait

kubectl wait --for=condition=ready pod -l app=confluent-operator -n "$NAMESPACE" --timeout=300s

log_info "Applying manifests from: $MANIFESTS_DIR"

kubectl apply -f "$MANIFESTS_DIR/kraftcontroller.yaml"
wait_for_pods "platform.confluent.io/type=kraftcontroller" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

kubectl apply -f "$MANIFESTS_DIR/kafka.yaml"
wait_for_pods "platform.confluent.io/type=kafka" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

kubectl apply -f "$MANIFESTS_DIR/schemaregistry.yaml"
wait_for_pods "platform.confluent.io/type=schemaregistry" 300 "$NAMESPACE"

kubectl apply -f "$MANIFESTS_DIR/connect.yaml"
wait_for_pods "platform.confluent.io/type=connect" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

kubectl apply -f "$MANIFESTS_DIR/kafkarestproxy.yaml"
wait_for_pods "platform.confluent.io/type=kafkarestproxy" 300 "$NAMESPACE"

kubectl apply -f "$MANIFESTS_DIR/controlcenter.yaml"
wait_for_pods "platform.confluent.io/type=controlcenter" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

log_info "Confluent components deployed"
kubectl get pods -n "$NAMESPACE" -o wide

if [ "$DEPLOY_DATADOG" = "true" ]; then
  log_info "Deploying monitoring stack (includes Datadog)"
  "$PROJECT_DIR/scripts/deploy-monitoring.sh"
else
  log_warn "DEPLOY_DATADOG=false, skipping monitoring deploy"
fi

echo ""
echo "Setup complete."
echo "Manifests source: $MANIFESTS_DIR"
echo ""
echo "Next checks:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get pods -n datadog-agent"
