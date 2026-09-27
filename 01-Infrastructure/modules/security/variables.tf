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
