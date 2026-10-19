#!/usr/bin/env bash
# =============================================================================
# Pre-Apply Cleanup — remove "survivor" resources so a fresh apply is CLEAN
# =============================================================================
# WHY THIS EXISTS
#   Some AWS resources SURVIVE `terraform destroy` (either AWS keeps them by
#   design, or they were created outside state, or a destroy was interrupted).
#   On the next `terraform apply` they cause "already exists" errors that you
#   then have to fix by hand — exactly the manual toil we're eliminating.
#
#   The worst offender is CloudWatch Log Groups: AWS does NOT delete them on
#   destroy, so a re-apply hits ResourceAlreadyExistsException. This script
#   deletes them (and other known survivors) in BOTH regions so apply just
#   creates everything fresh. No imports.tf toggling needed.
#
# WHAT IT CLEANS (idempotent — "not found" is treated as success):
#   - CloudWatch Log Groups (primary + DR): /aws/vpc/flowlogs/*, /aws/eks/*,
#     /aws/cloudtrail/*, /aws/lambda/*, /aws/kinesisfirehose/*
#   - CloudWatch Logs query definitions matching the project
#   - Orphaned WAF/ALB logs S3 buckets (primary + DR) — emptied then deleted
#
# WHAT IT DOES **NOT** TOUCH (destructive / stateful — handled by Terraform):
#   - Aurora clusters, EKS clusters, VPCs, IAM roles.
#   For Aurora Global DB leftovers, see the guidance printed at the end.
#
# USAGE
#   ./06-Scripts/00-pre-apply-cleanup.sh                # cleans both regions
#   PRIMARY_REGION=us-east-1 DR_REGION=us-west-2 ./06-Scripts/00-pre-apply-cleanup.sh
#
#   Run this BEFORE ./06-Scripts/04-terraform-apply.sh whenever you are
#   re-applying after a destroy.
# =============================================================================

set -uo pipefail   # NOT -e: we want to continue past "not found" deletions

PROJECT="${PROJECT:-pip-project-ecommerce}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-us-west-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

# ── Delete every log group whose name starts with a known project prefix ──────
clean_log_groups() {
  local region="$1"
  header "CloudWatch Log Groups — $region"

  # All prefixes this project creates (from modules/security + modules/monitoring)
  local prefixes=(
    "/aws/vpc/flowlogs/${PROJECT}"
    "/aws/eks/${PROJECT}"
    "/aws/cloudtrail/${PROJECT}"
    "/aws/lambda/${PROJECT}"
    "/aws/kinesisfirehose/${PROJECT}"
  )

  for prefix in "${prefixes[@]}"; do
    # List every log group under the prefix and delete each one.
    local groups
    groups=$(aws logs describe-log-groups \
      --log-group-name-prefix "$prefix" \
      --region "$region" \
      --query "logGroups[].logGroupName" --output text 2>/dev/null || echo "")

    if [[ -z "$groups" || "$groups" == "None" ]]; then
      continue
    fi

    for lg in $groups; do
      if aws logs delete-log-group --log-group-name "$lg" --region "$region" 2>/dev/null; then
        success "  deleted log group: $lg"
      else
        warn "  could not delete (may already be gone): $lg"
      fi
    done
  done
  success "Log group cleanup done for $region"
}

# ── Delete CloudWatch Logs query definitions for this project ─────────────────
clean_query_definitions() {
  local region="$1"
  header "CloudWatch Logs Query Definitions — $region"

  local ids
  ids=$(aws logs describe-query-definitions \
    --region "$region" \
    --query "queryDefinitions[?starts_with(name, '${PROJECT}')].queryDefinitionId" \
    --output text 2>/dev/null || echo "")

  if [[ -z "$ids" || "$ids" == "None" ]]; then
    info "  none found"
    return
  fi

  for id in $ids; do
    if aws logs delete-query-definition --query-definition-id "$id" --region "$region" 2>/dev/null; then
      success "  deleted query definition: $id"
    else
      warn "  could not delete query definition: $id"
    fi
  done
}

# ── Empty + delete an orphaned logs S3 bucket (only if it exists) ─────────────
clean_logs_bucket() {
  local bucket="$1"
  # Does it exist and do we own it?
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    return
  fi
  warn "  found orphaned bucket: $bucket — emptying + deleting"

  # Delete all object versions + delete markers (bucket is versioned).
  aws s3api list-object-versions --bucket "$bucket" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
    | grep -q '"Key"' && \
    aws s3api delete-objects --bucket "$bucket" \
      --delete "$(aws s3api list-object-versions --bucket "$bucket" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null || true

  aws s3api list-object-versions --bucket "$bucket" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json 2>/dev/null \
    | grep -q '"Key"' && \
    aws s3api delete-objects --bucket "$bucket" \
      --delete "$(aws s3api list-object-versions --bucket "$bucket" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)" 2>/dev/null || true

  # Fallback: plain recursive remove for any non-versioned objects.
  aws s3 rm "s3://${bucket}" --recursive 2>/dev/null || true

  if aws s3api delete-bucket --bucket "$bucket" --region "$2" 2>/dev/null; then
    success "  deleted bucket: $bucket"
  else
    warn "  could not delete bucket (leave for Terraform): $bucket"
  fi
}

clean_buckets() {
  header "Orphaned logs S3 buckets"
  # Primary WAF bucket:  ${PROJECT}-logs-prod-<acct>
  # DR WAF bucket:       ${PROJECT}-logs-prod-dr-<acct>
  clean_logs_bucket "${PROJECT}-logs-prod-${ACCOUNT_ID}"    "$PRIMARY_REGION"
  clean_logs_bucket "${PROJECT}-logs-prod-dr-${ACCOUNT_ID}" "$DR_REGION"
}

# ── Run ───────────────────────────────────────────────────────────────────────
header "PRE-APPLY CLEANUP — account $ACCOUNT_ID"
info "Primary: $PRIMARY_REGION   DR: $DR_REGION   Project: $PROJECT"

clean_log_groups     "$PRIMARY_REGION"
clean_log_groups     "$DR_REGION"
clean_query_definitions "$PRIMARY_REGION"
clean_query_definitions "$DR_REGION"
clean_buckets

# ── Aurora Global DB guidance (NOT auto-deleted — too destructive) ────────────
header "Aurora Global Database — manual check (only if a destroy was interrupted)"
GLOBAL_ID="${PROJECT}-global-db"
if aws rds describe-global-clusters --global-cluster-identifier "$GLOBAL_ID" \
     --region "$PRIMARY_REGION" >/dev/null 2>&1; then
  warn "Global cluster '$GLOBAL_ID' still exists. A fresh apply will fail with"
  warn "'global cluster already exists'. If you intend a clean rebuild, detach"
  warn "its members and delete it FIRST (data loss — only if you accept it):"
  echo "    # 1. Remove members from the global cluster"
  echo "    aws rds remove-from-global-cluster --global-cluster-identifier $GLOBAL_ID \\"
  echo "        --db-cluster-identifier arn:aws:rds:${DR_REGION}:${ACCOUNT_ID}:cluster:${PROJECT}-cluster-dr --region $PRIMARY_REGION"
  echo "    aws rds remove-from-global-cluster --global-cluster-identifier $GLOBAL_ID \\"
  echo "        --db-cluster-identifier arn:aws:rds:${PRIMARY_REGION}:${ACCOUNT_ID}:cluster:${PROJECT}-cluster --region $PRIMARY_REGION"
  echo "    # 2. Delete the (now empty) global cluster"
  echo "    aws rds delete-global-cluster --global-cluster-identifier $GLOBAL_ID --region $PRIMARY_REGION"
else
  success "No leftover global cluster — clean."
fi

echo ""
success "Cleanup complete. Now run: ./06-Scripts/04-terraform-apply.sh prod $PRIMARY_REGION"
