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
