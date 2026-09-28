terraform {
  # required_providers block lives in backend.tf
}

# ==============================================
# Primary region — us-east-1
# ==============================================
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

# ==============================================
# DR region — us-west-2
# ==============================================
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
# Helm + Kubernetes — exec-based, NO module output references
# ==============================================
# WHY NO module.eks references here:
#   On a fresh prod apply the EKS cluster doesn't exist yet.
#   module.eks.cluster_endpoint is "known after apply" = empty string.
#   When cluster_ca_certificate = base64decode("") it fails validation.
#
# FIX: Use empty strings directly. The exec block fetches a token
#   lazily — only when a helm_release is actually being applied,
#   by which time the cluster exists (eks_addons depends_on eks).
#   The empty host/ca just means Helm won't try to pre-connect at plan time.
# ==============================================

provider "helm" {
  kubernetes {
    host                   = ""
    cluster_ca_certificate = ""
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
  host                   = ""
  cluster_ca_certificate = ""
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

# DR Helm + Kubernetes — same pattern, DR region
provider "helm" {
  alias = "dr"
  kubernetes {
    host                   = ""
    cluster_ca_certificate = ""
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", "pip-project-ecommerce-cluster",
        "--region", var.dr_region
      ]
    }
  }
}

provider "kubernetes" {
  alias                  = "dr"
  host                   = ""
  cluster_ca_certificate = ""
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", "pip-project-ecommerce-cluster",
      "--region", var.dr_region
    ]
  }
}
