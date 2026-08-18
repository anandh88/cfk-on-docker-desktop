#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="${NAMESPACE:-confluent}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$PROJECT_DIR/manifests-jmx-no-prometheus-20260617-135249}"

# Reverse order for safe teardown.
MANIFEST_FILES_REVERSE=(
  "controlcenter.yaml"
  "kafkarestproxy.yaml"
  "connect.yaml"
  "schemaregistry.yaml"
  "kafka.yaml"
  "kraftcontroller.yaml"
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

echo ""
echo "=============================================="
echo "  Confluent Platform Destroy (JMX Manifests)"
echo "=============================================="
echo ""

require_cmd kubectl
require_cmd helm

if [ -x "$PROJECT_DIR/scripts/teardown-monitoring.sh" ]; then
  log_info "Tearing down monitoring stack"
  "$PROJECT_DIR/scripts/teardown-monitoring.sh" || true
fi

if [ -d "$MANIFESTS_DIR" ]; then
  for file in "${MANIFEST_FILES_REVERSE[@]}"; do
    if [ -f "$MANIFESTS_DIR/$file" ]; then
      log_info "Deleting ${file}"
      kubectl delete -f "$MANIFESTS_DIR/$file" --ignore-not-found --timeout=60s || true
    fi
  done
else
  log_warn "MANIFESTS_DIR not found ($MANIFESTS_DIR), skipping file-based deletes"
fi

log_info "Deleting remaining Confluent custom resources (best effort)"
for crd in $(kubectl get crds -o name 2>/dev/null | grep confluent | sed 's|customresourcedefinition.apiextensions.k8s.io/||'); do
  kubectl delete "$crd" --all -n "$NAMESPACE" --ignore-not-found --timeout=30s 2>/dev/null || true
done

log_info "Deleting PVCs in namespace $NAMESPACE"
kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found || true

log_info "Uninstalling CFK operator"
helm uninstall confluent-operator -n "$NAMESPACE" 2>/dev/null || true

log_info "Deleting namespace $NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=120s || true

echo ""
echo "Destroy complete."
