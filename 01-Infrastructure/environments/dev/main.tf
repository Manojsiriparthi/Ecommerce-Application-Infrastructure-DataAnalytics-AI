# ==============================================
# pip-project-ecommerce — DEV environment
# Region: ap-south-1 (Mumbai)  |  DR: us-east-1
#
# FIRST-TIME APPLY SEQUENCE:
#   Run 1: terraform apply  (creates all infra; ALB not yet provisioned)
#          → infra pipeline post-apply stage kubectl-applies K8s manifests
#          → ALB gets provisioned by Load Balancer Controller
#   Run 2: terraform apply  (now has alb_dns_name; creates Route53 A-records)
#          → domain resolves → HTTPS works
# ==============================================

module "networking" {
  source = "../../modules/networking"

  project_name     = "pip-project-ecommerce"
  environment      = var.environment
  vpc_cidr         = var.vpc_cidr
  azs              = var.azs
  public_subnets   = var.public_subnets
  private_subnets  = var.private_subnets
  database_subnets = var.database_subnets
}

# ==============================================
# Security — KMS, Secrets Manager, SSM Parameters
# Sensitive values passed via TF_VAR_* env variables:
#   TF_VAR_db_master_password
#   TF_VAR_jwt_secret
#   TF_VAR_internal_service_key
#   TF_VAR_redis_auth_token
# These are stored in Secrets Manager / SSM on first apply.
# Subsequent applies read them from there automatically.
# ==============================================
module "security" {
  source = "../../modules/security"

  project_name         = "pip-project-ecommerce"
  environment          = var.environment
  db_password          = var.db_master_password
  jwt_secret           = var.jwt_secret
  internal_service_key = var.internal_service_key
  ses_from_email       = var.ses_from_email
  vpc_id               = module.networking.vpc_id
  create_flow_logs     = true
  db_proxy_endpoint    = module.aurora.proxy_endpoint

  depends_on = [module.networking, module.aurora]
}

module "iam" {
  source = "../../modules/iam"

  project_name = "pip-project-ecommerce"
  environment  = var.environment

  depends_on = [module.networking]
}

module "eks" {
  source = "../../modules/eks"

  project_name              = "pip-project-ecommerce"
  environment               = var.environment
  cluster_version           = var.eks_cluster_version
  cluster_role_arn          = module.iam.cluster_role_arn
  node_role_arn             = module.iam.node_role_arn
  private_subnet_ids        = module.networking.private_subnet_ids
  public_subnet_ids         = module.networking.public_subnet_ids
  db_subnet_ids             = module.networking.database_subnet_ids
  private_route_dependency  = module.networking.private_route_table_association_ids
  database_route_dependency = module.networking.database_route_table_association_ids

  # Worker nodes — run all application pods (private subnets)
  worker_instance_type = var.worker_instance_type
  workers_desired      = 2
  workers_min          = 2
  workers_max          = 6

  # Public nodes — 1 per AZ is enough for ALB ip-mode support (small instance)
  public_node_instance_type = var.public_node_instance_type
  public_desired            = 1
  public_min                = 1
  public_max                = 3

  # DB nodes — disabled: Aurora is AWS-managed, no pods need database subnets today.
  # Enable in the future by setting create_db_nodes = true and adding db_node_instance_type.
  create_db_nodes = false

  depends_on = [module.iam, module.networking]
}

module "iam_irsa" {
  source = "../../modules/iam-irsa"

  project_name      = "pip-project-ecommerce"
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")

  depends_on = [module.eks]
}

module "eks_addons" {
  source = "../../modules/eks-addons"

  project_name                = "pip-project-ecommerce"
  cluster_name                = module.eks.cluster_name
  region                      = var.primary_region
  vpc_id                      = module.networking.vpc_id
  ebs_csi_role_arn            = module.iam_irsa.ebs_csi_role_arn
  lb_controller_role_arn      = module.iam_irsa.lb_controller_role_arn
  cluster_autoscaler_role_arn = module.iam_irsa.cluster_autoscaler_role_arn
  secrets_store_csi_role_arn  = module.iam_irsa.secrets_store_csi_role_arn

  depends_on = [module.eks, module.iam_irsa]
}

module "compute" {
  source = "../../modules/compute"

  project_name                  = "pip-project-ecommerce"
  environment                   = var.environment
  ami_id                        = var.ami_id
  public_subnet_id              = module.networking.public_subnet_ids[0]
  private_subnet_id             = module.networking.private_subnet_ids[0]
  bastion_sg_id                 = module.networking.bastion_sg_id
  jenkins_sg_id                 = module.networking.jenkins_sg_id
  bastion_instance_profile_name = module.iam.bastion_instance_profile_name
  jenkins_instance_profile_name = module.iam.jenkins_instance_profile_name

  depends_on = [module.networking, module.iam]
}

module "messaging" {
  source = "../../modules/messaging"

  project_name = "pip-project-ecommerce"
  environment  = var.environment
  kms_key_arn  = module.security.kms_key_arn

  depends_on = [module.security]
}

module "aurora" {
  source = "../../modules/aurora"

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }

  project_name         = "pip-project-ecommerce"
  environment          = var.environment
  engine_version       = var.aurora_engine_version
  master_password      = var.db_master_password
  db_subnet_group_name = module.networking.db_subnet_group_name
  db_subnet_ids        = module.networking.database_subnet_ids
  aurora_sg_id         = module.networking.aurora_sg_id
  kms_key_arn          = module.security.kms_key_arn
  db_secret_arn        = module.security.db_secret_arn
  instance_class       = var.aurora_instance_class
  reader_count         = var.aurora_reader_count
  deletion_protection  = false
  sns_topic_arn        = module.messaging.sns_topic_arn

  enable_global_db = var.enable_global_db
  primary_region   = var.primary_region
  dr_region        = var.dr_region

  depends_on = [module.networking, module.security, module.messaging]
}

module "elasticache" {
  source = "../../modules/elasticache"

  project_name       = "pip-project-ecommerce"
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  eks_sg_id          = module.networking.eks_sg_id
  kms_key_arn        = module.security.kms_key_arn
  auth_token         = var.redis_auth_token
  node_type          = var.redis_node_type
  num_replicas       = 0
  sns_topic_arn      = module.messaging.sns_topic_arn

  depends_on = [module.networking, module.security, module.messaging]
}

module "waf" {
  source = "../../modules/waf"

  project_name        = "pip-project-ecommerce"
  environment         = var.environment
  kms_key_arn         = module.security.kms_key_arn
  elb_account_id      = "718504428378"   # ap-south-1
  log_transition_days = 90
  log_expiration_days = 365

  depends_on = [module.security]
}

# ==============================================
# Route53 + ACM
# ==============================================
# First apply: alb_dns_name = "" → hosted zone + cert created,
#              A-records skipped (ALB doesn't exist yet).
# Post-apply stage: kubectl apply Ingresses → ALB provisioned.
# Second apply: alb_dns_name filled from SSM → A-records created.
# The infra pipeline reads cert_arn from SSM to patch ingress.yaml
# automatically — no manual ACM console visit needed.
#
# ALB zone ID for ap-south-1: Z11127IXD6XFTK
# ==============================================
module "route53_acm" {
  source = "../../modules/route53-acm"

  project_name = "pip-project-ecommerce"
  environment  = var.environment
  domain_name  = var.domain_name   # empty string = all resources skipped inside module
  alb_dns_name = var.alb_dns_name
  alb_zone_id  = var.alb_dns_name != "" ? "Z11127IXD6XFTK" : ""

  depends_on = [module.waf]
}

# ==============================================
# Destroy ordering guard — networking last
# ==============================================
resource "null_resource" "networking_dependency" {
  depends_on = [
    module.eks_addons,
    module.eks,
    module.aurora,
    module.elasticache,
    module.waf,
    module.compute,
    module.monitoring
  ]
}

# ==============================================
# Monitoring — CloudWatch alarms (20+), dashboard, EBS DLM snapshots
# Rubric: 20+ alarms, monitoring dashboards live, EBS snapshots to S3
# ==============================================
module "monitoring" {
  source = "../../modules/monitoring"

  project_name            = "pip-project-ecommerce"
  environment             = var.environment
  region                  = var.primary_region
  sns_topic_arn           = module.messaging.sns_topic_arn
  nat_gateway_id          = module.networking.nat_gateway_id
  # external_alb_arn_suffix filled after first apply + Ingress creation
  # Get with: kubectl get ingress frontend-external-ingress -n ecommerce \
  #   -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/load-balancer-arn}'
  external_alb_arn_suffix = ""

  depends_on = [module.messaging, module.networking, module.eks_addons]
}
