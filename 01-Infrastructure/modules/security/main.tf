# ==============================================
# KMS Key for Encryption
# ==============================================
resource "aws_kms_key" "main" {
  description             = "KMS Key for ${var.project_name} encryption"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  tags = {
    Name        = "${var.project_name}-kms"
    Environment = var.environment
  }
}

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
# SSM Parameters — application secrets (SecureString)
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
