# ==============================================
# RDS Proxy
# Sits between EKS pods and Aurora. Benefits:
#  - Connection pooling (many pods share fewer DB connections)
#  - Automatic failover without app reconnection logic
#  - Secrets Manager auth (no passwords in pod env vars)
# ==============================================
resource "aws_db_proxy" "ecommerce" {
  name                   = "${var.project_name}-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = var.proxy_idle_client_timeout
  require_tls            = true
  role_arn               = aws_iam_role.proxy.arn
  vpc_security_group_ids = [var.aurora_sg_id]
  vpc_subnet_ids         = var.db_subnet_ids

  auth {
    auth_scheme = "SECRETS"
    description = "Secrets Manager auth"
    iam_auth    = "DISABLED"
    secret_arn  = var.db_secret_arn
  }

  tags = {
    Name        = "${var.project_name}-proxy"
    Environment = var.environment
  }
}

resource "aws_db_proxy_default_target_group" "ecommerce" {
  db_proxy_name = aws_db_proxy.ecommerce.name

  connection_pool_config {
    connection_borrow_timeout    = var.proxy_connection_borrow_timeout
    max_connections_percent      = var.proxy_max_connections_percent
    max_idle_connections_percent = var.proxy_max_idle_connections_percent
  }
}

resource "aws_db_proxy_target" "ecommerce" {
  db_proxy_name         = aws_db_proxy.ecommerce.name
  target_group_name     = aws_db_proxy_default_target_group.ecommerce.name
  db_cluster_identifier = aws_rds_cluster.primary.id
}

# ==============================================
# SSM Parameters — DATABASE_URLs per service
# ==============================================
# Stored here (not in security module) to avoid circular dependency:
#   security needs aurora.proxy_endpoint
#   aurora needs security.kms_key_arn
# By putting DATABASE_URLs in the aurora module, the cycle is broken.
# Aurora already knows its own proxy endpoint — no external reference needed.
# ==============================================

locals {
  services_dbs = {
    "user"    = "user_db"
    "product" = "product_db"
    "cart"    = "cart_db"
    "order"   = "order_db"
    "payment" = "payment_db"
  }
}

resource "aws_ssm_parameter" "db_url" {
  for_each = local.services_dbs

  name        = "/${var.project_name}/${var.environment}/db/${each.key}-url"
  type        = "SecureString"
  value       = "postgresql://${var.master_username}:${var.master_password}@${aws_db_proxy.ecommerce.endpoint}:5432/${each.value}?sslmode=require"
  key_id      = var.kms_key_arn
  description = "DATABASE_URL for ${each.key}-service via RDS Proxy"

  lifecycle {
    ignore_changes = [value]  # Don't overwrite on password rotation
  }

  tags = {
    Name        = "${var.project_name}-${each.key}-db-url"
    Environment = var.environment
  }
}
