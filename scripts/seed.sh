#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Load environment
# ---------------------------------------------------------------------------
if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "ERROR: .env not found at $REPO_ROOT/.env"
  exit 1
fi
set -a; source "$REPO_ROOT/.env"; set +a

# RDS endpoint: prefer explicit AURORA_HOST, fall back to DB_HOST
RDS_ENDPOINT="${AURORA_HOST:-${DB_HOST:-}}"
if [[ -z "$RDS_ENDPOINT" ]]; then
  # Try to pull from Terraform output if we're inside the repo
  if command -v terraform &>/dev/null && [[ -d "$REPO_ROOT/terraform" ]]; then
    RDS_ENDPOINT=$(cd "$REPO_ROOT/terraform" && terraform output -raw rds_endpoint 2>/dev/null || true)
  fi
fi
if [[ -z "$RDS_ENDPOINT" ]]; then
  echo "ERROR: Could not determine RDS endpoint. Set AURORA_HOST or DB_HOST in .env."
  exit 1
fi

DB_USER="${AURORA_USER:-${DB_USER:-postgres}}"
DB_PASS="${AURORA_PASSWORD:-${DB_PASS:-}}"
DB_NAME="${AURORA_DB:-${DB_NAME:-plenful}}"
SEED_FILE="$REPO_ROOT/db/seed.sql"

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
RESET=false
for arg in "$@"; do
  case "$arg" in
    --reset) RESET=true ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Optional reset: truncate all tables in reverse FK order
# ---------------------------------------------------------------------------
if [[ "$RESET" == "true" ]]; then
  echo "==> --reset flag detected. Truncating all tables in reverse FK order..."
  PGPASSWORD="$DB_PASS" psql \
    -h "$RDS_ENDPOINT" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -v ON_ERROR_STOP=1 \
    <<'EOF'
TRUNCATE TABLE
  workflow_events,
  workflows,
  dispensing_records,
  claim_line_items,
  claims,
  prior_authorizations,
  patients,
  organizations
RESTART IDENTITY CASCADE;
EOF
  echo "    Tables truncated."
  echo ""
fi

# ---------------------------------------------------------------------------
# Seed
# ---------------------------------------------------------------------------
echo "==> Seeding $DB_NAME on $RDS_ENDPOINT..."
echo "    Seed file: $SEED_FILE"
echo ""

START_TS=$(date +%s)

PGPASSWORD="$DB_PASS" psql \
  -h "$RDS_ENDPOINT" \
  -U "$DB_USER" \
  -d "$DB_NAME" \
  -v ON_ERROR_STOP=1 \
  --echo-errors \
  -f "$SEED_FILE"

END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))

echo ""
echo "==> Seed complete in ${ELAPSED}s."
