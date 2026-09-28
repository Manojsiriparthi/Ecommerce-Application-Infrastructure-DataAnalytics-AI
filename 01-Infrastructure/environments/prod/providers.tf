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
# Primary Helm + Kubernetes — exec-based auth
# Reads cluster endpoint from module outputs (known after apply).
# Safe on first plan — try() returns "" when cluster doesn't exist yet.
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

# ==============================================
# DR Helm + Kubernetes (us-west-2)
# Same pattern — module outputs, no data source lookup.
# data "aws_eks_cluster" removed: it runs at plan time and fails
# because the DR cluster doesn't exist yet on first apply.
# ==============================================
provider "helm" {
  alias = "dr"
  kubernetes {
    host = try(module.eks_dr.cluster_endpoint, "")
    cluster_ca_certificate = try(
      base64decode(module.eks_dr.cluster_certificate_authority_data),
      ""
    )
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
  host  = try(module.eks_dr.cluster_endpoint, "")
  cluster_ca_certificate = try(
    base64decode(module.eks_dr.cluster_certificate_authority_data),
    ""
  )
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
