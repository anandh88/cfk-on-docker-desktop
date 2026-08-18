#!/bin/bash
#
# Validation script for Confluent Platform on Kubernetes
# Verifies all components are healthy after deployment
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Print functions
print_header() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_check() {
  echo -ne "  Checking $1... "
}

print_pass() {
  echo -e "${GREEN}✓ PASS${NC} $1"
  PASSED=$((PASSED + 1))
}

print_fail() {
  echo -e "${RED}✗ FAIL${NC} $1"
  FAILED=$((FAILED + 1))
}

print_warn() {
  echo -e "${YELLOW}⚠ WARN${NC} $1"
  WARNINGS=$((WARNINGS + 1))
}

print_info() {
  echo -e "  ${BLUE}ℹ${NC} $1"
}

# Check if a pod is running
check_pod_running() {
  local label=$1
  local namespace=${2:-confluent}
  local expected=${3:-1}

  local running=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || echo "0")

  if [ "$running" -ge "$expected" ]; then
    return 0
  else
    return 1
  fi
}

# Check if a service endpoint is responding
check_endpoint() {
  local pod=$1
  local namespace=$2
  local url=$3
  local timeout=${4:-5}

  kubectl exec -n "$namespace" "$pod" -- curl -s --max-time "$timeout" "$url" > /dev/null 2>&1
  return $?
}

# Get pod count
get_pod_count() {
  local label=$1
  local namespace=${2:-confluent}

  kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || echo "0"
}

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Confluent Platform Validation Script                      ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"

# ============================================================================
# KUBERNETES CLUSTER
# ============================================================================
print_header "Kubernetes Cluster"

print_check "cluster connectivity"
if kubectl cluster-info > /dev/null 2>&1; then
  print_pass ""
else
  print_fail "Cannot connect to Kubernetes cluster"
  exit 1
fi

print_check "confluent namespace"
if kubectl get namespace confluent > /dev/null 2>&1; then
  print_pass ""
else
  print_fail "Namespace 'confluent' does not exist"
  exit 1
fi

print_check "monitoring namespace"
if kubectl get namespace monitoring > /dev/null 2>&1; then
  print_pass ""
else
  print_warn "Namespace 'monitoring' does not exist (monitoring not deployed?)"
fi

# ============================================================================
# CFK OPERATOR
# ============================================================================
print_header "CFK Operator"

print_check "operator pod"
if check_pod_running "app=confluent-operator" "confluent"; then
  print_pass ""
else
  print_fail "CFK operator is not running"
fi

# ============================================================================
# KRAFT CONTROLLERS
# ============================================================================
print_header "KRaft Controllers"

print_check "controller pods (expected: 3)"
controller_count=$(get_pod_count "app=kraftcontroller" "confluent")
if [ "$controller_count" -eq 3 ]; then
  print_pass "($controller_count/3 running)"
elif [ "$controller_count" -gt 0 ]; then
  print_warn "Only $controller_count/3 controllers running"
else
  print_fail "No controllers running"
fi

# ============================================================================
# KAFKA BROKERS
# ============================================================================
print_header "Kafka Brokers"

print_check "broker pods (expected: 3)"
broker_count=$(get_pod_count "app=kafka" "confluent")
if [ "$broker_count" -eq 3 ]; then
  print_pass "($broker_count/3 running)"
elif [ "$broker_count" -gt 0 ]; then
  print_warn "Only $broker_count/3 brokers running"
else
  print_fail "No brokers running"
fi

if [ "$broker_count" -gt 0 ]; then
  print_check "broker metrics endpoint"
  if check_endpoint "kafka-0" "confluent" "http://localhost:7778/metrics"; then
    print_pass ""
  else
    print_warn "Metrics endpoint not responding"
  fi

  print_check "kafka cluster ID"
  cluster_id=$(kubectl exec -n confluent kafka-0 -- kafka-cluster cluster-id --bootstrap-server kafka:9092 2>/dev/null | grep -o 'Cluster ID: .*' || echo "")
  if [ -n "$cluster_id" ]; then
    print_pass ""
    print_info "$cluster_id"
  else
    print_warn "Could not retrieve cluster ID"
  fi
fi

# ============================================================================
# SCHEMA REGISTRY
# ============================================================================
print_header "Schema Registry"

print_check "schema registry pod"
if check_pod_running "app=schemaregistry" "confluent"; then
  print_pass ""

  print_check "schema registry API"
  if check_endpoint "schemaregistry-0" "confluent" "http://localhost:8081/subjects"; then
    print_pass ""
  else
    print_warn "API not responding"
  fi
else
  print_fail "Schema Registry is not running"
fi

# ============================================================================
# KAFKA CONNECT
# ============================================================================
print_header "Kafka Connect"

print_check "connect pod"
if check_pod_running "app=connect" "confluent"; then
  print_pass ""

  print_check "connect REST API"
  if check_endpoint "connect-0" "confluent" "http://localhost:8083/connectors" 10; then
    print_pass ""

    # Check connector count
    connector_count=$(kubectl exec -n confluent connect-0 -- curl -s http://localhost:8083/connectors 2>/dev/null | grep -o '"[^"]*"' | wc -l | tr -d ' ')
    print_info "Connectors deployed: $connector_count"
  else
    print_warn "REST API not responding (may still be starting)"
  fi

  print_check "connect metrics endpoint"
  if check_endpoint "connect-0" "confluent" "http://localhost:7778/metrics" 10; then
    print_pass ""
  else
    print_warn "Metrics endpoint not responding"
  fi
else
  print_fail "Kafka Connect is not running"
fi

# ============================================================================
# KSQLDB
# ============================================================================
print_header "ksqlDB"
print_warn "ksqlDB is intentionally not deployed (skipped)"

# ============================================================================
# REST PROXY
# ============================================================================
print_header "REST Proxy"

print_check "rest proxy pod"
if check_pod_running "app=kafkarestproxy" "confluent"; then
  print_pass ""

  print_check "rest proxy API"
  if check_endpoint "kafkarestproxy-0" "confluent" "http://localhost:8082/v3/clusters"; then
    print_pass ""
  else
    print_warn "API not responding"
  fi
else
  print_fail "REST Proxy is not running"
fi

# ============================================================================
# CONTROL CENTER
# ============================================================================
print_header "Control Center"

print_check "control center pod"
if check_pod_running "app=controlcenter" "confluent"; then
  print_pass ""

  print_check "control center UI"
  if check_endpoint "controlcenter-0" "confluent" "http://localhost:9021" 10; then
    print_pass ""
  else
    print_warn "UI not responding (may still be starting)"
  fi
else
  print_fail "Control Center is not running"
fi

# ============================================================================
# MONITORING STACK
# ============================================================================
print_header "Monitoring Stack"

if kubectl get namespace monitoring > /dev/null 2>&1; then
  print_check "prometheus pod"
  if kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -q "Running"; then
    print_pass ""
  else
    print_fail "Prometheus is not running"
  fi

  print_check "grafana pod"
  if kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -q "Running"; then
    print_pass ""
  else
    print_fail "Grafana is not running"
  fi

  print_check "alertmanager pod"
  if kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -q "Running"; then
    print_pass ""
  else
    print_warn "Alertmanager is not running"
  fi
else
  print_info "Monitoring namespace not found - skipping monitoring checks"
fi

# ============================================================================
# SUMMARY
# ============================================================================
print_header "Validation Summary"

echo ""
echo -e "  ${GREEN}Passed:${NC}   $PASSED"
echo -e "  ${RED}Failed:${NC}   $FAILED"
echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
echo ""

if [ $FAILED -eq 0 ]; then
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  ✓ All critical checks passed!                               ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
  exit 0
else
  echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ✗ Some checks failed. Review the output above.              ║${NC}"
  echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
  exit 1
fi
