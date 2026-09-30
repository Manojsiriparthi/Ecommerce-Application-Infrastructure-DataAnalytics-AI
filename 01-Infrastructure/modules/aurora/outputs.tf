output "cluster_id" {
  description = "Aurora cluster identifier"
  value       = aws_rds_cluster.primary.id
}

output "cluster_arn" {
  description = "Aurora cluster ARN"
  value       = aws_rds_cluster.primary.arn
}

output "writer_endpoint" {
  description = "Aurora writer endpoint"
  value       = aws_rds_cluster.primary.endpoint
}

output "reader_endpoint" {
  description = "Aurora reader endpoint"
  value       = aws_rds_cluster.primary.reader_endpoint
}

output "port" {
  description = "Aurora port"
  value       = aws_rds_cluster.primary.port
}

output "instance_ids" {
  description = "Aurora instance identifiers (writer + readers)"
  value = concat(
    [aws_rds_cluster_instance.writer.id],
    aws_rds_cluster_instance.readers[*].id
  )
}

output "global_cluster_id" {
  description = "Aurora Global Database identifier (empty when enable_global_db=false)"
  value       = var.enable_global_db ? aws_rds_global_cluster.ecommerce[0].id : ""
}

output "proxy_id" {
  description = "RDS Proxy ID"
  value       = aws_db_proxy.ecommerce.id
}

output "proxy_endpoint" {
  description = "RDS Proxy endpoint - use this from EKS pods via Secrets Manager"
  value       = aws_db_proxy.ecommerce.endpoint
}

output "cloudwatch_alarm_arns" {
  description = "CloudWatch alarm ARNs"
  value = [
    aws_cloudwatch_metric_alarm.cpu_high.arn,
    aws_cloudwatch_metric_alarm.freeable_memory.arn,
    aws_cloudwatch_metric_alarm.db_connections.arn,
    aws_cloudwatch_metric_alarm.replica_lag.arn,
    aws_cloudwatch_metric_alarm.global_replica_lag.arn
  ]
}

output "dr_kms_key_arn" {
  description = "KMS key ARN in the DR region (us-west-2) — created when enable_global_db=true. Used by DR WAF S3 bucket + DR SSM params."
  value       = var.enable_global_db ? aws_kms_key.dr_aurora[0].arn : ""
}

output "secondary_cluster_endpoint" {
  description = "DR Aurora secondary cluster endpoint (us-west-2). Empty when Global DB disabled."
  value       = var.enable_global_db ? aws_rds_cluster.secondary[0].endpoint : ""
}

output "global_cluster_id" {
  description = "Aurora Global Database identifier. Empty when Global DB disabled."
  value       = var.enable_global_db ? aws_rds_global_cluster.ecommerce[0].id : ""
}
