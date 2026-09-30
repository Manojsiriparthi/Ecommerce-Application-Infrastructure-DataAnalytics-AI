# ==============================================================================
# DR REGION (us-west-2) APP SECRETS & CONFIG
# ==============================================================================
# WHY THIS FILE EXISTS
#   Secrets Manager and SSM Parameter Store are REGIONAL services. The primary
#   modules (security, elasticache) create all app secrets/params ONLY in
#   us-east-1. When the app is deployed to the DR cluster (us-west-2), the
#   Secrets Store CSI driver tries to mount these by the SAME names in us-west-2
#   and fails because they don't exist there:
#     - AccessDenied / "Invalid parameters: /pip-project-ecommerce/prod/app/jwt-secret"
#     - "Failed fetching secret .../redis/auth-token"
#
#   Before this file, those had to be copied by hand (aws ssm put-parameter /
#   aws secretsmanager create-secret) after every DR deploy. This file creates
#   them in us-west-2 as part of `terraform apply`, so the DR deploy is fully
#   automated — no manual commands.
#
# WHAT IT CREATES IN us-west-2 (only when var.enable_global_db = true, i.e. when
# the DR region is actually in use):
#   Secrets Manager:
#     - pip-project-ecommerce/prod/redis/auth-token   (redis auth + host + port)
#     - pip-project-ecommerce-db-credentials          (aurora master creds)
#   SSM SecureString:
#     - /pip-project-ecommerce/prod/app/jwt-secret
#     - /pip-project-ecommerce/prod/app/internal-service-key
#   SSM String:
#     - /pip-project-ecommerce/prod/app/ses-from-email
#     - /pip-project-ecommerce/prod/redis/primary-endpoint
#     - /pip-project-ecommerce/prod/redis/port
#
#   NOTE: db/<svc>-url params in DR are created by aurora/global-database.tf
#   (they point at the DR Aurora secondary). This file does NOT duplicate them.
#
# CROSS-REGION REDIS: there is no ElastiCache cluster in the DR region (cost /
# warm-standby). The DR redis endpoint points at the PRIMARY Redis. Until a real
# failover, DR pods reach primary Redis cross-region (session/cart). If that path
# is blocked by SGs, cart/session degrade gracefully but core pages still load.
# For a full regional failover you would stand up a DR ElastiCache and repoint
# this value — tracked as a known warm-standby limitation.
# ==============================================================================

locals {
  dr_secrets_enabled = var.enable_global_db
  # KMS key in the DR region used to encrypt these secrets/params.
  # Reuse the DR logs KMS key already defined in main.tf (aws_kms_key.dr_logs)
  # so we don't create yet another key. It lives in us-west-2 and the DR IRSA
  # roles' kms:ViaService condition covers secretsmanager/ssm in that region.
  #
  # NOTE: aws_kms_key.dr_logs (main.tf) is NOT gated by enable_global_db, so it
  # always exists — safe to reference here. The aurora module's dr_aurora KMS
  # key IS gated, so we deliberately use the logs key to avoid a null reference.
  dr_app_kms_arn = aws_kms_key.dr_logs.arn
}

# ---- Redis AUTH secret (mirrors elasticache module's redis_auth) ----
resource "aws_secretsmanager_secret" "dr_redis_auth" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name                    = "pip-project-ecommerce/${var.environment}/redis/auth-token"
  kms_key_id              = local.dr_app_kms_arn
  description             = "Redis AUTH token for DR region (points at primary Redis until failover)"
  recovery_window_in_days = 0

  tags = {
    Name        = "pip-project-ecommerce-redis-auth-secret-dr"
    Environment = "${var.environment}-dr"
  }

  lifecycle {
    ignore_changes = [name]
  }
}

resource "aws_secretsmanager_secret_version" "dr_redis_auth" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  secret_id = aws_secretsmanager_secret.dr_redis_auth[0].id
  secret_string = jsonencode({
    auth_token = var.redis_auth_token
    host       = module.elasticache.primary_endpoint
    port       = "6379"
    tls        = "true"
  })
}

# ---- DB master credentials secret (mirrors security module's db_creds) ----
resource "aws_secretsmanager_secret" "dr_db_creds" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name                    = "pip-project-ecommerce-db-credentials"
  kms_key_id              = local.dr_app_kms_arn
  description             = "Aurora PostgreSQL master credentials (DR region)"
  recovery_window_in_days = 0

  tags = {
    Name        = "pip-project-ecommerce-db-secrets-dr"
    Environment = "${var.environment}-dr"
  }

  lifecycle {
    ignore_changes = [name]
  }
}

resource "aws_secretsmanager_secret_version" "dr_db_creds" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  secret_id = aws_secretsmanager_secret.dr_db_creds[0].id
  secret_string = jsonencode({
    username = "pipadmin"
    password = var.db_master_password
    engine   = "postgres"
    port     = 5432
    # DR reader endpoint — becomes writable after failover promotion.
    host = module.aurora.secondary_cluster_endpoint
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---- App SSM SecureString params (mirror security module) ----
resource "aws_ssm_parameter" "dr_jwt_secret" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name        = "/pip-project-ecommerce/${var.environment}/app/jwt-secret"
  type        = "SecureString"
  value       = var.jwt_secret
  key_id      = local.dr_app_kms_arn
  description = "JWT signing secret (DR region) — MUST match primary so tokens validate after failover"
  tier        = "Standard"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name        = "pip-project-ecommerce-jwt-secret-param-dr"
    Environment = "${var.environment}-dr"
  }
}

resource "aws_ssm_parameter" "dr_internal_service_key" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name        = "/pip-project-ecommerce/${var.environment}/app/internal-service-key"
  type        = "SecureString"
  value       = var.internal_service_key
  key_id      = local.dr_app_kms_arn
  description = "Internal service-to-service key (DR region)"
  tier        = "Standard"

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name        = "pip-project-ecommerce-internal-key-param-dr"
    Environment = "${var.environment}-dr"
  }
}

# ---- App SSM String params (non-sensitive config) ----
resource "aws_ssm_parameter" "dr_ses_from_email" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name        = "/pip-project-ecommerce/${var.environment}/app/ses-from-email"
  type        = "String"
  value       = var.ses_from_email
  description = "SES verified sender email (DR region)"

  tags = {
    Name        = "pip-project-ecommerce-ses-from-email-param-dr"
    Environment = "${var.environment}-dr"
  }
}

resource "aws_ssm_parameter" "dr_redis_host" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name        = "/pip-project-ecommerce/${var.environment}/redis/primary-endpoint"
  type        = "String"
  # Points at PRIMARY Redis (no DR ElastiCache in warm-standby). Repoint here
  # if a dedicated DR ElastiCache is later provisioned.
  value       = module.elasticache.primary_endpoint
  description = "Redis primary endpoint used by DR pods (cross-region until failover)"

  tags = {
    Name        = "pip-project-ecommerce-redis-host-param-dr"
    Environment = "${var.environment}-dr"
  }
}

resource "aws_ssm_parameter" "dr_redis_port" {
  count    = local.dr_secrets_enabled ? 1 : 0
  provider = aws.dr

  name        = "/pip-project-ecommerce/${var.environment}/redis/port"
  type        = "String"
  value       = "6379"
  description = "Redis port (DR region)"

  tags = {
    Name        = "pip-project-ecommerce-redis-port-param-dr"
    Environment = "${var.environment}-dr"
  }
}
