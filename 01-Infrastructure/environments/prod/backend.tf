terraform {
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # PINNED to the 5.x line. An unpinned ">= 5.0" let provider 6.x install,
      # which changed the aws_s3_bucket_server_side_encryption_configuration
      # schema and forced the WAF logs S3 bucket to be REPLACED on every apply
      # → "BucketAlreadyExists". Pinning to ~> 5.x keeps the schema stable so
      # the existing bucket is left in place. Do NOT loosen without testing.
      version = "~> 5.60"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }

  backend "s3" {
    bucket         = "manoj-pip-project-ecommerce-tfstate-prod"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true
  }
}
