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
  description = "Aurora Global Database identifier"
  value       = aws_rds_global_cluster.this.id
}

output "proxy_id" {
  description = "RDS Proxy ID"
  value       = aws_db_proxy.this.id
}

output "proxy_endpoint" {
  description = "RDS Proxy endpoint - use this from EKS application"
  value       = aws_db_proxy.this.endpoint
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
