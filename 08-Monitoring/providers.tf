# =============================================================================
# 08-Monitoring — Providers
# =============================================================================
# This is a STANDALONE Terraform project (no modules).
# It connects to the EKS cluster created by 01-Infrastructure and installs
# monitoring + DevOps tooling, exposed through a Gateway API ALB with IP
# restriction.
#
# PREREQUISITES:
#   1. 01-Infrastructure must be applied first (creates EKS + GatewayClass)
#   2. kubectl must be able to reach the cluster:
#        aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region <region>
#   3. Gateway API CRDs + GatewayClass "alb-gateway" already exist (from eks-addons)
#
# APPLY:
#   cd 08-Monitoring
#   terraform init
#   terraform apply -var-file="monitoring.tfvars"
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
  }
}

# ── AWS provider ─────────────────────────────────────────────────────────────
provider "aws" {
  region = var.region
}

# ── Kubernetes provider — connects to EKS cluster ─────────────────────────────
data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# ── Helm provider — same EKS cluster ──────────────────────────────────────────
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Account ID (for building ARNs)
data "aws_caller_identity" "current" {}

# VPC ID — needed for ALB security group
data "aws_vpc" "eks_vpc" {
  filter {
    name   = "tag:Name"
    values = ["pip-project-ecommerce-vpc"]
  }
}
