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

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDRs"
  type        = list(string)
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

variable "database_subnets" {
  description = "Database subnet CIDRs"
  type        = list(string)
}

variable "worker_instance_type" {
  description = "EKS worker node instance type"
  type        = string
  default     = "t3.medium"
}

variable "public_node_instance_type" {
  description = "EKS public subnet node instance type — supports ALB ip-mode target routing"
  type        = string
  default     = "t3.medium"
}

variable "eks_cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version (must support Global Database when enable_global_db = true)"
  type        = string
  default     = "15.4"
}

variable "ami_id" {
  description = "AMI ID for bastion/jenkins EC2 instances"
  type        = string
}

variable "db_master_password" {
  description = "Aurora master password"
  type        = string
  sensitive   = true
}

variable "aurora_instance_class" {
  description = "Aurora instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "aurora_reader_count" {
  description = "Number of Aurora reader instances"
  type        = number
  default     = 2
}

variable "enable_global_db" {
  description = "Enable Aurora Global Database (cross-region DR)"
  type        = bool
  default     = true
}

# ==============================================
# New variables for WAF, ElastiCache, Security additions
# ==============================================

variable "jwt_secret" {
  description = "JWT signing secret. Pass via TF_VAR_jwt_secret."
  type        = string
  sensitive   = true
}

variable "internal_service_key" {
  description = "Internal service-to-service key. Pass via TF_VAR_internal_service_key."
  type        = string
  sensitive   = true
}

variable "ses_from_email" {
  description = "SES verified sender email for notification-service"
  type        = string
  default     = "noreply@yourdomain.com"
}

variable "redis_auth_token" {
  description = "Redis AUTH token (16-128 chars). Pass via TF_VAR_redis_auth_token."
  type        = string
  sensitive   = true
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.r6g.large"
}

variable "domain_name" {
  description = <<-EOT
    Root domain name for production.
    Example: "ecommerce-pip.com"
    Same domain as dev — Route53 uses the same hosted zone.
    ACM issues a separate production certificate.
  EOT
  type        = string
  default     = ""
}

variable "alb_dns_name" {
  description = <<-EOT
    DNS name of the production external ALB.
    Empty on first apply. Set on second apply after ALB is provisioned.
    Format: <hash>.us-east-1.elb.amazonaws.com
  EOT
  type        = string
  default     = ""
}
