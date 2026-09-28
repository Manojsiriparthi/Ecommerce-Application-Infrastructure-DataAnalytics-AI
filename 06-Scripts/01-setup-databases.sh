#!/usr/bin/env bash
# =============================================================================
# Script 1 — Database Setup
# =============================================================================
# PURPOSE:
#   Aurora RDS is the server (engine), but each microservice needs its own
#   DATABASE created inside it. Prisma migrations then create the TABLES.
#
#   Think of it like this:
#     Aurora = one big PostgreSQL server
#     Each service needs its own database inside that server:
#       user_db, product_db, cart_db, order_db, payment_db
#
# WHAT THIS SCRIPT DOES:
#   1. Reads the Aurora proxy endpoint from AWS SSM
#   2. Reads the DB master credentials from Secrets Manager
#   3. Connects to Aurora via psql and creates the 5 databases
#   4. Runs Prisma migrations for each service (creates all tables)
#
# PREREQUISITES:
#   - Terraform apply completed (Aurora + RDS Proxy running)
#   - psql installed: sudo apt-get install postgresql-client
#   - Node.js + npm installed
#   - AWS CLI configured with credentials
#   - kubectl configured (aws eks update-kubeconfig already run)
#   - You are running this from the repo root
#
# USAGE:
#   chmod +x 06-Scripts/01-setup-databases.sh
#   ./06-Scripts/01-setup-databases.sh dev ap-south-1
#   ./06-Scripts/01-setup-databases.sh prod us-east-1
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

# ── Arguments ─────────────────────────────────────────────────────────────────
ENV="${1:-dev}"
REGION="${2:-ap-south-1}"
PROJECT="pip-project-ecommerce"

echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   Database Setup — $PROJECT"
echo "  ║   Environment: $ENV  |  Region: $REGION"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ── Check prerequisites ────────────────────────────────────────────────────────
header "Checking prerequisites"

command -v aws    &>/dev/null || fail "AWS CLI not found. Run install-tools.sh first."
command -v psql   &>/dev/null || { warn "psql not found. Installing..."; sudo apt-get install -y -q postgresql-client; }
command -v node   &>/dev/null || fail "Node.js not found. Run install-tools.sh first."
command -v npx    &>/dev/null || fail "npx not found. Install Node.js first."

success "All prerequisites met"

# ── Step 1: Read DB connection info from AWS ───────────────────────────────────
header "Step 1: Reading DB connection from AWS SSM + Secrets Manager"

info "Fetching RDS Proxy endpoint from SSM..."
# Try proxy endpoint first, fall back to writer endpoint
DB_HOST=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/rds/proxy-endpoint" \
  --region "$REGION" --query Parameter.Value --output text 2>/dev/null) || \
DB_HOST=$(aws rds describe-db-proxies \
  --db-proxy-name "${PROJECT}-proxy" \
  --region "$REGION" \
  --query "DBProxies[0].Endpoint" --output text 2>/dev/null) || \
DB_HOST=$(aws rds describe-db-clusters \
  --db-cluster-identifier "${PROJECT}-cluster" \
  --region "$REGION" \
  --query "DBClusters[0].Endpoint" --output text)

[[ -z "$DB_HOST" || "$DB_HOST" == "None" ]] && fail "Could not find DB endpoint. Is Aurora running?"
success "DB Host: $DB_HOST"

info "Fetching DB credentials from Secrets Manager..."
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT}-db-credentials" \
  --region "$REGION" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
DB_PORT="5432"

success "Credentials loaded (username: $DB_USER)"

export PGPASSWORD="$DB_PASS"

# ── Step 2: Test connection ────────────────────────────────────────────────────
header "Step 2: Testing Aurora connection"

info "Connecting to Aurora at $DB_HOST:$DB_PORT ..."

# RDS Proxy requires SSL
if psql "host=$DB_HOST port=$DB_PORT user=$DB_USER dbname=postgres sslmode=require" \
  -c "SELECT version();" -t -q 2>/dev/null | grep -q PostgreSQL; then
  success "Aurora connection successful"
else
  # Try without SSL (direct connection)
  psql "host=$DB_HOST port=$DB_PORT user=$DB_USER dbname=postgres" \
    -c "SELECT version();" -t -q || fail "Cannot connect to Aurora. Check security groups and VPC routing."
  SSLMODE=""
  success "Aurora connection successful (no SSL — direct endpoint)"
fi

SSLMODE="${SSLMODE:-sslmode=require}"

# ── Step 3: Create databases ───────────────────────────────────────────────────
header "Step 3: Creating service databases"

DATABASES=("user_db" "product_db" "cart_db" "order_db" "payment_db")

for DB in "${DATABASES[@]}"; do
  info "Creating database: $DB"

  # Check if already exists
  EXISTS=$(psql "host=$DB_HOST port=$DB_PORT user=$DB_USER dbname=postgres $SSLMODE" \
    -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" 2>/dev/null || echo "")

  if [[ "$EXISTS" == "1" ]]; then
    warn "  Database $DB already exists — skipping"
  else
    psql "host=$DB_HOST port=$DB_PORT user=$DB_USER dbname=postgres $SSLMODE" \
      -c "CREATE DATABASE $DB;" 2>/dev/null && success "  Created: $DB" || warn "  $DB may already exist"
  fi
done

success "All 5 databases ready"

# ── Step 4: Run Prisma migrations ─────────────────────────────────────────────
header "Step 4: Running Prisma migrations (creates all tables)"

info "Prisma migrations run inside each service container."
info "This creates the tables inside each database."
echo ""

# Map service → database
declare -A SERVICE_DB=(
  ["user-service"]="user_db"
  ["product-service"]="product_db"
  ["cart-service"]="cart_db"
  ["order-service"]="order_db"
  ["payment-service"]="payment_db"
)

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

for SERVICE in "${!SERVICE_DB[@]}"; do
  DB="${SERVICE_DB[$SERVICE]}"
  SERVICE_DIR="$REPO_ROOT/02-Application-Code/services/$SERVICE"

  if [[ ! -d "$SERVICE_DIR/prisma" ]]; then
    warn "No prisma/ directory found in $SERVICE — skipping"
    continue
  fi

  info "Running Prisma migration for $SERVICE → $DB ..."

  DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB}?${SSLMODE/sslmode/sslmode}"

  (
    cd "$SERVICE_DIR"
    DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB}?sslmode=require" \
      npx prisma migrate deploy 2>&1 | tail -5
  ) && success "  $SERVICE migration complete" || warn "  $SERVICE migration had issues (check above)"
done

# ── Step 5: Verify tables ──────────────────────────────────────────────────────
header "Step 5: Verifying tables were created"

for DB in user_db product_db cart_db order_db payment_db; do
  TABLE_COUNT=$(psql "host=$DB_HOST port=$DB_PORT user=$DB_USER dbname=$DB $SSLMODE" \
    -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null || echo "0")
  if [[ "$TABLE_COUNT" -gt 0 ]]; then
    success "$DB: $TABLE_COUNT table(s) found"
  else
    warn "$DB: no tables found (migration may have failed)"
  fi
done

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Database setup complete!${NC}"
echo ""
echo -e "Next step: Run ${CYAN}./06-Scripts/02-deploy-app.sh $ENV $REGION${NC}"
echo ""
