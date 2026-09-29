variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "cluster_role_arn" {
  description = "IAM role ARN for EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.32"
}

variable "node_role_arn" {
  description = "IAM role ARN for EKS node groups"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs — workers node group (application pods)"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs — public node group (ALB ip-mode support)"
  type        = list(string)
}

variable "db_subnet_ids" {
  description = "Database subnet IDs — db_nodes node group (disabled by default, see create_db_nodes)"
  type        = list(string)
}

variable "private_route_dependency" {
  description = "Pass module.networking.private_route_table_association_ids here. Forces workers node group to wait until private subnets have a real NAT route before nodes try to bootstrap."
  type        = any
  default     = null
}

variable "database_route_dependency" {
  description = "Pass module.networking.database_route_table_association_ids here. Same purpose as private_route_dependency but for db_nodes."
  type        = any
  default     = null
}

# ==============================================
# Worker node group sizing
# ==============================================
variable "worker_instance_type" {
  description = "Instance type for private worker nodes (runs application pods)"
  type        = string
  default     = "t3.medium"
}

variable "workers_desired" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "workers_min" {
  description = "Minimum worker nodes"
  type        = number
  default     = 2
}

variable "workers_max" {
  description = "Maximum worker nodes (Cluster Autoscaler ceiling)"
  type        = number
  default     = 6
}

# ==============================================
# Public node group sizing
# ==============================================
variable "public_node_instance_type" {
  description = "Instance type for public subnet nodes (ALB support)"
  type        = string
  default     = "t3.small"
}

variable "public_desired" {
  description = "Desired number of public nodes. 1 per AZ is sufficient for ALB ip-mode."
  type        = number
  default     = 1
}

variable "public_min" {
  description = "Minimum public nodes"
  type        = number
  default     = 1
}

variable "public_max" {
  description = "Maximum public nodes"
  type        = number
  default     = 3
}

# ==============================================
# DB node group — disabled by default
# ==============================================
variable "create_db_nodes" {
  description = <<-EOT
    Set to true to create a dedicated EKS node group in the database subnets.
    Default: false — Aurora RDS is AWS-managed; no pods need database subnet placement today.
    Enable only when a future workload (data pipeline, migration pod, etc.) needs
    to run co-located with Aurora in the database subnets.
  EOT
  type        = bool
  default     = false
}

variable "db_node_instance_type" {
  description = "Instance type for db nodes. Only used when create_db_nodes = true."
  type        = string
  default     = "t3.medium"
}

variable "region" {
  description = "AWS region — used for auto kubeconfig update after cluster creation"
  type        = string
  default     = "us-east-1"
}
