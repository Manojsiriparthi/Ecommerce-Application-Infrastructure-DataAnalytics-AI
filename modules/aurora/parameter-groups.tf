# ==============================================
# Aurora Cluster Parameter Group
# NOTE: shared_buffers and effective_cache_size defaults are
# generic. Tune these according to your actual instance_class
# memory capacity and real workload - do not assume the defaults
# below are correct for every instance size.
# ==============================================
resource "aws_rds_cluster_parameter_group" "this" {
  name        = "${var.project_name}-cluster-pg"
  family      = "aurora-postgresql17"
  description = "Aurora PostgreSQL cluster parameter group for ${var.project_name}"

  parameter {
    name         = "shared_buffers"
    value        = var.shared_buffers
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "effective_cache_size"
    value        = var.effective_cache_size
    apply_method = "pending-reboot"
  }

  tags = {
    Name        = "${var.project_name}-cluster-pg"
    Environment = var.environment
  }
}

# ==============================================
# Aurora DB Instance Parameter Group
# NOTE: max_connections default uses AWS's formula based on
# DBInstanceClassMemory. Adjust per workload/instance size.
# ==============================================
resource "aws_db_parameter_group" "this" {
  name        = "${var.project_name}-instance-pg"
  family      = "aurora-postgresql17"
  description = "Aurora PostgreSQL instance parameter group for ${var.project_name}"

  parameter {
    name         = "max_connections"
    value        = var.max_connections
    apply_method = "pending-reboot"
  }

  tags = {
    Name        = "${var.project_name}-instance-pg"
    Environment = var.environment
  }
}

