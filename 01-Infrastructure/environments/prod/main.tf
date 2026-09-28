# ==============================================
# pip-project-ecommerce — PRODUCTION environment
# Region: us-east-1  |  DR: us-west-2
#
# DEPLOY SEQUENCE:
#   1. terraform apply dev  → dev EKS live, smoke tests pass
#   2. terraform apply prod → prod EKS live (this file)
#   3. CI PR approved → ArgoCD deploys to prod EKS
#   4. terraform destroy dev → dev torn down (cost saving)
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

module "security" {
  source = "../../modules/security"

  project_name         = "pip-project-ecommerce"
  environment          = var.environment
  db_password          = var.db_master_password
  jwt_secret           = var.jwt_secret
  internal_service_key = var.internal_service_key
  ses_from_email       = var.ses_from_email
  vpc_id               = module.networking.vpc_id
  create_flow_logs     = true   # boolean — safe to evaluate at plan time

  depends_on = [module.networking]
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

  # Worker nodes — t3.small to fit within 8 vCPU account limit
  # 2×t3.small = 4 vCPU. Raise limit then change to t3.medium/desired=3
  worker_instance_type = var.worker_instance_type
  workers_desired      = 2
  workers_min          = 2
  workers_max          = 6

  # Public nodes — t3.micro (1 vCPU, ALB support only)
  public_node_instance_type = var.public_node_instance_type
  public_desired            = 1
  public_min                = 1
  public_max                = 3

  # DB nodes — disabled: Aurora is AWS-managed
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
  deletion_protection  = true
  sns_topic_arn        = module.messaging.sns_topic_arn

  enable_global_db = var.enable_global_db
  primary_region   = var.primary_region
  dr_region        = var.dr_region

  # Wire DR networking outputs so Aurora Global DB secondary gets its subnet + SG
  dr_db_subnet_group_name = module.networking_dr.db_subnet_group_name
  dr_aurora_sg_id         = module.networking_dr.aurora_sg_id

  depends_on = [module.networking, module.security, module.messaging, module.networking_dr]
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
  num_replicas       = 1
  sns_topic_arn      = module.messaging.sns_topic_arn

  depends_on = [module.networking, module.security, module.messaging]
}

module "waf" {
  source = "../../modules/waf"

  project_name        = "pip-project-ecommerce"
  environment         = var.environment
  kms_key_arn         = module.security.kms_key_arn
  elb_account_id      = "127311923021"   # us-east-1
  log_transition_days = 365
  log_expiration_days = 730

  depends_on = [module.security]
}

# ==============================================
# Route53 + ACM
# ALB zone ID for us-east-1: Z35SXDOTRQ7X7K
# ==============================================
module "route53_acm" {
  source = "../../modules/route53-acm"

  project_name = "pip-project-ecommerce"
  environment  = var.environment
  domain_name  = var.domain_name
  alb_dns_name = var.alb_dns_name
  alb_zone_id  = var.alb_dns_name != "" ? "Z35SXDOTRQ7X7K" : ""

  depends_on = [module.waf]
}

resource "null_resource" "networking_dependency" {
  depends_on = [
    module.eks_addons,
    module.eks,
    module.aurora,
    module.elasticache,
    module.waf,
    module.route53_acm,
    module.compute,
    module.monitoring
  ]
}

# ==============================================
# Monitoring — CloudWatch alarms (20+), dashboard, EBS DLM snapshots
# ==============================================
module "monitoring" {
  source = "../../modules/monitoring"

  project_name            = "pip-project-ecommerce"
  environment             = var.environment
  region                  = var.primary_region
  sns_topic_arn           = module.messaging.sns_topic_arn
  nat_gateway_id          = module.networking.nat_gateway_id
  external_alb_arn_suffix = ""   # filled after first apply

  depends_on = [module.messaging, module.networking, module.eks_addons]
}

# ==============================================
# ==============================================
# DR REGION (us-west-2) — WARM STANDBY
# ==============================================
# IAM NOTE: IAM is a GLOBAL service — role names must be unique per account,
# not per region. The primary cluster's IAM roles (module.iam) work perfectly
# for the DR cluster too. No need for module.iam_dr — just pass the same
# role ARNs from module.iam to module.eks_dr.
# ==============================================

# DR Networking (us-west-2) — different CIDR to avoid overlap
module "networking_dr" {
  source = "../../modules/networking"

  providers = {
    aws = aws.dr
  }

  project_name     = "pip-project-ecommerce"
  environment      = "${var.environment}-dr"
  vpc_cidr         = var.dr_vpc_cidr
  azs              = var.dr_azs
  public_subnets   = var.dr_public_subnets
  private_subnets  = var.dr_private_subnets
  database_subnets = var.dr_database_subnets
}

# DR EKS — uses the SAME IAM roles as primary (IAM is global)
# t3.micro nodes keep CoreDNS healthy without consuming many vCPUs
# vCPU cost: 2×t3.micro = 2 vCPU (fits within 8 vCPU account limit)
module "eks_dr" {
  source = "../../modules/eks"

  providers = {
    aws = aws.dr
  }

  project_name   = "pip-project-ecommerce"
  environment    = "${var.environment}-dr"
  cluster_version = var.eks_cluster_version

  # ── REUSE PRIMARY IAM ROLES — no separate iam_dr module needed ──
  # IAM roles are global. The same role ARN works in any region.
  cluster_role_arn = module.iam.cluster_role_arn
  node_role_arn    = module.iam.node_role_arn

  private_subnet_ids        = module.networking_dr.private_subnet_ids
  public_subnet_ids         = module.networking_dr.public_subnet_ids
  db_subnet_ids             = module.networking_dr.database_subnet_ids
  private_route_dependency  = module.networking_dr.private_route_table_association_ids
  database_route_dependency = module.networking_dr.database_route_table_association_ids

  # t3.micro — just enough for CoreDNS + system pods to stay healthy
  # During failover: change to t3.medium + desired=3 → rolling replace, zero downtime
  worker_instance_type = "t3.micro"
  workers_desired      = 1
  workers_min          = 1
  workers_max          = 10

  public_node_instance_type = "t3.micro"
  public_desired            = 1
  public_min                = 1
  public_max                = 3

  create_db_nodes = false

  depends_on = [module.iam, module.networking_dr]
}

# DR IRSA — OIDC-bound roles for pods in the DR cluster
# These are separate because each EKS cluster has its own OIDC endpoint
module "iam_irsa_dr" {
  source = "../../modules/iam-irsa"

  providers = {
    aws = aws.dr
  }

  # Use -dr suffix so IRSA role names don't clash with primary region IRSA roles
  # (IRSA roles include the OIDC URL in their trust policy, so they must be separate)
  project_name      = "pip-project-ecommerce-dr"
  environment       = "${var.environment}-dr"
  oidc_provider_arn = module.eks_dr.oidc_provider_arn
  oidc_provider_url = replace(module.eks_dr.oidc_provider_url, "https://", "")

  depends_on = [module.eks_dr]
}

# Wire DR networking into Aurora module
# (already configured in the aurora module call above via dr_* variables)
