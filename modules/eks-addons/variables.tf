variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "ebs_csi_role_arn" {
  description = "EBS CSI driver IRSA role ARN"
  type        = string
}

variable "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IRSA role ARN"
  type        = string
}

variable "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler IRSA role ARN"
  type        = string
}
