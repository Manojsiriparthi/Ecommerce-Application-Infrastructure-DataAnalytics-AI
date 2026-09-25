# ==============================================
# pip-project-ecommerce - DEV environment values
# Primary region: ap-south-1 (Mumbai)
# DR region:      us-east-1 (N. Virginia)
# ==============================================

primary_region = "ap-south-1"
dr_region      = "us-east-1"
environment    = "dev"

# Networking
vpc_cidr         = "10.0.0.0/16"
azs              = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
public_subnets   = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnets  = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
database_subnets = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]

# EKS
worker_instance_type  = "t3.medium"
db_node_instance_type = "t3.medium"

# Compute (Bastion + Jenkins) - Ubuntu 22.04 LTS AMI for ap-south-1
# Owner: Canonical (099720109477) - verify/update AMI ID at deploy time:
#   aws ec2 describe-images --owners 099720109477 \
#     --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
#     "Name=state,Values=available" --region ap-south-1 \
#     --query "sort_by(Images,&CreationDate)[-1].ImageId" --output text
ami_id = "ami-0f5ee92e2d63afc18"

# Aurora
aurora_instance_class = "db.r5.large"
aurora_reader_count   = 1
enable_global_db      = false

# Sensitive - override via environment variable or -var at runtime:
# TF_VAR_db_master_password=<value> terraform apply -var-file=dev.tfvars
# db_master_password = "SET_VIA_TF_VAR_ENV_VARIABLE"
