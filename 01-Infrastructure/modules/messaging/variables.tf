variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev | prod)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN — encrypts the SNS topic at rest."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = <<-EOT
    Email address to receive all CloudWatch alarm notifications.
    AWS sends a confirmation email on first apply — click the link to activate.
    Leave empty to skip the email subscription (Slack Lambda still fires).
    Example: "ops@yourcompany.com"
  EOT
  type    = string
  default = ""
}
