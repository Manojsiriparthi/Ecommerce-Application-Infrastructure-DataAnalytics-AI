variable "project_name" {
  description = "Project name — used as ECR repository prefix"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev | prod)"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encrypting ECR repositories at rest"
  type        = string
}
