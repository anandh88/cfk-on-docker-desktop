#!/bin/bash
set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# -------------------- Config (env overridable) --------------------
NAMESPACE="${NAMESPACE:-confluent}"
SC_DEFAULT_NAME="${SC_DEFAULT_NAME:-gp2}"   # set to gp3 if your cluster has gp3
AUTO_CLEANUP="${AUTO_CLEANUP:-false}"       # true = auto cleanup before install
NON_INTERACTIVE="${NON_INTERACTIVE:-true}"  # true = don't prompt
KUBECTL_WAIT_TIMEOUT="${KUBECTL_WAIT_TIMEOUT:-600}" # seconds
DEPLOY_JDBC_SINK="${DEPLOY_JDBC_SINK:-true}"        # true = run MySQL setup + deploy JDBC sink
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_ROOT_USER="${MYSQL_ROOT_USER:-root}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
MYSQL_SERVICE_NAME="${MYSQL_SERVICE_NAME:-mysql}"
MYSQL_CONTAINER_NAME="${MYSQL_CONTAINER_NAME:-mysql}"
MYSQL_SETUP_SQL="${MYSQL_SETUP_SQL:-$PROJECT_DIR/connectors/mysql-db-scripts/orders-table.sql}"
DEPLOY_DATADOG="${DEPLOY_DATADOG:-true}"
DD_SITE="${DD_SITE:-us5.datadoghq.com}"
DD_API_KEY="${DD_API_KEY:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

die() { log_error "$1"; exit 1; }

prompt_for_datadog_api_key() {
  if [ "$DEPLOY_DATADOG" != "true" ]; then
    return 0
  fi

  if [ -n "$DD_API_KEY" ]; then
    export DD_API_KEY
    return 0
  fi

  if [ -t 0 ]; then
    echo ""
    log_info "=== Datadog Agent Setup ==="
    echo "Enter your Datadog API key to install the agent, or press Enter to skip Datadog."
    read -rsp "DD_API_KEY (hidden, Enter to skip): " DD_API_KEY
    echo ""
    export DD_API_KEY
  fi
}

wait_for_datadog_agent() {
  if [ "$DEPLOY_DATADOG" != "true" ] || [ -z "$DD_API_KEY" ]; then
    log_warn "Datadog agent install was skipped or no API key was provided."
    return 0
  fi

  if ! kubectl get namespace datadog-agent &>/dev/null; then
    die "Datadog namespace 'datadog-agent' was not created"
  fi

  log_info "Waiting for Datadog Agent pod(s) to become ready..."
  if ! kubectl wait --for=condition=ready pod --all -n datadog-agent --timeout=300s; then
    log_error "Datadog Agent pods did not become ready"
    kubectl get pods -n datadog-agent -o wide || true
    die "Datadog Agent installation incomplete"
  fi

  log_info "Datadog Agent is ready"
}

# -------------------- Helpers --------------------
require_cmd() {
  command -v "$1" &>/dev/null || die "$1 is not installed or not in PATH"
}

kube_ok() {
  kubectl cluster-info &>/dev/null
}

# Wait for pods by selector. If it fails, print useful diagnostics.
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

  log_info "Waiting for pods to be ready (timeout=${timeout}s)..."
  if ! kubectl wait --for=condition=ready pod -l "$selector" -n "$ns" --timeout="${timeout}s"; then
    log_error "Timeout waiting for pods to be ready: selector='$selector' ns='$ns'"
    kubectl get pods -n "$ns" -l "$selector" -o wide || true
    kubectl get pvc -n "$ns" -o wide || true
    log_warn "Describe pending pods (if any):"
    for p in $(kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | awk '$3=="Pending"{print $1}'); do
      echo "---- describe pod/$p ----"
      kubectl describe pod "$p" -n "$ns" | tail -n 120 || true
    done
    die "Pods not ready for selector '$selector'"
  fi
}

ensure_kafka_topic() {
  local topic_name="$1"
  local partitions="${2:-1}"
  local replication_factor="${3:-1}"
  local ns="${4:-$NAMESPACE}"
  local kafka_pod="${5:-kafka-0}"
  local bootstrap="${6:-kafka:9071}"

  log_info "Ensuring Kafka topic '$topic_name' exists (partitions=$partitions, rf=$replication_factor)..."
  kubectl exec -n "$ns" "$kafka_pod" -- \
    kafka-topics --bootstrap-server "$bootstrap" --create --if-not-exists \
    --topic "$topic_name" --partitions "$partitions" --replication-factor "$replication_factor"

  kubectl exec -n "$ns" "$kafka_pod" -- \
    kafka-topics --bootstrap-server "$bootstrap" --describe --topic "$topic_name" >/dev/null
  log_info "Topic '$topic_name' is ready"
}

setup_mysql_for_jdbc_sink() {
  if [ "$DEPLOY_JDBC_SINK" != "true" ]; then
    log_info "Skipping MySQL setup and JDBC Sink deployment (DEPLOY_JDBC_SINK=false)"
    return 0
  fi

  require_cmd mysql

  if [ ! -f "$MYSQL_SETUP_SQL" ]; then
    die "MySQL setup SQL file not found: $MYSQL_SETUP_SQL"
  fi

  local mysql_root_cmd=(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_ROOT_USER")
  if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
    mysql_root_cmd+=("-p$MYSQL_ROOT_PASSWORD")
  fi

  ensure_local_mysql_running "${mysql_root_cmd[@]}"

  log_info "Validating MySQL root connectivity on ${MYSQL_HOST}:${MYSQL_PORT}..."
  if ! "${mysql_root_cmd[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    die "Cannot connect to MySQL as '$MYSQL_ROOT_USER' on ${MYSQL_HOST}:${MYSQL_PORT}. Set MYSQL_ROOT_USER/MYSQL_ROOT_PASSWORD and re-run."
  fi

  log_info "Applying MySQL bootstrap SQL: $MYSQL_SETUP_SQL"
  "${mysql_root_cmd[@]}" < "$MYSQL_SETUP_SQL"

  log_info "Validating JDBC sink user access (admin/admin)..."
  if ! mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u admin -padmin -e "SELECT COUNT(*) FROM Orders.orders;" >/dev/null 2>&1; then
    die "MySQL bootstrap completed but admin/admin validation failed. Verify MySQL auth settings."
  fi

  log_info "MySQL setup for JDBC Sink is ready"
}

# Symmetric counterpart to destroy.sh's teardown_local_mysql(): if the local
# MySQL used for the JDBC sink was stopped by a previous teardown, start it
# back up so setup.sh can run unattended on a fresh relaunch.
ensure_local_mysql_running() {
  local mysql_root_cmd=("$@")

  if "${mysql_root_cmd[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
    return 0
  fi

  log_warn "MySQL not reachable on ${MYSQL_HOST}:${MYSQL_PORT} yet, attempting to start it..."

  if command -v brew &>/dev/null && brew services list 2>/dev/null | awk '{print $1}' | grep -qx "$MYSQL_SERVICE_NAME"; then
    log_info "Starting Homebrew MySQL service: $MYSQL_SERVICE_NAME"
    brew services start "$MYSQL_SERVICE_NAME" >/dev/null 2>&1 || true
  elif command -v docker &>/dev/null && docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$MYSQL_CONTAINER_NAME"; then
    log_info "Starting Docker MySQL container: $MYSQL_CONTAINER_NAME"
    docker start "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || true
  else
    log_warn "No known local MySQL service/container found to start automatically."
    return 0
  fi

  log_info "Waiting for MySQL to accept connections..."
  local count=0
  while [ $count -lt 30 ]; do
    if "${mysql_root_cmd[@]}" -e "SELECT 1;" >/dev/null 2>&1; then
      log_info "MySQL is up"
      return 0
    fi
    sleep 2
    count=$((count + 1))
  done

  log_warn "MySQL still not reachable after waiting; the connectivity check below will report the final status."
}

ensure_namespace() {
  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_info "Namespace '$NAMESPACE' already exists"
  else
    log_info "Creating namespace '$NAMESPACE'"
    kubectl create namespace "$NAMESPACE"
  fi
}

# Ensure there is a default StorageClass. If not, try to set SC_DEFAULT_NAME as default.
ensure_default_storageclass() {
  log_info "Checking StorageClass (EKS PVCs require a default StorageClass)..."
  kubectl get storageclass || die "No StorageClass found in cluster. Install EBS CSI + create a StorageClass."

  local has_default
  has_default=$(kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}' 2>/dev/null | grep -c true || true)

  if [ "${has_default:-0}" -gt 0 ]; then
    log_info "Default StorageClass already configured"
    return 0
  fi

  log_warn "No default StorageClass found. Attempting to set '$SC_DEFAULT_NAME' as default..."
  if kubectl get storageclass "$SC_DEFAULT_NAME" &>/dev/null; then
    kubectl annotate storageclass "$SC_DEFAULT_NAME" storageclass.kubernetes.io/is-default-class=true --overwrite
    log_info "StorageClass '$SC_DEFAULT_NAME' set as default"
  else
    log_error "StorageClass '$SC_DEFAULT_NAME' not found."
    kubectl get storageclass
    die "Set SC_DEFAULT_NAME to an existing StorageClass (e.g., gp2/gp3) and re-run."
  fi
}

# Cleanup existing install (optional)
cleanup_confluent() {
  log_warn "AUTO_CLEANUP=true -> cleaning existing CFK resources in namespace '$NAMESPACE'"

  # Delete CRs (ignore if not present)
  kubectl delete controlcenter --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete kafkarestproxy --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete ksqldb --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete connect --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete schemaregistry --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete kafka --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete kraftcontroller --all -n "$NAMESPACE" --ignore-not-found || true

  # Delete pods + pvc
  kubectl delete pod --all -n "$NAMESPACE" --ignore-not-found || true
  kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found || true

  # Remove stuck PVC finalizers if any (best-effort)
  for pvc in $(kubectl get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$2=="Terminating"{print $1}'); do
    log_warn "Removing finalizers from stuck PVC: $pvc"
    kubectl patch pvc "$pvc" -n "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge || true
  done
}

# Warn if namespace already has pods (interactive vs non-interactive)
guard_existing_namespace() {
  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    local existing_pods
    existing_pods=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${existing_pods:-0}" -gt 0 ]; then
      log_warn "Namespace '$NAMESPACE' already has $existing_pods pod(s)."

      if [ "$AUTO_CLEANUP" = "true" ]; then
        cleanup_confluent
        return 0
      fi

      if [ "$NON_INTERACTIVE" = "true" ]; then
        die "Existing pods found. Set AUTO_CLEANUP=true or run scripts/destroy.sh before re-running."
      else
        log_warn "Run 'scripts/destroy.sh' first to clean up existing installation"
        read -p "Do you want to continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          exit 1
        fi
      fi
    fi
  fi
}

# -------------------- Pre-flight checks --------------------
log_info "Running pre-flight checks..."
require_cmd kubectl
require_cmd helm

kube_ok || die "Cannot connect to Kubernetes cluster (kubectl cluster-info failed). Check kubeconfig/IAM."

prompt_for_datadog_api_key

ensure_default_storageclass
ensure_namespace
guard_existing_namespace

echo ""
echo "=============================================="
echo "  Confluent Platform Setup"
echo "=============================================="
echo ""

# -------------------- Install CFK Operator --------------------
log_info "=== Installing Confluent for Kubernetes Operator ==="
helm repo add confluentinc https://packages.confluent.io/helm >/dev/null 2>&1 || true
helm repo update

# If you have a namespace.yaml, keep using it; otherwise ensure_namespace already handled it.
if [ -f "namespace.yaml" ]; then
  kubectl apply -f namespace.yaml
fi

helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --namespace "$NAMESPACE" \
  --set namespaced=false \
  --wait

log_info "Waiting for CFK operator to be ready..."
kubectl wait --for=condition=ready pod -l app=confluent-operator -n "$NAMESPACE" --timeout=300s

echo ""
log_info "=== Deploying Confluent Platform Components ==="

# -------------------- Deploy Components --------------------
log_info "Deploying KRaft Controller..."
kubectl apply -f kraftcontroller.yaml
wait_for_pods "platform.confluent.io/type=kraftcontroller" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

log_info "Deploying Kafka brokers..."
kubectl apply -f kafka.yaml
wait_for_pods "platform.confluent.io/type=kafka" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

log_info "Deploying Schema Registry..."
kubectl apply -f schemaregistry.yaml
wait_for_pods "platform.confluent.io/type=schemaregistry" 300 "$NAMESPACE"

log_info "Deploying Connect..."
kubectl apply -f connect.yaml
wait_for_pods "platform.confluent.io/type=connect" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

log_info "Deploying Kafka REST Proxy..."
kubectl apply -f kafkarestproxy.yaml
wait_for_pods "platform.confluent.io/type=kafkarestproxy" 300 "$NAMESPACE"

log_info "Deploying Control Center..."
kubectl apply -f controlcenter.yaml
wait_for_pods "platform.confluent.io/type=controlcenter" "$KUBECTL_WAIT_TIMEOUT" "$NAMESPACE"

echo ""
log_info "=== Verifying Confluent Platform Components ==="
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
log_info "=== Preparing Kafka Topics ==="
ensure_kafka_topic "Orders" 1 1 "$NAMESPACE"

echo ""
log_info "=== Deploying Monitoring Stack ==="
if [ -x "$SCRIPT_DIR/deploy-monitoring.sh" ]; then
  "$SCRIPT_DIR/deploy-monitoring.sh"
else
  log_warn "deploy-monitoring.sh not found or not executable. Skipping."
fi

wait_for_datadog_agent

echo ""
log_info "=== Deploying Connectors ==="
log_info "Starting port-forward to Connect in background..."
kubectl port-forward svc/connect -n "$NAMESPACE" 8083:8083 >/dev/null 2>&1 &
CONNECT_PF_PID=$!
sleep 5

if kill -0 $CONNECT_PF_PID 2>/dev/null; then
  setup_mysql_for_jdbc_sink

  if [ "$DEPLOY_JDBC_SINK" = "true" ]; then
    DEPLOY_JDBC_SINK=yes "$PROJECT_DIR/connectors/deploy-connectors.sh" || log_warn "Connector deployment had issues"
  else
    DEPLOY_JDBC_SINK=no "$PROJECT_DIR/connectors/deploy-connectors.sh" || log_warn "Connector deployment had issues"
  fi

  kill $CONNECT_PF_PID 2>/dev/null || true
else
  log_warn "Port-forward to Connect failed, skipping connector deployment"
  log_warn "Run manually: kubectl port-forward svc/connect -n $NAMESPACE 8083:8083"
  log_warn "Then: connectors/deploy-connectors.sh"
fi

echo ""
echo "=============================================="
echo "  Setup Complete!"
echo "=============================================="
echo ""
echo "Confluent Platform:"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "Control Center:"
echo "  kubectl port-forward svc/controlcenter -n $NAMESPACE 9021:9021"
echo "  http://localhost:9021"
echo ""

