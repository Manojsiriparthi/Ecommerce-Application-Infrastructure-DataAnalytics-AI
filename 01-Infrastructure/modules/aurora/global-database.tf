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
