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
  create_flow_logs     = true

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
  region                    = var.primary_region
  cluster_version           = var.eks_cluster_version
  cluster_role_arn          = module.iam.cluster_role_arn
  node_role_arn             = module.iam.node_role_arn
  private_subnet_ids        = module.networking.private_subnet_ids
  public_subnet_ids         = module.networking.public_subnet_ids
  db_subnet_ids             = module.networking.database_subnet_ids
  private_route_dependency  = module.networking.private_route_table_association_ids
  database_route_dependency = module.networking.database_route_table_association_ids

  # PRIMARY worker nodes — t3.small, 3 nodes (one per AZ) = 6 vCPU
  # Total: 6 (workers) + 1 (public t3.micro) = 7 vCPU — fits under 8 limit
  worker_instance_type = var.worker_instance_type
  workers_desired      = 3    # one node per AZ (us-east-1a, 1b, 1c)
  workers_min          = 3
  workers_max          = 6
  worker_disk_size     = 25   # 25GB root volume per worker

  # Public nodes — t3.micro (1 vCPU, ALB support only, no application pods)
  public_node_instance_type = var.public_node_instance_type
  public_desired            = 1
  public_min                = 1
  public_max                = 3
  public_disk_size          = 20   # 20GB — EKS AMI snapshot minimum (can't go lower)

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

  providers = {
    aws        = aws
    helm       = helm
    kubernetes = kubernetes
  }

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
  # Disabled while vCPU limit increase is pending.
  # bastion (t3.micro=1 vCPU) + jenkins (t3.medium=2 vCPU) = 3 vCPU saved.
  # Set enable_compute = true in prod.tfvars once limit is raised to 32.
  count  = var.enable_compute ? 1 : 0
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
  deletion_protection  = true   # production DB protected. To destroy later, set
                                 # false first, apply, then destroy.
  sns_topic_arn        = module.messaging.sns_topic_arn

  # DB/table creation removed from Terraform (was hanging apply via local-exec).
  # Run ./06-Scripts/01-setup-databases.sh after apply instead.

  enable_global_db = var.enable_global_db
  primary_region   = var.primary_region
  dr_region        = var.dr_region

  # Wire DR networking outputs so Aurora Global DB secondary gets its subnet + SG
  dr_db_subnet_group_name = module.networking_dr.db_subnet_group_name
  dr_aurora_sg_id         = module.networking_dr.aurora_sg_id

  # Aurora no longer depends on EKS (db_setup local-exec removed).
  # It only needs networking, security (KMS), messaging (SNS), and DR networking.
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

  # DR failover — when dr_alb_dns_name is set, Route53 creates PRIMARY/SECONDARY
  # failover records with a health check on the primary ALB.
  # us-west-2 ALB hosted zone ID = Z1H1FL5HABSF5
  dr_alb_dns_name = var.dr_alb_dns_name
  dr_alb_zone_id  = "Z1H1FL5HABSF5"
  sns_topic_arn   = module.messaging.sns_topic_arn

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
# Aurora SG — EKS auto-created node SG rule
# ==============================================
# WHY THIS IS HERE (not in networking/main.tf):
#   EKS auto-creates a second SG (cluster_security_group_id) at cluster
#   creation time and attaches it to every worker node. Terraform doesn't
#   know this SG ID until AFTER aws_eks_cluster is created.
#   networking/main.tf runs BEFORE eks/main.tf, so it cannot reference
#   module.eks.node_security_group_id — that would be a circular dependency.
#
#   The solution: a standalone aws_security_group_rule here in prod/main.tf,
#   which Terraform resolves AFTER both modules exist. This rule is what
#   allows EKS pods to reach Aurora on port 5432.
#
# WITHOUT THIS RULE: pods get "connection timeout" to Aurora/RDS Proxy.
# ==============================================
resource "aws_security_group_rule" "aurora_allow_eks_nodes" {
  type                     = "ingress"
  description              = "PostgreSQL from EKS auto-created node SG (cluster_security_group_id)"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.networking.aurora_sg_id
  source_security_group_id = module.eks.node_security_group_id

  depends_on = [module.networking, module.eks]
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

  project_name = "pip-project-ecommerce"
  # environment = "prod" (same as primary) — DR is the SAME prod environment,
  # just in a different region. Resources are regional so names don't clash,
  # and the deploy script uses ENV=prod for both regions (same SSM paths,
  # same subnet tag filter Environment=prod).
  environment      = var.environment
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

  project_name    = "pip-project-ecommerce"
  environment     = var.environment   # "prod" — same env, different region
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

  # DR: 3 private worker nodes across 3 AZs (mirrors primary) + 1 public node
  # vCPU cost: 3×t3.small = 6 vCPU workers + 1×t3.micro = 1 vCPU public = 7 vCPU
  # (fits under the 8 vCPU limit in us-west-2, same budget as primary)
  worker_instance_type = "t3.small"
  workers_desired      = 3
  workers_min          = 3
  workers_max          = 6
  worker_disk_size     = 25   # 25GB root volume per worker

  # Public node — needed for ALB ip-mode target routing (same as primary)
  public_node_instance_type = "t3.micro"
  public_desired            = 1
  public_min                = 1
  public_max                = 3
  public_disk_size          = 20   # 20GB — EKS AMI snapshot minimum (can't go lower)

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

# ==============================================
# DR WAF (us-west-2) — regional WebACL for the DR external ALB
# ==============================================
# Same WAF module, DR provider. Note the different elb_account_id for us-west-2
# (797873946194) — this is the AWS account that writes ALB logs in that region.
# ==============================================
# Dedicated KMS key in DR region for the WAF S3 logs bucket.
# Kept separate from aurora's DR key so waf_dr does NOT depend on the large
# aurora module (avoids a long dependency chain through db_setup/eks_addons).
resource "aws_kms_key" "dr_logs" {
  provider = aws.dr

  description             = "KMS key for DR region WAF/ALB S3 logs bucket"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "pip-project-ecommerce-dr-logs-kms"
    Environment = "${var.environment}-dr"
  }
}

resource "aws_kms_alias" "dr_logs" {
  provider      = aws.dr
  name          = "alias/pip-project-ecommerce-dr-logs-kms"
  target_key_id = aws_kms_key.dr_logs.key_id
}

module "waf_dr" {
  source = "../../modules/waf"

  providers = {
    aws = aws.dr
  }

  project_name = "pip-project-ecommerce"
  # environment = "prod-dr" here ONLY because the WAF module creates an S3
  # bucket, and S3 bucket names are GLOBALLY unique across all regions.
  # Primary bucket: pip-project-ecommerce-logs-prod-<acct>
  # DR bucket:      pip-project-ecommerce-logs-prod-dr-<acct>  ← must differ
  # The WebACL itself is regional so the name doesn't actually need -dr,
  # but keeping it consistent avoids confusion.
  environment         = "${var.environment}-dr"
  kms_key_arn         = aws_kms_key.dr_logs.arn
  elb_account_id      = "797873946194"   # us-west-2 ELB service account
  log_transition_days = 365
  log_expiration_days = 730

  depends_on = [module.networking_dr]
}

# ==============================================
# DR EKS Addons — LB Controller, EBS CSI, Secrets Store CSI (us-west-2)
# ==============================================
# CRITICAL for DR: installs the AWS Load Balancer Controller so applying
# frontend/ingress.yaml in the DR cluster provisions a real ALB. Without
# this, no DR ALB exists and failover has no target.
#
# Uses aws.dr + helm.dr + kubernetes.dr providers (pinned to us-west-2 cluster).
#
# BEFORE APPLYING THIS MODULE, run:
#   aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-west-2
# so the helm.dr/kubernetes.dr providers can reach the DR cluster.
# ==============================================
module "eks_addons_dr" {
  source = "../../modules/eks-addons"

  providers = {
    aws        = aws.dr
    helm       = helm.dr
    kubernetes = kubernetes.dr
  }

  project_name                = "pip-project-ecommerce"
  cluster_name                = module.eks_dr.cluster_name
  region                      = var.dr_region
  vpc_id                      = module.networking_dr.vpc_id
  ebs_csi_role_arn            = module.iam_irsa_dr.ebs_csi_role_arn
  lb_controller_role_arn      = module.iam_irsa_dr.lb_controller_role_arn
  cluster_autoscaler_role_arn = module.iam_irsa_dr.cluster_autoscaler_role_arn
  secrets_store_csi_role_arn  = module.iam_irsa_dr.secrets_store_csi_role_arn

  depends_on = [module.eks_dr, module.iam_irsa_dr]
}

# ==============================================
# DR Aurora SG — EKS auto-created node SG rule (us-west-2)
# ==============================================
# Same fix as primary (aurora_allow_eks_nodes): the DR EKS cluster auto-creates
# a node SG that must be allowed to reach the DR Aurora secondary on 5432.
# Without this, DR pods get connection timeouts to the DR database.
# ==============================================
resource "aws_security_group_rule" "dr_aurora_allow_eks_nodes" {
  provider = aws.dr

  type                     = "ingress"
  description              = "PostgreSQL from DR EKS auto-created node SG"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.networking_dr.aurora_sg_id
  source_security_group_id = module.eks_dr.node_security_group_id

  depends_on = [module.networking_dr, module.eks_dr]
}

# Wire DR networking into Aurora module
# (already configured in the aurora module call above via dr_* variables)
