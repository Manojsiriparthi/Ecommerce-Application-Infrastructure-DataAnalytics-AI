terraform {
  # required_providers block lives in backend.tf
}

# ==============================================
# Primary AWS provider — ap-south-1 (Mumbai)
# ==============================================
provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "pip-project-ecommerce"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

# ==============================================
# DR region provider — us-east-1
# Used only by Aurora Global Database secondary cluster.
# ==============================================
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = "pip-project-ecommerce"
      Environment = "dev"
      ManagedBy   = "terraform"
      Region      = "DR"
    }
  }
}

# ==============================================
# Helm + Kubernetes providers
# ==============================================
# PROBLEM WITH data "aws_eks_cluster":
#   It runs at plan time. On the first apply the cluster doesn't
#   exist yet so it fails with "couldn't find resource".
#
# SOLUTION — exec-based token via aws CLI:
#   The exec block calls `aws eks get-token` lazily — only when
#   Terraform actually needs to talk to Kubernetes (i.e. when
#   applying a helm_release or kubernetes resource).
#   During the first plan/apply the Helm provider is configured
#   but never connects because eks_addons runs AFTER the EKS
#   module creates the cluster.
#
#   cluster_endpoint and cluster_ca_certificate come from the
#   module outputs. On the first plan these are "known after apply"
#   (empty) so Terraform skips Helm provider validation entirely.
#   On apply, by the time eks_addons runs, the values are real.
# ==============================================

provider "helm" {
  kubernetes {
    host = try(module.eks.cluster_endpoint, "")
    cluster_ca_certificate = try(
      base64decode(module.eks.cluster_certificate_authority_data),
      ""
    )
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", "pip-project-ecommerce-cluster",
        "--region", var.primary_region
      ]
    }
  }
}

provider "kubernetes" {
  host = try(module.eks.cluster_endpoint, "")
  cluster_ca_certificate = try(
    base64decode(module.eks.cluster_certificate_authority_data),
    ""
  )
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", "pip-project-ecommerce-cluster",
      "--region", var.primary_region
    ]
  }
}
