terraform {
  # NOTE: required_providers block lives in backend.tf
  # This file only configures provider instances.
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
# Used by Aurora Global Database secondary cluster.
# When enable_global_db = false the aurora module
# still receives this provider alias but never uses it.
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
# WHY exec-based auth (not static kubeconfig):
#   - ~/.kube/config does not exist before the EKS cluster is created.
#     Using config_path would fail on every fresh apply.
#   - exec-based auth calls `aws eks get-token` at runtime using the
#     same AWS credentials already in the environment — no file needed.
#   - The cluster_name and region are passed as arguments so Terraform
#     can generate a token for the correct cluster automatically.
#   - This is the AWS-recommended pattern for Terraform + EKS.
#
# IMPORTANT: The EKS cluster must be created before any Helm release
# or Kubernetes resource is applied. The eks_addons module has
# `depends_on = [module.eks]` which enforces this ordering.
# ==============================================

data "aws_eks_cluster" "ecommerce" {
  name = "pip-project-ecommerce-cluster"
}

data "aws_eks_cluster_auth" "ecommerce" {
  name = "pip-project-ecommerce-cluster"
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.ecommerce.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.ecommerce.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.ecommerce.token
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.ecommerce.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.ecommerce.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.ecommerce.token
}
