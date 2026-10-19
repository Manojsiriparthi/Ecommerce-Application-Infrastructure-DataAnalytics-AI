#!/usr/bin/env bash
# =============================================================================
# Terraform Apply Wrapper
# =============================================================================
# WHY THIS EXISTS:
#   The Helm provider (used by eks_addons) needs ~/.kube/config to exist
#   before Terraform initializes. On a fresh environment this file doesn't
#   exist yet because the EKS cluster hasn't been created.
#
#   Solution: Apply in two phases:
#     Phase 1: Apply everything EXCEPT eks_addons (creates EKS cluster)
#     Phase 2: Update kubeconfig (now cluster exists)
#     Phase 3: Apply eks_addons (Helm can now connect)
#
# USAGE:
#   ./06-Scripts/04-terraform-apply.sh prod us-east-1
#   ./06-Scripts/04-terraform-apply.sh dev ap-south-1
# =============================================================================

set -euo pipefail

ENV="${1:-prod}"
REGION="${2:-us-east-1}"
PROJECT="pip-project-ecommerce"
TF_DIR="01-Infrastructure/environments/${ENV}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

cd "$REPO_ROOT/$TF_DIR"

export TF_VAR_db_master_password="${TF_VAR_db_master_password:?Set TF_VAR_db_master_password}"
export TF_VAR_jwt_secret="${TF_VAR_jwt_secret:?Set TF_VAR_jwt_secret}"
export TF_VAR_internal_service_key="${TF_VAR_internal_service_key:?Set TF_VAR_internal_service_key}"
export TF_VAR_redis_auth_token="${TF_VAR_redis_auth_token:?Set TF_VAR_redis_auth_token}"

# ── Phase 1: Apply everything except eks_addons ───────────────────────────────
header "Phase 1: Apply infrastructure (EKS cluster + everything except Helm charts)"
info "This creates VPC, EKS cluster, Aurora, ElastiCache, WAF, etc."
info "eks_addons is excluded because Helm needs kubeconfig to exist first."

terraform apply \
  -var-file="${ENV}.tfvars" \
  -target=module.networking \
  -target=module.security \
  -target=module.iam \
  -target=module.eks \
  -target=module.iam_irsa \
  -target=module.compute \
  -target=module.messaging \
  -target=module.aurora \
  -target=module.elasticache \
  -target=module.waf \
  -target=module.route53_acm \
  -target=module.monitoring \
  -target=module.networking_dr \
  -target=module.iam_irsa_dr \
  -target=module.eks_dr \
  -auto-approve

success "Phase 1 complete — EKS cluster created"

# ── Phase 2: Update kubeconfig ────────────────────────────────────────────────
header "Phase 2: Update kubeconfig"
aws eks update-kubeconfig \
  --name "${PROJECT}-cluster" \
  --region "$REGION"

kubectl get nodes
success "kubeconfig updated — cluster is reachable"

# ── Phase 3: Apply eks_addons (Helm charts) ───────────────────────────────────
header "Phase 3: Apply Helm charts (LB controller, autoscaler, CSI driver, etc.)"
terraform apply \
  -var-file="${ENV}.tfvars" \
  -target=module.eks_addons \
  -auto-approve

success "Phase 3 complete — Helm charts installed"

# ── Phase 4: Apply remaining (anything left) ──────────────────────────────────
header "Phase 4: Final apply (catch any remaining resources)"
terraform apply \
  -var-file="${ENV}.tfvars" \
  -auto-approve

success "All infrastructure applied successfully"

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Setup databases: ./06-Scripts/01-setup-databases.sh ${ENV} ${REGION}"
echo "  2. Deploy app:      ./06-Scripts/02-deploy-app.sh"
echo ""
