# ==============================================
# EKS Cluster
# ==============================================
resource "aws_eks_cluster" "this" {
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
# depends_on includes the private route table associations
# so this node group only starts creating AFTER the private
# subnets actually have a working NAT route - not just after
# the subnets themselves exist. Without this, nodes can start
# launching before internet egress is ready and hang for a
# long time retrying kubelet bootstrap / ECR pulls.
# ==============================================
resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-workers"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.private_subnet_ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 2
  }

  instance_types = [var.worker_instance_type]

  tags = {
    Name        = "${var.project_name}-workers"
    Environment = var.environment
  }

  depends_on = [
    aws_eks_cluster.this,
    var.private_route_dependency,
  ]
}

# ==============================================
# EKS Node Group: Dedicated DB Nodes (Database Subnets)
# depends_on the database route table associations for the
# same reason as above - the database subnets previously had
# NO internet route at all, which made this node group hang
# indefinitely ("Still creating...") until timeout, because
# nodes could never reach the EKS API endpoint or pull the
# bootstrap images from ECR. That route has now been fixed in
# the networking module (see modules/networking/main.tf).
# ==============================================
resource "aws_eks_node_group" "db_nodes" {
  cluster_name    = aws_eks_cluster.this.name
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

  tags = {
    Name        = "${var.project_name}-db-nodes"
    Environment = var.environment
  }

  depends_on = [
    aws_eks_cluster.this,
    var.database_route_dependency,
  ]
}

# ==============================================
# EKS Node Group: Public (Public Subnets)
# Nodes here route outbound traffic directly through the
# Internet Gateway (public route table) instead of the NAT
# Gateway - avoids NAT Gateway data-processing cost, and
# supports AWS Load Balancer Controller "instance" target-type
# mode where worker nodes benefit from public subnet placement.
# Public subnets already had a route from creation (IGW), which
# is why this node group was NOT hanging like the other two.
# ==============================================
resource "aws_eks_node_group" "public" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-public"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.public_subnet_ids

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 2
  }

  instance_types = [var.public_node_instance_type]

  labels = {
    "node-role" = "public"
  }

  tags = {
    Name        = "${var.project_name}-public-nodes"
    Environment = var.environment
  }

  depends_on = [aws_eks_cluster.this]
}

# ==============================================
# OIDC Provider for IRSA
# ==============================================
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

# ==============================================
# Core EKS Addons
# ==============================================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  depends_on = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  depends_on = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  depends_on = [aws_eks_node_group.workers]
}

# NOTE: The aws-ebs-csi-driver addon requires the EBS CSI IRSA role,
# which is created in the "iam-irsa" module AFTER this cluster's OIDC
# provider exists. That addon is applied via the "eks-addons" module
# in the environment root to avoid a circular module dependency.
