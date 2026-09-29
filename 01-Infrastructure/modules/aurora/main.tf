# ==============================================
# Aurora Cluster (Primary Region)
# ==============================================
resource "aws_rds_cluster" "primary" {
  cluster_identifier      = "${var.project_name}-cluster"
  engine                  = "aurora-postgresql"
  engine_version          = var.engine_version
  database_name           = var.database_name
  master_username         = var.master_username
  master_password         = var.master_password
  backup_retention_period = var.backup_retention_period
  preferred_backup_window = var.backup_window
  db_subnet_group_name    = var.db_subnet_group_name
  vpc_security_group_ids  = [var.aurora_sg_id]
  storage_encrypted       = true
  kms_key_id              = var.kms_key_arn

  # IMPORTANT: global_cluster_identifier can only be set at cluster CREATION time.
  # If the primary cluster already exists without it, you cannot add it later.
  # To use Global Database:
  #   1. Set enable_global_db = true BEFORE first terraform apply
  #   2. OR destroy primary cluster and recreate with enable_global_db = true
  # Setting this to null on an existing cluster that was created with it will
  # REMOVE the cluster from the global database (allowed but irreversible without recreate)
  global_cluster_identifier       = var.enable_global_db ? aws_rds_global_cluster.ecommerce[0].id : null
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.ecommerce.name
  enabled_cloudwatch_logs_exports = ["postgresql"]
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = !var.deletion_protection
  final_snapshot_identifier       = var.deletion_protection ? "${var.project_name}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  lifecycle {
    ignore_changes = [master_password, final_snapshot_identifier]
  }

  tags = {
    Name        = "${var.project_name}-aurora-cluster"
    Environment = var.environment
  }
}

# ==============================================
# Writer Instance (Promotion Tier 0)
# ==============================================
resource "aws_rds_cluster_instance" "writer" {
  identifier           = "${var.project_name}-writer"
  cluster_identifier   = aws_rds_cluster.primary.id
  instance_class       = var.instance_class
  engine               = aws_rds_cluster.primary.engine
  engine_version       = aws_rds_cluster.primary.engine_version
  db_subnet_group_name = var.db_subnet_group_name
  db_parameter_group_name = aws_db_parameter_group.ecommerce.name
  promotion_tier       = 0

  auto_minor_version_upgrade            = true
  preferred_maintenance_window          = var.maintenance_window
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention : null
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = {
    Name        = "${var.project_name}-writer"
    Environment = var.environment
  }
}

# ==============================================
# Reader Instances (Promotion Tier 1, across AZs)
# ==============================================
resource "aws_rds_cluster_instance" "readers" {
  count                = var.reader_count
  identifier           = "${var.project_name}-reader-${count.index + 1}"
  cluster_identifier   = aws_rds_cluster.primary.id
  instance_class       = var.instance_class
  engine               = aws_rds_cluster.primary.engine
  engine_version       = aws_rds_cluster.primary.engine_version
  db_subnet_group_name = var.db_subnet_group_name
  db_parameter_group_name = aws_db_parameter_group.ecommerce.name
  promotion_tier       = 1

  auto_minor_version_upgrade            = true
  preferred_maintenance_window          = var.maintenance_window
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention : null
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = {
    Name        = "${var.project_name}-reader-${count.index + 1}"
    Environment = var.environment
  }

  depends_on = [aws_rds_cluster_instance.writer]
}
