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
# Helm + Kubernetes — exec-based EKS auth
# No ~/.kube/config needed. Token generated at runtime
# using aws eks get-token via the same AWS credentials
# already in the environment. Correct pattern for CI/CD.
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
