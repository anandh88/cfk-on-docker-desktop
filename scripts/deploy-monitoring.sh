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

# ---------- Splunk config (optional, additive to Grafana) ----------
DEPLOY_SPLUNK="${DEPLOY_SPLUNK:-true}"   # set to false to skip Splunk entirely
# SPLUNK_HEC_TOKEN must be exported or entered interactively; there's no safe default.
# Requires a metrics-type Splunk index ("cfk_metrics") already created — see
# monitoring/splunk/README-local-poc.md.

cd "$MONITORING_DIR"

# NOTE: Prometheus + Grafana (with all dashboards) are always installed below,
# regardless of DEPLOY_DATADOG/DEPLOY_SPLUNK. Datadog and Splunk are separate,
# optional add-ons installed afterwards — neither gates or replaces the Grafana stack.

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

echo "=== Applying Confluent ServiceMonitors ==="
kubectl apply -f docker-desktop-k8s/kafka-servicemonitor.yaml
kubectl apply -f docker-desktop-k8s/kraftcontroller-servicemonitor.yaml

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

echo ""
echo "=============================================="
echo "  Splunk OTel Collector (optional, additive)"
echo "=============================================="

# Prompt for SPLUNK_HEC_TOKEN if not already set and Splunk install is requested.
# Running non-interactively (e.g. piped or CI)? Skip the prompt and let the
# missing-token warning below handle it gracefully.
if [ "${DEPLOY_SPLUNK}" = "true" ] && [ -z "${SPLUNK_HEC_TOKEN:-}" ]; then
  if [ -t 0 ]; then
    echo "  Enter your Splunk Cloud HEC token to install the collector, or press Enter to skip."
    read -rsp "  SPLUNK_HEC_TOKEN (hidden, Enter to skip): " SPLUNK_HEC_TOKEN
    echo ""
  fi
fi

if [ "${DEPLOY_SPLUNK}" = "true" ]; then
  if [ -z "${SPLUNK_HEC_TOKEN:-}" ]; then
    echo "  WARN: SPLUNK_HEC_TOKEN is not set — skipping Splunk OTel Collector install."
    echo "  Export SPLUNK_HEC_TOKEN and re-run, or set DEPLOY_SPLUNK=false to suppress this warning."
    echo "  See monitoring/splunk/README-local-poc.md for how to create a metrics-type index"
    echo "  ('cfk_metrics') and HEC token — required before this will forward any data."
  else
    echo "  Creating splunk-otel namespace..."
    kubectl create namespace splunk-otel --dry-run=client -o yaml | kubectl apply -f -

    echo "  Creating/updating splunk-hec secret (HEC token, key: splunk_platform_hec_token)..."
    # Created as its own Secret, referenced via secret.create=false/secret.name in the values
    # file, rather than passed with --set - --set would land the plaintext token in
    # `helm get values`/release history. This is the chart's own documented pattern for
    # providing tokens as a secret, not a local invention.
    kubectl create secret generic splunk-hec \
      --from-literal=splunk_platform_hec_token="$SPLUNK_HEC_TOKEN" \
      --namespace splunk-otel \
      --dry-run=client -o yaml | kubectl apply -f -

    echo "  Adding Splunk OTel Collector Helm repo..."
    helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart 2>/dev/null || true
    helm repo update splunk-otel-collector-chart

    echo "  Installing/upgrading Splunk OTel Collector..."
    helm upgrade --install splunk-otel-collector \
      splunk-otel-collector-chart/splunk-otel-collector \
      --namespace splunk-otel \
      --values "$MONITORING_DIR/splunk/otel-collector-values.docker-desktop.yaml" \
      --wait

    echo "  Splunk OTel Collector pods:"
    kubectl get pods -n splunk-otel
  fi
else
  echo "  DEPLOY_SPLUNK=false — skipping."
fi

echo "=== Monitoring deployment complete ==="
echo ""
echo "Dashboards deployed (Grafana):"
echo "  - Kafka (metrics)"
echo "  - Connect (metrics)"
echo "  - Kafka Broker Resources (Memory, CPU, Disk, JVM)"
echo "  - Kafka Connect Resources (Memory, CPU, JVM)"
echo "  - Schema Registry Resources (Memory, CPU, JVM)"
echo "  - Control Center Resources (Memory, CPU, JVM)"
echo "  - KRaft Controller Resources (Memory, CPU, JVM)"
echo "  - REST Proxy Resources (Memory, CPU, JVM)"
echo "  - Enterprise Tiered Observability (Tier 1 Infrastructure / Tier 2 Platform / Tier 3 Business)"

if [ "${DEPLOY_SPLUNK}" = "true" ] && [ -n "${SPLUNK_HEC_TOKEN:-}" ]; then
  echo ""
  echo "Splunk dashboards (import manually into Splunk Dashboard Studio — Splunk Cloud"
  echo "has no kubectl-equivalent for this step; source JSON lives in monitoring/splunk/dashboards/):"
  echo "  - Kafka_splunk.json"
  echo "  - Connect_splunk.json"
  echo "  - Kafka_Broker_Resources_splunk.json"
  echo "  - Kafka_Connect_Resources_splunk.json"
  echo "  - Schema_Registry_Resources_splunk.json"
  echo "  - Control_Center_Resources_splunk.json"
  echo "  - KRaft_Controller_Resources_splunk.json"
  echo "  - Enterprise_Tiered_Observability_splunk.json"
  echo "  (see monitoring/splunk/dashboards/METRICS_REFERENCE.md if a panel comes up blank)"
fi
