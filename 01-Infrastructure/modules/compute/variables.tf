variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "ami_id" {
  description = "AMI ID for instances (Amazon Linux 2/2023 recommended)"
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet ID for bastion"
  type        = string
}

variable "private_subnet_id" {
  description = "Private subnet ID for Jenkins"
  type        = string
}

variable "bastion_sg_id" {
  description = "Bastion security group ID"
  type        = string
}

variable "jenkins_sg_id" {
  description = "Jenkins security group ID"
  type        = string
}

variable "bastion_instance_type" {
  description = "Bastion host instance type"
  type        = string
  default     = "t3.micro"
}

variable "jenkins_instance_type" {
  description = "Jenkins server instance type"
  type        = string
  default     = "t3.medium"
}

variable "bastion_instance_profile_name" {
  description = "IAM instance profile name for bastion (SSM Session Manager access)"
  type        = string
}

variable "jenkins_instance_profile_name" {
  description = "IAM instance profile name for Jenkins (SSM Session Manager + EKS/ECR access)"
  type        = string
}
