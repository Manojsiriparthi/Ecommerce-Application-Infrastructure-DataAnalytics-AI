# ==============================================
# Aurora Global Database (Cross-Region DR)
# ==============================================
resource "aws_rds_global_cluster" "ecommerce" {
  count = var.enable_global_db ? 1 : 0

  global_cluster_identifier = "${var.project_name}-global-db"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = var.database_name
  storage_encrypted         = true

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# ==============================================
# KMS key in DR region for encrypted Global DB replica
# AWS REQUIRES an explicit KMS key for cross-region encrypted replicas.
# "null" or omitting kms_key_id is rejected with InvalidParameterCombination.
# This key is created in the DR region using the aws.dr provider alias.
# ==============================================
resource "aws_kms_key" "dr_aurora" {
  count    = var.enable_global_db ? 1 : 0
  provider = aws.dr

  description             = "KMS key for Aurora Global DB secondary cluster in DR region"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "${var.project_name}-aurora-dr-kms"
    Environment = "dr"
  }
}

resource "aws_kms_alias" "dr_aurora" {
  count         = var.enable_global_db ? 1 : 0
  provider      = aws.dr
  name          = "alias/${var.project_name}-aurora-dr"
  target_key_id = aws_kms_key.dr_aurora[0].key_id
}

# ==============================================
# Secondary Cluster (DR Region)
# ==============================================
resource "aws_rds_cluster" "secondary" {
  count = var.enable_global_db ? 1 : 0

  provider                  = aws.dr
  cluster_identifier        = "${var.project_name}-cluster-dr"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  global_cluster_identifier = aws_rds_global_cluster.ecommerce[0].id
  db_subnet_group_name      = var.dr_db_subnet_group_name
  vpc_security_group_ids    = [var.dr_aurora_sg_id]
  storage_encrypted         = true
  # Explicit KMS key in DR region — required by AWS for cross-region encrypted replicas
  kms_key_id          = var.dr_kms_key_arn != "" ? var.dr_kms_key_arn : aws_kms_key.dr_aurora[0].arn
  skip_final_snapshot = true

  # CRITICAL: the secondary can only start physical replication AFTER the
  # primary cluster + its writer instance are fully available. Without this
  # dependency the secondary races ahead and fails with
  # "Source cluster is in a state which is not valid for physical replication".
  depends_on = [
    aws_rds_cluster.primary,
    aws_rds_cluster_instance.writer,
  ]

  lifecycle {
    ignore_changes = [engine_version]
  }
}

resource "aws_rds_cluster_instance" "secondary" {
  count = var.enable_global_db ? var.dr_reader_count : 0

  provider             = aws.dr
  identifier           = "${var.project_name}-dr-reader-${count.index + 1}"
  cluster_identifier   = aws_rds_cluster.secondary[0].id
  instance_class       = var.instance_class
  engine               = "aurora-postgresql"
  engine_version       = var.engine_version
  db_subnet_group_name = var.dr_db_subnet_group_name

  performance_insights_enabled = var.performance_insights_enabled
}

# ==============================================
# DR Region SSM DATABASE_URLs (us-west-2)
# ==============================================
# The DR app reads these to connect to the DR Aurora secondary cluster.
#
# IMPORTANT — read-only until failover:
#   The DR secondary is READ-ONLY while the primary is healthy. The DR app
#   can read (products load, browse works) but writes (register/login writing
#   sessions) fail until the DR cluster is PROMOTED during failover.
#   After promotion (aws rds failover-global-cluster), the secondary becomes
#   writable and the app is fully functional.
#
# The reader endpoint is used here — after promotion it automatically accepts
# writes as the new primary writer endpoint.
# ==============================================

resource "aws_ssm_parameter" "dr_db_url" {
  for_each = var.enable_global_db ? local.services_dbs : {}

  provider = aws.dr

  name   = "/${var.project_name}/${var.environment}/db/${each.key}-url"
  type   = "SecureString"
  # DR secondary cluster endpoint. # in password is URL-encoded as %23.
  value  = "postgresql://${var.master_username}:${replace(var.master_password, "#", "%23")}@${aws_rds_cluster.secondary[0].endpoint}:5432/${each.value}?sslmode=require"
  key_id = var.dr_kms_key_arn != "" ? var.dr_kms_key_arn : aws_kms_key.dr_aurora[0].arn

  description = "DR DATABASE_URL for ${each.key}-service (Aurora secondary, us-west-2)"
  overwrite   = true

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name        = "${var.project_name}-${each.key}-db-url-dr"
    Environment = "${var.environment}-dr"
  }
}
