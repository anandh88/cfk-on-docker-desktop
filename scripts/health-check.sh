#!/bin/bash
#
# Quick health check script for Confluent Platform on Kubernetes
# Provides a fast, at-a-glance view of all component status
#

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Status icons
OK="${GREEN}●${NC}"
WARN="${YELLOW}●${NC}"
FAIL="${RED}●${NC}"
UNKNOWN="${BLUE}○${NC}"

print_header() {
  echo ""
  echo -e "${BOLD}${CYAN}$1${NC}"
  echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"
}

get_pod_status() {
  local label=$1
  local namespace=${2:-confluent}
  local expected=${3:-1}

  local running=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  local total=$(kubectl get pods -n "$namespace" -l "$label" --no-headers 2>/dev/null | wc -l | tr -d ' ')

  if [ "$running" -eq "$expected" ] && [ "$running" -eq "$total" ]; then
    echo -e "${OK} ${running}/${expected}"
  elif [ "$running" -gt 0 ]; then
    echo -e "${WARN} ${running}/${expected}"
  else
    echo -e "${FAIL} ${running}/${expected}"
  fi
}

get_pod_status_by_name() {
  local name=$1
  local namespace=${2:-confluent}

  local status=$(kubectl get pod -n "$namespace" "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

  if [ "$status" = "Running" ]; then
    echo -e "${OK} Running"
  elif [ "$status" = "Pending" ]; then
    echo -e "${WARN} Pending"
  elif [ "$status" = "NotFound" ]; then
    echo -e "${FAIL} Not Found"
  else
    echo -e "${FAIL} $status"
  fi
}

get_deployment_status() {
  local name=$1
  local namespace=${2:-confluent}

  local ready=$(kubectl get deployment -n "$namespace" "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  local desired=$(kubectl get deployment -n "$namespace" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")

  if [ "$ready" = "$desired" ] && [ "$ready" != "0" ]; then
    echo -e "${OK} ${ready}/${desired}"
  elif [ "$ready" -gt 0 ] 2>/dev/null; then
    echo -e "${WARN} ${ready}/${desired}"
  else
    echo -e "${FAIL} ${ready:-0}/${desired}"
  fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Confluent Platform Health Check                  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo -e "  ${BLUE}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

# ============================================================================
# CONFLUENT PLATFORM
# ============================================================================
print_header "Confluent Platform"

printf "  %-25s %s\n" "CFK Operator:" "$(get_pod_status 'app=confluent-operator' 'confluent' 1)"
printf "  %-25s %s\n" "KRaft Controllers:" "$(get_pod_status 'app=kraftcontroller' 'confluent' 3)"
printf "  %-25s %s\n" "Kafka Brokers:" "$(get_pod_status 'app=kafka' 'confluent' 3)"
printf "  %-25s %s\n" "Schema Registry:" "$(get_pod_status 'app=schemaregistry' 'confluent' 1)"
printf "  %-25s %s\n" "Kafka Connect:" "$(get_pod_status 'app=connect' 'confluent' 1)"
printf "  %-25s %s\n" "REST Proxy:" "$(get_pod_status 'app=kafkarestproxy' 'confluent' 1)"
printf "  %-25s %s\n" "Control Center:" "$(get_pod_status 'app=controlcenter' 'confluent' 1)"

# ============================================================================
# MONITORING
# ============================================================================
if kubectl get namespace monitoring > /dev/null 2>&1; then
  print_header "Monitoring Stack"

  # Prometheus
  prom_running=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$prom_running" -gt 0 ]; then
    printf "  %-25s ${OK} Running\n" "Prometheus:"
  else
    printf "  %-25s ${FAIL} Not Running\n" "Prometheus:"
  fi

  # Grafana
  graf_running=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$graf_running" -gt 0 ]; then
    printf "  %-25s ${OK} Running\n" "Grafana:"
  else
    printf "  %-25s ${FAIL} Not Running\n" "Grafana:"
  fi

  # Alertmanager
  alert_running=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$alert_running" -gt 0 ]; then
    printf "  %-25s ${OK} Running\n" "Alertmanager:"
  else
    printf "  %-25s ${WARN} Not Running\n" "Alertmanager:"
  fi
fi

# ============================================================================
# CONNECTORS (if Connect is running)
# ============================================================================
if kubectl get pod -n confluent connect-0 > /dev/null 2>&1; then
  connect_ready=$(kubectl get pod -n confluent connect-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$connect_ready" = "True" ]; then
    print_header "Kafka Connectors"

    connectors=$(kubectl exec -n confluent connect-0 -- curl -s http://localhost:8083/connectors 2>/dev/null)
    if [ -n "$connectors" ] && [ "$connectors" != "[]" ]; then
      # Parse connector names and get their status
      echo "$connectors" | tr -d '[]"' | tr ',' '\n' | while read -r connector; do
        if [ -n "$connector" ]; then
          status=$(kubectl exec -n confluent connect-0 -- curl -s "http://localhost:8083/connectors/$connector/status" 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
          if [ "$status" = "RUNNING" ]; then
            printf "  %-25s ${OK} %s\n" "$connector:" "$status"
          elif [ "$status" = "PAUSED" ]; then
            printf "  %-25s ${WARN} %s\n" "$connector:" "$status"
          else
            printf "  %-25s ${FAIL} %s\n" "$connector:" "${status:-UNKNOWN}"
          fi
        fi
      done
    else
      echo -e "  ${BLUE}No connectors deployed${NC}"
    fi
  fi
fi

# ============================================================================
# RESOURCE USAGE
# ============================================================================
print_header "Resource Summary"

# Pod counts
confluent_pods=$(kubectl get pods -n confluent --no-headers 2>/dev/null | grep -c "Running" || echo "0")
confluent_total=$(kubectl get pods -n confluent --no-headers 2>/dev/null | wc -l | tr -d ' ')
monitoring_pods=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | grep -c "Running" || echo "0")
monitoring_total=$(kubectl get pods -n monitoring --no-headers 2>/dev/null | wc -l | tr -d ' ')

printf "  %-25s %s/%s pods running\n" "Confluent namespace:" "$confluent_pods" "$confluent_total"
printf "  %-25s %s/%s pods running\n" "Monitoring namespace:" "$monitoring_pods" "$monitoring_total"

# ============================================================================
# QUICK ACCESS
# ============================================================================
print_header "Quick Access (port-forward)"

echo -e "  ${BLUE}Control Center:${NC}  kubectl port-forward svc/controlcenter -n confluent 9021:9021"
echo -e "  ${BLUE}Grafana:${NC}         kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo -e "  ${BLUE}Prometheus:${NC}      kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090"

# ============================================================================
# LEGEND
# ============================================================================
echo ""
echo -e "  ${OK} Healthy  ${WARN} Warning  ${FAIL} Failed  ${UNKNOWN} Unknown"
echo ""
