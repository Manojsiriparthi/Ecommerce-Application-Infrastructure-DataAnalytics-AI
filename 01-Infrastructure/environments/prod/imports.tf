# =============================================================================
# Terraform Import Blocks (Terraform 1.5+)
# =============================================================================
# CloudWatch log groups survive terraform destroy by design — AWS keeps them.
# These import blocks tell Terraform: "if this resource already exists in AWS,
# adopt it instead of trying to create it."
# This permanently fixes the ResourceAlreadyExistsException on every fresh apply.
# =============================================================================

import {
  to = module.security.aws_cloudwatch_log_group.vpc_flow_logs
  id = "/aws/vpc/flowlogs/pip-project-ecommerce-prod"
}

import {
  to = module.security.aws_cloudwatch_log_group.app_logs
  id = "/aws/eks/pip-project-ecommerce-prod/application"
}

import {
  to = module.security.aws_cloudwatch_log_group.infra_logs
  id = "/aws/eks/pip-project-ecommerce-prod/infrastructure"
}
