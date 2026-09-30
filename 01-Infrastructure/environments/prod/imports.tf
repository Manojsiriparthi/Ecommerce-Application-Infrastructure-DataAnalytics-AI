# =============================================================================
# Terraform Import Blocks (Terraform 1.5+)
# =============================================================================
# These import blocks were used to ADOPT CloudWatch log groups that survived a
# previous `terraform destroy` (AWS keeps log groups by design).
#
# They are DISABLED right now because the infrastructure was fully destroyed —
# the log groups no longer exist, so importing them fails with
# "Cannot import non-existent remote object". On a fresh build, Terraform
# CREATES the log groups normally (no import needed).
#
# WHEN TO RE-ENABLE:
#   If you later `terraform destroy` and the log groups survive, then on the
#   next apply you'll get "ResourceAlreadyExistsException". At THAT point,
#   uncomment the import blocks below to adopt the surviving log groups.
#
# import {
#   to = module.security.aws_cloudwatch_log_group.vpc_flow_logs
#   id = "/aws/vpc/flowlogs/pip-project-ecommerce-prod"
# }
#
# import {
#   to = module.security.aws_cloudwatch_log_group.app_logs
#   id = "/aws/eks/pip-project-ecommerce-prod/application"
# }
#
# import {
#   to = module.security.aws_cloudwatch_log_group.infra_logs
#   id = "/aws/eks/pip-project-ecommerce-prod/infrastructure"
# }
