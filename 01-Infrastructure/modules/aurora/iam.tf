# ==============================================
# RDS Enhanced Monitoring Role
# Used by Aurora writer/reader instances for enhanced
# OS-level monitoring metrics sent to CloudWatch Logs.
# ==============================================
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })

  tags = {
    Name        = "${var.project_name}-rds-monitoring-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
  role       = aws_iam_role.rds_monitoring.name
}

# ==============================================
# RDS Proxy Role
# Assumed by RDS Proxy so it can read the DB
# credentials secret from Secrets Manager and
# decrypt it using KMS. This is a least-privilege
# role - it can ONLY read the one secret and use
# the one KMS key passed into this module.
# ==============================================
resource "aws_iam_role" "proxy" {
  name = "${var.project_name}-rds-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
    }]
  })

  tags = {
    Name        = "${var.project_name}-rds-proxy-role"
    Environment = var.environment
  }
}

resource "aws_iam_policy" "proxy_secrets" {
  name        = "${var.project_name}-proxy-secrets-policy"
  description = "Least-privilege policy allowing RDS Proxy to read DB credentials from Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [var.db_secret_arn]
      },
      {
        Sid      = "DecryptWithKms"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "proxy_secrets" {
  policy_arn = aws_iam_policy.proxy_secrets.arn
  role       = aws_iam_role.proxy.name
}
