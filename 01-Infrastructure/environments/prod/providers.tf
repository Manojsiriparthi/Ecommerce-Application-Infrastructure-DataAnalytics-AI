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
# Helm + Kubernetes — exec-only, no host/ca
# ==============================================
# WHY no host or cluster_ca_certificate:
#   Setting host="" causes "no configuration provided" error in Helm provider.
#   The correct pattern (same as dev) is exec-only — aws eks get-token
#   fetches both the endpoint and token dynamically at apply time.
#   This works because eks_addons depends_on eks, so cluster exists first.
# ==============================================

provider "helm" {
  kubernetes {
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

provider "helm" {
  alias = "dr"
  kubernetes {
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
  alias = "dr"
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
