output "primary_endpoint" {
  description = "Redis primary endpoint address — for write operations (user-service sessions, cart writes)"
  value       = aws_elasticache_replication_group.ecommerce.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Redis reader endpoint address — for read operations"
  value       = aws_elasticache_replication_group.ecommerce.reader_endpoint_address
}

output "port" {
  description = "Redis port (6379)"
  value       = aws_elasticache_replication_group.ecommerce.port
}

output "replication_group_id" {
  description = "ElastiCache Replication Group ID"
  value       = aws_elasticache_replication_group.ecommerce.id
}

output "security_group_id" {
  description = "ElastiCache security group ID"
  value       = aws_security_group.elasticache.id
}

output "auth_secret_arn" {
  description = "Secrets Manager ARN for Redis AUTH token — pods use this via Secrets Store CSI driver"
  value       = aws_secretsmanager_secret.redis_auth.arn
}

output "auth_secret_name" {
  description = "Secrets Manager secret name for Redis AUTH token"
  value       = aws_secretsmanager_secret.redis_auth.name
}

output "redis_host_ssm_path" {
  description = "SSM Parameter path for Redis primary endpoint hostname"
  value       = aws_ssm_parameter.redis_host.name
}
