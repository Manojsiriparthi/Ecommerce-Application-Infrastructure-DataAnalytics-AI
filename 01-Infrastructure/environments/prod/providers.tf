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
# DR Region Helm + Kubernetes providers (us-west-2)
# Used by eks_addons_dr module to install helm charts on DR cluster
# ==============================================
data "aws_eks_cluster" "ecommerce_dr" {
  provider = aws.dr
  name     = "pip-project-ecommerce-cluster"
}

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
