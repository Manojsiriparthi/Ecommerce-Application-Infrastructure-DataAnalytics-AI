# ==============================================
# Aurora Global Database (Cross-Region DR)
# ==============================================
# NOTE: This resource is defined in the primary region provider.
# The secondary cluster must be created using aws.dr provider alias
# passed from the root module (see environments/*/main.tf).

resource "aws_rds_global_cluster" "this" {
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
# Secondary Cluster (DR Region)
# Deployed only when var.enable_global_db = true
# Uses provider alias "aws.dr" passed from root module
# ==============================================
resource "aws_rds_cluster" "secondary" {
  count = var.enable_global_db ? 1 : 0

  provider                  = aws.dr
  cluster_identifier        = "${var.project_name}-cluster-dr"
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this.id
  db_subnet_group_name      = var.dr_db_subnet_group_name
  vpc_security_group_ids    = [var.dr_aurora_sg_id]
  storage_encrypted         = true
  kms_key_id                = var.dr_kms_key_arn
  skip_final_snapshot       = true

  # NOTE: master_username/master_password are intentionally NOT set here.
  # A Global Database secondary cluster inherits authentication from the
  # primary cluster automatically - setting credentials here is invalid.
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
