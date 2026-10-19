variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev / prod)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN used to encrypt the S3 logs bucket and Firehose"
  type        = string
}

variable "elb_account_id" {
  description = <<-EOT
    AWS ELB service account ID for the deployment region.
    This is the account that writes ALB access logs to S3.
    Find the correct ID for your region at:
    https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html
    Common values:
      ap-south-1  = 718504428378
      us-east-1   = 127311923021
      us-west-2   = 797873946194
      eu-west-1   = 156460612806
  EOT
  type        = string
}

variable "log_transition_days" {
  description = "Days before transitioning log objects to Glacier"
  type        = number
  default     = 90
}

variable "log_expiration_days" {
  description = "Days before expiring log objects entirely"
  type        = number
  default     = 365
}
