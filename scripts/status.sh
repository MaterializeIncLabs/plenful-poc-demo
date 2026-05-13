#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# ANSI color helpers
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

go()   { echo -e "  ${GREEN}[GO]${RESET}    $1"; }
nogo() { echo -e "  ${RED}[NO-GO]${RESET} $1"; }
info() { echo -e "  ${YELLOW}[INFO]${RESET}  $1"; }

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "ERROR: .env not found at $REPO_ROOT/.env"
  exit 1
fi
set -a; source "$REPO_ROOT/.env"; set +a

# Resolve endpoints
RDS_ENDPOINT="${AURORA_HOST:-${DB_HOST:-}}"
if [[ -z "$RDS_ENDPOINT" ]]; then
  if command -v terraform &>/dev/null && [[ -d "$REPO_ROOT/terraform" ]]; then
    RDS_ENDPOINT=$(cd "$REPO_ROOT/terraform" && terraform output -raw rds_endpoint 2>/dev/null || true)
  fi
fi

APP_IP="${APP_PUBLIC_IP:-}"
if [[ -z "$APP_IP" ]]; then
  if command -v terraform &>/dev/null && [[ -d "$REPO_ROOT/terraform" ]]; then
    APP_IP=$(cd "$REPO_ROOT/terraform" && terraform output -raw app_public_ip 2>/dev/null || true)
  fi
fi

DB_USER="${AURORA_USER:-${DB_USER:-postgres}}"
DB_PASS="${AURORA_PASSWORD:-${DB_PASS:-}}"
DB_NAME="${AURORA_DB:-${DB_NAME:-plenful}}"

MZ_HOST="${MZ_HOST:-}"
MZ_PORT="${MZ_PORT:-6875}"
MZ_USER="${MZ_USER:-}"
MZ_PASSWORD="${MZ_PASSWORD:-}"
MZ_DB="${MZ_DB:-materialize}"

OVERALL_OK=true

echo ""
echo -e "${BOLD}=== Plenful POC Status Check ===${RESET}"
echo ""

# ---------------------------------------------------------------------------
# 1. RDS connectivity
# ---------------------------------------------------------------------------
echo -e "${BOLD}1. Aurora RDS connectivity${RESET}"
if [[ -z "$RDS_ENDPOINT" ]]; then
  nogo "RDS_ENDPOINT not set — cannot check"
  OVERALL_OK=false
else
  if PGPASSWORD="$DB_PASS" psql \
      -h "$RDS_ENDPOINT" -U "$DB_USER" -d "$DB_NAME" \
      -c "SELECT 1" &>/dev/null 2>&1; then
    go "Connected to $RDS_ENDPOINT"
  else
    nogo "Cannot connect to $RDS_ENDPOINT (host=$RDS_ENDPOINT user=$DB_USER db=$DB_NAME)"
    OVERALL_OK=false
  fi
fi

# ---------------------------------------------------------------------------
# 2. Seed data check — row count on claims
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}2. Seed data present (claims row count)${RESET}"
if [[ -z "$RDS_ENDPOINT" ]]; then
  nogo "Skipped — RDS endpoint unknown"
  OVERALL_OK=false
else
  CLAIM_COUNT=$(PGPASSWORD="$DB_PASS" psql \
    -h "$RDS_ENDPOINT" -U "$DB_USER" -d "$DB_NAME" \
    -t -A -c "SELECT COUNT(*) FROM claims;" 2>/dev/null || echo "0")
  CLAIM_COUNT=$(echo "$CLAIM_COUNT" | tr -d '[:space:]')
  if [[ "$CLAIM_COUNT" =~ ^[0-9]+$ ]] && [[ "$CLAIM_COUNT" -ge 100000 ]]; then
    go "claims table has $CLAIM_COUNT rows (seed data present)"
  elif [[ "$CLAIM_COUNT" =~ ^[0-9]+$ ]] && [[ "$CLAIM_COUNT" -gt 0 ]]; then
    info "claims table has $CLAIM_COUNT rows (below expected ~500,000 — seed may be incomplete)"
  else
    nogo "claims table is empty or inaccessible ($CLAIM_COUNT) — run scripts/seed.sh"
    OVERALL_OK=false
  fi
fi

# ---------------------------------------------------------------------------
# 3. Materialize connectivity
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}3. Materialize connectivity (port $MZ_PORT)${RESET}"
if [[ -z "$MZ_HOST" ]]; then
  nogo "MZ_HOST not set — cannot check"
  OVERALL_OK=false
else
  MZ_PSQL_OPTS="-h $MZ_HOST -p $MZ_PORT -U $MZ_USER -d $MZ_DB"
  if PGPASSWORD="$MZ_PASSWORD" psql $MZ_PSQL_OPTS \
      -c "SELECT 1" &>/dev/null 2>&1; then
    go "Connected to $MZ_HOST:$MZ_PORT"
  else
    nogo "Cannot connect to Materialize at $MZ_HOST:$MZ_PORT"
    OVERALL_OK=false
  fi
fi

# ---------------------------------------------------------------------------
# 4. mv_insurance_recon row count
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}4. Materialize view — mv_insurance_recon${RESET}"
if [[ -z "$MZ_HOST" ]]; then
  nogo "Skipped — MZ_HOST not set"
  OVERALL_OK=false
else
  MZ_PSQL_OPTS="-h $MZ_HOST -p $MZ_PORT -U $MZ_USER -d $MZ_DB"
  MV_COUNT=$(PGPASSWORD="$MZ_PASSWORD" psql $MZ_PSQL_OPTS \
    -t -A -c "SELECT COUNT(*) FROM mv_insurance_recon;" 2>/dev/null || echo "ERR")
  MV_COUNT=$(echo "$MV_COUNT" | tr -d '[:space:]')
  if [[ "$MV_COUNT" =~ ^[0-9]+$ ]] && [[ "$MV_COUNT" -gt 0 ]]; then
    go "mv_insurance_recon has $MV_COUNT rows"
  elif [[ "$MV_COUNT" == "0" ]]; then
    info "mv_insurance_recon has 0 rows — view may still be backfilling"
  else
    nogo "mv_insurance_recon not accessible ($MV_COUNT) — check Materialize source status"
    OVERALL_OK=false
  fi
fi

# ---------------------------------------------------------------------------
# 5. App server HTTP check
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}5. App server HTTP /metrics${RESET}"
if [[ -z "$APP_IP" ]]; then
  nogo "APP_IP not set — cannot check"
  OVERALL_OK=false
else
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 5 --max-time 10 \
    "http://${APP_IP}/metrics" 2>/dev/null || echo "000")
  if [[ "$HTTP_STATUS" == "200" ]]; then
    go "http://$APP_IP/metrics returned HTTP 200"
  elif [[ "$HTTP_STATUS" == "000" ]]; then
    nogo "http://$APP_IP/metrics — connection refused or timed out"
    OVERALL_OK=false
  else
    nogo "http://$APP_IP/metrics returned HTTP $HTTP_STATUS"
    OVERALL_OK=false
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "-------------------------------"
if [[ "$OVERALL_OK" == "true" ]]; then
  echo -e "${GREEN}${BOLD}  All checks passed — demo is GO${RESET}"
else
  echo -e "${RED}${BOLD}  One or more checks failed — demo is NO-GO${RESET}"
fi
echo ""
