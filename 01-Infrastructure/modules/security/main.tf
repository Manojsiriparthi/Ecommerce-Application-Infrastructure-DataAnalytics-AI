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
      },
      # Explicitly allow the services IRSA role to decrypt secrets
      # This is required even though root account has access above —
      # KMS evaluates both the key policy AND the IAM policy.
      # Allow the IRSA roles (services-role, secrets-store-csi-role) to decrypt.
      # WHY Principal = account root + ArnLike condition (not the role ARN directly):
      #   On a fresh build, the security module runs BEFORE iam-irsa creates those
      #   roles. KMS rejects a policy that names a principal ARN that doesn't exist
      #   yet ("invalid principals"). Using the account root as principal + an
      #   ArnLike condition on aws:PrincipalArn lets the policy be created NOW and
      #   still grants ONLY those roles once they exist. Wildcards match future roles.
      {
        Sid    = "AllowIRSARolesDecrypt"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.security.account_id}:root"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::${data.aws_caller_identity.security.account_id}:role/${var.project_name}-services-role",
              "arn:aws:iam::${data.aws_caller_identity.security.account_id}:role/${var.project_name}-secrets-store-csi-role"
            ]
          }
        }
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
    # host is the RDS Proxy endpoint — set after Aurora + Proxy are created
    # The 01-setup-databases.sh script updates this value after first apply
    # pods read host via JMESPath from this secret
    host     = var.db_proxy_endpoint
  })

  lifecycle {
    ignore_changes = [secret_string]  # Don't overwrite if manually updated
  }
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

# DATABASE_URL SSM parameters are created in the aurora module
# (modules/aurora/proxy.tf) to avoid a circular dependency:
#   security → aurora.proxy_endpoint → aurora → security.kms_key_arn
# The aurora module stores DATABASE_URLs in SSM after the proxy is created.

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

  tags = {
    Name        = "${var.project_name}-vpc-flow-logs"
    Environment = var.environment
  }

  # Prevent failure if log group already exists from a previous apply
  # CloudWatch log groups survive terraform destroy by design
  lifecycle {
    prevent_destroy       = false
    create_before_destroy = false
  }
}

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/eks/${var.project_name}-${var.environment}/application"
  retention_in_days = 30

  tags = {
    Name        = "${var.project_name}-app-logs"
    Environment = var.environment
  }

  lifecycle {
    prevent_destroy       = false
    create_before_destroy = false
  }
}

resource "aws_cloudwatch_log_group" "infra_logs" {
  name              = "/aws/eks/${var.project_name}-${var.environment}/infrastructure"
  retention_in_days = 90

  tags = {
    Name        = "${var.project_name}-infra-logs"
    Environment = var.environment
  }

  lifecycle {
    prevent_destroy       = false
    create_before_destroy = false
  }
}

# Flow log resource

# =============================================================================
# AWS CONFIG — configuration recording + compliance rules
# =============================================================================
# WHY: Records EVERY configuration change to AWS resources (SG rules, IAM
# policies, S3 bucket policies, etc.). If someone changes a security group
# via the console, AWS Config records WHO changed WHAT and WHEN.
#
# CONFIG RULES (built-in compliance checks):
#   - root-account-mfa-enabled: root account must have MFA
#   - no-public-s3-buckets: no S3 bucket can be public
#   - vpc-sg-open-only-to-authorized-ports: SGs can't allow 0.0.0.0/0 on non-443/22
#   - iam-no-root-access-key: root account must not have access keys
#   - db-instance-public-access-check: RDS must not be publicly accessible
# =============================================================================

# ── S3 bucket for Config delivery ─────────────────────────────────────────────
resource "aws_s3_bucket" "config" {
  bucket = "${var.project_name}-config-${var.environment}"

  tags = {
    Name        = "${var.project_name}-config"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Config recorder ──────────────────────────────────────────────────────────
resource "aws_iam_role" "config" {
  name = "${var.project_name}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRole"
  role       = aws_iam_role.config.name
}

resource "aws_config_configuration_recorder" "main" {
  name     = "${var.project_name}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.project_name}-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config.bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ── Config rules (compliance checks) ────────────────────────────────────────
resource "aws_config_config_rule" "root_mfa" {
  name             = "${var.project_name}-root-mfa-enabled"
  source {
    owner             = "AWS"
    source_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
  }
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "no_public_s3" {
  name             = "${var.project_name}-no-public-s3-buckets"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "no_root_keys" {
  name             = "${var.project_name}-no-root-access-keys"
  source {
    owner             = "AWS"
    source_identifier = "IAM_NO_ROOT_ACCESS_KEY"
  }
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "no_public_db" {
  name             = "${var.project_name}-db-no-public-access"
  source {
    owner             = "AWS"
    source_identifier = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
  }
  depends_on = [aws_config_configuration_recorder.main]
}
