#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

echo ""
echo "=========================================="
echo "  WARNING: This will DESTROY all resources"
echo "  created by Terraform for the Plenful POC"
echo "  demo, including the Aurora RDS instance"
echo "  and ALL data in it. This cannot be undone."
echo "=========================================="
echo ""
read -r -p "Type 'yes' to confirm destruction: " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
  echo "Aborted — no resources were destroyed."
  exit 0
fi

# 1. Load environment
if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo "ERROR: .env file not found. Cannot resolve Terraform variables."
  exit 1
fi
set -a; source "$REPO_ROOT/.env"; set +a

# 2. Terraform destroy
echo ""
echo "==> Running terraform destroy..."
cd "$REPO_ROOT/terraform"
terraform destroy -auto-approve \
  -var="db_password=$DB_PASS" \
  -var="materialize_host=$MZ_HOST" \
  -var="materialize_user=$MZ_USER" \
  -var="materialize_password=$MZ_PASSWORD"

echo ""
echo "All resources destroyed."
