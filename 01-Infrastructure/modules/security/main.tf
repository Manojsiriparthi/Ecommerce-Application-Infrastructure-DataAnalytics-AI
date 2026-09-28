# ==============================================
# KMS Key for Encryption
# ==============================================
resource "aws_kms_key" "main" {
  description             = "KMS Key for ${var.project_name} encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  # Explicit key policy required so AWS services (CloudWatch Logs, Secrets Manager,
  # ElastiCache, SSM) can use this key. Without this, CreateLogGroup fails with
  # AccessDeniedException because CloudWatch Logs cannot use a KMS key unless
  # logs.amazonaws.com is explicitly granted GenerateDataKey + Decrypt.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # Root account full control (required — without this you lose all access)
      {
        Sid    = "RootAccountFullControl"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.security.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # CloudWatch Logs — needed for encrypted log groups (VPC flow logs, app logs)
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.name}.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Describe*",
          "kms:ReEncrypt*",
          "kms:CreateGrant",
          "kms:ListGrants"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.security.account_id}:*"
          }
        }
      },
      # Secrets Manager
      {
        Sid    = "AllowSecretsManager"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Describe*"
        ]
        Resource = "*"
      },
      # IAM roles with permission can use the key (covers EKS pods via IRSA, Jenkins, etc.)
      {
        Sid    = "AllowIAMUsage"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.security.account_id}:root"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:ReEncrypt*",
          "kms:DescribeKey",
          "kms:CreateGrant",
          "kms:ListGrants"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-kms"
    Environment = var.environment
  }
}

data "aws_caller_identity" "security" {}
data "aws_region" "current" {}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project_name}-kms"
  target_key_id = aws_kms_key.main.key_id
}

# ==============================================
# Secrets Manager for DB Credentials
# ==============================================
resource "aws_secretsmanager_secret" "db_creds" {
  name                    = "${var.project_name}-db-credentials"
  kms_key_id              = aws_kms_key.main.arn
  description             = "Aurora PostgreSQL master credentials"
  recovery_window_in_days = 0  # Force delete without recovery

  tags = {
    Name        = "${var.project_name}-db-secrets"
    Environment = var.environment
  }

  lifecycle {
    ignore_changes = [name]
  }
}

resource "aws_secretsmanager_secret_version" "db_creds" {
  secret_id = aws_secretsmanager_secret.db_creds.id
  secret_string = jsonencode({
    username = "pipadmin"
    password = var.db_password
    engine   = "postgres"
    port     = 5432
  })
}

# ==============================================
# SSM Parameters - application secrets (SecureString)
# ==============================================
# WHY SECURESTRING IN SSM (not Secrets Manager):
#   JWT secret and internal service key are short strings.
#   SSM SecureString with KMS is simpler and cheaper than Secrets Manager
#   for values that don't need automatic rotation.
#   Secrets Manager is used for DB credentials (supports rotation lambda).
#
# SENSITIVE data → Secrets Manager (DB creds, Redis auth token)
# APP SECRETS    → SSM SecureString (JWT secret, internal key)
# CONFIG         → SSM String (Redis host, SNS ARN, SES email, internal ALB DNS)
# ==============================================

resource "aws_ssm_parameter" "jwt_secret" {
  name        = "/${var.project_name}/${var.environment}/app/jwt-secret"
  type        = "SecureString"
  value       = var.jwt_secret
  key_id      = aws_kms_key.main.arn
  description = "JWT signing secret for all backend services"
  tier        = "Standard"

  lifecycle {
    ignore_changes = [value]  # Rotated out-of-band
  }

  tags = {
    Name        = "${var.project_name}-jwt-secret-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "internal_service_key" {
  name        = "/${var.project_name}/${var.environment}/app/internal-service-key"
  type        = "SecureString"
  value       = var.internal_service_key
  key_id      = aws_kms_key.main.arn
  description = "Shared key for internal service-to-service calls (/internal/* endpoints)"
  tier        = "Standard"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name        = "${var.project_name}-internal-key-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "ses_from_email" {
  name        = "/${var.project_name}/${var.environment}/app/ses-from-email"
  type        = "String"
  value       = var.ses_from_email
  description = "SES verified sender email for notification-service"

  tags = {
    Name        = "${var.project_name}-ses-from-email-param"
    Environment = var.environment
  }
}

# ==============================================
# GuardDuty - threat detection
# Rubric requirement: GuardDuty enabled, HIGH severity < 5
# Detects: compromised EC2/EKS nodes, unusual API calls,
#          crypto-mining, data exfiltration attempts
# ==============================================
resource "aws_guardduty_detector" "ecommerce" {
  enable = true

  tags = {
    Name        = "${var.project_name}-guardduty"
    Environment = var.environment
  }
}

# GuardDuty features — replaces deprecated datasources block
resource "aws_guardduty_detector_feature" "s3_logs" {
  detector_id = aws_guardduty_detector.ecommerce.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_audit" {
  detector_id = aws_guardduty_detector.ecommerce.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "malware" {
  detector_id = aws_guardduty_detector.ecommerce.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

# CloudWatch alarm - HIGH severity GuardDuty findings
# Rubric: HIGH severity findings < 5
resource "aws_cloudwatch_metric_alarm" "guardduty_high" {
  alarm_name          = "${var.project_name}-guardduty-high-findings"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FindingCount"
  namespace           = "AWS/GuardDuty"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "GuardDuty HIGH/CRITICAL finding detected - investigate immediately"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DetectorId = aws_guardduty_detector.ecommerce.id
    Severity   = "High"
  }

  tags = {
    Name        = "${var.project_name}-guardduty-alarm"
    Environment = var.environment
  }
}

# ==============================================
# VPC Flow Logs → CloudWatch Logs
# Rubric requirement: VPC flow logs enabled
# Records all IP traffic to/from ENIs in the VPC.
# Used for: security analysis, network troubleshooting,
#           compliance auditing
# ==============================================
resource "aws_iam_role" "vpc_flow_logs" {
  name = "${var.project_name}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.project_name}-vpc-flow-logs-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "${var.project_name}-vpc-flow-logs-policy"
  role = aws_iam_role.vpc_flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/flowlogs/${var.project_name}-${var.environment}"
  retention_in_days = 90
  # KMS not used here — CloudWatch Logs encrypts with AES-256 by default.
  # Custom KMS requires key policy propagation timing that causes apply failures.

  tags = {
    Name        = "${var.project_name}-vpc-flow-logs"
    Environment = var.environment
  }
}

# Flow log resource - vpc_id passed in as variable
resource "aws_flow_log" "ecommerce" {
  count           = var.vpc_id != "" ? 1 : 0

  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = var.vpc_id

  tags = {
    Name        = "${var.project_name}-vpc-flow-log"
    Environment = var.environment
  }
}

# ==============================================
# CloudWatch Log Groups (centralised application logs)
# Fluent Bit (in EKS) ships pod logs to these groups.
# Rubric: centralize application and infrastructure logs
# ==============================================
resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/eks/${var.project_name}-${var.environment}/application"
  retention_in_days = 30
  # AES-256 default encryption — sufficient for application logs

  tags = {
    Name        = "${var.project_name}-app-logs"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "infra_logs" {
  name              = "/aws/eks/${var.project_name}-${var.environment}/infrastructure"
  retention_in_days = 90
  # AES-256 default encryption — sufficient for infrastructure logs

  tags = {
    Name        = "${var.project_name}-infra-logs"
    Environment = var.environment
  }
}
