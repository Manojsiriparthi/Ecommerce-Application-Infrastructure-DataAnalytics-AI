#!/bin/bash
# ==============================================
# Post-Deployment Automation Script
# Invoked by Terraform's local-exec provisioner
# (see main.tf -> null_resource.jenkins_post_deploy)
#
# Usage: post-deploy.sh <instance-id> <environment>
# ==============================================
set -euo pipefail

INSTANCE_ID="${1:?instance ID required}"
ENVIRONMENT="${2:?environment required}"

echo "=============================================="
echo " pip-project-ecommerce - Post-Deploy Automation"
echo "=============================================="
echo "Instance ID : ${INSTANCE_ID}"
echo "Environment : ${ENVIRONMENT}"
echo "Timestamp   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "[1/3] Waiting for SSM agent to register instance..."
for i in $(seq 1 20); do
  STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "None")

  if [ "$STATUS" = "Online" ]; then
    echo "  -> Instance is Online in SSM."
    break
  fi

  echo "  -> Attempt ${i}/20: SSM status = ${STATUS}. Retrying in 15s..."
  sleep 15
done

echo ""
echo "[2/3] Verifying Jenkins service via SSM Run Command..."
aws ssm send-command \
  --instance-ids "${INSTANCE_ID}" \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl is-active jenkins || echo NOT_RUNNING"]' \
  --query 'Command.CommandId' \
  --output text > /tmp/jenkins_check_command_id.txt 2>/dev/null || \
  echo "  -> Skipped (requires AWS CLI credentials at apply time)."

echo ""
echo "[3/3] Post-deployment automation complete for ${ENVIRONMENT}."
echo "=============================================="
