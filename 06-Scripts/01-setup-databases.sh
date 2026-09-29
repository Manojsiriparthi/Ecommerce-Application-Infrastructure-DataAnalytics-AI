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
#   - AWS CLI configured with credentials
#   - kubectl installed (aws eks update-kubeconfig will be run automatically)
#   - You are running this from the repo root
#
# NOTE: psql and Node.js are NOT needed on your machine.
#   All DB operations run as pods INSIDE EKS (same VPC as Aurora).
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

command -v aws     &>/dev/null || fail "AWS CLI not found. Run install-tools.sh first."
command -v kubectl &>/dev/null || fail "kubectl not found. Run install-tools.sh first."

success "All prerequisites met (psql/node not needed — all DB ops run inside EKS)"

# ── Step 1: Connect kubectl ───────────────────────────────────────────────────
header "Step 1: Connect kubectl to EKS"

CLUSTER_NAME="${PROJECT}-cluster"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

info "Connecting kubectl to EKS cluster..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null || \
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
[[ "$NODES" -eq 0 ]] && fail "No Ready nodes found. Is the EKS cluster up? Run 04-terraform-apply.sh first."
success "kubectl connected — $NODES node(s) Ready"

# Ensure namespace + SecretProviderClasses are in place
kubectl apply -f "$REPO_ROOT/03-Kubernetes/namespace.yaml" 2>/dev/null || true
kubectl apply -f "$REPO_ROOT/03-Kubernetes/secrets/serviceaccount.yaml" 2>/dev/null || true
kubectl apply -f "$REPO_ROOT/03-Kubernetes/secrets/secretproviderclass-db.yaml" 2>/dev/null || true

# ── Step 2: Read DB endpoint from AWS (for the create-databases pod) ──────────
header "Step 2: Fetching DB endpoint from AWS"

# WHY we still read DB_HOST here (but not connect locally):
#   Steps 3 creates databases using a psql pod inside the cluster.
#   That pod needs the RDS host + master credentials — we pass them as env vars.

info "Fetching RDS Writer endpoint from SSM / Aurora API..."
DB_HOST=$(aws ssm get-parameter \
  --name "/${PROJECT}/${ENV}/rds/proxy-endpoint" \
  --region "$REGION" --query Parameter.Value --output text 2>/dev/null || echo "")

if [[ -z "$DB_HOST" || "$DB_HOST" == "None" ]]; then
  DB_HOST=$(aws rds describe-db-proxies \
    --db-proxy-name "${PROJECT}-proxy" \
    --region "$REGION" \
    --query "DBProxies[0].Endpoint" --output text 2>/dev/null || echo "")
fi

if [[ -z "$DB_HOST" || "$DB_HOST" == "None" ]]; then
  DB_HOST=$(aws rds describe-db-clusters \
    --db-cluster-identifier "${PROJECT}-cluster" \
    --region "$REGION" \
    --query "DBClusters[0].Endpoint" --output text 2>/dev/null || echo "")
fi

[[ -z "$DB_HOST" || "$DB_HOST" == "None" ]] && fail "Could not find DB endpoint. Is Aurora running?"
success "DB Host: $DB_HOST"

info "Fetching master credentials from Secrets Manager..."
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT}-db-credentials" \
  --region "$REGION" \
  --query SecretString --output text)

DB_USER=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
DB_PASS=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

success "Credentials loaded (username: $DB_USER)"

# ── Step 3: Create databases inside Aurora (runs as a pod in the cluster) ─────
header "Step 3: Creating service databases inside Aurora"

# WHY a pod:
#   Aurora is in a private subnet — unreachable from your laptop.
#   We run a postgres:alpine pod INSIDE EKS, which is in the same VPC,
#   to execute CREATE DATABASE for each service. Pod is deleted after.

info "Launching create-databases pod inside EKS (same VPC as Aurora)..."

kubectl delete pod create-databases -n ecommerce --ignore-not-found 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: create-databases
  namespace: ecommerce
spec:
  restartPolicy: Never
  containers:
  - name: psql
    image: postgres:15-alpine
    command:
    - sh
    - -c
    - |
      export PGPASSWORD="\$DB_PASS"
      echo "Connecting to Aurora at \$DB_HOST..."
      for DB in user_db product_db cart_db order_db payment_db; do
        EXISTS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres -tAc \
          "SELECT 1 FROM pg_database WHERE datname='\$DB'" 2>/dev/null || echo "")
        if [ "\$EXISTS" = "1" ]; then
          echo "  SKIP: \$DB already exists"
        else
          psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
            -c "CREATE DATABASE \$DB;" && echo "  CREATED: \$DB" || echo "  WARN: \$DB may already exist"
        fi
      done
      echo "Done creating databases."
    env:
    - name: DB_HOST
      value: "${DB_HOST}"
    - name: DB_USER
      value: "${DB_USER}"
    - name: DB_PASS
      value: "${DB_PASS}"
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
EOF

info "Waiting for create-databases pod..."
kubectl wait pod create-databases -n ecommerce \
  --for=condition=Ready --timeout=60s 2>/dev/null || true
kubectl wait pod create-databases -n ecommerce \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s 2>/dev/null || true
kubectl logs create-databases -n ecommerce 2>/dev/null || warn "Could not get logs"
kubectl delete pod create-databases -n ecommerce --ignore-not-found 2>/dev/null || true

success "All 5 databases created (or already existed)"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# ── Step 4: Run Prisma migrations via Kubernetes Jobs ─────────────────────────
header "Step 4: Running Prisma migrations (creates all tables)"

# WHY Kubernetes Jobs, not local npx:
#   RDS is in a private subnet — your laptop in Hyderabad cannot reach it.
#   The EKS worker nodes ARE inside the VPC, so they can reach RDS.
#   We spin up a one-off pod per service (using the already-pushed ECR image),
#   run `prisma db push`, then delete the pod.
#   WHY db push not migrate deploy:
#     Your services have schema.prisma but no prisma/migrations/ folder yet.
#     `migrate deploy` requires migration files — it would fail on a fresh DB.
#     `prisma db push` syncs the schema directly, creating all tables.
#     Once you're in production with real data, switch to `migrate deploy`
#     and generate migrations with `prisma migrate dev` locally.
#   The pod inherits the same IRSA + SecretProviderClass as the service pod,
#   so it gets the correct DATABASE_URL automatically.

# ── Services that need migrations ────────────────────────────────────────────
# notification-service has no prisma dir — excluded
declare -A SERVICE_SECRET=(
  ["user-service"]="user-service-secrets:user-db-url"
  ["product-service"]="product-service-secrets:product-db-url"
  ["cart-service"]="cart-service-secrets:cart-db-url"
  ["order-service"]="order-service-secrets:order-db-url"
  ["payment-service"]="payment-service-secrets:payment-db-url"
)

MIGRATION_FAILED=()

for SERVICE in user-service product-service cart-service order-service payment-service; do
  IFS=':' read -r SPC SECRET_NAME <<< "${SERVICE_SECRET[$SERVICE]}"
  IMAGE="${ECR_REGISTRY}/${PROJECT}/${SERVICE}:latest"
  POD_NAME="migrate-${SERVICE}"

  info "[$SERVICE] Launching migration pod..."

  # Delete any leftover pod from a previous run
  kubectl delete pod "$POD_NAME" -n ecommerce --ignore-not-found --wait=false 2>/dev/null || true

  # Build the pod spec as a YAML and apply it
  # - Uses the same ServiceAccount (IRSA) as the service deployment
  # - Mounts the SecretProviderClass so DATABASE_URL is available as a K8s secret
  # - Runs `prisma db push` to create all tables, then exits
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ecommerce
  labels:
    app: db-migrate
    service: ${SERVICE}
spec:
  restartPolicy: Never
  serviceAccountName: ecommerce-services-sa
  volumes:
  - name: aws-secrets
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "${SPC}"
  containers:
  - name: migrate
    image: ${IMAGE}
    imagePullPolicy: Always
    command: ["npx", "prisma", "db", "push", "--accept-data-loss"]
    volumeMounts:
    - name: aws-secrets
      mountPath: /mnt/secrets
      readOnly: true
    env:
    - name: NODE_ENV
      value: "production"
    - name: DATABASE_URL
      valueFrom:
        secretKeyRef:
          name: ${SECRET_NAME}
          key: database_url
    resources:
      requests:
        memory: "128Mi"
        cpu: "100m"
      limits:
        memory: "256Mi"
        cpu: "300m"
EOF

  # Wait up to 3 minutes for the migration to complete
  info "[$SERVICE] Waiting for migration to complete (timeout: 3m)..."
  if kubectl wait pod "$POD_NAME" -n ecommerce \
    --for=condition=Ready --timeout=60s 2>/dev/null; then
    # Pod started — now wait for it to finish
    kubectl wait pod "$POD_NAME" -n ecommerce \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s 2>/dev/null || true
  fi

  PHASE=$(kubectl get pod "$POD_NAME" -n ecommerce \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

  echo ""
  echo -e "${BOLD}  ── $SERVICE migration logs ──${NC}"
  kubectl logs "$POD_NAME" -n ecommerce 2>/dev/null || echo "  (no logs yet)"
  echo ""

  if [[ "$PHASE" == "Succeeded" ]]; then
    success "[$SERVICE] Migration COMPLETE ✓"
  else
    warn "[$SERVICE] Migration pod phase: $PHASE — check logs above"
    MIGRATION_FAILED+=("$SERVICE")
  fi

  # Clean up the pod
  kubectl delete pod "$POD_NAME" -n ecommerce --ignore-not-found 2>/dev/null || true
done

# ── Report ───────────────────────────────────────────────────────────────────
if [[ ${#MIGRATION_FAILED[@]} -gt 0 ]]; then
  warn "The following migrations had issues: ${MIGRATION_FAILED[*]}"
  warn "Re-run this script or check pod logs with:"
  warn "  kubectl logs migrate-<service> -n ecommerce"
else
  success "All 5 service migrations completed successfully"
fi

# ── Step 5: Verify tables exist in RDS ───────────────────────────────────────
header "Step 5: Verifying tables exist inside RDS"

# Runs a postgres:alpine pod inside EKS (same VPC as Aurora).
# Uses the master credentials fetched in Step 2 to connect to each database
# and list every table — so you can see exactly what was created.

info "Launching verify pod (connects to all 5 databases and lists tables)..."

kubectl delete pod db-verify -n ecommerce --ignore-not-found 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: db-verify
  namespace: ecommerce
spec:
  restartPolicy: Never
  containers:
  - name: verify
    image: postgres:15-alpine
    command:
    - sh
    - -c
    - |
      export PGPASSWORD="\$DB_PASS"
      echo ""
      echo "╔══════════════════════════════════════════════════╗"
      echo "║         RDS Table Verification Report            ║"
      echo "║  Host: \$DB_HOST                                  ║"
      echo "╚══════════════════════════════════════════════════╝"
      echo ""

      ALL_OK=true

      for DB in user_db product_db cart_db order_db payment_db; do
        echo "── \$DB ──────────────────────────────────────────"

        # Check DB exists
        DB_EXISTS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
          -tAc "SELECT 1 FROM pg_database WHERE datname='\$DB'" 2>/dev/null || echo "")

        if [ "\$DB_EXISTS" != "1" ]; then
          echo "  ✗ DATABASE '\$DB' does NOT exist in RDS"
          ALL_OK=false
          echo ""
          continue
        fi

        echo "  ✓ Database exists"

        # List all tables in this database
        TABLES=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB" \
          -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename" \
          2>/dev/null || echo "")

        if [ -z "\$TABLES" ]; then
          echo "  ✗ No tables found — migration may have failed"
          ALL_OK=false
        else
          echo "  Tables in \$DB:"
          echo "\$TABLES" | while read -r TBL; do
            [ -z "\$TBL" ] && continue
            # Count rows in each table
            ROWS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB" \
              -tAc "SELECT count(*) FROM \"\$TBL\"" 2>/dev/null | tr -d ' ' || echo "?")
            echo "    ✓ \$TBL  (rows: \$ROWS)"
          done
        fi
        echo ""
      done

      echo "══════════════════════════════════════════════════"
      if [ "\$ALL_OK" = "true" ]; then
        echo "  RESULT: All databases and tables are present ✓"
      else
        echo "  RESULT: Some databases/tables are MISSING ✗"
        echo "  Re-run: ./06-Scripts/01-setup-databases.sh"
      fi
      echo "══════════════════════════════════════════════════"
      echo ""
    env:
    - name: DB_HOST
      value: "${DB_HOST}"
    - name: DB_USER
      value: "${DB_USER}"
    - name: DB_PASS
      value: "${DB_PASS}"
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
EOF

info "Waiting for verify pod..."
kubectl wait pod db-verify -n ecommerce \
  --for=condition=Ready --timeout=60s 2>/dev/null || true
kubectl wait pod db-verify -n ecommerce \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s 2>/dev/null || true

echo ""
kubectl logs db-verify -n ecommerce 2>/dev/null || warn "Verify pod logs unavailable"
kubectl delete pod db-verify -n ecommerce --ignore-not-found 2>/dev/null || true

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Database setup complete!${NC}"
echo ""
echo -e "Next step: Run ${CYAN}./06-Scripts/02-deploy-app.sh $ENV $REGION${NC}"
echo ""
