variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL for IRSA (without https://)"
  type        = string
}

variable "region" {
  description = "AWS region — used to scope Karpenter EC2 permissions and build EventBridge ARNs"
  type        = string
  default     = "us-east-1"
}

variable "karpenter_node_role_arn" {
  description = <<-EOT
    ARN of the IAM role that Karpenter passes to new EC2 instances.
    Typically the same EKS node role (AmazonEKSWorkerNodePolicy etc.)
    Pass module.iam.node_role_arn from the environment.
  EOT
  type    = string
  default = ""
}

# NOTE: karpenter_sqs_queue_arn variable REMOVED.
# The SQS queue is now created IN this module (aws_sqs_queue.karpenter_interruption)
# so the Karpenter role policy can scope to the real ARN in a single terraform apply.
