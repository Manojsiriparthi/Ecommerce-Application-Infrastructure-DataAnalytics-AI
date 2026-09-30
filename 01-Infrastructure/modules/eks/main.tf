# ==============================================
# EKS Cluster
# ==============================================
resource "aws_eks_cluster" "ecommerce" {
  name     = "${var.project_name}-cluster"
  role_arn = var.cluster_role_arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  tags = {
    Name        = "${var.project_name}-cluster"
    Environment = var.environment
  }

  lifecycle {
    ignore_changes = [version]
  }
}

# ==============================================
# EKS Node Group: Workers (Private Subnets)
# Purpose: runs all application pods.
#   - frontend pods (Next.js)
#   - all 6 backend service pods
#   - ArgoCD, Secrets Store CSI driver, Fluent Bit
# Private subnets → outbound via NAT Gateway.
# Pods connect to Aurora RDS Proxy and ElastiCache via
# private subnet routing — no internet exposure.
# ==============================================
resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.ecommerce.name
  node_group_name = "${var.project_name}-workers"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = var.workers_desired
    max_size     = var.workers_max
    min_size     = var.workers_min
  }

  instance_types = [var.worker_instance_type]

  # Launch template — gives EC2 instances proper Name tags
  # Without this, nodes show as "ip-10-x-x-x.ec2.internal" with no name
  launch_template {
    id      = aws_launch_template.workers.id
    version = aws_launch_template.workers.latest_version
  }

  labels = {
    "node-role" = "worker"
    "workload"  = "application"
  }

  tags = {
    Name        = "${var.project_name}-workers"
    Environment = var.environment
  }

  depends_on = [
    aws_eks_cluster.ecommerce,
    var.private_route_dependency,
  ]
}

resource "aws_launch_template" "workers" {
  name_prefix = "${var.project_name}-workers-"
  # instance_type is NOT set here — set in node group instance_types instead
  # Setting it in both causes: "Cannot specify instance types in launch template and API request"
  # NOTE: no block_device_mappings — nodes use the EKS default disk (20GB).
  # Adding disk size here forces a node replacement that can fail; left default.

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-worker-node"
      Environment = var.environment
      Role        = "worker"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "${var.project_name}-worker-volume"
      Environment = var.environment
      Backup      = "false"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name        = "${var.project_name}-workers-lt"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================
# EKS Node Group: Public (Public Subnets)
# Purpose: supports ALB ip-mode target routing.
#
# WHY PUBLIC NODES ARE NEEDED:
#   The AWS Load Balancer Controller with target-type=ip
#   registers pod IPs directly as ALB targets. For the ALB
#   to health-check those pod IPs it needs ENIs in the same
#   subnets as the ALB (public subnets). Without nodes here
#   the LB controller has no network interface to attach to
#   in the public subnet and falls back to instance mode.
#
#   Additionally, nodes here route outbound directly through
#   the Internet Gateway (not NAT Gateway), which avoids
#   NAT Gateway data-processing charges for those nodes.
#
# NOTE: Application pods do NOT run on public nodes.
#   The node label "node-role=public" can be used in
#   nodeAffinity rules to restrict system daemonsets here.
#   No NoSchedule taint is set — keeping it simple.
# ==============================================
resource "aws_eks_node_group" "public" {
  cluster_name    = aws_eks_cluster.ecommerce.name
  node_group_name = "${var.project_name}-public"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.public_subnet_ids

  scaling_config {
    desired_size = var.public_desired
    max_size     = var.public_max
    min_size     = var.public_min
  }

  instance_types = [var.public_node_instance_type]

  launch_template {
    id      = aws_launch_template.public.id
    version = aws_launch_template.public.latest_version
  }

  labels = {
    "node-role" = "public"
    "workload"  = "alb-support"
  }

  tags = {
    Name        = "${var.project_name}-public-nodes"
    Environment = var.environment
  }

  depends_on = [aws_eks_cluster.ecommerce]
}

resource "aws_launch_template" "public" {
  name_prefix = "${var.project_name}-public-"
  # instance_type NOT set here — controlled by node group instance_types
  # NOTE: no block_device_mappings — nodes use the EKS default disk (20GB).

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-public-node"
      Environment = var.environment
      Role        = "public-alb-support"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "${var.project_name}-public-volume"
      Environment = var.environment
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = {
    Name        = "${var.project_name}-public-lt"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================
# EKS Node Group: DB Nodes (Database Subnets)
# ==============================================
# CURRENTLY DISABLED (create_db_nodes = false in tfvars).
#
# WHY THE CODE IS KEPT:
#   Aurora RDS is AWS-managed — no pods need to run in the
#   database subnets today. However, if a future workload
#   requires direct database-subnet placement (e.g. a Kafka
#   cluster, a data pipeline job, or a migration tooling pod
#   that must be co-located with Aurora), these nodes can be
#   enabled by setting create_db_nodes = true in the tfvars.
#
# TO ENABLE:
#   dev.tfvars  → create_db_nodes = true
#   prod.tfvars → create_db_nodes = true
#   Then: terraform apply
#
# TAINT: dedicated=database:NoSchedule
#   Nothing schedules here unless the pod explicitly tolerates
#   this taint — so enabling this node group does not affect
#   existing workloads at all.
# ==============================================
resource "aws_eks_node_group" "db_nodes" {
  count = var.create_db_nodes ? 1 : 0

  cluster_name    = aws_eks_cluster.ecommerce.name
  node_group_name = "${var.project_name}-db-nodes"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.db_subnet_ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 2
  }

  instance_types = [var.db_node_instance_type]

  taint {
    key    = "dedicated"
    value  = "database"
    effect = "NO_SCHEDULE"
  }

  labels = {
    "node-role" = "database"
    "workload"  = "db-workloads"
  }

  tags = {
    Name        = "${var.project_name}-db-nodes"
    Environment = var.environment
  }

  depends_on = [
    aws_eks_cluster.ecommerce,
    var.database_route_dependency,
  ]
}

# ==============================================
# OIDC Provider for IRSA
# ==============================================
data "tls_certificate" "eks" {
  url = aws_eks_cluster.ecommerce.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "ecommerce" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.ecommerce.identity[0].oidc[0].issuer
}

# ==============================================
# Core EKS Addons
# ==============================================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.ecommerce.name
  addon_name   = "vpc-cni"
  depends_on   = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.ecommerce.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.ecommerce.name
  addon_name   = "kube-proxy"
  depends_on   = [aws_eks_node_group.workers]
}

# NOTE: aws-ebs-csi-driver is applied in the eks-addons module
# to avoid a circular dependency with the OIDC provider.

# ==============================================
# Auto-update kubeconfig after cluster is ready
# ==============================================
# WHY: The Helm provider uses ~/.kube/config. Without this, the
# eks_addons module fails with "cluster unreachable" because
# kubeconfig hasn't been updated yet after cluster creation.
# This null_resource runs aws eks update-kubeconfig automatically
# so the Helm provider can connect without any manual steps.
# ==============================================
resource "null_resource" "update_kubeconfig" {
  triggers = {
    cluster_name     = aws_eks_cluster.ecommerce.name
    cluster_endpoint = aws_eks_cluster.ecommerce.endpoint
  }

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${aws_eks_cluster.ecommerce.name} --region ${var.region} --kubeconfig ~/.kube/config"
  }

  depends_on = [
    aws_eks_node_group.workers,
    aws_eks_node_group.public,
  ]
}
