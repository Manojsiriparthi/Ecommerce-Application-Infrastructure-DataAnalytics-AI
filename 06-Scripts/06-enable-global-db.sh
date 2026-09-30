#!/usr/bin/env bash
# =============================================================================
# Enable Aurora Global Database — in-place conversion (no data loss)
# =============================================================================
# WHY THIS SCRIPT (not Terraform):
#   AWS does not allow attaching an EXISTING standalone Aurora cluster to a
#   Global Database via Terraform. But the AWS CLI CAN wrap an existing cluster
#   in-place using create-global-cluster --source-db-cluster-identifier.
#   This converts the running primary with ZERO downtime and ZERO data loss,
#   then adds a read-only secondary in the DR region.
#
# WHAT IT DOES:
#   1. Wrap the existing primary (us-east-1) into a new Global Database
#   2. Create a secondary cluster in the DR region (us-west-2) that replicates
#   3. Add a reader instance to the secondary
#   4. Store DR DATABASE_URLs in us-west-2 SSM
#
# PREREQUISITES:
#   - Primary Aurora cluster is running (pip-project-ecommerce-cluster)
#   - DR networking exists (module.networking_dr applied) — DB subnet group + SG
#   - Run AFTER terraform apply has created the DR VPC/subnets
#
# USAGE:
#   ./06-Scripts/06-enable-global-db.sh
# =============================================================================

set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[GDB]${NC}  $1"; }
success() { echo -e "${GREEN}[GDB]${NC}  ✓ $1"; }
warn()    { echo -e "${YELLOW}[GDB]${NC}  ⚠ $1"; }
fail()    { echo -e "${RED}[GDB]${NC}  ✗ $1"; exit 1; }

PROJECT="pip-project-ecommerce"
PRIMARY_REGION="us-east-1"
DR_REGION="us-west-2"
GLOBAL_ID="${PROJECT}-global-db"
PRIMARY_CLUSTER="${PROJECT}-cluster"
DR_CLUSTER="${PROJECT}-cluster-dr"
ENGINE_VERSION="17.9"
INSTANCE_CLASS="db.r6g.large"
DB_USER="pipadmin"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo -e "${BOLD}══ Enable Aurora Global Database (in-place, no data loss) ══${NC}"
echo ""

# ── Step 1: Verify primary is available ──────────────────────────────────────
info "Checking primary cluster status..."
STATUS=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$PRIMARY_CLUSTER" \
  --region "$PRIMARY_REGION" \
  --query "DBClusters[0].Status" --output text 2>/dev/null || echo "")
[[ "$STATUS" != "available" ]] && fail "Primary cluster not available (status: $STATUS)"
success "Primary cluster available"

PRIMARY_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$PRIMARY_CLUSTER" \
  --region "$PRIMARY_REGION" \
  --query "DBClusters[0].DBClusterArn" --output text)
info "Primary ARN: $PRIMARY_ARN"

# ── Step 2: Create Global Database wrapping the existing primary ─────────────
EXISTING_GLOBAL=$(aws rds describe-global-clusters \
  --global-cluster-identifier "$GLOBAL_ID" \
  --region "$PRIMARY_REGION" \
  --query "GlobalClusters[0].GlobalClusterIdentifier" --output text 2>/dev/null || echo "")

if [[ "$EXISTING_GLOBAL" == "$GLOBAL_ID" ]]; then
  warn "Global cluster $GLOBAL_ID already exists — skipping create"
else
  info "Creating Global Database from existing primary (in-place)..."
  aws rds create-global-cluster \
    --global-cluster-identifier "$GLOBAL_ID" \
    --source-db-cluster-identifier "$PRIMARY_ARN" \
    --region "$PRIMARY_REGION" >/dev/null \
    && success "Global cluster created, primary attached in-place" \
    || fail "create-global-cluster failed"

  info "Waiting for global cluster to be available..."
  for i in $(seq 1 30); do
    GS=$(aws rds describe-global-clusters \
      --global-cluster-identifier "$GLOBAL_ID" \
      --region "$PRIMARY_REGION" \
      --query "GlobalClusters[0].Status" --output text 2>/dev/null || echo "")
    [[ "$GS" == "available" ]] && break
    echo "  [$i/30] status=$GS ..."; sleep 20
  done
  success "Global cluster available"
fi

# ── Step 3: Get DR networking (subnet group + SG) ────────────────────────────
info "Looking up DR DB subnet group + security group..."
DR_SUBNET_GROUP=$(aws rds describe-db-subnet-groups \
  --region "$DR_REGION" \
  --query "DBSubnetGroups[?contains(DBSubnetGroupName,'${PROJECT}')].DBSubnetGroupName | [0]" \
  --output text 2>/dev/null | tr -d '"' || echo "")
[[ -z "$DR_SUBNET_GROUP" || "$DR_SUBNET_GROUP" == "None" ]] && \
  fail "DR DB subnet group not found. Run terraform apply for networking_dr first."

DR_SG=$(aws ec2 describe-security-groups \
  --region "$DR_REGION" \
  --filters "Name=group-name,Values=${PROJECT}-aurora-sg" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "")
[[ -z "$DR_SG" || "$DR_SG" == "None" ]] && fail "DR Aurora SG not found."

# DR KMS key (created by terraform aws_kms_key.dr_aurora, alias set)
DR_KMS=$(aws kms describe-key \
  --key-id "alias/${PROJECT}-aurora-dr" \
  --region "$DR_REGION" \
  --query "KeyMetadata.Arn" --output text 2>/dev/null || echo "")

info "DR subnet group: $DR_SUBNET_GROUP"
info "DR SG: $DR_SG"
info "DR KMS: ${DR_KMS:-<will use default>}"

# ── Step 4: Create secondary cluster in DR region ────────────────────────────
EXISTING_DR=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$DR_CLUSTER" \
  --region "$DR_REGION" \
  --query "DBClusters[0].DBClusterIdentifier" --output text 2>/dev/null || echo "")

if [[ "$EXISTING_DR" == "$DR_CLUSTER" ]]; then
  warn "DR cluster $DR_CLUSTER already exists — skipping create"
else
  info "Creating DR secondary cluster (joins global cluster)..."
  # NOTE: secondary in a global cluster does NOT take master username/password —
  # it inherits from the primary. That was the error in Terraform.
  KMS_ARG=""
  [[ -n "$DR_KMS" && "$DR_KMS" != "None" ]] && KMS_ARG="--kms-key-id $DR_KMS"

  aws rds create-db-cluster \
    --db-cluster-identifier "$DR_CLUSTER" \
    --engine aurora-postgresql \
    --engine-version "$ENGINE_VERSION" \
    --global-cluster-identifier "$GLOBAL_ID" \
    --db-subnet-group-name "$DR_SUBNET_GROUP" \
    --vpc-security-group-ids "$DR_SG" \
    --storage-encrypted $KMS_ARG \
    --region "$DR_REGION" >/dev/null \
    && success "DR secondary cluster created" \
    || fail "create-db-cluster (secondary) failed"
fi

# ── Step 5: Add reader instance to secondary ─────────────────────────────────
EXISTING_INST=$(aws rds describe-db-instances \
  --region "$DR_REGION" \
  --query "DBInstances[?DBClusterIdentifier=='${DR_CLUSTER}'].DBInstanceIdentifier | [0]" \
  --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_INST" && "$EXISTING_INST" != "None" ]]; then
  warn "DR reader instance already exists ($EXISTING_INST) — skipping"
else
  info "Adding reader instance to DR secondary..."
  aws rds create-db-instance \
    --db-instance-identifier "${DR_CLUSTER}-reader-1" \
    --db-cluster-identifier "$DR_CLUSTER" \
    --engine aurora-postgresql \
    --db-instance-class "$INSTANCE_CLASS" \
    --region "$DR_REGION" >/dev/null \
    && success "DR reader instance creating (takes ~10 min)" \
    || warn "create-db-instance failed — check manually"
fi

# ── Step 6: Wait for DR cluster available, then store DR SSM URLs ────────────
info "Waiting for DR cluster to be available (~10 min)..."
for i in $(seq 1 40); do
  DS=$(aws rds describe-db-clusters \
    --db-cluster-identifier "$DR_CLUSTER" \
    --region "$DR_REGION" \
    --query "DBClusters[0].Status" --output text 2>/dev/null || echo "")
  [[ "$DS" == "available" ]] && break
  echo "  [$i/40] DR status=$DS ..."; sleep 30
done

DR_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier "$DR_CLUSTER" \
  --region "$DR_REGION" \
  --query "DBClusters[0].Endpoint" --output text 2>/dev/null || echo "")

if [[ -n "$DR_ENDPOINT" && "$DR_ENDPOINT" != "None" ]]; then
  success "DR cluster endpoint: $DR_ENDPOINT"

  # Read the master password from Secrets Manager (same as primary)
  DB_PASS=$(aws secretsmanager get-secret-value \
    --secret-id "${PROJECT}-db-credentials" \
    --region "$PRIMARY_REGION" \
    --query SecretString --output text | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")

  ENC_PASS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote('$DB_PASS', safe=''))")

  info "Storing DR DATABASE_URLs in us-west-2 SSM..."
  for SVC in user product cart order payment; do
    aws ssm put-parameter \
      --region "$DR_REGION" \
      --name "/${PROJECT}/prod/db/${SVC}-url" \
      --value "postgresql://${DB_USER}:${ENC_PASS}@${DR_ENDPOINT}:5432/${SVC}_db?sslmode=require" \
      --type SecureString --overwrite >/dev/null \
      && info "  stored: ${SVC}-url" || warn "  failed: ${SVC}-url"
  done
  success "DR DATABASE_URLs stored"
else
  warn "DR endpoint not ready yet — re-run this script or store SSM URLs manually later"
fi

echo ""
success "Global Database setup complete"
echo ""
echo "  Global cluster: $GLOBAL_ID"
echo "  Primary:        $PRIMARY_CLUSTER (us-east-1, writable)"
echo "  Secondary:      $DR_CLUSTER (us-west-2, read-only replica)"
echo ""
echo "  Replication lag: aws rds describe-global-clusters --global-cluster-identifier $GLOBAL_ID --region us-east-1"
