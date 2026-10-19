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
  description = "Aurora PostgreSQL engine version. 17.9 = latest Aurora PostgreSQL LTS as of 2026."
  type        = string
  default     = "17.9"
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
  description = "Aurora instance class — prod uses db.r6g.large (16 GB RAM, Graviton2, no CPU bursting)"
  type        = string
  default     = "db.r6g.large"
}

variable "aurora_reader_count" {
  description = <<-EOT
    Number of Aurora reader instances in the primary cluster.
    2 = cross-AZ read HA: reader-1 in AZ[1], reader-2 in AZ[2].
    Writer is in AZ[0]. Any single AZ failure leaves 1 reader + the surviving
    nodes to handle traffic. Aurora auto-promotes a reader to writer in ~30s.
    Do NOT set below 2 — 1 reader means an AZ failure can take out both
    writer and reader simultaneously.
  EOT
  type    = number
  default = 2
}

variable "enable_global_db" {
  description = <<-EOT
    Enable Aurora Global Database (cross-region replication to DR region).
    Prod: true — async replication to us-west-2 DR cluster (typically <1s lag).
    Secondary cluster has 2 cross-AZ readers, ready for promotion.
    During failover:
      aws rds failover-global-cluster --global-cluster-identifier <id>
  EOT
  type    = bool
  default = true
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

variable "cluster_endpoint_public_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the EKS public API endpoint (kubectl/API access).
    Default 0.0.0.0/0 keeps things open — MUST be restricted for production.

    What to add:
      - VPC CIDR         : "10.0.0.0/16"        all nodes + bastion inside VPC
      - Your office IP   : "203.0.113.45/32"     your laptop/workstation
      - NAT Gateway EIP  : "52.90.100.200/32"    private nodes hit the API via NAT
      - CI/CD runner IP  : "18.209.0.0/16"       GitHub Actions / Jenkins runner

    Get your NAT EIP after first apply:
      terraform output -raw nat_gateway_eip
      OR: AWS Console → VPC → Elastic IPs

    /32 = exactly one IP.   /16 = a range.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ==============================================
# DR Region Networking (us-west-2)
# Different CIDRs to avoid overlap if VPC peering is needed later
# ==============================================
variable "dr_vpc_cidr" {
  description = "VPC CIDR for DR region (us-west-2)"
  type        = string
  default     = "10.2.0.0/16"
}

variable "dr_azs" {
  description = "Availability zones in DR region"
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b", "us-west-2c"]
}

variable "dr_public_subnets" {
  description = "Public subnet CIDRs in DR region"
  type        = list(string)
  default     = ["10.2.1.0/24", "10.2.2.0/24", "10.2.3.0/24"]
}

variable "dr_private_subnets" {
  description = "Private subnet CIDRs in DR region"
  type        = list(string)
  default     = ["10.2.11.0/24", "10.2.12.0/24", "10.2.13.0/24"]
}

variable "dr_database_subnets" {
  description = "Database subnet CIDRs in DR region"
  type        = list(string)
  default     = ["10.2.21.0/24", "10.2.22.0/24", "10.2.23.0/24"]
}

variable "enable_compute" {
  description = <<-EOT
    Set to true to create Bastion + Jenkins EC2 instances.
    Disabled by default while vCPU account limit is pending increase.
    Bastion = t3.micro (1 vCPU), Jenkins = t3.medium (2 vCPU) = 3 vCPU total.
    Once EC2 vCPU limit is raised to 32, set this to true and re-apply.
  EOT
  type        = bool
  default     = false
}

# force_db_setup variable removed — DB/table creation no longer in Terraform.
# Use ./06-Scripts/01-setup-databases.sh instead.

variable "dr_alb_dns_name" {
  description = <<-EOT
    DNS name of the DR region (us-west-2) external ALB.
    Empty until the app is deployed to DR and its ALB is provisioned.
    When set, route53_acm creates PRIMARY/SECONDARY failover records.
  EOT
  type    = string
  default = ""
}

# ==============================================
# ALB auto-discovery toggle (see alb-discovery.tf)
# ==============================================
variable "discover_alb_from_ingress" {
  description = <<-EOT
    When true, Route53 reads the live external ALB hostname from the Kubernetes
    ingress in each region (auto-follows a rebuilt ALB — no manual tfvars edit).
    Leave FALSE on the very first apply (no cluster/app yet), then set TRUE for
    re-applies after the app is deployed.
      Fresh build : false → uses alb_dns_name / dr_alb_dns_name from tfvars
      Re-apply    : true  → auto-discovers current ALBs from the ingress
  EOT
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Email address for SNS alarm notifications (Aurora, EKS, ALB, NAT). Leave empty to skip."
  type        = string
  default     = ""
}
