#!/usr/bin/env bash
# =============================================================================
# Script 3 — Manual EBS Snapshot
# =============================================================================
# Takes EBS snapshots of all volumes tagged with Backup=true
# (Bastion + Jenkins EC2 instances)
#
# The DLM lifecycle policy (Terraform monitoring module) handles daily
# automated snapshots. Use this script for on-demand snapshots before:
#   - Terraform apply that changes EC2 instances
#   - OS patching
#   - Before terraform destroy (to preserve Jenkins config)
#
# USAGE:
#   chmod +x 06-Scripts/03-ebs-snapshot.sh
#   ./06-Scripts/03-ebs-snapshot.sh prod us-east-1
# =============================================================================

set -euo pipefail

ENV="${1:-prod}"
REGION="${2:-us-east-1}"
PROJECT="pip-project-ecommerce"
TIMESTAMP=$(date +%Y-%m-%d-%H%M)

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }

echo "Starting EBS snapshots — $PROJECT $ENV $REGION"

# Find all volumes tagged with Backup=true for this project
VOLUME_IDS=$(aws ec2 describe-volumes \
  --filters \
    "Name=tag:Backup,Values=true" \
    "Name=tag:Project,Values=$PROJECT" \
  --region "$REGION" \
  --query "Volumes[*].VolumeId" \
  --output text)

if [[ -z "$VOLUME_IDS" ]]; then
  info "No volumes with Backup=true tag found in $REGION"
  info "Trying by instance name tag..."
  
  # Fallback: find volumes attached to Jenkins/Bastion instances
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Name,Values=${PROJECT}-jenkins,${PROJECT}-bastion" \
      "Name=instance-state-name,Values=running,stopped" \
    --region "$REGION" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text)

  if [[ -z "$INSTANCE_IDS" ]]; then
    echo "No Jenkins/Bastion instances found in $REGION. Nothing to snapshot."
    exit 0
  fi

  VOLUME_IDS=$(aws ec2 describe-volumes \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_IDS" \
    --region "$REGION" \
    --query "Volumes[*].VolumeId" \
    --output text)
fi

if [[ -z "$VOLUME_IDS" ]]; then
  echo "No EBS volumes found to snapshot."
  exit 0
fi

# Take snapshot of each volume
for VOL_ID in $VOLUME_IDS; do
  # Get volume name tag
  VOL_NAME=$(aws ec2 describe-volumes \
    --volume-ids "$VOL_ID" \
    --region "$REGION" \
    --query "Volumes[0].Tags[?Key=='Name'].Value | [0]" \
    --output text 2>/dev/null || echo "unnamed")

  info "Snapshotting: $VOL_ID ($VOL_NAME)"

  SNAP_ID=$(aws ec2 create-snapshot \
    --volume-id "$VOL_ID" \
    --description "${PROJECT}-${ENV}-manual-${TIMESTAMP}" \
    --tag-specifications "ResourceType=snapshot,Tags=[
      {Key=Name,Value=${PROJECT}-${ENV}-${VOL_NAME}-${TIMESTAMP}},
      {Key=Project,Value=${PROJECT}},
      {Key=Environment,Value=${ENV}},
      {Key=SnapshotType,Value=manual},
      {Key=CreatedBy,Value=03-ebs-snapshot.sh}
    ]" \
    --region "$REGION" \
    --query "SnapshotId" \
    --output text)

  success "Created snapshot: $SNAP_ID for volume $VOL_ID"
done

echo ""
echo "All snapshots initiated. Check status:"
echo "  aws ec2 describe-snapshots --owner-ids self --region $REGION --query \"Snapshots[?contains(Description,'$PROJECT')].{ID:SnapshotId,State:State,Progress:Progress}\" --output table"
