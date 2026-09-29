#!/usr/bin/env bash
# =============================================================================
# Aurora Database + Table Setup
# Called by Terraform null_resource local-exec (aurora/db-setup.tf)
#
# Args:
#   $1  CLUSTER_NAME   — EKS cluster name
#   $2  REGION         — AWS region
#   $3  DB_HOST        — RDS Proxy endpoint
#   $4  DB_USER        — Aurora master username
#   $5  ECR_REGISTRY   — e.g. 497149484677.dkr.ecr.us-east-1.amazonaws.com
#   $6  PROJECT        — e.g. pip-project-ecommerce
#
# Password is read from env var TF_DB_PASS (set in local-exec environment{})
# This keeps the password OUT of the command string so Terraform
# does NOT suppress script output.
# =============================================================================

# NOTE: intentionally NOT using `set -e` here.
# Many kubectl commands return non-zero for "not found" which is expected.
# We handle errors explicitly per-step instead.
set -uo pipefail

# ── Args ─────────────────────────────────────────────────────────────────────
CLUSTER_NAME="${1:?cluster name required}"
REGION="${2:?region required}"
DB_HOST="${3:?db host required}"
DB_USER="${4:?db user required}"
ECR_REGISTRY="${5:?ecr registry required}"
PROJECT="${6:?project name required}"
DB_PASS="${TF_DB_PASS:?TF_DB_PASS env var required}"
NAMESPACE="ecommerce"

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[TF-DB]${NC}  $1"; }
success() { echo -e "${GREEN}[TF-DB]${NC}  ✓ $1"; }
warn()    { echo -e "${YELLOW}[TF-DB]${NC}  ⚠ $1"; }

echo ""
echo -e "${BOLD}══ Aurora DB + Table Setup (Terraform local-exec) ══${NC}"
echo "  Cluster : $CLUSTER_NAME"
echo "  Region  : $REGION"
echo "  DB Host : $DB_HOST"
echo ""

# ── Step 1: Connect kubectl ───────────────────────────────────────────────────
info "Connecting kubectl to $CLUSTER_NAME ..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --alias "$CLUSTER_NAME" 2>/dev/null \
  || aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

NODES=0
for i in $(seq 1 20); do
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)
  [[ "$NODES" -gt 0 ]] && break
  info "  [$i/20] Waiting for EKS nodes..."; sleep 15
done

if [[ "$NODES" -eq 0 ]]; then
  warn "No Ready nodes found — DB setup skipped. Re-run terraform apply."
  exit 0    # exit 0 so Terraform doesn't mark this as an error
fi
success "EKS has $NODES Ready node(s)"

# Ensure namespace exists (ignore error if already exists)
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

# ── Step 2: CREATE the 5 service databases ───────────────────────────────────
info "Creating service databases inside Aurora ..."

kubectl delete pod create-databases -n "$NAMESPACE" \
  --ignore-not-found --wait=false 2>/dev/null || true

# Wait for any previous termination
sleep 3

kubectl apply -f - <<EOF
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
      CONNECTED=false
      for i in \$(seq 1 20); do
        if psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
             -c "SELECT 1" >/dev/null 2>&1; then
          CONNECTED=true
          break
        fi
        echo "  [\$i/20] Aurora not ready yet — retrying in 15s..."
        sleep 15
      done
      if [ "\$CONNECTED" = "false" ]; then
        echo "ERROR: Could not connect to Aurora after 5 minutes"
        exit 1
      fi
      echo "Connected to Aurora successfully."
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
            || echo "  WARN: could not create \$DB"
        fi
      done
      echo ""
      echo "All databases done."
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

info "Waiting for create-databases pod (timeout: 5m)..."

# Wait for pod to be Running first
kubectl wait pod create-databases -n "$NAMESPACE" \
  --for=condition=Ready --timeout=120s 2>/dev/null || true

# Wait for it to complete (aurora connection retry loop can take up to 5min)
for i in $(seq 1 40); do
  PHASE=$(kubectl get pod create-databases -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  if [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]]; then
    break
  fi
  sleep 10
done

echo ""
info "create-databases pod output:"
kubectl logs create-databases -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /' || true
echo ""

PHASE=$(kubectl get pod create-databases -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

if [[ "$PHASE" == "Failed" ]]; then
  warn "create-databases pod failed (phase=Failed) — see logs above"
  warn "Most likely Aurora proxy not ready yet. Re-run terraform apply."
  kubectl delete pod create-databases -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  exit 0   # don't block terraform — databases can be created on next apply
fi

kubectl delete pod create-databases -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
success "Databases created (or already existed)"

# ── Step 3: prisma db push per service ───────────────────────────────────────
info "Checking if ServiceAccount exists for prisma migration..."

SA_EXISTS=$(kubectl get serviceaccount ecommerce-services-sa \
  -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")

if [[ "${SA_EXISTS}" -eq 0 ]]; then
  warn "ServiceAccount 'ecommerce-services-sa' not found."
  warn "Prisma tables will be created when 02-deploy-app.sh is run next."
  warn "(That script applies the ServiceAccount + SecretProviderClasses first)"
else
  # service → "SecretProviderClass:K8sSecretName"
  USER_SPC="user-service-secrets:user-db-url"
  PRODUCT_SPC="product-service-secrets:product-db-url"
  CART_SPC="cart-service-secrets:cart-db-url"
  ORDER_SPC="order-service-secrets:order-db-url"
  PAYMENT_SPC="payment-service-secrets:payment-db-url"

  run_prisma_push() {
    local SERVICE="$1"
    local SPC_PAIR="$2"
    local SPC="${SPC_PAIR%%:*}"
    local SECRET_NAME="${SPC_PAIR##*:}"
    local IMAGE="${ECR_REGISTRY}/${PROJECT}/${SERVICE}:latest"
    local POD_NAME="tf-migrate-${SERVICE}"

    # Check ECR image exists
    local IMG_EXISTS
    IMG_EXISTS=$(aws ecr describe-images \
      --repository-name "${PROJECT}/${SERVICE}" \
      --image-ids imageTag=latest \
      --region "$REGION" \
      --query "imageDetails[0].imageTags[0]" \
      --output text 2>/dev/null || echo "")

    if [[ -z "$IMG_EXISTS" || "$IMG_EXISTS" == "None" ]]; then
      warn "[$SERVICE] ECR image not found — skipping (build images first via Jenkins)"
      return 0
    fi

    # Check SecretProviderClass exists
    local SPC_EXISTS
    SPC_EXISTS=$(kubectl get secretproviderclass "$SPC" \
      -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    if [[ "${SPC_EXISTS}" -eq 0 ]]; then
      warn "[$SERVICE] SecretProviderClass '$SPC' not found — skipping (run 02-deploy-app.sh)"
      return 0
    fi

    info "[$SERVICE] Running prisma db push..."

    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" \
      --ignore-not-found --wait=false 2>/dev/null || true
    sleep 2

    kubectl apply -f - <<PODEOF
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
PODEOF

    # Wait up to 4 minutes for pod to complete
    for i in $(seq 1 24); do
      local PHASE
      PHASE=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
      [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]] && break
      sleep 10
    done

    local FINAL_PHASE
    FINAL_PHASE=$(kubectl get pod "$POD_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    echo "  ── $SERVICE prisma logs ──"
    kubectl logs "$POD_NAME" -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /' || true
    echo ""

    if [[ "$FINAL_PHASE" == "Succeeded" ]]; then
      success "[$SERVICE] prisma db push complete ✓"
    else
      warn "[$SERVICE] pod phase=$FINAL_PHASE — will retry on next terraform apply"
    fi

    kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  }

  run_prisma_push "user-service"    "$USER_SPC"
  run_prisma_push "product-service" "$PRODUCT_SPC"
  run_prisma_push "cart-service"    "$CART_SPC"
  run_prisma_push "order-service"   "$ORDER_SPC"
  run_prisma_push "payment-service" "$PAYMENT_SPC"
fi

# ── Step 4: Verify ────────────────────────────────────────────────────────────
info "Running verification pod (lists all tables in all 5 databases)..."

kubectl delete pod tf-db-verify -n "$NAMESPACE" \
  --ignore-not-found --wait=false 2>/dev/null || true
sleep 2

kubectl apply -f - <<EOF
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
      echo "╔════════════════════════════════════════╗"
      echo "║  Terraform DB Verification — RDS Tables ║"
      echo "╚════════════════════════════════════════╝"
      echo "  Host: \$DB_HOST"
      echo ""
      ALL_OK=true
      for DB in user_db product_db cart_db order_db payment_db; do
        echo "── \$DB ──────────────────────────────────"
        DB_EXISTS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d postgres \
          -tAc "SELECT 1 FROM pg_database WHERE datname='\$DB'" 2>/dev/null || echo "")
        if [ "\$DB_EXISTS" != "1" ]; then
          echo "  ✗ Database does NOT exist in RDS"
          ALL_OK=false
          continue
        fi
        echo "  ✓ Database exists"
        TABLES=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB" \
          -tAc "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename" \
          2>/dev/null || echo "")
        if [ -z "\$TABLES" ]; then
          echo "  ✗ No tables yet — run 02-deploy-app.sh to trigger prisma push"
          ALL_OK=false
        else
          echo "\$TABLES" | while read -r TBL; do
            [ -z "\$TBL" ] && continue
            ROWS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB" \
              -tAc "SELECT count(*) FROM \"\$TBL\"" 2>/dev/null | tr -d ' ' || echo "?")
            echo "    ✓ \$TBL  (rows: \$ROWS)"
          done
        fi
        echo ""
      done
      echo "════════════════════════════════════════"
      if [ "\$ALL_OK" = "true" ]; then
        echo "  RESULT: All databases + tables present ✓"
      else
        echo "  RESULT: Some items missing (see above)"
      fi
      echo "════════════════════════════════════════"
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

for i in $(seq 1 12); do
  PHASE=$(kubectl get pod tf-db-verify -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
  [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]] && break
  sleep 10
done

echo ""
kubectl logs tf-db-verify -n "$NAMESPACE" 2>/dev/null | sed 's/^/  /' || true
kubectl delete pod tf-db-verify -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo ""
success "DB setup complete"
echo ""

# Always exit 0 — failures are warnings not blockers.
# The app still deploys; tables get created on re-apply or via 01-setup-databases.sh
exit 0
