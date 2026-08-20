#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MONITORING_DIR="$PROJECT_DIR/monitoring"
DOCKER_DESKTOP_DIR="$MONITORING_DIR/docker-desktop-k8s"

cd "$MONITORING_DIR"

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

log_info "=== Tearing down Monitoring Stack ==="

log_info "Uninstalling Datadog Agent (if installed)..."
helm uninstall datadog -n datadog-agent 2>/dev/null || true
kubectl delete namespace datadog-agent --ignore-not-found --timeout=60s || true

log_info "Uninstalling Splunk OTel Collector (if installed)..."
helm uninstall splunk-otel-collector -n splunk-otel 2>/dev/null || true
kubectl delete namespace splunk-otel --ignore-not-found --timeout=60s || true

# Check if monitoring namespace exists
if ! kubectl get namespace monitoring &>/dev/null; then
  log_info "Monitoring namespace does not exist, nothing to clean up"
  exit 0
fi

log_info "Deleting Grafana dashboard ConfigMaps..."
kubectl delete configmap grafana-dashboard-kafka -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-connect -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-kafka-broker-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-kafka-connect-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-schema-registry-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-ksqldb-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-control-center-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-kraft-controller-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-rest-proxy-resources -n monitoring --ignore-not-found
kubectl delete configmap grafana-dashboard-enterprise-tiered -n monitoring --ignore-not-found

log_info "Deleting alert rules..."
kubectl delete -f docker-desktop-k8s/alertrules.yaml --ignore-not-found

log_info "Deleting Confluent ServiceMonitors..."
kubectl delete -f docker-desktop-k8s/kafka-servicemonitor.yaml --ignore-not-found
kubectl delete -f docker-desktop-k8s/kraftcontroller-servicemonitor.yaml --ignore-not-found

log_info "Uninstalling Prometheus & Grafana (kube-prometheus-stack)..."
helm uninstall prometheus -n monitoring 2>/dev/null || true

log_info "Waiting for pods to terminate..."
kubectl wait --for=delete pod -l app.kubernetes.io/instance=prometheus -n monitoring --timeout=120s 2>/dev/null || true

# Delete any remaining pods
remaining_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$remaining_pods" -gt 0 ]; then
  log_warn "Found $remaining_pods remaining pods, waiting for deletion..."
  sleep 10
  kubectl delete pods --all -n monitoring --grace-period=30 2>/dev/null || true
  kubectl wait --for=delete pod --all -n monitoring --timeout=60s 2>/dev/null || true
fi

# Delete PVCs in monitoring namespace
log_info "Deleting Persistent Volume Claims..."
kubectl delete pvc --all -n monitoring --ignore-not-found || true
kubectl wait --for=delete pvc --all -n monitoring --timeout=60s 2>/dev/null || true

log_info "Deleting monitoring namespace..."
kubectl delete namespace monitoring --ignore-not-found --timeout=120s || true

# Wait for namespace deletion
count=0
while kubectl get namespace monitoring &>/dev/null && [ $count -lt 30 ]; do
  sleep 2
  count=$((count + 1))
done

if kubectl get namespace monitoring &>/dev/null; then
  log_warn "Monitoring namespace still exists, attempting force delete..."
  kubectl get namespace monitoring -o json | \
    jq '.spec.finalizers = []' | \
    kubectl replace --raw "/api/v1/namespaces/monitoring/finalize" -f - 2>/dev/null || true
fi

log_info "=== Monitoring teardown complete ==="
