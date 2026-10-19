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

  # global_cluster_identifier links this primary to the Global Database.
  # Set at CREATION time (fresh cluster) so the primary is born inside the global
  # cluster — no "existing cluster" error. We destroy the old standalone Aurora
  # first, so this is a clean fresh create.
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
# Writer Instance — pinned to AZ[0]
# ==============================================
# WHY AZ PINNING:
#   Without explicit availability_zone, AWS places instances freely.
#   Two instances can land in the same AZ, meaning an AZ failure takes
#   out both writer and reader simultaneously — no HA benefit.
#   Pinning guarantees: writer in AZ-a, reader-1 in AZ-b, reader-2 in AZ-c.
#   Result: any single AZ failure loses at most 1 instance; the cluster
#   auto-promotes a reader in a surviving AZ within ~30 seconds.
# ==============================================
resource "aws_rds_cluster_instance" "writer" {
  identifier              = "${var.project_name}-writer"
  cluster_identifier      = aws_rds_cluster.primary.id
  instance_class          = var.instance_class
  engine                  = aws_rds_cluster.primary.engine
  engine_version          = aws_rds_cluster.primary.engine_version
  db_subnet_group_name    = var.db_subnet_group_name
  db_parameter_group_name = aws_db_parameter_group.ecommerce.name
  promotion_tier          = 0

  # Pin to first AZ — writer always in AZ[0]
  availability_zone = length(var.availability_zones) > 0 ? var.availability_zones[0] : null

  auto_minor_version_upgrade            = true
  preferred_maintenance_window          = var.maintenance_window
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention : null
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = {
    Name        = "${var.project_name}-writer"
    Environment = var.environment
    AZ          = length(var.availability_zones) > 0 ? var.availability_zones[0] : "auto"
  }
}

# ==============================================
# Reader Instances — each pinned to a different AZ
# ==============================================
# reader-1 → AZ[1]  (different AZ from writer)
# reader-2 → AZ[2]  (third AZ — survives any single AZ failure)
#
# CROSS-AZ READ SCALING:
#   Both readers handle SELECT queries via the cluster reader endpoint.
#   Aurora automatically load-balances reads across all healthy readers.
#   Applications using the reader endpoint get horizontal read scaling
#   with automatic failover — if one reader's AZ goes down, Aurora
#   routes reads to the surviving reader within seconds.
#
# PROMOTION ORDER:
#   promotion_tier = 1 on all readers → any reader can become writer
#   if the current writer fails. Aurora picks the reader with the
#   least lag (most up-to-date) to minimise data loss.
# ==============================================
resource "aws_rds_cluster_instance" "readers" {
  count                   = var.reader_count
  identifier              = "${var.project_name}-reader-${count.index + 1}"
  cluster_identifier      = aws_rds_cluster.primary.id
  instance_class          = var.instance_class
  engine                  = aws_rds_cluster.primary.engine
  engine_version          = aws_rds_cluster.primary.engine_version
  db_subnet_group_name    = var.db_subnet_group_name
  db_parameter_group_name = aws_db_parameter_group.ecommerce.name
  promotion_tier          = 1

  # Pin each reader to a distinct AZ: index+1 wraps around if fewer AZs than readers
  # reader-0 → AZ[1], reader-1 → AZ[2], reader-2 → AZ[0] (wraps), etc.
  availability_zone = (
    length(var.availability_zones) > 0
    ? var.availability_zones[(count.index + 1) % length(var.availability_zones)]
    : null
  )

  auto_minor_version_upgrade            = true
  preferred_maintenance_window          = var.maintenance_window
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention : null
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  tags = {
    Name        = "${var.project_name}-reader-${count.index + 1}"
    Environment = var.environment
    AZ          = (
      length(var.availability_zones) > 0
      ? var.availability_zones[(count.index + 1) % length(var.availability_zones)]
      : "auto"
    )
  }

  depends_on = [aws_rds_cluster_instance.writer]
}
