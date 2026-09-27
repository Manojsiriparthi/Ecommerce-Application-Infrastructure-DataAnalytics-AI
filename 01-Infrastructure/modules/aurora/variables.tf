variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL engine version. Must be a version that supports Aurora Global Database (15.5+ required) when enable_global_db = true."
  type        = string
  default     = "17.9"
}

variable "database_name" {
  description = "Database name"
  type        = string
  default     = "ecommerce"
}

variable "master_username" {
  description = "Master username"
  type        = string
  default     = "pipadmin"
}

variable "master_password" {
  description = "Master password"
  type        = string
  sensitive   = true
}

variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 35
}

variable "backup_window" {
  description = "Preferred backup window"
  type        = string
  default     = "02:00-03:00"
}

variable "maintenance_window" {
  description = "Preferred maintenance window"
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "db_subnet_group_name" {
  description = "DB subnet group name"
  type        = string
}

variable "aurora_sg_id" {
  description = "Security group ID for Aurora"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption"
  type        = string
}

variable "instance_class" {
  description = "Instance class for Aurora instances"
  type        = string
  default     = "db.t3.medium"
}

variable "reader_count" {
  description = "Number of reader instances"
  type        = number
  default     = 2
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights"
  type        = bool
  default     = true
}

variable "performance_insights_retention" {
  description = "Performance Insights retention period"
  type        = number
  default     = 7
}

variable "max_connections" {
  description = "Maximum database connections"
  type        = string
  default     = "LEAST({DBInstanceClassMemory/9531392}, 5000)"
}

variable "shared_buffers" {
  description = "PostgreSQL shared_buffers"
  type        = string
  default     = "{DBInstanceClassMemory/12038}"
}

variable "effective_cache_size" {
  description = "PostgreSQL effective_cache_size"
  type        = string
  default     = "{DBInstanceClassMemory/12038}"
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for alarms"
  type        = string
  default     = ""
}

variable "cpu_threshold" {
  description = "CPU utilization alarm threshold (%)"
  type        = number
  default     = 80
}

variable "replica_lag_threshold" {
  description = "Local replica lag threshold (ms)"
  type        = number
  default     = 1000
}

# ==============================================
# RDS Proxy variables
# ==============================================
variable "db_secret_arn" {
  description = "Secrets Manager ARN holding DB credentials, used by RDS Proxy auth"
  type        = string
}

variable "db_subnet_ids" {
  description = "Database subnet IDs (list) for RDS Proxy ENIs"
  type        = list(string)
}

variable "proxy_max_connections_percent" {
  description = "RDS Proxy max connections percent"
  type        = number
  default     = 100
}

variable "proxy_max_idle_connections_percent" {
  description = "RDS Proxy max idle connections percent"
  type        = number
  default     = 50
}

variable "proxy_connection_borrow_timeout" {
  description = "RDS Proxy connection borrow timeout (seconds)"
  type        = number
  default     = 120
}

variable "proxy_idle_client_timeout" {
  description = "RDS Proxy idle client timeout (seconds)"
  type        = number
  default     = 1800
}

# ==============================================
# Global Database / DR variables
# ==============================================
variable "enable_global_db" {
  description = "Enable Aurora Global Database secondary cluster in DR region"
  type        = bool
  default     = false
}

variable "primary_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "dr_region" {
  description = "DR AWS region"
  type        = string
  default     = "us-west-2"
}

variable "dr_db_subnet_group_name" {
  description = "DB subnet group name in DR region"
  type        = string
  default     = ""
}

variable "dr_aurora_sg_id" {
  description = "Aurora security group ID in DR region"
  type        = string
  default     = ""
}

variable "dr_kms_key_arn" {
  description = "KMS key ARN in DR region"
  type        = string
  default     = ""
}

variable "dr_reader_count" {
  description = "Number of reader instances in DR secondary cluster"
  type        = number
  default     = 1
}


