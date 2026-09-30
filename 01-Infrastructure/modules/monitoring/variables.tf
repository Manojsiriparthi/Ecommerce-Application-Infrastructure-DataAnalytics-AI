variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev / prod)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for alarm notifications"
  type        = string
  default     = ""
}

variable "external_alb_arn_suffix" {
  description = <<-EOT
    ARN suffix of the external ALB created by the AWS Load Balancer Controller.
    Format: app/<name>/<id>
    Get it after ingress is applied:
      kubectl get ingress frontend-external-ingress -n ecommerce \
        -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/load-balancer-arn}' \
        | awk -F'loadbalancer/' '{print $2}'
    Leave empty on first apply — alarms that need it will be in INSUFFICIENT_DATA state.
  EOT
  type        = string
  default     = ""
}

variable "nat_gateway_id" {
  description = "NAT Gateway ID for NAT error alarm"
  type        = string
  default     = ""
}

variable "internal_alb_arn_suffix" {
  description = "ARN suffix of the internal ALB (for application dashboard)"
  type        = string
  default     = ""
}

variable "slack_webhook_url" {
  description = <<-EOT
    Slack Incoming Webhook URL for alarm notifications.
    Set post-deploy via aws lambda update-function-configuration to avoid
    storing the URL in Terraform state.
    Leave empty here — set directly on the Lambda function.
  EOT
  type      = string
  default   = ""
  sensitive = true
}
