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

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}

# DR providers — aliased, used only by DR EKS addons if needed
provider "helm" {
  alias = "dr"
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  alias       = "dr"
  config_path = "~/.kube/config"
}
