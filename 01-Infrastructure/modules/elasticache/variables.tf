variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev / prod)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the ElastiCache security group"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the ElastiCache subnet group. Redis lives in private subnets, NOT database subnets."
  type        = list(string)
}

variable "eks_sg_id" {
  description = "EKS node security group ID — only EKS nodes are allowed to connect to Redis"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for at-rest encryption and Secrets Manager encryption"
  type        = string
}

variable "auth_token" {
  description = <<-EOT
    Redis AUTH token (password). Must be 16–128 characters, alphanumeric + special chars.
    Pass via TF_VAR_redis_auth_token environment variable — never hardcode.
    Stored in Secrets Manager; pods retrieve it via Secrets Store CSI driver.
  EOT
  type        = string
  sensitive   = true
}

variable "node_type" {
  description = "ElastiCache node type. cache.t3.micro for dev, cache.r6g.large for prod."
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "num_replicas" {
  description = "Number of read replicas (0 for dev, 1+ for prod). Set >0 to enable multi-AZ failover."
  type        = number
  default     = 0
}

variable "maintenance_window" {
  description = "Weekly maintenance window (UTC)"
  type        = string
  default     = "sun:05:00-sun:06:00"
}

variable "snapshot_retention_limit" {
  description = "Number of days to retain Redis snapshots (0 disables backups)"
  type        = number
  default     = 1
}

variable "snapshot_window" {
  description = "Daily snapshot window (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications. Leave empty to disable."
  type        = string
  default     = ""
}
