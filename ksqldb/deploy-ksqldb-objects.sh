#!/bin/bash
#
# Deploy ksqlDB streams and tables
# Creates the example objects in ksqlDB
#

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

KSQLDB_URL="http://localhost:8088"

# Check if port-forward is running
check_port_forward() {
  if ! curl -s "$KSQLDB_URL/info" > /dev/null 2>&1; then
    log_error "Cannot connect to ksqlDB at $KSQLDB_URL"
    log_info "Please run: kubectl port-forward svc/ksqldb -n confluent 8088:8088"
    exit 1
  fi
}

# Execute a ksqlDB statement
execute_ksql() {
  local statement="$1"
  local description="$2"

  log_info "Executing: $description"

  response=$(curl -s -X POST "$KSQLDB_URL/ksql" \
    -H "Content-Type: application/vnd.ksql.v1+json; charset=utf-8" \
    -d "{
      \"ksql\": \"$statement\",
      \"streamsProperties\": {}
    }")

  # Check for errors
  if echo "$response" | grep -q '"@type":"currentStatus"'; then
    echo -e "  ${GREEN}✓${NC} Success"
  elif echo "$response" | grep -q '"@type":"sourceDescription"'; then
    echo -e "  ${GREEN}✓${NC} Success"
  elif echo "$response" | grep -q 'already exists'; then
    echo -e "  ${YELLOW}⚠${NC} Already exists (skipping)"
  elif echo "$response" | grep -q '"@type":"statement_error"'; then
    error_msg=$(echo "$response" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo -e "  ${RED}✗${NC} Error: $error_msg"
  else
    echo -e "  ${BLUE}ℹ${NC} Response: $(echo "$response" | head -c 200)"
  fi
}

# Execute SQL file
execute_sql_file() {
  local file="$1"
  local filename=$(basename "$file")

  echo ""
  log_info "Processing $filename..."
  echo -e "${BLUE}────────────────────────────────────────${NC}"

  # Read file and extract statements (skip comments and empty lines)
  while IFS= read -r line || [ -n "$line" ]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^--.*$ ]] && continue
    [[ -z "${line// }" ]] && continue

    # Accumulate statement until semicolon
    statement="$statement $line"

    # If line ends with semicolon, execute
    if [[ "$line" =~ \;[[:space:]]*$ ]]; then
      # Clean up statement (keep the semicolon for ksqlDB REST API)
      statement=$(echo "$statement" | tr '\n' ' ' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')

      if [ -n "$statement" ]; then
        # Get description (first few words)
        desc=$(echo "$statement" | cut -c1-60)
        execute_ksql "$statement" "$desc..."
      fi
      statement=""
    fi
  done < "$file"
}

echo ""
echo "=============================================="
echo "  ksqlDB Objects Deployment"
echo "=============================================="
echo ""

check_port_forward

# Show ksqlDB server info
log_info "Connected to ksqlDB server:"
curl -s "$KSQLDB_URL/info" | grep -E '"version"|"kafkaClusterId"' | sed 's/^/  /'

# Deploy SQL files in order
for sql_file in "$SCRIPT_DIR"/[0-9]*.sql; do
  if [ -f "$sql_file" ]; then
    execute_sql_file "$sql_file"
  fi
done

echo ""
echo "=============================================="
echo "  Deployment Complete"
echo "=============================================="
echo ""

# Show created objects
log_info "Listing ksqlDB objects..."
echo ""

echo -e "${BLUE}Streams:${NC}"
curl -s -X POST "$KSQLDB_URL/ksql" \
  -H "Content-Type: application/vnd.ksql.v1+json" \
  -d '{"ksql": "SHOW STREAMS;"}' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sed 's/^/  - /'

echo ""
echo -e "${BLUE}Tables:${NC}"
curl -s -X POST "$KSQLDB_URL/ksql" \
  -H "Content-Type: application/vnd.ksql.v1+json" \
  -d '{"ksql": "SHOW TABLES;"}' | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sed 's/^/  - /'

echo ""
log_info "To run interactive queries, use:"
echo "  kubectl exec -it ksqldb-0 -n confluent -- ksql http://localhost:8088"
echo ""
