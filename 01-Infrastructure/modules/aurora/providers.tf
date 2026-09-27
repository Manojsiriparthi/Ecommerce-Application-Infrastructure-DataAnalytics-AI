# ==============================================
# Provider Configuration Aliases
# ==============================================
# This module requires two provider configurations to be passed in
# from the root module: the default (primary region) and "aws.dr"
# (secondary/DR region) for Aurora Global Database.
#
# Example (root module):
#   module "aurora" {
#     source = "../../modules/aurora"
#     providers = {
#       aws    = aws.primary
#       aws.dr = aws.dr
#     }
#   }

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.0"
      configuration_aliases = [aws.dr]
    }
  }
}
