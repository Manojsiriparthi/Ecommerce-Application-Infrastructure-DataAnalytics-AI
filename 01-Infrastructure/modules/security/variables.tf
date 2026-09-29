variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "db_password" {
  description = "Database master password"
  type        = string
  sensitive   = true
}

variable "jwt_secret" {
  description = "JWT signing secret. Pass via TF_VAR_jwt_secret — never hardcode."
  type        = string
  sensitive   = true
}

variable "internal_service_key" {
  description = "Shared key for internal service-to-service /internal/* calls. Pass via TF_VAR_internal_service_key."
  type        = string
  sensitive   = true
}

variable "ses_from_email" {
  description = "SES verified sender email address for notification-service"
  type        = string
  default     = "noreply@yourdomain.com"
}

variable "vpc_id" {
  description = "VPC ID for Flow Logs attachment. Pass module.networking.vpc_id."
  type        = string
  default     = ""
}

variable "create_flow_logs" {
  description = <<-EOT
    Set to true to enable VPC Flow Logs to CloudWatch.
    Must be true when vpc_id is set.
    Kept as a separate boolean so Terraform can evaluate count at plan time
    (resource attribute values like vpc_id cannot be used in count directly).
  EOT
  type        = bool
  default     = false
}

variable "db_proxy_endpoint" {
  description = <<-EOT
    RDS Proxy endpoint — stored in the DB credentials secret so pods can
    read host via JMESPath. Pass module.aurora.proxy_endpoint here.
    Leave empty on first apply (proxy created after this module).
    The 01-setup-databases.sh script updates the secret after first apply.
  EOT
  type        = string
  default     = ""
}
