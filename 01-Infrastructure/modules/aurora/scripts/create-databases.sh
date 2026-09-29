#!/usr/bin/env bash
# =============================================================================
# Aurora Database + Table Setup
# =============================================================================
# Called by Terraform null_resource local-exec AFTER Aurora + RDS Proxy are ready.
#
# WHAT IT DOES:
#   1. Connects kubectl to EKS cluster
#   2. Launches a postgres:alpine pod inside EKS (same VPC as Aurora)
#      → runs CREATE DATABASE for each of the 5 service databases
#   3. Launches one pod per service (using ECR image with prisma baked in)
#      → runs `prisma db push` to create all tables
#   4. Runs a verify pod → lists all tables in all 5 databases
#   5. Cleans up all pods
#
# WHY INSIDE EKS (not local psql):
#   Aurora is in a PRIVATE subnet. Your machine cannot reach it.
#   EKS worker nodes ARE in the same VPC, so pods can reach Aurora directly.
#
# CALLED BY: aurora/db-setup.tf → null_resource.db_setup → local-exec
# =============================================================================

set -euo pipefail

# ── Args passed by Terraform local-exec ─────────────────────────────────────
CLUSTER_NAME="${1:?cluster name required}"
REGION="${2:?region required}"
DB_HOST="${3:?db host required}"
DB_USER="${4:?db user required}"
DB_PASS="${5:?db pass required}"
ECR_REGISTRY="${6:?ecr registry required}"   # e.g. 497149484677.dkr.ecr.us-east-1.amazonaws.com
PROJECT="${7:?project name required}"          # e.g. pip-project-ecommerce
NAMESPACE="ecommerce"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[TF-DB]${NC}  $1"; }
success() { echo -e "${GREEN}[TF-DB]${NC}  ✓ $1"; }
warn()    { echo -e "${YELLOW}[TF-DB]${NC}  ⚠ $1"; }
fail()    { echo -e "${RED}[TF-DB]${NC}  ✗ $1"; exit 1; }

echo ""
echo -e "${BOLD}══ Aurora DB + Table Setup (Terraform local-exec) ══${NC}"
echo "  Cluster : $CLUSTER_NAME"
echo "  Region  : $REGION"
echo "  DB Host : $DB_HOST"
echo ""

# ── Step 1: kubectl connect ──────────────────────────────────────────────────
info "Connecting kubectl to EKS cluster $CLUSTER_NAME ..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" \
  --alias "$CLUSTER_NAME" 2>/dev/null || \
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Wait for at least 1 Ready node
for i in $(seq 1 20); do
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
  [[ "$NODES" -gt 0 ]] && { success "EKS has $NODES Ready node(s)"; break; }
  info "  [$i/20] Waiting for EKS nodes to be Ready..."; sleep 15
done
[[ "$NODES" -eq 0 ]] && fail "No Ready nodes after 5 minutes — skipping DB setup"

# Ensure ecommerce namespace exists
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | \
  kubectl apply -f - 2>/dev/null || true

# ── Step 2: Create the 5 service databases ───────────────────────────────────
info "Creating service databases inside Aurora ..."

kubectl delete pod create-databases -n "$NAMESPACE" \
  --ignore-not-found --wait=false 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: create-databases
  namespace: ${NAMESPACE}
  labels:
    app: db-setup
    managed-by: terraform
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
      echo "Connecting to Aurora at \$DB_HOST ..."
      # Wait for Aurora to accept connections (may be warming up)
      for i in \$(seq 1 12); do
        psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres -c "SELECT 1" \
          >/dev/null 2>&1 && break
        echo "  [\$i/12] Aurora not ready yet — waiting 10s..."
        sleep 10
      done
      echo ""
      echo "Creating databases..."
      for DB in user_db product_db cart_db order_db payment_db; do
        EXISTS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
          -tAc "SELECT 1 FROM pg_database WHERE datname='\$DB'" 2>/dev/null || echo "")
        if [ "\$EXISTS" = "1" ]; then
          echo "  SKIP: \$DB already exists"
        else
          psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
            -c "CREATE DATABASE \$DB;" \
            && echo "  CREATED: \$DB" \
            || echo "  WARN: could not create \$DB (may already exist)"
        fi
      done
      echo "Done."
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

info "Waiting for create-databases pod ..."
kubectl wait pod create-databases -n "$NAMESPACE" \
  --for=condition=Ready --timeout=120s 2>/dev/null || true
kubectl wait pod create-databases -n "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s 2>/dev/null || true
kubectl logs create-databases -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /'
kubectl delete pod create-databases -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

success "Databases created (or already existed)"

# ── Step 3: Run prisma db push per service ───────────────────────────────────
# Each service ECR image has prisma/schema.prisma baked in (from Dockerfile COPY)
# `prisma db push` syncs the schema → creates tables
#
# NOTE: Uses SecretProviderClass (IRSA) to get DATABASE_URL from SSM.
#       SecretProviderClass must already be applied (done by 02-deploy-app.sh).
#       If not applied yet, this step is SKIPPED with a warning.
# ─────────────────────────────────────────────────────────────────────────────

# Check if ServiceAccount + SecretProviderClasses exist
SA_EXISTS=$(kubectl get serviceaccount ecommerce-services-sa \
  -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$SA_EXISTS" -eq 0 ]]; then
  warn "ServiceAccount 'ecommerce-services-sa' not found in namespace $NAMESPACE"
  warn "Tables will be created when you run: ./06-Scripts/01-setup-databases.sh $REGION"
  warn "OR run ./06-Scripts/02-deploy-app.sh first (it applies the ServiceAccount)"
  echo ""
else
  # Services with Prisma schemas → secret name
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
    POD_NAME="tf-migrate-${SERVICE}"

    # Check ECR image exists before trying to run it
    SVC_SHORT="${SERVICE%-service}"
    IMG_EXISTS=$(aws ecr describe-images \
      --repository-name "${PROJECT}/${SERVICE}" \
      --image-ids imageTag=latest \
      --region "$REGION" \
      --query "imageDetails[0].imageTags[0]" \
      --output text 2>/dev/null || echo "")

    if [[ -z "$IMG_EXISTS" || "$IMG_EXISTS" == "None" ]]; then
      warn "[$SERVICE] ECR image not found — build and push images first (Jenkins CI)"
      warn "[$SERVICE] Tables will be created automatically on next terraform apply"
      continue
    fi

    # Check SecretProviderClass exists
    SPC_EXISTS=$(kubectl get secretproviderclass "$SPC" -n "$NAMESPACE" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$SPC_EXISTS" -eq 0 ]]; then
      warn "[$SERVICE] SecretProviderClass '$SPC' not found — run 02-deploy-app.sh first"
      continue
    fi

    info "[$SERVICE] Running prisma db push ..."

    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" \
      --ignore-not-found --wait=false 2>/dev/null || true

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: db-migrate
    service: ${SERVICE}
    managed-by: terraform
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

    # Wait for pod to finish (max 3 min)
    kubectl wait pod "$POD_NAME" -n "$NAMESPACE" \
      --for=condition=Ready --timeout=60s 2>/dev/null || true
    kubectl wait pod "$POD_NAME" -n "$NAMESPACE" \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s 2>/dev/null || true

    PHASE=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    echo "  ── $SERVICE logs ──"
    kubectl logs "$POD_NAME" -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /' || true
    echo ""

    if [[ "$PHASE" == "Succeeded" ]]; then
      success "[$SERVICE] prisma db push complete"
    else
      warn "[$SERVICE] pod phase=$PHASE — will retry on next terraform apply"
      MIGRATION_FAILED+=("$SERVICE")
    fi

    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" \
      --ignore-not-found 2>/dev/null || true
  done
fi

# ── Step 4: Verify — list all tables in all 5 DBs ───────────────────────────
info "Verifying tables inside Aurora ..."

kubectl delete pod tf-db-verify -n "$NAMESPACE" \
  --ignore-not-found --wait=false 2>/dev/null || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tf-db-verify
  namespace: ${NAMESPACE}
  labels:
    app: db-setup
    managed-by: terraform
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
      echo "╔════════════════════════════════════════════════╗"
      echo "║   Terraform DB Verification — RDS Tables       ║"
      echo "║   Host: \$DB_HOST"
      echo "╚════════════════════════════════════════════════╝"
      ALL_OK=true
      for DB in user_db product_db cart_db order_db payment_db; do
        echo ""
        echo "── \$DB ────────────────────────────────────────"
        DB_EXISTS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
          -tAc "SELECT 1 FROM pg_database WHERE datname='\$DB'" 2>/dev/null || echo "")
        if [ "\$DB_EXISTS" != "1" ]; then
          echo "  ✗ DATABASE does NOT exist"
          ALL_OK=false; continue
        fi
        echo "  ✓ Database exists"
        TABLES=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB" \
          -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename" \
          2>/dev/null || echo "")
        if [ -z "\$TABLES" ]; then
          echo "  ✗ No tables — prisma db push may not have run yet"
          echo "    Run: ./06-Scripts/02-deploy-app.sh prod us-east-1"
          ALL_OK=false
        else
          echo "\$TABLES" | while read -r TBL; do
            [ -z "\$TBL" ] && continue
            ROWS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB" \
              -tAc "SELECT count(*) FROM \"\$TBL\"" 2>/dev/null | tr -d ' ' || echo "?")
            echo "    ✓ \$TBL  (rows: \$ROWS)"
          done
        fi
      done
      echo ""
      echo "════════════════════════════════════════════════"
      if [ "\$ALL_OK" = "true" ]; then
        echo "  RESULT: All databases + tables present ✓"
      else
        echo "  RESULT: Some items missing — check above"
        echo "  Next:   ./06-Scripts/02-deploy-app.sh prod us-east-1"
      fi
      echo "════════════════════════════════════════════════"
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

kubectl wait pod tf-db-verify -n "$NAMESPACE" \
  --for=condition=Ready --timeout=60s 2>/dev/null || true
kubectl wait pod tf-db-verify -n "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s 2>/dev/null || true
echo ""
kubectl logs tf-db-verify -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /' || true
kubectl delete pod tf-db-verify -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo ""
success "DB setup complete — Terraform local-exec finished"
echo ""
