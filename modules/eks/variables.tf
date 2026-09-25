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
  description = "IAM role ARN for cluster"
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes version. Use a version supported by your AWS account/region (e.g. 1.32)."
  type        = string
  default     = "1.32"
}

variable "node_role_arn" {
  description = "IAM role ARN for nodes"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for worker nodes"
  type        = list(string)
}

variable "db_subnet_ids" {
  description = "Database subnet IDs for DB nodes"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the public node group (ALB / instance target-type support)"
  type        = list(string)
}

variable "private_route_dependency" {
  description = "Opaque value (e.g. NAT gateway ID or route table association IDs) used purely to force Terraform to wait until the private subnets have a real internet route before creating the workers node group. Prevents nodes from launching before NAT is ready and hanging on bootstrap."
  type        = any
  default     = null
}

variable "database_route_dependency" {
  description = "Same purpose as private_route_dependency, but for the database subnets / db_nodes node group."
  type        = any
  default     = null
}

variable "worker_instance_type" {
  description = "Instance type for worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "db_node_instance_type" {
  description = "Instance type for DB specific nodes"
  type        = string
  default     = "t3.medium"
}

variable "public_node_instance_type" {
  description = "Instance type for public subnet nodes"
  type        = string
  default     = "t3.medium"
}
