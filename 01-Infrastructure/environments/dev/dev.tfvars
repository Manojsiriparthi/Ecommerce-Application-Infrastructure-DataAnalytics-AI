# =============================================================================
# DEV ENVIRONMENT — Terraform Variables
# =============================================================================
# USAGE:
#   export TF_VAR_db_master_password="YourStrongPassword123!"
#   export TF_VAR_jwt_secret="your-jwt-secret-key"
#   export TF_VAR_internal_service_key="your-internal-service-key"
#   export TF_VAR_redis_auth_token="your-redis-auth-token-16chars-min"
#   terraform apply -var-file="dev.tfvars"
#
# OR use the wrapper script:
#   ./06-Scripts/04-terraform-apply.sh dev ap-south-1
#   (the script reads TF_VAR_* from environment — set them first)
#
# SENSITIVE VALUES — NOT in this file (set via TF_VAR_* environment variables):
#   db_master_password      → TF_VAR_db_master_password
#   jwt_secret              → TF_VAR_jwt_secret
#   internal_service_key    → TF_VAR_internal_service_key
#   redis_auth_token        → TF_VAR_redis_auth_token
# =============================================================================

# ── Region ───────────────────────────────────────────────────────────────────
primary_region = "ap-south-1"
dr_region      = "us-east-1"
environment    = "dev"

# ── Networking (VPC + Subnets) ────────────────────────────────────────────────
vpc_cidr = "10.0.0.0/16"

azs = [
  "ap-south-1a",
  "ap-south-1b",
  "ap-south-1c",
]

public_subnets = [
  "10.0.1.0/24",
  "10.0.2.0/24",
  "10.0.3.0/24",
]

private_subnets = [
  "10.0.11.0/24",
  "10.0.12.0/24",
  "10.0.13.0/24",
]

database_subnets = [
  "10.0.21.0/24",
  "10.0.22.0/24",
  "10.0.23.0/24",
]

# ── AMI for Bastion host ──────────────────────────────────────────────────────
# Get latest Amazon Linux 2023 AMI:
#   aws ssm get-parameter \
#     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
#     --region ap-south-1 --query 'Parameter.Value' --output text
ami_id = "ami-0f403e3180720dd7e"

# ── EKS Cluster ───────────────────────────────────────────────────────────────
eks_cluster_version = "1.35"

# Worker nodes (private) — t3.medium = 2 vCPU / 4 GB RAM
worker_instance_type = "t3.medium"

# Public nodes (ALB support) — t3.small = 2 vCPU / 2 GB RAM
public_node_instance_type = "t3.medium"

# API endpoint — restrict to your IP for security
# Get your IP: curl ifconfig.me
# Format: ["10.0.0.0/16", "YOUR_IP/32"]
cluster_endpoint_public_cidrs = ["0.0.0.0/0"]

# ── Aurora PostgreSQL ────────────────────────────────────────────────────────
aurora_engine_version  = "17.9"
aurora_instance_class  = "db.t3.medium"
aurora_reader_count    = 2

# Dev: no cross-region Global DB (saves cost)
enable_global_db = false

# ── ElastiCache Redis ────────────────────────────────────────────────────────
redis_node_type = "cache.t3.micro"

# ── Domain + ALB ─────────────────────────────────────────────────────────────
# Leave empty on first apply — A-records skipped until ALB exists.
# After Ingress is applied, fill from SSM or re-apply with discovery enabled.
domain_name   = ""
alb_dns_name  = ""

# ── Notifications ─────────────────────────────────────────────────────────────
# SNS alarm notifications — CloudWatch alerts go to this email
alert_email = "manojchowdary932@gmail.com"

# ── SES ──────────────────────────────────────────────────────────────────────
ses_from_email = "manojchowdary932@gmail.com"
