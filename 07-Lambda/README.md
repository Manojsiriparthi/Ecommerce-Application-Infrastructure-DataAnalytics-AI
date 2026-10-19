# 07-Lambda — pip-project-ecommerce

Three Lambda functions for automated operations.

## Functions

| Function | Schedule | Purpose |
|---|---|---|
| `pip-project-ecommerce-secrets-rotation` | 1st of every month, 02:00 UTC | Rotates DB password + JWT secret + internal service key |
| `pip-project-ecommerce-ebs-backup` | Daily 12:00 UTC (5:30 PM IST) | EBS snapshots of EKS nodes, 7-day retention |
| `pip-project-ecommerce-sns-to-slack` | On SNS event | Forwards CloudWatch Alarms → Slack + PagerDuty |

## Deploy

```bash
# Deploy all
chmod +x 07-Lambda/deploy.sh
./07-Lambda/deploy.sh prod us-east-1 deploy

# Deploy one
./07-Lambda/deploy.sh prod us-east-1 deploy secrets-rotation

# Test (safe — dry_run / jwt-only)
./07-Lambda/deploy.sh prod us-east-1 test

# Destroy
./07-Lambda/deploy.sh prod us-east-1 destroy
```

## Post-Deploy: Set Slack Webhook

```bash
aws lambda update-function-configuration \
  --function-name pip-project-ecommerce-sns-to-slack \
  --region us-east-1 \
  --environment 'Variables={
    SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK,
    SLACK_CHANNEL=#alerts-prod,
    ENVIRONMENT=prod,
    PROJECT_NAME=pip-project-ecommerce,
    PAGERDUTY_ROUTING_KEY=your-key-optional
  }'
```

## Manual Invocation

```bash
# Rotate JWT secret only (safe — no DB changes)
aws lambda invoke \
  --function-name pip-project-ecommerce-secrets-rotation \
  --payload '{"rotate":"jwt"}' \
  --cli-binary-format raw-in-base64-out \
  --region us-east-1 response.json && cat response.json

# EBS backup dry run (discover volumes, no snapshots)
aws lambda invoke \
  --function-name pip-project-ecommerce-ebs-backup \
  --payload '{"dry_run":true}' \
  --cli-binary-format raw-in-base64-out \
  --region us-east-1 response.json && cat response.json

# EBS backup real run
aws lambda invoke \
  --function-name pip-project-ecommerce-ebs-backup \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  --region us-east-1 response.json && cat response.json

# Check Lambda logs
aws logs tail /aws/lambda/pip-project-ecommerce-ebs-backup \
  --region us-east-1 --since 1h --follow
```

## After Secrets Rotation

When secrets-rotation runs, all backend pods must be restarted to pick up new secrets:

```bash
for SVC in user-service product-service cart-service order-service payment-service; do
  kubectl rollout restart deployment/${SVC}-deployment -n ecommerce
  kubectl rollout status deployment/${SVC}-deployment -n ecommerce --timeout=60s
done
```

## IAM Permissions

Each Lambda has a least-privilege IAM role defined in `<function>/iam-policy.json`:

- **secrets-rotation**: SecretsManager update, SSM put, RDS modify-cluster, KMS decrypt/encrypt, SNS publish
- **ebs-snapshot-backup**: EC2 describe+create snapshot (own tag only for delete), KMS for encryption, SNS publish
- **sns-to-slack**: CloudWatch Logs only (outbound HTTPS to Slack/PagerDuty via urllib)
