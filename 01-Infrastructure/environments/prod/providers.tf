terraform {
  # required_providers block lives in backend.tf
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "pip-project-ecommerce"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = "pip-project-ecommerce"
      Environment = "prod"
      ManagedBy   = "terraform"
      Region      = "DR"
    }
  }
}

# ==============================================
# Helm + Kubernetes providers
# ==============================================
# Uses ~/.kube/config which is updated by the infra pipeline
# via: aws eks update-kubeconfig --name pip-project-ecommerce-cluster
#
# WHY ~/.kube/config instead of exec-only:
#   exec-only without host= fails with "no configuration provided"
#   in Terraform Helm provider v2.x because it requires a host to
#   establish the TLS connection before calling exec for the token.
#
# The infra pipeline runs update-kubeconfig BEFORE eks_addons apply,
# so ~/.kube/config always has the correct endpoint by the time Helm runs.
# This is identical to how dev works (dev also uses ~/.kube/config).
# ==============================================

# PRIMARY (us-east-1) — uses the kubeconfig context for the primary cluster.
# config_context pins it to the primary cluster ARN so it never accidentally
# uses the DR context when both are in ~/.kube/config.
provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "arn:aws:eks:${var.primary_region}:${data.aws_caller_identity.current.account_id}:cluster/pip-project-ecommerce-cluster"
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "arn:aws:eks:${var.primary_region}:${data.aws_caller_identity.current.account_id}:cluster/pip-project-ecommerce-cluster"
}

# DR (us-west-2) — pinned to the DR cluster context.
# Both clusters share the name pip-project-ecommerce-cluster but live in
# different regions, so the context ARN (which includes the region) is unique.
# Run before applying DR addons:
#   aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-west-2
provider "helm" {
  alias = "dr"
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "arn:aws:eks:${var.dr_region}:${data.aws_caller_identity.current.account_id}:cluster/pip-project-ecommerce-cluster"
  }
}

provider "kubernetes" {
  alias          = "dr"
  config_path    = "~/.kube/config"
  config_context = "arn:aws:eks:${var.dr_region}:${data.aws_caller_identity.current.account_id}:cluster/pip-project-ecommerce-cluster"
}

# ==============================================
# Current account identity — used to build ECR registry URL
# for the aurora db-setup local-exec
# ==============================================
data "aws_caller_identity" "current" {}
