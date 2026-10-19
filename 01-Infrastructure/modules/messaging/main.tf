# =============================================================================
# MESSAGING MODULE
# =============================================================================
# WHAT IS HERE AND WHY:
#
#   SNS topic (pipeline-alerts)
#   ─────────────────────────────
#   Every CloudWatch alarm in this project fires alarm_actions into this topic:
#     - Aurora: CPU high, replica lag, low memory, too many connections
#     - EKS:    node CPU high, pod restart spike
#     - ALB:    5xx error rate, unhealthy target count
#     - NAT GW: error port allocation
#     - ElastiCache: CPU / evictions
#   Subscribers on this topic:
#     1. Email  → immediate human notification (always-on fallback)
#     2. Slack Lambda → formatted Slack message (wired in monitoring module)
#
#   SQS is NOT used here.
#   ─────────────────────────────
#   The original SQS queue was tied to Jenkins pipeline failures.
#   Jenkins has been removed from this project. SQS has no consumer
#   and no purpose — removed to avoid dead infrastructure and KMS cost.
#   If a future async workload (order events, notification fan-out) needs
#   a queue, add a purpose-specific SQS queue in the relevant service module.
#
# =============================================================================

# =============================================================================
# SNS Topic — Infrastructure Alarms
# =============================================================================
resource "aws_sns_topic" "pipeline_alerts" {
  name              = "${var.project_name}-pipeline-alerts"
  kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = {
    Name        = "${var.project_name}-pipeline-alerts"
    Environment = var.environment
    Purpose     = "CloudWatch alarm notifications — Aurora, EKS, ALB, NAT, ElastiCache"
  }
}

# =============================================================================
# SNS Topic Policy
# =============================================================================
# Allows CloudWatch to publish alarm state-change notifications directly
# to this topic. Without this policy, alarm_actions silently fail.
# =============================================================================
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_sns_topic_policy" "pipeline_alerts" {
  arn = aws_sns_topic.pipeline_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.pipeline_alerts.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:alarm:*"
          }
        }
      },
      {
        Sid    = "AllowRDSEvents"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.pipeline_alerts.arn
      }
    ]
  })
}

# =============================================================================
# Email Subscription (always-on fallback)
# =============================================================================
# Sends alarm notifications directly to an email address.
# This fires even if the Slack Lambda is down/misconfigured.
# AWS sends a confirmation email on first apply — you MUST click the link
# or the subscription stays in "PendingConfirmation" and no emails are sent.
#
# Set alert_email in tfvars:
#   alert_email = "ops@yourcompany.com"
# Leave empty to skip (no email subscription created).
# =============================================================================
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
