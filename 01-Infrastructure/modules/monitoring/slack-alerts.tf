# =============================================================================
# SNS → Slack Lambda — IAM + SNS subscription wiring only
# =============================================================================
# The Lambda function itself is deployed by:
#   ./07-Lambda/deploy.sh prod us-east-1 deploy sns-to-slack
#
# This file only manages:
#   - IAM execution role for the Lambda
#   - SNS topic subscription (SNS → Lambda)
#   - Lambda invoke permission
#   - CloudWatch log group (30-day retention)
#
# WHY not deploy Lambda here:
#   archive_file data source requires the .py file to exist on the machine
#   running terraform apply. The server may not have the 07-Lambda folder.
#   deploy.sh handles packaging and deployment independently.
# =============================================================================

# ── IAM Role ─────────────────────────────────────────────────────────────────
resource "aws_iam_role" "slack_lambda" {
  name = "${var.project_name}-sns-to-slack-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.project_name}-slack-lambda-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "slack_lambda" {
  name = "${var.project_name}-sns-to-slack-policy"
  role = aws_iam_role.slack_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CloudWatchLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/${var.project_name}-sns-to-slack:*"
    }]
  })
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "slack_lambda" {
  name              = "/aws/lambda/${var.project_name}-sns-to-slack"
  retention_in_days = 30

  tags = {
    Name        = "${var.project_name}-slack-lambda-logs"
    Environment = var.environment
  }
}

# ── SNS subscription (only after Lambda is deployed via deploy.sh) ────────────
# count=0 by default — set to 1 after running:
#   ./07-Lambda/deploy.sh prod us-east-1 deploy sns-to-slack
# Then set sns_slack_lambda_deployed = true in prod.tfvars and re-apply.
resource "aws_sns_topic_subscription" "slack_lambda" {
  count     = var.sns_slack_lambda_deployed && var.sns_topic_arn != "" ? 1 : 0
  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = "arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-sns-to-slack"
}

resource "aws_lambda_permission" "sns_invoke" {
  count         = var.sns_slack_lambda_deployed && var.sns_topic_arn != "" ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = "${var.project_name}-sns-to-slack"
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}
