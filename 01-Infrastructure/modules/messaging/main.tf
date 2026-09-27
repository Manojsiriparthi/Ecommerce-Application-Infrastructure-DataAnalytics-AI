# ==============================================
# SNS Topic - Pipeline Alerts
# ==============================================
resource "aws_sns_topic" "pipeline_alerts" {
  name              = "${var.project_name}-pipeline-alerts"
  kms_master_key_id = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = {
    Name        = "${var.project_name}-pipeline-alerts"
    Environment = var.environment
  }
}

# ==============================================
# SQS Queue - Jenkins Pipeline Failures
# ==============================================
resource "aws_sqs_queue" "jenkins_failures_dlq" {
  name                      = "${var.project_name}-jenkins-failures-dlq"
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = var.kms_key_arn != "" ? var.kms_key_arn : null

  tags = {
    Name        = "${var.project_name}-jenkins-failures-dlq"
    Environment = var.environment
  }
}

resource "aws_sqs_queue" "jenkins_failures" {
  name                        = "${var.project_name}-jenkins-failures"
  message_retention_seconds  = 86400 # 1 day
  visibility_timeout_seconds = 30    # 30 seconds
  kms_master_key_id          = var.kms_key_arn != "" ? var.kms_key_arn : null

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.jenkins_failures_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name        = "${var.project_name}-jenkins-failures"
    Environment = var.environment
  }
}

# ==============================================
# SNS -> SQS Subscription
# ==============================================
resource "aws_sns_topic_subscription" "jenkins_failures" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.jenkins_failures.arn
}

resource "aws_sqs_queue_policy" "allow_sns" {
  queue_url = aws_sqs_queue.jenkins_failures.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.jenkins_failures.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_sns_topic.pipeline_alerts.arn }
      }
    }]
  })
}
