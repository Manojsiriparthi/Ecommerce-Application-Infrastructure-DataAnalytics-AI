terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
    # helm + kubernetes are declared with configuration_aliases so the caller
    # can pass either the default (primary us-east-1) or aliased (.dr us-west-2)
    # provider. This lets the SAME module deploy addons to either cluster.
    helm = {
      source                = "hashicorp/helm"
      configuration_aliases = [helm]
    }
    kubernetes = {
      source                = "hashicorp/kubernetes"
      configuration_aliases = [kubernetes]
    }
  }
}
