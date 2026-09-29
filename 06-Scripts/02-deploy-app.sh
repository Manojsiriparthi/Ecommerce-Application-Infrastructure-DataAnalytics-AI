#!/usr/bin/env bash
# =============================================================================
# pip-project-ecommerce — Application Deploy / Destroy
# =============================================================================
# USAGE:
#   ./06-Scripts/02-deploy-app.sh              # interactive menu
#   ./06-Scripts/02-deploy-app.sh prod us-east-1
#
# The script asks:
#   1) Deploy   — build images (skip if already in ECR), push, deploy to EKS
#   2) Destroy  — delete pods + ALB ingresses cleanly BEFORE terraform destroy
#                 (prevents ENI/SG conflicts during infra destroy)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $1"; exit 1; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

# ── Args ─────────────────────────────────────────────────────────────────────
ENV="${1:-}"
REGION="${2:-}"
IMAGE_TAG="${3:-latest}"
PROJECT="pip-project-ecommerce"
CLUSTER_NAME="${PROJECT}-cluster"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
K8S="$REPO_ROOT/03-Kubernetes"

# ── Banner ───────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${GREEN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║   pip-project-ecommerce — App Manager             ║"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Ask environment if not provided ──────────────────────────────────────────
if [[ -z "$ENV" ]]; then
  echo -e "${YELLOW}Environment:${NC}"
  echo "  1) dev   (ap-south-1)"
  echo "  2) prod  (us-east-1)"
  echo -ne "Choice [1/2]: "
  read -r env_choice
  case "$env_choice" in
    1) ENV="dev";  REGION="ap-south-1" ;;
    2) ENV="prod"; REGION="us-east-1"  ;;
    *) fail "Invalid choice" ;;
  esac
fi

[[ -z "$REGION" ]] && REGION="${ENV == 'prod' ? 'us-east-1' : 'ap-south-1'}"

# ── Ask action ────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Action:${NC}"
echo "  1) Deploy   — build/push images → deploy to EKS"
echo "  2) Destroy  — delete pods + ALBs (run BEFORE terraform destroy)"
echo ""
echo -ne "Choice [1/2]: "
read -r action_choice

case "$action_choice" in
  1) ACTION="deploy"  ;;
  2) ACTION="destroy" ;;
  *) fail "Invalid choice" ;;
esac

echo ""
echo -e "${BOLD}Environment : $ENV${NC}"
echo -e "${BOLD}Region      : $REGION${NC}"
echo -e "${BOLD}Action      : $ACTION${NC}"
echo ""
echo -ne "Confirm? [y/N]: "
read -r confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Aborted."; exit 0; }

# ── Shared setup ─────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

ssm() {
  aws ssm get-parameter --name "/${PROJECT}/${ENV}/$1" \
    --region "$REGION" --query Parameter.Value --output text 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "deploy" ]]; then

  # ── Phase 1: kubectl connect ─────────────────────────────────────────────
  header "Phase 1: Connect kubectl"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
  NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
  [[ "$NODES" -eq 0 ]] && fail "No Ready nodes. Is EKS cluster up?"
  success "Connected — $NODES node(s) Ready"

  # ── Phase 2: ECR login ───────────────────────────────────────────────────
  header "Phase 2: ECR Login"
  aws ecr get-login-password --region "$REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
  success "ECR login OK"

  # ── Phase 3: Build images (skip if already in ECR) ──────────────────────
  header "Phase 3: Build & Push Images"

  SERVICES=()
  for d in "$REPO_ROOT/02-Application-Code/services"/*/; do
    [[ -f "${d}Dockerfile" ]] && SERVICES+=("$(basename "$d")")
  done
  SERVICES+=("frontend")

  for SVC in "${SERVICES[@]}"; do
    REPO="${PROJECT}/${SVC}"
    IMAGE="${ECR_REGISTRY}/${REPO}:${IMAGE_TAG}"

    # ── Check if image already exists in ECR ─────────────────────────────
    EXISTS=$(aws ecr describe-images \
      --repository-name "$REPO" \
      --image-ids imageTag="${IMAGE_TAG}" \
      --region "$REGION" \
      --query "imageDetails[0].imageTags[0]" \
      --output text 2>/dev/null || echo "")

    if [[ -n "$EXISTS" && "$EXISTS" != "None" ]]; then
      success "  SKIP build — image already in ECR: $REPO:$IMAGE_TAG"
      continue
    fi

    # ── Image not in ECR — build and push ────────────────────────────────
    info "  Building: $SVC"
    if [[ "$SVC" == "frontend" ]]; then
      SRC="$REPO_ROOT/02-Application-Code/frontend"
    else
      SRC="$REPO_ROOT/02-Application-Code/services/$SVC"
    fi

    docker build --pull -t "$IMAGE" "$SRC"

    # Create ECR repo if missing
    aws ecr create-repository \
      --repository-name "$REPO" \
      --image-scanning-configuration scanOnPush=true \
      --region "$REGION" 2>/dev/null || true

    docker push "$IMAGE"
    success "  Pushed: $SVC"
  done

  # ── Phase 4: Patch K8s placeholders ─────────────────────────────────────
  header "Phase 4: Patch K8s manifests"

  IRSA_ROLE_ARN=$(aws iam get-role \
    --role-name "${PROJECT}-services-role" \
    --query "Role.Arn" --output text 2>/dev/null || echo "")
  REDIS_HOST=$(ssm "redis/primary-endpoint")
  SNS_TOPIC=$(aws sns list-topics --region "$REGION" \
    --query "Topics[?contains(TopicArn,'${PROJECT}')].TopicArn|[0]" \
    --output text 2>/dev/null | tr -d '"' || echo "")
  WAF_ARN=$(ssm "waf/web-acl-arn")
  LOGS_BUCKET=$(ssm "s3/logs-bucket-name")
  SES_EMAIL=$(ssm "app/ses-from-email")
  SES_EMAIL="${SES_EMAIL:-noreply@ecommerce-pip.com}"

  PUB_IDS=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=${PROJECT}-public-*" \
              "Name=tag:Environment,Values=${ENV}" \
    --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' ',' || echo "")
  PRIV_IDS=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=${PROJECT}-private-*" \
              "Name=tag:Environment,Values=${ENV}" \
    --query "Subnets[*].SubnetId" --output text --region "$REGION" | tr '\t' ',' || echo "")

  PUB1=$(echo "$PUB_IDS"  | cut -d, -f1)
  PUB2=$(echo "$PUB_IDS"  | cut -d, -f2)
  PUB3=$(echo "$PUB_IDS"  | cut -d, -f3)
  PRIV1=$(echo "$PRIV_IDS" | cut -d, -f1)
  PRIV2=$(echo "$PRIV_IDS" | cut -d, -f2)
  PRIV3=$(echo "$PRIV_IDS" | cut -d, -f3)

  # Patch image tags in all deployments
  for SVC in "${SERVICES[@]}"; do
    [[ "$SVC" == "frontend" ]] && \
      DEPLOY="$K8S/frontend/deployment.yaml" || \
      DEPLOY="$K8S/services/$SVC/deployment.yaml"
    [[ -f "$DEPLOY" ]] || continue
    IMAGE="${ECR_REGISTRY}/${PROJECT}/${SVC}:${IMAGE_TAG}"
    sed -i "s|<AWS_ACCOUNT_ID>|${AWS_ACCOUNT_ID}|g" "$DEPLOY"
    sed -i "s|<AWS_REGION>|${REGION}|g"              "$DEPLOY"
    sed -i "s|image:.*${PROJECT}/${SVC}:.*|image: ${IMAGE}|g" "$DEPLOY"
  done

  # Patch ServiceAccount IRSA
  [[ -n "$IRSA_ROLE_ARN" ]] && \
    sed -i "s|<IRSA_ROLE_ARN>|${IRSA_ROLE_ARN}|g" \
      "$K8S/secrets/serviceaccount.yaml" 2>/dev/null || true

  # Patch external ingress
  EI="$K8S/frontend/ingress.yaml"
  [[ -n "$WAF_ARN"     ]] && sed -i "s|<WAF_WEBACL_ARN>|${WAF_ARN}|g"         "$EI"
  [[ -n "$LOGS_BUCKET" ]] && sed -i "s|<LOGS_BUCKET_NAME>|${LOGS_BUCKET}|g"   "$EI"
  [[ -n "$PUB1" ]] && sed -i "s|<PUBLIC_SUBNET_ID_1>|${PUB1}|g" "$EI"
  [[ -n "$PUB2" ]] && sed -i "s|<PUBLIC_SUBNET_ID_2>|${PUB2}|g" "$EI"
  [[ -n "$PUB3" ]] && sed -i "s|<PUBLIC_SUBNET_ID_3>|${PUB3}|g" "$EI"

  # Patch internal ingress
  II="$K8S/services/ingress-internal.yaml"
  [[ -n "$LOGS_BUCKET" ]] && sed -i "s|<LOGS_BUCKET_NAME>|${LOGS_BUCKET}|g"   "$II"
  [[ -n "$PRIV1" ]] && sed -i "s|<PRIVATE_SUBNET_ID_1>|${PRIV1}|g" "$II"
  [[ -n "$PRIV2" ]] && sed -i "s|<PRIVATE_SUBNET_ID_2>|${PRIV2}|g" "$II"
  [[ -n "$PRIV3" ]] && sed -i "s|<PRIVATE_SUBNET_ID_3>|${PRIV3}|g" "$II"

  # Fix SecretProviderClass env path (dev → prod)
  sed -i "s|/dev/db/|/prod/db/|g;s|/dev/app/|/prod/app/|g;s|/dev/redis/|/prod/redis/|g" \
    "$K8S/secrets/secretproviderclass-db.yaml" 2>/dev/null || true

  success "All placeholders patched"

  # ── Phase 5: Deploy to EKS ───────────────────────────────────────────────
  header "Phase 5: Deploy to EKS"

  kubectl apply -f "$K8S/namespace.yaml"
  kubectl apply -f "$K8S/secrets/serviceaccount.yaml"
  kubectl apply -f "$K8S/secrets/secretproviderclass-db.yaml"

  # ConfigMap with real values
  kubectl create configmap ecommerce-config \
    --namespace ecommerce \
    --from-literal=aws_region="$REGION" \
    --from-literal=redis_host="${REDIS_HOST:-placeholder}" \
    --from-literal=redis_port="6379" \
    --from-literal=sns_topic_arn="${SNS_TOPIC:-placeholder}" \
    --from-literal=internal_alb_dns="pending" \
    --from-literal=ses_from_email="$SES_EMAIL" \
    --dry-run=client -o yaml | kubectl apply -f -

  # Backend services
  for SVC in user-service product-service cart-service \
             order-service payment-service notification-service; do
    kubectl apply -f "$K8S/services/$SVC/service.yaml"
    kubectl apply -f "$K8S/services/$SVC/deployment.yaml"
  done
  kubectl apply -f "$K8S/services/ingress-internal.yaml"

  # Frontend
  kubectl apply -f "$K8S/frontend/service.yaml"
  kubectl apply -f "$K8S/frontend/deployment.yaml"
  kubectl apply -f "$K8S/frontend/hpa.yaml" 2>/dev/null || true
  kubectl apply -f "$K8S/frontend/ingress.yaml"

  success "All manifests applied"

  # ── Phase 6: Wait for pods ───────────────────────────────────────────────
  header "Phase 6: Wait for pods"
  for DEPLOY in user-service-deployment product-service-deployment \
                cart-service-deployment order-service-deployment \
                payment-service-deployment notification-service-deployment \
                frontend-deployment; do
    kubectl rollout status deployment/"$DEPLOY" \
      --namespace ecommerce --timeout=300s \
      && success "  $DEPLOY Ready" \
      || warn "  $DEPLOY timeout — check: kubectl describe deployment $DEPLOY -n ecommerce"
  done

  # ── Phase 7: Wait for ALBs ───────────────────────────────────────────────
  header "Phase 7: Wait for ALBs"
  wait_alb() {
    local NAME="$1" DNS=""
    for i in $(seq 1 30); do
      DNS=$(kubectl get ingress "$NAME" -n ecommerce \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
      [[ -n "$DNS" ]] && { echo "$DNS"; return; }
      echo -n "."; sleep 10
    done; echo ""
  }

  EXT_ALB=$(wait_alb "frontend-external-ingress")
  INT_ALB=$(wait_alb "services-internal-ingress")
  [[ -n "$EXT_ALB" ]] && success "External ALB: $EXT_ALB"
  [[ -n "$INT_ALB" ]] && success "Internal ALB: $INT_ALB"

  # Update ConfigMap with real internal ALB — with http:// prefix for Next.js rewrites
  if [[ -n "$INT_ALB" ]]; then
    kubectl create configmap ecommerce-config --namespace ecommerce \
      --from-literal=aws_region="$REGION" \
      --from-literal=redis_host="${REDIS_HOST:-placeholder}" \
      --from-literal=redis_port="6379" \
      --from-literal=sns_topic_arn="${SNS_TOPIC:-placeholder}" \
      --from-literal=internal_alb_dns="http://$INT_ALB" \
      --from-literal=ses_from_email="$SES_EMAIL" \
      --dry-run=client -o yaml | kubectl apply -f -

    aws ssm put-parameter \
      --name "/${PROJECT}/${ENV}/alb/internal-dns" \
      --value "$INT_ALB" --type String --overwrite \
      --region "$REGION" 2>/dev/null || true
  fi

  # ── Phase 8: Verify ──────────────────────────────────────────────────────
  header "Phase 8: Verify"
  echo ""
  echo -e "${BOLD}Pods:${NC}"
  kubectl get pods -n ecommerce

  echo ""
  echo -e "${BOLD}Ingresses:${NC}"
  kubectl get ingress -n ecommerce

  echo ""
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║   DEPLOYMENT COMPLETE                ║${NC}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════╝${NC}"
  echo ""
  [[ -n "$EXT_ALB" ]] && echo -e "  App URL: ${CYAN}http://$EXT_ALB${NC}" || \
    echo -e "  Access:  kubectl port-forward svc/frontend-service 3000:80 -n ecommerce"
  echo ""

fi

# ─────────────────────────────────────────────────────────────────────────────
# DESTROY  — clean up app BEFORE terraform destroy
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "destroy" ]]; then

  header "App Destroy — cleaning up before terraform destroy"
  echo ""
  echo -e "${RED}WHY run this before terraform destroy:${NC}"
  echo "  ALBs create network interfaces (ENIs) inside your VPC."
  echo "  If you run terraform destroy without deleting the ALBs first,"
  echo "  the VPC/subnets/SGs hang because ENIs still exist."
  echo "  This step deletes the ALBs cleanly so terraform destroy completes fast."
  echo ""
  echo -ne "${YELLOW}Confirm destroy app in ${ENV}? [y/N]: ${NC}"
  read -r final_confirm
  [[ "$final_confirm" != "y" && "$final_confirm" != "Y" ]] && { echo "Aborted."; exit 0; }

  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null || \
    warn "Could not update kubeconfig — continuing anyway"

  # Step 1: Delete Ingresses first — this tells ALB controller to delete the ALBs
  echo ""
  info "Step 1: Deleting Ingresses (triggers ALB deletion in AWS)..."
  kubectl delete ingress --all -n ecommerce --timeout=120s 2>/dev/null || true
  kubectl delete ingress --all -n default --timeout=60s   2>/dev/null || true
  echo "Waiting 60s for ALBs to be deleted by AWS..."
  sleep 60

  # Step 2: Delete all application pods
  info "Step 2: Deleting all application pods..."
  kubectl delete deployment --all -n ecommerce --timeout=120s 2>/dev/null || true
  kubectl delete service --all -n ecommerce    --timeout=60s  2>/dev/null || true

  # Step 3: Delete namespace (removes everything remaining in ecommerce ns)
  info "Step 3: Deleting ecommerce namespace..."
  kubectl delete namespace ecommerce --timeout=120s 2>/dev/null || true

  # Step 4: Delete any leftover ENIs from ALB in this VPC
  info "Step 4: Checking for leftover ENIs..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=${PROJECT}-vpc" \
    --region "$REGION" \
    --query "Vpcs[0].VpcId" --output text 2>/dev/null || echo "")

  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]]; then
    ENI_IDS=$(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=status,Values=available" \
      --query "NetworkInterfaces[*].NetworkInterfaceId" \
      --output text --region "$REGION" 2>/dev/null || echo "")

    if [[ -n "$ENI_IDS" ]]; then
      for ENI in $ENI_IDS; do
        aws ec2 delete-network-interface \
          --network-interface-id "$ENI" \
          --region "$REGION" 2>/dev/null && info "  Deleted ENI: $ENI" || true
      done
    else
      success "  No leftover ENIs found"
    fi
  fi

  echo ""
  echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${GREEN}║   APP DESTROYED — safe to run terraform destroy ║${NC}"
  echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "Now run:"
  echo -e "  ${CYAN}cd 01-Infrastructure/environments/${ENV}${NC}"
  echo -e "  ${CYAN}terraform destroy -var-file=${ENV}.tfvars${NC}"
  echo ""

fi
