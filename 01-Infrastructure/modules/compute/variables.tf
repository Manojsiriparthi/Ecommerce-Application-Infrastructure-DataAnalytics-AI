# =========================================================================
# COMPUTE MODULE VARIABLES
# =========================================================================

variable "project_name" {
  description = "Project name — prefix for all resource names and tags."
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name (dev | prod)."
  type        = string
}

# -------------------------------------------------------------------------
# AMI
# -------------------------------------------------------------------------
variable "ami_id" {
  description = <<-EOT
    AMI ID for the bastion host.
    Recommended:
      Amazon Linux 2023 : ami-0f403e3180720dd7e  (us-east-1)
      Ubuntu 22.04 LTS  : ami-0c7217cdde317cfec  (us-east-1)
    SSH user:
      Amazon Linux : ec2-user
      Ubuntu       : ubuntu
  EOT
  type        = string
}

# -------------------------------------------------------------------------
# Networking
# -------------------------------------------------------------------------
variable "public_subnet_id" {
  description = "Public subnet ID — bastion gets a public IP in this subnet."
  type        = string
}

variable "bastion_sg_id" {
  description = "Security group ID for the bastion host (port 22 + egress)."
  type        = string
}

# -------------------------------------------------------------------------
# IAM
# -------------------------------------------------------------------------
variable "bastion_instance_profile_name" {
  description = "IAM instance profile for bastion (SSM Session Manager access)."
  type        = string
}

# -------------------------------------------------------------------------
# Bastion sizing
# -------------------------------------------------------------------------
variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion. t3.micro is sufficient."
  type        = string
  default     = "t3.micro"
}

# -------------------------------------------------------------------------
# SSH access
# -------------------------------------------------------------------------
variable "ssh_allowed_cidr" {
  description = <<-EOT
    CIDR allowed to SSH (port 22) into the bastion.
    Default: "0.0.0.0/0" — open to all.
    Restrict to your office/home IP for production:
      ssh_allowed_cidr = "203.0.113.5/32"
    Note: The bastion SG is managed in the networking module.
    This variable is informational here and used in outputs/docs.
    To restrict SSH at the SG level, set it in the networking module's
    bastion_sg ingress rule instead.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}
