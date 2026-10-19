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
  # WHY writer endpoint (not RDS Proxy):
  #   RDS Proxy requires specific TLS negotiation that Prisma's pg driver
  #   does not satisfy with Aurora PostgreSQL 17. The proxy works for native
  #   psql (libpq) but not for Prisma's connection pooler.
  #   The Aurora writer endpoint works reliably with Prisma.
  #   Connection pooling is handled by Prisma's own pool (default: 10 per pod).
  # WHY %23 not #:
  #   The # character is a URL fragment delimiter. Without encoding, Prisma
  #   misparses the port as empty (P1013: invalid port number).
  value       = "postgresql://${var.master_username}:${replace(var.master_password, "#", "%23")}@${aws_rds_cluster.primary.endpoint}:5432/${each.value}?sslmode=require"
  key_id      = var.kms_key_arn
  description = "DATABASE_URL for ${each.key}-service via Aurora writer endpoint"
  overwrite   = true

  lifecycle {
    ignore_changes = [value]  # Don't overwrite on password rotation
  }

  tags = {
    Name        = "${var.project_name}-${each.key}-db-url"
    Environment = var.environment
  }
}

# ==============================================
# Writer endpoint in SSM — used by 06-Scripts/01-setup-databases.sh
# ==============================================
# The setup script resolves the DB host for CREATE DATABASE + Prisma migrations.
# It prefers `aws rds describe-db-clusters`, but this SSM param is a stable
# fallback and a single source of truth. WRITER endpoint (not proxy) because
# Prisma/psql work reliably against it (see db_url resource above).
resource "aws_ssm_parameter" "writer_endpoint" {
  name        = "/${var.project_name}/${var.environment}/rds/writer-endpoint"
  type        = "String"
  value       = aws_rds_cluster.primary.endpoint
  description = "Aurora writer endpoint (used by DB setup script for DDL + migrations)"
  overwrite   = true

  tags = {
    Name        = "${var.project_name}-writer-endpoint-param"
    Environment = var.environment
  }
}
