#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MONITORING_DIR="$PROJECT_DIR/monitoring"
DOCKER_DESKTOP_DIR="$MONITORING_DIR/docker-desktop-k8s"
DATADOG_DIR="$MONITORING_DIR/datadog"

# ---------- Datadog config (optional, additive to Grafana) ----------
DEPLOY_DATADOG="${DEPLOY_DATADOG:-true}"   # set to false to skip Datadog entirely
DD_SITE="${DD_SITE:-us5.datadoghq.com}"

cd "$MONITORING_DIR"

# NOTE: Prometheus + Grafana (with all dashboards) are always installed below,
# regardless of DEPLOY_DATADOG. Datadog is a separate, optional agent installed
# afterwards — it never gates or replaces the Grafana stack.

# Function to create/replace ConfigMap (handles large files)
create_dashboard_configmap() {
  local name=$1
  local file_key=$2
  local file_path=$3

  kubectl delete configmap "$name" -n monitoring --ignore-not-found
  kubectl create configmap "$name" \
    --from-file="$file_key=$file_path" \
    --namespace monitoring
  kubectl label configmap "$name" \
    --namespace monitoring grafana_dashboard=1 --overwrite
  echo "  Created: $name"
}

echo "=============================================="
echo "  Grafana / Prometheus (always provisioned)"
echo "=============================================="

echo "=== Creating monitoring namespace ==="
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "=== Installing Prometheus & Grafana (kube-prometheus-stack) ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values docker-desktop-k8s/prometheus-values.yaml \
  --wait

echo "=== Creating Grafana dashboard ConfigMaps ==="

# Kafka dashboard
create_dashboard_configmap "grafana-dashboard-kafka" \
  "kafka-dashboard.json" "dashboards/Kafka_grafana.json"

# Connect dashboard
create_dashboard_configmap "grafana-dashboard-connect" \
  "connect-dashboard.json" "dashboards/Connect_grafana.json"

# Kafka Broker Resources dashboard
create_dashboard_configmap "grafana-dashboard-kafka-broker-resources" \
  "kafka-broker-resources.json" "dashboards/Kafka_Broker_Resources_grafana.json"

# Kafka Connect Resources dashboard
create_dashboard_configmap "grafana-dashboard-kafka-connect-resources" \
  "kafka-connect-resources.json" "dashboards/Kafka_Connect_Resources_grafana.json"

# Schema Registry Resources dashboard
create_dashboard_configmap "grafana-dashboard-schema-registry-resources" \
  "schema-registry-resources.json" "dashboards/Schema_Registry_Resources_grafana.json"

# Control Center Resources dashboard
create_dashboard_configmap "grafana-dashboard-control-center-resources" \
  "control-center-resources.json" "dashboards/Control_Center_Resources_grafana.json"

# KRaft Controller Resources dashboard
create_dashboard_configmap "grafana-dashboard-kraft-controller-resources" \
  "kraft-controller-resources.json" "dashboards/KRaft_Controller_Resources_grafana.json"

# REST Proxy Resources dashboard
create_dashboard_configmap "grafana-dashboard-rest-proxy-resources" \
  "rest-proxy-resources.json" "dashboards/REST_Proxy_Resources_grafana.json"

# Enterprise Tiered Observability dashboard (cross-CRD Tier 1/2/3 rollup)
create_dashboard_configmap "grafana-dashboard-enterprise-tiered" \
  "enterprise-tiered.json" "dashboards/Enterprise_Tiered_Observability_grafana.json"

echo "=== Applying alert rules ==="
kubectl apply -f docker-desktop-k8s/alertrules.yaml

echo ""
echo "=============================================="
echo "  Datadog Agent (optional, additive)"
echo "=============================================="

# Prompt for DD_API_KEY if not already set and Datadog install is requested.
# Running non-interactively (e.g. piped or CI)? Skip the prompt and let the
# missing-key warning below handle it gracefully.
if [ "${DEPLOY_DATADOG}" = "true" ] && [ -z "${DD_API_KEY:-}" ]; then
  if [ -t 0 ]; then
    echo "  Enter your Datadog API key to install the agent, or press Enter to skip."
    read -rsp "  DD_API_KEY (hidden, Enter to skip): " DD_API_KEY
    echo ""
  fi
fi

if [ "${DEPLOY_DATADOG}" = "true" ]; then
  if [ -z "${DD_API_KEY:-}" ]; then
    echo "  WARN: DD_API_KEY is not set — skipping Datadog agent install."
    echo "  Export DD_API_KEY and re-run, or set DEPLOY_DATADOG=false to suppress this warning."
  else
    echo "  Creating datadog-agent namespace..."
    kubectl apply -f "$DATADOG_DIR/datadog-agent-namespace.yaml"

    echo "  Adding Datadog Helm repo..."
    helm repo add datadog https://helm.datadoghq.com 2>/dev/null || true
    helm repo update datadog

    echo "  Installing/upgrading Datadog agent..."
    helm upgrade --install datadog datadog/datadog \
      --namespace datadog-agent \
      --values "$DATADOG_DIR/datadog-agent-values.yaml" \
      --set datadog.apiKey="$DD_API_KEY" \
      --set datadog.site="$DD_SITE" \
      --wait

    echo "  Datadog agent pods:"
    kubectl get pods -n datadog-agent
  fi
else
  echo "  DEPLOY_DATADOG=false — skipping."
fi

echo "=== Monitoring deployment complete ==="
echo ""
echo "Dashboards deployed:"
echo "  - Kafka (metrics)"
echo "  - Connect (metrics)"
echo "  - Kafka Broker Resources (Memory, CPU, Disk, JVM)"
echo "  - Kafka Connect Resources (Memory, CPU, JVM)"
echo "  - Schema Registry Resources (Memory, CPU, JVM)"
echo "  - Control Center Resources (Memory, CPU, JVM)"
echo "  - KRaft Controller Resources (Memory, CPU, JVM)"
echo "  - REST Proxy Resources (Memory, CPU, JVM)"
echo "  - Enterprise Tiered Observability (Tier 1 Infrastructure / Tier 2 Platform / Tier 3 Business)"
