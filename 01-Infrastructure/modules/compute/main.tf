# ==============================================
# Bastion Host (Public Subnet)
# Access via AWS Systems Manager Session Manager - no SSH key needed
# ==============================================
resource "aws_instance" "bastion" {
  ami                    = var.ami_id
  instance_type          = var.bastion_instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [var.bastion_sg_id]
  iam_instance_profile   = var.bastion_instance_profile_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name        = "${var.project_name}-bastion"
    Environment = var.environment
  }
}

# ==============================================
# Jenkins Server (Private Subnet)
# Access via AWS Systems Manager Session Manager - no SSH key needed
# User data installs and starts Jenkins automatically (Ubuntu/apt)
# ==============================================
resource "aws_instance" "jenkins" {
  ami                    = var.ami_id
  instance_type          = var.jenkins_instance_type
  subnet_id              = var.private_subnet_id
  vpc_security_group_ids = [var.jenkins_sg_id]
  iam_instance_profile   = var.jenkins_instance_profile_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get install -y fontconfig openjdk-17-jre wget gnupg curl

    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | \
      tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc]" \
      "https://pkg.jenkins.io/debian-stable binary/" | \
      tee /etc/apt/sources.list.d/jenkins.list > /dev/null

    apt-get update -y
    apt-get install -y jenkins

    systemctl daemon-reload
    systemctl enable jenkins
    systemctl start jenkins

    snap start amazon-ssm-agent 2>/dev/null || systemctl enable amazon-ssm-agent 2>/dev/null || true
    snap start amazon-ssm-agent 2>/dev/null || systemctl start amazon-ssm-agent 2>/dev/null || true
  EOF

  tags = {
    Name        = "${var.project_name}-jenkins"
    Environment = var.environment
  }
}

# ==============================================
# Post-Deployment Automation (local-exec provisioner)
# NOTE: explicitly invoking bash to avoid permission issues.
# ==============================================
resource "null_resource" "jenkins_post_deploy" {
  triggers = {
    instance_id = aws_instance.jenkins.id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/scripts/post-deploy.sh ${aws_instance.jenkins.id} ${var.environment}"
  }

  depends_on = [aws_instance.jenkins]
}

