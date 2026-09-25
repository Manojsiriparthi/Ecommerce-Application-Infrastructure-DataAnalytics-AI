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

# DR region provider for Aurora Global Database
provider "aws" {
  alias  = "dr"
  region = var.dr_region

  default_tags {
    tags = {
      Project     = "pip-project-ecommerce"
      Environment = "prod"
      ManagedBy   = "terraform"
    }
  }
}

# ==============================================
# Helm and Kubernetes Providers
# NOTE: These are configured with empty blocks initially.
# After EKS cluster creation, use kubectl or aws eks CLI
# to configure access. Terraform will automatically use
# the credentials from your kubeconfig or AWS credentials.
# ==============================================
provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
