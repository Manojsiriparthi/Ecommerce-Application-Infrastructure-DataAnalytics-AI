# ==============================================
# CloudWatch Alarms - Aurora
# NOTE: cpu_threshold and replica_lag_threshold variables are
# declared once in variables.tf (not duplicated here).
# ==============================================

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-aurora-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_threshold
  alarm_description   = "Aurora CPU utilization is high"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.primary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "freeable_memory" {
  alarm_name          = "${var.project_name}-aurora-low-memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "FreeableMemory"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 100000000
  alarm_description   = "Aurora freeable memory is low"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.primary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "db_connections" {
  alarm_name          = "${var.project_name}-aurora-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 500
  alarm_description   = "Aurora database connections high"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.primary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "replica_lag" {
  alarm_name          = "${var.project_name}-aurora-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = var.replica_lag_threshold
  alarm_description   = "Aurora local reader replica lag is high"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.primary.id
  }
}

resource "aws_cloudwatch_metric_alarm" "global_replica_lag" {
  alarm_name          = "${var.project_name}-aurora-global-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraGlobalDBReplicationLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 5000
  alarm_description   = "Aurora cross-region replication lag is high - measure actual value, do not assume"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.primary.id
  }
}
