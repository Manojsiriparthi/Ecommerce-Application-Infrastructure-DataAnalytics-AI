# =============================================================================
# PROD ENVIRONMENT — Terraform Variables
# =============================================================================
# USAGE:
#   export TF_VAR_db_master_password="YourStrongPassword123!"
#   export TF_VAR_jwt_secret="your-jwt-secret-key"
#   export TF_VAR_internal_service_key="your-internal-service-key"
#   export TF_VAR_redis_auth_token="your-redis-auth-token-16chars-min"
#   terraform apply -var-file="prod.tfvars"
#
# OR use the wrapper script:
#   ./06-Scripts/04-terraform-apply.sh prod us-east-1
#   (set TF_VAR_* first — the script reads them from environment)
#
# SENSITIVE VALUES — NOT in this file (set via TF_VAR_* environment variables):
#   db_master_password      → TF_VAR_db_master_password
#   jwt_secret              → TF_VAR_jwt_secret
#   internal_service_key    → TF_VAR_internal_service_key
#   redis_auth_token        → TF_VAR_redis_auth_token
# =============================================================================

# ── Region ───────────────────────────────────────────────────────────────────
primary_region = "us-east-1"
dr_region      = "us-west-2"
environment    = "prod"

# ── Networking (VPC + Subnets) ────────────────────────────────────────────────
vpc_cidr = "10.1.0.0/16"

azs = [
  "us-east-1a",
  "us-east-1b",
  "us-east-1c",
]

public_subnets = [
  "10.1.1.0/24",
  "10.1.2.0/24",
  "10.1.3.0/24",
]

private_subnets = [
  "10.1.11.0/24",
  "10.1.12.0/24",
  "10.1.13.0/24",
]

database_subnets = [
  "10.1.21.0/24",
  "10.1.22.0/24",
  "10.1.23.0/24",
]

# ── DR Region Networking (us-west-2) ─────────────────────────────────────────
# Different CIDR to avoid overlap if VPC peering is added later
dr_vpc_cidr = "10.2.0.0/16"

dr_azs = [
  "us-west-2a",
  "us-west-2b",
  "us-west-2c",
]

dr_public_subnets = [
  "10.2.1.0/24",
  "10.2.2.0/24",
  "10.2.3.0/24",
]

dr_private_subnets = [
  "10.2.11.0/24",
  "10.2.12.0/24",
  "10.2.13.0/24",
]

dr_database_subnets = [
  "10.2.21.0/24",
  "10.2.22.0/24",
  "10.2.23.0/24",
]

# ── AMI for Bastion host ──────────────────────────────────────────────────────
# Get latest Amazon Linux 2023 AMI:
#   aws ssm get-parameter \
#     --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
#     --region us-east-1 --query 'Parameter.Value' --output text
ami_id = "ami-0f403e3180720dd7e"

# ── EKS Cluster ───────────────────────────────────────────────────────────────
eks_cluster_version = "1.35"

# Worker nodes (private) — t3.medium = 2 vCPU / 4 GB RAM (same as dev)
worker_instance_type = "t3.medium"

# Public nodes (ALB support) — t3.medium (same as dev)
public_node_instance_type = "t3.medium"

# API endpoint — MUST restrict for production
# Get your IP: curl ifconfig.me
# Format: ["10.1.0.0/16", "YOUR_IP/32"]
cluster_endpoint_public_cidrs = ["0.0.0.0/0"]

# ── Aurora PostgreSQL ────────────────────────────────────────────────────────
# Prod: r6g.large = 2 vCPU / 16 GB RAM (Graviton2, memory-optimised)
# Why not t3.medium: t3 is burstable — CPU credits run out under sustained
# traffic, performance drops 20%. t3.medium has only 4 GB RAM — not enough
# for PostgreSQL shared_buffers + effective_cache_size + connection pooling.
# r6g.large has 16 GB RAM — caches hot data, handles traffic spikes, VACUUM
# without memory pressure. ~$180/month per instance (writer + 2 readers = ~$540/mo).
aurora_engine_version  = "17.9"
aurora_instance_class  = "db.r6g.large"
aurora_reader_count    = 2

# Prod: cross-region Global DB enabled (DR in us-west-2)
enable_global_db = true

# ── ElastiCache Redis ────────────────────────────────────────────────────────
# Prod: r6g.large for higher throughput and memory
redis_node_type = "cache.r6g.large"

# ── Domain + ALB ─────────────────────────────────────────────────────────────
# Set your domain — Route53 + ACM cert created on first apply
# Example: domain_name = "ecommerce-pip.com"
domain_name  = ""
alb_dns_name = ""

# ALB auto-discovery from Kubernetes Ingress (set to true after first apply
# when the app + Ingress are live — follows rebuilt ALBs automatically)
discover_alb_from_ingress = false

# ── Compute (Bastion host) ───────────────────────────────────────────────────
# Set to true to create the bastion host in the public subnet
enable_compute = true

# ── Notifications ─────────────────────────────────────────────────────────────
# SNS alarm notifications — CloudWatch alerts go to this email
alert_email = "manojchowdary932@gmail.com"

# ── SES ──────────────────────────────────────────────────────────────────────
ses_from_email = "manojchowdary932@gmail.com"
