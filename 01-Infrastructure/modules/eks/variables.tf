# =========================================================================
# EKS MODULE VARIABLES
# =========================================================================

# -------------------------------------------------------------------------
# Identity
# -------------------------------------------------------------------------
variable "project_name" {
  description = "Project name — used as prefix for all resource names and tags."
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev | prod). Embedded in resource tags."
  type        = string
}

variable "region" {
  description = "AWS region — used for auto kubeconfig update after cluster creation."
  type        = string
  default     = "us-east-1"
}

# -------------------------------------------------------------------------
# IAM
# -------------------------------------------------------------------------
variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS control plane. Must have AmazonEKSClusterPolicy attached."
  type        = string
}

variable "node_role_arn" {
  description = "IAM role ARN for EKS node groups. Must have AmazonEKSWorkerNodePolicy, AmazonEC2ContainerRegistryReadOnly, AmazonEKS_CNI_Policy."
  type        = string
}

# -------------------------------------------------------------------------
# Cluster
# -------------------------------------------------------------------------
variable "cluster_version" {
  description = "EKS Kubernetes version. Use latest available minor version."
  type        = string
  default     = "1.32"
}

# -------------------------------------------------------------------------
# Networking
# -------------------------------------------------------------------------
variable "private_subnet_ids" {
  description = "Private subnet IDs — used by workers node group (app pods) and the cluster vpc_config."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs — used by the public node group (ALB ip-mode ENI support)."
  type        = list(string)
}

variable "db_subnet_ids" {
  description = "Database subnet IDs — reserved for db_nodes (currently commented out)."
  type        = list(string)
}

variable "private_route_dependency" {
  description = <<-EOT
    Pass module.networking.private_route_table_association_ids here.
    Forces the workers node group to wait until private subnets have a real
    NAT route before nodes start bootstrapping. Without this, nodes spin up
    with no outbound internet and fail to join the cluster (cannot pull ECR images).
  EOT
  type    = any
  default = null
}

variable "database_route_dependency" {
  description = "Same purpose as private_route_dependency but for the db_nodes group."
  type        = any
  default     = null
}

# -------------------------------------------------------------------------
# Cluster Endpoint Access
# -------------------------------------------------------------------------
variable "cluster_endpoint_public_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the EKS public API endpoint (kubectl / API access).

    HOW IT WORKS:
      endpoint_public_access = true   → API server is reachable from the internet
      public_access_cidrs             → but ONLY from these CIDRs

    WITHOUT restricting this (default = 0.0.0.0/0), anyone on the internet
    can send requests to the API server. Auth still applies, but the attack
    surface (brute force, CVE scans, log noise) is unnecessarily wide.

    WHAT TO INCLUDE:
      - VPC CIDR          "10.0.0.0/16"       nodes + bastion + Jenkins (private → API via ENI)
      - NAT Gateway EIP   "52.90.10.20/32"    private nodes reach PUBLIC endpoint via NAT
      - Office / laptop   "203.0.113.5/32"    your direct kubectl
      - CI/CD runner IP   "18.209.0.0/16"     GitHub Actions us-east-1 range (optional)

    /32 = exactly one IP address.   /16 = a range (65536 addresses).

    Get your NAT EIP after first apply:
      AWS Console → VPC → Elastic IPs
      OR: terraform output -raw nat_gateway_eip

    DEFAULT: ["0.0.0.0/0"] — keeps existing behaviour (open).
    Set real CIDRs in dev.tfvars / prod.tfvars before production.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -------------------------------------------------------------------------
# Encryption
# -------------------------------------------------------------------------
variable "kms_key_arn" {
  description = <<-EOT
    KMS key ARN for encrypting Kubernetes Secrets at rest.
    When set, EKS encrypts all Secret objects stored in etcd with this key.
    Pass module.security.kms_key_arn from the environment.
    Set to "" to skip encryption (not recommended for production).
  EOT
  type        = string
  default     = ""
}

# -------------------------------------------------------------------------
# Worker Node Group (Private Subnets — Application Pods)
# -------------------------------------------------------------------------
variable "worker_instance_type" {
  description = "EC2 instance type for private worker nodes. t3.medium = 2 vCPU / 4 GB RAM."
  type        = string
  default     = "t3.medium"
}

variable "workers_desired" {
  description = "Desired worker node count. 3 = one node per AZ for HA pod distribution."
  type        = number
  default     = 3
}

variable "workers_min" {
  description = "Minimum worker nodes. Set equal to desired to prevent Cluster Autoscaler from scaling below HA threshold."
  type        = number
  default     = 3
}

variable "workers_max" {
  description = "Maximum worker nodes — Cluster Autoscaler ceiling. Scale up during traffic spikes."
  type        = number
  default     = 6
}

variable "worker_disk_size_gb" {
  description = <<-EOT
    EBS root volume size (GB) for worker nodes.
    50 GB recommended: EKS default (20 GB) fills up quickly when multiple
    large container images are cached on the same node.
  EOT
  type        = number
  default     = 50
}

# -------------------------------------------------------------------------
# Public Node Group (Public Subnets — ALB Support)
# -------------------------------------------------------------------------
variable "public_node_instance_type" {
  description = "EC2 instance type for public subnet nodes. t3.small is sufficient (no app pods run here)."
  type        = string
  default     = "t3.small"
}

variable "public_desired" {
  description = "Desired public node count. 2 = one per AZ for ALB HA."
  type        = number
  default     = 2
}

variable "public_min" {
  description = "Minimum public nodes."
  type        = number
  default     = 2
}

variable "public_max" {
  description = "Maximum public nodes."
  type        = number
  default     = 3
}

# -------------------------------------------------------------------------
# DB Node Group — FUTURE USE (currently commented out in main.tf)
# -------------------------------------------------------------------------
variable "create_db_nodes" {
  description = <<-EOT
    FUTURE USE ONLY — the DB node group resource block is commented out.
    Aurora RDS is AWS-managed; no pods need database subnet placement today.
    Set true AND uncomment the resource block when a future workload
    (data pipeline, migration pod, Kafka) needs DB-subnet placement.
  EOT
  type        = bool
  default     = false
}

variable "db_node_instance_type" {
  description = "Instance type for db nodes. Only relevant when db_nodes is re-enabled."
  type        = string
  default     = "t3.medium"
}
