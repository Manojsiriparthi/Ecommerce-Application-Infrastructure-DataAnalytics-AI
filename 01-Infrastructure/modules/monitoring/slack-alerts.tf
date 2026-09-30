# =============================================================================
# SNS → Slack / PagerDuty Lambda Forwarder
# =============================================================================
# Deploys the sns-to-slack Lambda and subscribes it to the SNS alarm topic.
# ALL CloudWatch alarm actions (ALARM + OK) trigger this Lambda.
#
# SETUP AFTER APPLY:
#   1. Get Lambda name from output: terraform output -json | jq .slack_lambda_name
#   2. Set Slack webhook:
#      aws lambda update-function-configuration \
#        --function-name pip-project-ecommerce-sns-to-slack \
#        --environment "Variables={SLACK_WEBHOOK_URL=https://hooks.slack.com/...,
#                                  SLACK_CHANNEL=#alerts-prod,
#                                  ENVIRONMENT=prod,
#                                  PROJECT_NAME=pip-project-ecommerce}"
#   3. For PagerDuty, also add PAGERDUTY_ROUTING_KEY to the env vars above.
# =============================================================================

locals {
  slack_lambda_zip = "${path.module}/../../07-Lambda/sns-to-slack/deployment.zip"
  slack_lambda_src = "${path.module}/../../07-Lambda/sns-to-slack/lambda_function.py"
}

# ── IAM Role for Slack Lambda ─────────────────────────────────────────────────
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
    Statement = [
      # CloudWatch Logs — write Lambda execution logs
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/${var.project_name}-sns-to-slack:*"
      },
    ]
  })
}

# ── Package the Lambda (zip the .py file inline) ──────────────────────────────
# Uses archive_file data source to zip the Lambda on every plan/apply.
data "archive_file" "slack_lambda" {
  type        = "zip"
  source_file = local.slack_lambda_src
  output_path = local.slack_lambda_zip
}

# ── Lambda Function ───────────────────────────────────────────────────────────
resource "aws_lambda_function" "sns_to_slack" {
  function_name = "${var.project_name}-sns-to-slack"
  description   = "Forwards CloudWatch Alarm SNS notifications to Slack and PagerDuty"
  role          = aws_iam_role.slack_lambda.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.slack_lambda.output_path
  source_code_hash = data.archive_file.slack_lambda.output_base64sha256

  environment {
    variables = {
      ENVIRONMENT  = var.environment
      PROJECT_NAME = var.project_name
      # Sensitive values set post-deploy via aws lambda update-function-configuration
      # to avoid storing webhook URLs in Terraform state
      SLACK_WEBHOOK_URL     = ""   # Set manually after deploy
      SLACK_CHANNEL         = "#alerts-prod"
      PAGERDUTY_ROUTING_KEY = ""   # Set manually after deploy (optional)
    }
  }

  tags = {
    Name        = "${var.project_name}-sns-to-slack"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── CloudWatch Log Group for the Lambda ──────────────────────────────────────
resource "aws_cloudwatch_log_group" "slack_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.sns_to_slack.function_name}"
  retention_in_days = 30

  tags = {
    Name        = "${var.project_name}-slack-lambda-logs"
    Environment = var.environment
  }
}

# ── SNS Subscription: topic → Lambda ─────────────────────────────────────────
resource "aws_sns_topic_subscription" "slack_lambda" {
  count     = var.sns_topic_arn != "" ? 1 : 0
  topic_arn = var.sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.sns_to_slack.arn
}

# ── Lambda permission: SNS may invoke this Lambda ─────────────────────────────
resource "aws_lambda_permission" "sns_invoke" {
  count         = var.sns_topic_arn != "" ? 1 : 0
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sns_to_slack.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.sns_topic_arn
}
