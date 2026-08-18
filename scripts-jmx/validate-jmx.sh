#!/bin/bash
set -euo pipefail

DATADOG_NAMESPACE="${DATADOG_NAMESPACE:-datadog-agent}"
CONFLUENT_NAMESPACE="${CONFLUENT_NAMESPACE:-confluent}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed or not in PATH"
}

check_namespace() {
  local ns="$1"
  kubectl get namespace "$ns" >/dev/null 2>&1 || fail "Namespace not found: $ns"
}

print_header() {
  echo ""
  echo "=================================================="
  echo "  Datadog Confluent JMX Validation"
  echo "=================================================="
}

get_datadog_pod() {
  kubectl get pod -n "$DATADOG_NAMESPACE" -l app=datadog,agent.datadoghq.com/component=agent -o jsonpath='{.items[0].metadata.name}'
}

main() {
  require_cmd kubectl

  print_header

  info "Checking namespaces"
  check_namespace "$CONFLUENT_NAMESPACE"
  check_namespace "$DATADOG_NAMESPACE"
  pass "Namespaces are present"

  info "Checking Confluent pods"
  if kubectl get pods -n "$CONFLUENT_NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | grep -q '^Running$'; then
    pass "Confluent has running pods"
  else
    fail "No running pods found in namespace $CONFLUENT_NAMESPACE"
  fi

  info "Checking Datadog agent pods"
  if kubectl get pods -n "$DATADOG_NAMESPACE" --no-headers 2>/dev/null | awk '{print $3}' | grep -q '^Running$'; then
    pass "Datadog has running pods"
  else
    fail "No running Datadog pods found in namespace $DATADOG_NAMESPACE"
  fi

  local dd_pod
  dd_pod="$(get_datadog_pod)"
  [ -n "$dd_pod" ] || fail "Could not resolve a Datadog agent pod"
  info "Using Datadog pod: $dd_pod"

  info "Checking JMXFetch status"
  local status_out
  status_out="$(kubectl exec -n "$DATADOG_NAMESPACE" "$dd_pod" -- agent status 2>/dev/null || true)"

  if echo "$status_out" | grep -q "JMXFetch"; then
    pass "JMXFetch section found"
  else
    fail "JMXFetch section not found in agent status"
  fi

  if echo "$status_out" | grep -q "confluent_platform"; then
    pass "confluent_platform check initialized"
  else
    warn "confluent_platform check not found in initialized checks"
  fi

  info "Summarizing confluent_platform instances"
  echo "$status_out" | awk '/confluent_platform/{flag=1} flag{print} /========/{if(flag){exit}}' || true

  info "Checking recent Datadog agent logs for confluent_platform"
  kubectl logs -n "$DATADOG_NAMESPACE" "$dd_pod" --tail=200 | grep -i "confluent_platform\|jmx" || warn "No recent confluent_platform/jmx log lines found"

  echo ""
  info "Validation complete"
  info "If any instance is not OK, verify JMX reachability on port 7203 from the Datadog pod."
}

main "$@"
