#!/bin/bash
set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

CONNECT_URL="http://localhost:8083"

# Check if port-forward is running
check_port_forward() {
  if ! curl -s "$CONNECT_URL/connectors" > /dev/null 2>&1; then
    log_error "Cannot connect to Kafka Connect at $CONNECT_URL"
    log_info "Please run: kubectl port-forward svc/connect -n confluent 8083:8083"
    exit 1
  fi
}

# Deploy a connector
deploy_connector() {
  local config_file=$1
  local connector_name=$(jq -r '.name' "$config_file")

  log_info "Deploying connector: $connector_name"

  # Check if connector already exists
  if curl -s "$CONNECT_URL/connectors/$connector_name" | jq -e '.name' > /dev/null 2>&1; then
    log_warn "Connector $connector_name already exists, updating..."
    curl -s -X PUT "$CONNECT_URL/connectors/$connector_name/config" \
      -H "Content-Type: application/json" \
      -d "$(jq '.config' "$config_file")" | jq .
  else
    curl -s -X POST "$CONNECT_URL/connectors" \
      -H "Content-Type: application/json" \
      -d @"$config_file" | jq .
  fi
}

# Check connector status
check_status() {
  local connector_name=$1
  log_info "Checking status of $connector_name..."
  curl -s "$CONNECT_URL/connectors/$connector_name/status" | jq .
}

echo ""
echo "=============================================="
echo "  Kafka Connect - Deploy Connectors"
echo "=============================================="
echo ""

check_port_forward

log_info "Available connector plugins:"
curl -s "$CONNECT_URL/connector-plugins" | jq -r '.[].class' | grep -E "Datagen|Jdbc" || log_warn "Expected plugins not found"

echo ""
log_info "Deploying Datagen Orders connector..."
deploy_connector "$SCRIPT_DIR/datagen-orders.json"

echo ""
log_info "Waiting for Datagen connector to start..."
sleep 5
check_status "datagen-orders"

echo ""
log_warn "Before deploying JDBC Sink, ensure:"
log_warn "  1. MySQL is running on host.docker.internal:3306"
log_warn "  2. Orders database and table are created (run orders-table.sql)"
log_warn "  3. User 'admin' with password 'admin' has access"
echo ""

# Support non-interactive mode via environment variable
if [ "$DEPLOY_JDBC_SINK" = "yes" ]; then
  REPLY="y"
elif [ "$DEPLOY_JDBC_SINK" = "no" ] || [ ! -t 0 ]; then
  # Non-interactive mode (piped input or explicit no) - skip JDBC sink
  log_info "Skipping JDBC Sink connector (non-interactive mode or DEPLOY_JDBC_SINK=no)"
  REPLY="n"
else
  read -p "Deploy JDBC Sink connector now? (y/N) " -n 1 -r
  echo ""
fi

if [[ $REPLY =~ ^[Yy]$ ]]; then
  log_info "Deploying JDBC Sink Orders connector..."
  deploy_connector "$SCRIPT_DIR/jdbc-sink-orders.json"

  echo ""
  log_info "Waiting for JDBC Sink connector to start..."
  sleep 5
  check_status "jdbc-sink-orders"
fi

echo ""
log_info "All connectors:"
curl -s "$CONNECT_URL/connectors" | jq .

echo ""
echo "=============================================="
echo "  Deployment Complete"
echo "=============================================="
echo ""
