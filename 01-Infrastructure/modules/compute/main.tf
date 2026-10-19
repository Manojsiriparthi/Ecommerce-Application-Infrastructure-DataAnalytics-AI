# =========================================================================
# COMPUTE MODULE — Bastion Host
# =========================================================================
# RESOURCES:
#   1. tls_private_key        — generates RSA-4096 key pair
#   2. aws_key_pair           — uploads public key to EC2
#   3. local_sensitive_file   — saves private key (.pem) to local disk
#   4. aws_instance.bastion   — bastion host in public subnet
#
# ACCESS:
#   SSH : ssh -i <key_path> ec2-user@<bastion_public_ip>   (Amazon Linux)
#         ssh -i <key_path> ubuntu@<bastion_public_ip>     (Ubuntu)
#   SSM : aws ssm start-session --target <instance-id>     (no key needed)
#
# PORT 22 is open to var.ssh_allowed_cidr (default: 0.0.0.0/0).
# Restrict to your office IP in tfvars:
#   ssh_allowed_cidr = "203.0.113.5/32"
# =========================================================================

# =========================================================================
# 1. TLS KEY PAIR — generate RSA 4096-bit key
# =========================================================================
# Terraform generates the key locally → uploads public half to AWS →
# saves private half as a .pem file on your disk.
# The private key is marked sensitive so it never appears in plan output.
# =========================================================================
resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# =========================================================================
# 2. AWS KEY PAIR — register public key with EC2
# =========================================================================
resource "aws_key_pair" "bastion" {
  key_name   = "${var.project_name}-bastion-key"
  public_key = tls_private_key.bastion.public_key_openssh

  tags = {
    Name        = "${var.project_name}-bastion-key"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# =========================================================================
# 3. SAVE PRIVATE KEY TO LOCAL DISK
# =========================================================================
# Writes the .pem file to your local machine (wherever terraform apply runs).
# File path: <module_root>/keys/<project>-bastion.pem
# Permissions: 0400 (read-only for owner) — required by SSH.
#
# IMPORTANT: This file contains the private key. It is:
#   - Listed in .gitignore (never commit it)
#   - Marked sensitive in Terraform state (never shown in plan/output)
# =========================================================================
resource "local_sensitive_file" "bastion_private_key" {
  content         = tls_private_key.bastion.private_key_pem
  filename        = "${path.module}/keys/${var.project_name}-bastion.pem"
  file_permission = "0400"   # SSH requires 0400; 0644 causes "permissions too open" error
}

# =========================================================================
# 4. BASTION HOST (Public Subnet)
# =========================================================================
# PURPOSE:
#   - SSH jump host into the VPC for developers / ops
#   - kubectl access to EKS (via private API endpoint from inside VPC)
#   - psql access to Aurora via RDS Proxy
#   - SSM Session Manager access (no SSH needed if preferred)
#
# SIZE: t3.micro — bastion does no compute, only proxies sessions.
# DISK: 10 GB gp3 encrypted.
# PUBLIC IP: yes — needed for direct SSH inbound.
# =========================================================================
resource "aws_instance" "bastion" {
  ami                         = var.ami_id
  instance_type               = var.bastion_instance_type
  subnet_id                   = var.public_subnet_id
  vpc_security_group_ids      = [var.bastion_sg_id]
  iam_instance_profile        = var.bastion_instance_profile_name
  key_name                    = aws_key_pair.bastion.key_name
  associate_public_ip_address = true

  # IMDSv2 enforced — blocks SSRF metadata credential theft
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = 10
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags = {
      Name        = "${var.project_name}-bastion-volume"
      Environment = var.environment
      Backup      = "true"
    }
  }

  # Ensure SSM agent is running (needed even when using SSH, for SSM fallback)
  user_data = <<-INIT
    #!/bin/bash
    set -e
    if command -v snap &>/dev/null; then
      snap start amazon-ssm-agent 2>/dev/null || true
    fi
    systemctl enable amazon-ssm-agent 2>/dev/null || true
    systemctl start  amazon-ssm-agent 2>/dev/null || true
  INIT

  tags = {
    Name        = "${var.project_name}-bastion"
    Environment = var.environment
    Role        = "bastion"
    ManagedBy   = "terraform"
    Backup      = "true"
  }

  # Replace instance if AMI changes
  lifecycle {
    replace_triggered_by = [aws_key_pair.bastion]
  }
}
