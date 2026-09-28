#!/usr/bin/env bash
# =============================================================================
# Script 2 — Application Deployment
# =============================================================================
# PURPOSE:
#   Builds Docker images, pushes to ECR, patches K8s placeholders with real
#   AWS values, deploys to EKS, then verifies everything is working.
#
# USAGE:
#   chmod +x 06-Scripts/02-deploy-app.sh
#   ./06-Scripts/02-deploy-app.sh dev ap-south-1
#   ./06-Scripts/02-deploy-app.sh prod us-east-1
#   ./06-Scripts/02-deploy-app.sh dev ap-south-1 v1.2.0   # specific tag
#
# PREREQUISITES:
#   - terraform apply completed
#   - 01-setup-databases.sh already run
#   - Docker installed
#   - AWS CLI configured
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

ENV="${1:-dev}"
REGION="${2:-ap-south-1}"
IMAGE_TAG="${3:-latest}"
PROJECT="pip-project-ecommerce"
CLUSTER_NAME="${PROJECT}-cluster"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
K8S="$REPO_ROOT/03-Kubernetes"

echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════════╗"
echo "  ║   pip-project-ecommerce — Application Deployment      ║"
echo "  ║   Env: $ENV  |  Region: $REGION  |  Tag: $IMAGE_TAG"
echo "  ╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Helper: read SSM param ──────────────────────────────────────────────────
ssm() {
  aws ssm get-parameter --name "/${PROJECT}/${ENV}/$1" \
    --region "$REGION" --query Parameter.Value --output text 2>/dev/null || echo ""
}

# =============================================================================
# PHASE 1 — kubectl connection
# =============================================================================
header "Phase 1: Connect kubectl to EKS cluster"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
[[ "$NODES" -eq 0 ]] && fail "No Ready nodes. Is EKS cluster up?"
success "Connected to $CLUSTER_NAME — $NODES node(s) Ready"
kubectl get nodes

# =============================================================================
# PHASE 2 — Read real values from AWS
# =============================================================================
header "Phase 2: Reading values from AWS"

IRSA_ROLE_ARN=$(aws iam get-role \
  --role-name "${PROJECT}-services-role" \
  --query "Role.Arn" --output text 2>/dev/null || echo "")
REDIS_HOST=$(ssm "redis/primary-endpoint")
SNS_TOPIC_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?contains(TopicArn,'${PROJECT}')].TopicArn | [0]" \
  --output text 2>/dev/null | tr -d '"' || echo "")
WAF_ARN=$(ssm "waf/web-acl-arn")
LOGS_BUCKET=$(ssm "s3/logs-bucket-name")
SES_EMAIL=$(ssm "app/ses-from-email"); SES_EMAIL="${SES_EMAIL:-noreply@ecommerce-pip.com}"

PUB_IDS=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=${PROJECT}-public-*" "Name=tag:Environment,Values=${ENV}" \
  --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' ',' || echo "")
PRIV_IDS=$(aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=${PROJECT}-private-*" "Name=tag:Environment,Values=${ENV}" \
  --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' ',' || echo "")

PUB1=$(echo "$PUB_IDS" | cut -d, -f1)
PUB2=$(echo "$PUB_IDS" | cut -d, -f2)
PUB3=$(echo "$PUB_IDS" | cut -d, -f3)
PRIV1=$(echo "$PRIV_IDS" | cut -d, -f1)
PRIV2=$(echo "$PRIV_IDS" | cut -d, -f2)
PRIV3=$(echo "$PRIV_IDS" | cut -d, -f3)

info "IRSA role  : ${IRSA_ROLE_ARN:-NOT FOUND}"
info "Redis host : ${REDIS_HOST:-NOT FOUND}"
info "SNS topic  : ${SNS_TOPIC_ARN:-NOT FOUND}"
info "WAF ARN    : ${WAF_ARN:-NOT FOUND}"
info "Pub subnets: $PUB_IDS"
info "Priv subnets: $PRIV_IDS"

# =============================================================================
# PHASE 3 — Build Docker images
# =============================================================================
header "Phase 3: Build Docker images"

info "ECR login..."
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_REGISTRY"

SERVICES=()
for d in "$REPO_ROOT/02-Application-Code/services"/*/; do
  [[ -f "${d}Dockerfile" ]] && SERVICES+=("$(basename "$d")")
done
SERVICES+=("frontend")

for SVC in "${SERVICES[@]}"; do
  [[ "$SVC" == "frontend" ]] && SRC="$REPO_ROOT/02-Application-Code/frontend" \
                             || SRC="$REPO_ROOT/02-Application-Code/services/$SVC"
  IMAGE="${ECR_REGISTRY}/${PROJECT}/${SVC}:${IMAGE_TAG}"
  info "Building $SVC..."
  docker build --pull -t "$IMAGE" "$SRC"
  success "Built: $SVC"
done

# =============================================================================
# PHASE 4 — Push to ECR
# =============================================================================
header "Phase 4: Push to ECR"

for SVC in "${SERVICES[@]}"; do
  REPO="${PROJECT}/${SVC}"
  IMAGE="${ECR_REGISTRY}/${REPO}:${IMAGE_TAG}"
  aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" &>/dev/null || \
    aws ecr create-repository --repository-name "$REPO" \
      --image-scanning-configuration scanOnPush=true \
      --region "$REGION" >/dev/null
  docker push "$IMAGE"
  success "Pushed: $SVC"
done

# =============================================================================
# PHASE 5 — Patch all K8s placeholders
# =============================================================================
header "Phase 5: Patch K8s YAML placeholders"

# ── Image tags in all deployments ────────────────────────────────────────────
for SVC in "${SERVICES[@]}"; do
  [[ "$SVC" == "frontend" ]] && DEPLOY="$K8S/frontend/deployment.yaml" \
                             || DEPLOY="$K8S/services/$SVC/deployment.yaml"
  [[ -f "$DEPLOY" ]] || continue
  IMAGE="${ECR_REGISTRY}/${PROJECT}/${SVC}:${IMAGE_TAG}"
  sed -i "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" "$DEPLOY"
  sed -i "s|<AWS_REGION>|${REGION}|g"              "$DEPLOY"
  # Replace full image line with real image
  sed -i "s|image:.*${PROJECT}/${SVC}:.*|image: ${IMAGE}|g" "$DEPLOY"
  success "  Image: $SVC → $IMAGE"
done

# ── ServiceAccount IRSA ARN ───────────────────────────────────────────────────
[[ -n "$IRSA_ROLE_ARN" ]] && \
  sed -i "s|<IRSA_ROLE_ARN>|${IRSA_ROLE_ARN}|g" "$K8S/secrets/serviceaccount.yaml"

# ── External Ingress ─────────────────────────────────────────────────────────
EI="$K8S/frontend/ingress.yaml"
[[ -n "$WAF_ARN"     ]] && sed -i "s|<WAF_WEBACL_ARN>|${WAF_ARN}|g"         "$EI"
[[ -n "$LOGS_BUCKET" ]] && sed -i "s|<LOGS_BUCKET_NAME>|${LOGS_BUCKET}|g"   "$EI"
[[ -n "$PUB1" ]] && sed -i "s|<PUBLIC_SUBNET_ID_1>|${PUB1}|g" "$EI"
[[ -n "$PUB2" ]] && sed -i "s|<PUBLIC_SUBNET_ID_2>|${PUB2}|g" "$EI"
[[ -n "$PUB3" ]] && sed -i "s|<PUBLIC_SUBNET_ID_3>|${PUB3}|g" "$EI"

# ── Internal Ingress ─────────────────────────────────────────────────────────
II="$K8S/services/ingress-internal.yaml"
[[ -n "$LOGS_BUCKET" ]] && sed -i "s|<LOGS_BUCKET_NAME>|${LOGS_BUCKET}|g"   "$II"
[[ -n "$PRIV1" ]] && sed -i "s|<PRIVATE_SUBNET_ID_1>|${PRIV1}|g" "$II"
[[ -n "$PRIV2" ]] && sed -i "s|<PRIVATE_SUBNET_ID_2>|${PRIV2}|g" "$II"
[[ -n "$PRIV3" ]] && sed -i "s|<PRIVATE_SUBNET_ID_3>|${PRIV3}|g" "$II"

# ── SecretProviderClass — environment path ────────────────────────────────────
sed -i "s|/dev/|/${ENV}/|g;s|/prod/|/${ENV}/|g" \
  "$K8S/secrets/secretproviderclass-db.yaml" 2>/dev/null || true

success "All placeholders patched"

# =============================================================================
# PHASE 6 — Deploy to EKS
# =============================================================================
header "Phase 6: Deploy to EKS"

# Create namespace first
kubectl apply -f "$K8S/namespace.yaml"

# Secrets and config — must exist before pods start
kubectl apply -f "$K8S/secrets/serviceaccount.yaml"
kubectl apply -f "$K8S/secrets/secretproviderclass-db.yaml"

# Apply ConfigMap with real values (not the placeholder YAML file)
kubectl create configmap ecommerce-config \
  --namespace ecommerce \
  --from-literal=aws_region="$REGION" \
  --from-literal=redis_host="${REDIS_HOST:-placeholder-update-after-deploy}" \
  --from-literal=redis_port="6379" \
  --from-literal=sns_topic_arn="${SNS_TOPIC_ARN:-placeholder}" \
  --from-literal=internal_alb_dns="pending" \
  --from-literal=ses_from_email="$SES_EMAIL" \
  --dry-run=client -o yaml | kubectl apply -f -

# Backend services
for SVC in user-service product-service cart-service order-service payment-service notification-service; do
  kubectl apply -f "$K8S/services/$SVC/service.yaml"
  kubectl apply -f "$K8S/services/$SVC/deployment.yaml"
done
kubectl apply -f "$K8S/services/ingress-internal.yaml"

# Frontend
kubectl apply -f "$K8S/frontend/service.yaml"
kubectl apply -f "$K8S/frontend/deployment.yaml"
kubectl apply -f "$K8S/frontend/hpa.yaml"
kubectl apply -f "$K8S/frontend/ingress.yaml"

success "All manifests applied"

# =============================================================================
# PHASE 7 — Wait for rollout
# =============================================================================
header "Phase 7: Wait for pods"

for DEPLOY in user-service-deployment product-service-deployment \
              cart-service-deployment order-service-deployment \
              payment-service-deployment notification-service-deployment \
              frontend-deployment; do
  info "Waiting: $DEPLOY"
  kubectl rollout status deployment/"$DEPLOY" \
    --namespace ecommerce --timeout=300s && success "  $DEPLOY Ready" || \
    warn "  $DEPLOY timeout — run: kubectl describe deployment $DEPLOY -n ecommerce"
done

kubectl get pods -n ecommerce -o wide

# =============================================================================
# PHASE 8 — Wait for ALBs
# =============================================================================
header "Phase 8: Wait for ALBs"

wait_alb() {
  local INGRESS="$1" LABEL="$2"
  local DNS=""
  for i in $(seq 1 30); do
    DNS=$(kubectl get ingress "$INGRESS" -n ecommerce \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    [[ -n "$DNS" ]] && { echo "$DNS"; return; }
    echo -n "." ; sleep 10
  done
  echo ""
  warn "$LABEL ALB not provisioned in 5 min. Check ALB controller logs:"
  warn "  kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
  echo ""
}

info "Waiting for external ALB..."
EXT_ALB=$(wait_alb "frontend-external-ingress" "External")
[[ -n "$EXT_ALB" ]] && success "External ALB: $EXT_ALB"

info "Waiting for internal ALB..."
INT_ALB=$(wait_alb "services-internal-ingress" "Internal")
[[ -n "$INT_ALB" ]] && success "Internal ALB: $INT_ALB"

# Update ConfigMap with real internal ALB DNS
if [[ -n "$INT_ALB" ]]; then
  kubectl create configmap ecommerce-config --namespace ecommerce \
    --from-literal=aws_region="$REGION" \
    --from-literal=redis_host="${REDIS_HOST:-placeholder}" \
    --from-literal=redis_port="6379" \
    --from-literal=sns_topic_arn="${SNS_TOPIC_ARN:-placeholder}" \
    --from-literal=internal_alb_dns="$INT_ALB" \
    --from-literal=ses_from_email="$SES_EMAIL" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "ConfigMap updated with internal ALB DNS: $INT_ALB"

  # Store in SSM
  aws ssm put-parameter --name "/${PROJECT}/${ENV}/alb/internal-dns" \
    --value "$INT_ALB" --type String --overwrite --region "$REGION" 2>/dev/null || true
fi

# =============================================================================
# PHASE 9 — Verification
# =============================================================================
header "Phase 9: Full verification"

echo ""
echo -e "${BOLD}Pods:${NC}"
kubectl get pods -n ecommerce

echo ""
echo -e "${BOLD}Services (ClusterIP + ports):${NC}"
kubectl get services -n ecommerce

echo ""
echo -e "${BOLD}Ingresses (ALB DNS):${NC}"
kubectl get ingress -n ecommerce

echo ""
echo -e "${BOLD}Secrets (names only):${NC}"
kubectl get secrets -n ecommerce

echo ""
echo -e "${BOLD}ConfigMap values:${NC}"
kubectl get configmap ecommerce-config -n ecommerce -o jsonpath='{.data}' | \
  python3 -c "import sys,json; [print(f'  {k}: {v}') for k,v in json.load(sys.stdin).items()]" 2>/dev/null || \
  kubectl get configmap ecommerce-config -n ecommerce -o yaml | grep -A20 "^data:"

# ── Internal DNS test ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Internal DNS resolution test:${NC}"
kubectl run dns-test --image=busybox:1.35 --restart=Never --rm -it \
  -n ecommerce --command -- sh -c "
    for svc in user-service product-service cart-service order-service payment-service notification-service; do
      nslookup \${svc}.ecommerce.svc.cluster.local 2>/dev/null | grep -q 'Address' \
        && echo \"  DNS OK: \${svc}\" || echo \"  DNS FAIL: \${svc}\"
    done
  " 2>/dev/null || warn "DNS test pod could not run"

# ── Health endpoint test via port-forward ────────────────────────────────────
echo ""
echo -e "${BOLD}Service health checks (via port-forward):${NC}"

declare -A SVC_PORTS=([user-service]=4001 [product-service]=4002 [cart-service]=4003
                      [order-service]=4004 [payment-service]=4005 [notification-service]=4006)
PF_PIDS=()

for SVC in "${!SVC_PORTS[@]}"; do
  PORT="${SVC_PORTS[$SVC]}"
  kubectl port-forward "svc/$SVC" "${PORT}:${PORT}" -n ecommerce &>/dev/null &
  PF_PIDS+=($!)
done
sleep 8

for SVC in "${!SVC_PORTS[@]}"; do
  PORT="${SVC_PORTS[$SVC]}"
  STATUS=$(curl -sf --max-time 3 "http://localhost:${PORT}/health" 2>/dev/null | \
    python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "unreachable")
  [[ "$STATUS" == "ok" ]] && success "  $SVC: OK" || warn "  $SVC: $STATUS"
done

for PID in "${PF_PIDS[@]}"; do kill "$PID" 2>/dev/null || true; done

# ── External ALB test ─────────────────────────────────────────────────────────
if [[ -n "$EXT_ALB" ]]; then
  echo ""
  echo -e "${BOLD}External ALB test:${NC}"
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "http://$EXT_ALB" 2>/dev/null || echo "000")
  [[ "$HTTP" =~ ^(200|301|302)$ ]] && success "  External ALB: HTTP $HTTP" || \
    warn "  External ALB: HTTP $HTTP (may still be warming up)"
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   DEPLOYMENT COMPLETE                                 ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}External ALB:${NC}  ${EXT_ALB:-not yet assigned}"
echo -e "  ${BOLD}Internal ALB:${NC}  ${INT_ALB:-not yet assigned}"
echo ""
if [[ -n "$EXT_ALB" ]]; then
  echo -e "  ${BOLD}App URL:${NC}       http://$EXT_ALB"
else
  echo -e "  ${BOLD}Access app:${NC}    kubectl port-forward svc/frontend-service 3000:80 -n ecommerce"
  echo -e "                  Open: http://localhost:3000"
fi
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    kubectl get pods -n ecommerce"
echo -e "    kubectl logs -n ecommerce -l app=user-service --tail=30"
echo -e "    kubectl describe pod <pod> -n ecommerce"
echo -e "    kubectl get ingress -n ecommerce"
echo ""
