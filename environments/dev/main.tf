# ==============================================
# Networking Module
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
# Security Module (KMS + Secrets Manager)
# ==============================================
module "security" {
  source = "../../modules/security"

  project_name = "pip-project-ecommerce"
  environment  = var.environment
  db_password  = var.db_master_password
}

# ==============================================
# IAM Module (base roles for EKS cluster + nodes)
# ==============================================
module "iam" {
  source = "../../modules/iam"

  project_name = "pip-project-ecommerce"
  environment  = var.environment

  depends_on = [module.networking]
}

# ==============================================
# EKS Module (Cluster + Node Groups + Core Addons)
# ==============================================
module "eks" {
  source = "../../modules/eks"

  project_name              = "pip-project-ecommerce"
  environment               = var.environment
  cluster_version           = var.eks_cluster_version
  cluster_role_arn          = module.iam.cluster_role_arn
  node_role_arn             = module.iam.node_role_arn
  private_subnet_ids        = module.networking.private_subnet_ids
  db_subnet_ids             = module.networking.database_subnet_ids
  public_subnet_ids         = module.networking.public_subnet_ids
  private_route_dependency  = module.networking.private_route_table_association_ids
  database_route_dependency = module.networking.database_route_table_association_ids
  worker_instance_type      = var.worker_instance_type
  db_node_instance_type     = var.db_node_instance_type
  public_node_instance_type = var.public_node_instance_type

  depends_on = [module.iam, module.networking]
}

# ==============================================
# IAM-IRSA Module (roles that need the EKS OIDC provider,
# created AFTER the cluster to avoid a circular dependency)
# ==============================================
module "iam_irsa" {
  source = "../../modules/iam-irsa"

  project_name      = "pip-project-ecommerce"
  environment       = var.environment
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = replace(module.eks.oidc_provider_url, "https://", "")

  depends_on = [module.eks]
}

# ==============================================
# EKS Addons Module (LB Controller, Autoscaler, EBS CSI,
# Metrics Server, VPA, Fluent Bit)
# ==============================================
module "eks_addons" {
  source = "../../modules/eks-addons"

  project_name                = "pip-project-ecommerce"
  cluster_name                = module.eks.cluster_name
  region                      = var.primary_region
  ebs_csi_role_arn            = module.iam_irsa.ebs_csi_role_arn
  lb_controller_role_arn      = module.iam_irsa.lb_controller_role_arn
  cluster_autoscaler_role_arn = module.iam_irsa.cluster_autoscaler_role_arn

  depends_on = [module.eks, module.iam_irsa]
}

# ==============================================
# Compute Module (Bastion + Jenkins)
# Access via SSM Session Manager - no SSH key required
# ==============================================
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

# ==============================================
# Messaging Module (SNS + SQS for pipeline failures)
# ==============================================
module "messaging" {
  source = "../../modules/messaging"

  project_name = "pip-project-ecommerce"
  environment  = var.environment
  kms_key_arn  = module.security.kms_key_arn

  depends_on = [module.security]
}

# ==============================================
# Aurora PostgreSQL Module (Multi-AZ + Global DB + Proxy)
# ==============================================
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

# ==============================================
# Prevent Destroy Until Dependencies Cleaned
# This null_resource ensures networking is destroyed LAST
# ==============================================
resource "null_resource" "networking_dependency" {
  depends_on = [
    module.eks_addons,
    module.eks,
    module.aurora,
    module.compute
  ]
}
