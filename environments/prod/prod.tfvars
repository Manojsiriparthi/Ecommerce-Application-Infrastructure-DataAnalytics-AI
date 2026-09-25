
# ==============================================
# pip-project-ecommerce - PRODUCTION environment values
# ==============================================

primary_region = "us-east-1"
dr_region      = "us-west-2"
environment    = "prod"

# Networking
vpc_cidr          = "10.1.0.0/16"
azs               = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnets    = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
private_subnets   = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]
database_subnets  = ["10.1.21.0/24", "10.1.22.0/24", "10.1.23.0/24"]

# EKS
worker_instance_type  = "t3.large"
db_node_instance_type = "r5.large"

# Compute (Bastion + Jenkins) - Amazon Linux 2023 AMI (update per region)
ami_id = "ami-0c101f26f147fa7fd"

# Aurora
aurora_instance_class = "db.r6g.large"
aurora_reader_count   = 2
enable_global_db      = true

# Sensitive - override via environment variable or -var at runtime:
# TF_VAR_db_master_password=<value> terraform apply -var-file=prod.tfvars
# db_master_password = "SET_VIA_TF_VAR_ENV_VARIABLE"
