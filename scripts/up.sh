#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Plenful POC Demo — Spinning up"
echo ""

# 1. Load environment
if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "ERROR: .env file not found. Copy .env.example and fill in values."
  exit 1
fi
set -a; source "$REPO_ROOT/.env"; set +a

# 2. Terraform apply
echo "==> Running terraform apply..."
cd "$REPO_ROOT/terraform"
terraform init -input=false
terraform apply -auto-approve \
  -var="db_password=$DB_PASS" \
  -var="materialize_host=$MZ_HOST" \
  -var="materialize_user=$MZ_USER" \
  -var="materialize_password=$MZ_PASSWORD"

# 3. Get outputs
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)
APP_IP=$(terraform output -raw app_public_ip)

echo ""
echo "==> RDS endpoint: $RDS_ENDPOINT"
echo "==> App IP: $APP_IP"

# 4. Wait for RDS to be reachable
echo ""
echo "==> Waiting for RDS to accept connections..."
for i in $(seq 1 30); do
  if PGPASSWORD="$DB_PASS" psql -h "$RDS_ENDPOINT" -U "$DB_USER" -d postgres -c "SELECT 1" &>/dev/null; then
    echo "    RDS ready."
    break
  fi
  echo "    Attempt $i/30 — waiting 10s..."
  sleep 10
done

# 5. Run schema
echo ""
echo "==> Applying schema..."
PGPASSWORD="$DB_PASS" psql -h "$RDS_ENDPOINT" -U "$DB_USER" -d "$DB_NAME" -f "$REPO_ROOT/db/schema.sql"

# 6. Seed data
echo ""
echo "==> Seeding database (~3 minutes)..."
"$SCRIPT_DIR/seed.sh"

# 7. Status check
echo ""
"$SCRIPT_DIR/status.sh"

echo ""
echo "=========================================="
echo "  Demo is live at: http://$APP_IP"
echo "  Aurora endpoint: $RDS_ENDPOINT:5432"
echo "=========================================="
