#!/usr/bin/env bash
# =============================================================================
# 07-Lambda — Deploy / Test / Destroy all Lambda functions
# =============================================================================
# USAGE:
#   ./07-Lambda/deploy.sh prod us-east-1 deploy    # deploy all
#   ./07-Lambda/deploy.sh prod us-east-1 test      # test invoke each
#   ./07-Lambda/deploy.sh prod us-east-1 destroy   # remove all
#   ./07-Lambda/deploy.sh prod us-east-1 deploy secrets-rotation  # one only
#
# LAMBDAS:
#   1. pip-project-ecommerce-secrets-rotation
#      Schedule: cron(0 2 1 * ? *)  — 1st of month 02:00 UTC
#   2. pip-project-ecommerce-ebs-backup
#      Schedule: cron(0 12 * * ? *) — daily 12:00 UTC (5:30 PM IST)
#   3. pip-project-ecommerce-sns-to-slack
#      Trigger:  SNS subscription (set Slack webhook after deploy)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[LAMBDA]${NC}  $1"; }
success() { echo -e "${GREEN}[LAMBDA]${NC}  ✓ $1"; }
warn()    { echo -e "${YELLOW}[LAMBDA]${NC}  ⚠ $1"; }
fail()    { echo -e "${RED}[LAMBDA]${NC}  ✗ $1"; exit 1; }
header()  { echo -e "\n${BOLD}══ $1 ══${NC}"; }

ENV="${1:-prod}"
REGION="${2:-us-east-1}"
ACTION="${3:-deploy}"
ONLY="${4:-all}"     # optional: deploy only one lambda
PROJECT="pip-project-ecommerce"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "\n${BOLD}  pip-project-ecommerce — Lambda Manager${NC}"
echo "  Env=$ENV | Region=$REGION | Account=$ACCOUNT_ID | Action=$ACTION"
echo ""

# SNS topic
SNS_ARN=$(aws sns list-topics --region "$REGION" \
  --query "Topics[?contains(TopicArn,'${PROJECT}')].TopicArn|[0]" \
  --output text 2>/dev/null | tr -d '"' || echo "")
[[ -z "$SNS_ARN" || "$SNS_ARN" == "None" ]] && SNS_ARN="" && \
  warn "SNS topic not found — set SNS_TOPIC_ARN manually in Lambda config"

# =============================================================================
# Lambda configuration table
# =============================================================================
# Each Lambda: dir, function name, timeout, memory, schedule, test payload
LAMBDAS=(
  "secrets-rotation:${PROJECT}-secrets-rotation:900:256:cron(0 2 1 * ? *):{\"rotate\":\"all\"}"
  "ebs-snapshot-backup:${PROJECT}-ebs-backup:300:256:cron(0 12 * * ? *):{\"dry_run\":false}"
  "sns-to-slack:${PROJECT}-sns-to-slack:30:128:none:{}"
)

get_env_vars() {
  case "$1" in
    "secrets-rotation")
      echo "Variables={PROJECT_NAME=${PROJECT},ENVIRONMENT=${ENV},REGION=${REGION},SNS_TOPIC_ARN=${SNS_ARN},KMS_KEY_ALIAS=alias/${PROJECT}-kms,DB_CLUSTER_ID=${PROJECT}-cluster,DB_SECRET_NAME=${PROJECT}-db-credentials,DB_USERNAME=pipadmin}"
      ;;
    "ebs-snapshot-backup")
      echo "Variables={PROJECT_NAME=${PROJECT},ENVIRONMENT=${ENV},REGION=${REGION},CLUSTER_NAME=${PROJECT}-cluster,RETENTION_DAYS=7,SNS_TOPIC_ARN=${SNS_ARN},KMS_KEY_ALIAS=alias/${PROJECT}-kms}"
      ;;
    "sns-to-slack")
      echo "Variables={PROJECT_NAME=${PROJECT},ENVIRONMENT=${ENV},SLACK_CHANNEL=#alerts-prod,SLACK_WEBHOOK_URL=,PAGERDUTY_ROUTING_KEY=}"
      ;;
  esac
}

ensure_role() {
  local ROLE="$1" POLICY="$2"
  if aws iam get-role --role-name "$ROLE" --query "Role.Arn" \
      --output text 2>/dev/null | grep -q "arn:aws"; then
    aws iam get-role --role-name "$ROLE" --query "Role.Arn" --output text
    return
  fi
  info "  Creating IAM role: $ROLE"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' \
    --tags Key=Project,Value="${PROJECT}" Key=Environment,Value="${ENV}" \
    --region "$REGION" --query "Role.Arn" --output text
  [[ -f "$POLICY" ]] && aws iam put-role-policy \
    --role-name "$ROLE" --policy-name "${ROLE}-policy" \
    --policy-document "file://$POLICY" --region "$REGION"
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
    --region "$REGION" 2>/dev/null || true
  info "  Waiting 15s for IAM role to propagate..."
  sleep 15
  echo "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}"
}

package_lambda() {
  local DIR="$1" ZIP="$1/deployment.zip"
  info "  Packaging lambda_function.py..."
  (cd "$DIR" && zip -q -j "$ZIP" lambda_function.py)
  success "  Packaged: $(du -sh "$ZIP" | cut -f1)"
  echo "$ZIP"
}

create_eventbridge_rule() {
  local RULE_NAME="$1" SCHEDULE="$2" LAMBDA_ARN="$3" INPUT="$4"
  [[ "$SCHEDULE" == "none" ]] && return
  info "  EventBridge rule: $RULE_NAME ($SCHEDULE)"
  aws events put-rule \
    --name "$RULE_NAME" --schedule-expression "$SCHEDULE" \
    --state ENABLED --region "$REGION" >/dev/null
  aws events put-targets \
    --rule "$RULE_NAME" --region "$REGION" \
    --targets "[{\"Id\":\"LambdaTarget\",\"Arn\":\"${LAMBDA_ARN}\",\"Input\":\"${INPUT}\"}]" >/dev/null
  aws lambda add-permission \
    --function-name "$LAMBDA_ARN" \
    --statement-id "EB-${RULE_NAME}" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${RULE_NAME}" \
    --region "$REGION" 2>/dev/null || true
  success "  EventBridge rule created"
}

log_group() {
  local FN="$1"
  aws logs create-log-group \
    --log-group-name "/aws/lambda/${FN}" --region "$REGION" 2>/dev/null || true
  aws logs put-retention-policy \
    --log-group-name "/aws/lambda/${FN}" \
    --retention-in-days 30 --region "$REGION" 2>/dev/null || true
}

# =============================================================================
# DEPLOY ACTION
# =============================================================================
if [[ "$ACTION" == "deploy" ]]; then

  for ENTRY in "${LAMBDAS[@]}"; do
    IFS=':' read -r DIR_KEY FN TIMEOUT MEMORY SCHEDULE TEST_PAYLOAD <<< "$ENTRY"
    [[ "$ONLY" != "all" && "$ONLY" != "$DIR_KEY" ]] && continue

    header "Deploying: $FN"
    DIR="$SCRIPT_DIR/$DIR_KEY"
    ROLE_NAME="${FN}-role"
    POLICY="$DIR/iam-policy.json"

    # IAM role
    info "Step 1/5: IAM role"
    ROLE_ARN=$(ensure_role "$ROLE_NAME" "$POLICY")
    success "  Role: $ROLE_ARN"

    # Package
    info "Step 2/5: Package"
    ZIP=$(package_lambda "$DIR")

    # Deploy / update
    info "Step 3/5: Lambda function"
    ENV_VARS=$(get_env_vars "$DIR_KEY")

    if aws lambda get-function --function-name "$FN" \
        --region "$REGION" >/dev/null 2>&1; then
      info "  Updating existing Lambda..."
      aws lambda update-function-code \
        --function-name "$FN" --zip-file "fileb://$ZIP" \
        --region "$REGION" >/dev/null
      sleep 8   # wait for update to complete
      aws lambda update-function-configuration \
        --function-name "$FN" \
        --timeout "$TIMEOUT" --memory-size "$MEMORY" \
        --environment "$ENV_VARS" \
        --region "$REGION" >/dev/null
    else
      info "  Creating Lambda..."
      aws lambda create-function \
        --function-name "$FN" \
        --description "$(grep -A1 '"Description"' "$DIR/eventbridge-rule.json" 2>/dev/null | tail -1 | tr -d '",' | xargs || echo "$FN")" \
        --runtime python3.12 \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file "fileb://$ZIP" \
        --timeout "$TIMEOUT" \
        --memory-size "$MEMORY" \
        --environment "$ENV_VARS" \
        --region "$REGION" >/dev/null
    fi
    success "  Lambda deployed: $FN"

    # CloudWatch Logs
    info "Step 4/5: Log group (30-day retention)"
    log_group "$FN"
    success "  Log group: /aws/lambda/$FN"

    # EventBridge
    info "Step 5/5: EventBridge schedule"
    LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FN}"
    # Escape the JSON input for put-targets
    SAFE_INPUT=$(echo "$TEST_PAYLOAD" | sed 's/"/\\"/g')
    create_eventbridge_rule "${FN}-schedule" "$SCHEDULE" "$LAMBDA_ARN" "$SAFE_INPUT"

    success "Deployed: $FN"
  done

  # Post-deploy instructions for Slack webhook
  header "Post-Deploy: Set Slack Webhook"
  echo -e "${YELLOW}The sns-to-slack Lambda needs a Slack webhook URL to send alerts.${NC}"
  echo "Run this command after getting the webhook from api.slack.com/apps:"
  echo ""
  echo "  aws lambda update-function-configuration \\"
  echo "    --function-name ${PROJECT}-sns-to-slack \\"
  echo "    --region $REGION \\"
  echo "    --environment 'Variables={SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL,SLACK_CHANNEL=#alerts-prod,ENVIRONMENT=${ENV},PROJECT_NAME=${PROJECT}}'"
  echo ""
  echo "For PagerDuty, also add: PAGERDUTY_ROUTING_KEY=your-32-char-key"
  echo ""
  success "All Lambdas deployed"
fi

# =============================================================================
# TEST ACTION — invoke each Lambda with a safe test payload
# =============================================================================
if [[ "$ACTION" == "test" ]]; then
  header "Testing Lambdas"
  RESULTS=()

  for ENTRY in "${LAMBDAS[@]}"; do
    IFS=':' read -r DIR_KEY FN TIMEOUT MEMORY SCHEDULE TEST_PAYLOAD <<< "$ENTRY"
    [[ "$ONLY" != "all" && "$ONLY" != "$DIR_KEY" ]] && continue

    info "Testing: $FN"

    # Safe test payloads (dry_run=true for backup, rotate=jwt only for rotation)
    case "$DIR_KEY" in
      "secrets-rotation")    PAYLOAD='{"rotate":"jwt"}' ;;   # JWT only — safe, no DB change
      "ebs-snapshot-backup") PAYLOAD='{"dry_run":true}'  ;;  # dry run — no snapshots created
      "sns-to-slack")        PAYLOAD='{"Records":[{"EventSource":"aws:sns","Sns":{"Message":"{\"AlarmName\":\"Test Alarm\",\"NewStateValue\":\"OK\",\"OldStateValue\":\"ALARM\",\"NewStateReason\":\"Test\",\"AlarmDescription\":\"Lambda test\"}"}}]}' ;;
    esac

    OUTFILE="/tmp/lambda-test-${FN}.json"
    HTTP_CODE=$(aws lambda invoke \
      --function-name "$FN" \
      --payload "$PAYLOAD" \
      --cli-binary-format raw-in-base64-out \
      --region "$REGION" \
      --log-type Tail \
      "$OUTFILE" 2>/dev/null \
      --query "StatusCode" --output text || echo "0")

    RESULT=$(cat "$OUTFILE" 2>/dev/null || echo "{}")
    ERRORS=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errors','[]'))" 2>/dev/null || echo "[]")

    if [[ "$HTTP_CODE" == "200" ]]; then
      success "$FN → HTTP $HTTP_CODE"
      echo "  Response: $(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',d.get('statusCode','ok')))" 2>/dev/null || echo "$RESULT" | head -c 100)"
    else
      warn "$FN → HTTP $HTTP_CODE (check CloudWatch logs)"
      echo "  Response: $RESULT"
    fi

    echo "  Logs: aws logs tail /aws/lambda/$FN --region $REGION --since 5m"
    echo ""
    RESULTS+=("$FN:$HTTP_CODE")
  done

  header "Test Summary"
  for R in "${RESULTS[@]}"; do
    FN="${R%%:*}"; CODE="${R##*:}"
    [[ "$CODE" == "200" ]] && success "$FN: PASS" || warn "$FN: HTTP $CODE"
  done
fi

# =============================================================================
# DESTROY ACTION
# =============================================================================
if [[ "$ACTION" == "destroy" ]]; then
  header "Destroying Lambdas"
  echo -ne "${YELLOW}Confirm destroy all Lambdas in $ENV? [y/N]: ${NC}"
  read -r CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }

  for ENTRY in "${LAMBDAS[@]}"; do
    IFS=':' read -r DIR_KEY FN TIMEOUT MEMORY SCHEDULE TEST_PAYLOAD <<< "$ENTRY"

    info "Removing: $FN"

    # Delete EventBridge rule
    RULE="${FN}-schedule"
    aws events remove-targets --rule "$RULE" --ids LambdaTarget \
      --region "$REGION" 2>/dev/null || true
    aws events delete-rule --name "$RULE" \
      --region "$REGION" 2>/dev/null && info "  EventBridge rule deleted" || true

    # Delete Lambda
    aws lambda delete-function --function-name "$FN" \
      --region "$REGION" 2>/dev/null && success "  Lambda deleted: $FN" || \
      warn "  Lambda not found: $FN"

    # Delete IAM role
    ROLE="${FN}-role"
    aws iam delete-role-policy --role-name "$ROLE" \
      --policy-name "${ROLE}-policy" --region "$REGION" 2>/dev/null || true
    aws iam detach-role-policy --role-name "$ROLE" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
      --region "$REGION" 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE" \
      --region "$REGION" 2>/dev/null && info "  IAM role deleted: $ROLE" || true
  done

  success "All Lambdas destroyed"
fi
