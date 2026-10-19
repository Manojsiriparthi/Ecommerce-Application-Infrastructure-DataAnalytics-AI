# =========================================================================
# EKS MODULE — pip-project-ecommerce
# =========================================================================
# RESOURCES IN THIS FILE (read-order):
#   1.  aws_eks_cluster              — control plane
#   2.  aws_launch_template (×2)     — workers + public node launch configs
#   3.  aws_eks_node_group.workers   — private subnets (app pods)
#   4.  aws_eks_node_group.public    — public subnets (ALB ip-mode)
#   5.  [commented] db_nodes         — future: DB-subnet workloads
#   6.  [commented] ai_gps_nodes     — future: GPU / AI inference
#   7.  data.tls_certificate         — OIDC thumbprint
#   8.  aws_iam_openid_connect_provider — IRSA foundation
#   9.  aws_eks_addon (×3)           — vpc-cni, coredns, kube-proxy
#   10. null_resource.update_kubeconfig — post-create kubeconfig sync
# =========================================================================

# =========================================================================
# 1. EKS CLUSTER — Control Plane
# =========================================================================
resource "aws_eks_cluster" "ecommerce" {
  name     = "${var.project_name}-cluster"
  role_arn = var.cluster_role_arn
  version  = var.cluster_version

  # ------------------------------------------------------------------
  # VPC CONFIG
  # endpoint_private_access = true  → nodes inside the VPC reach the
  #   API server over a private ENI (no internet round-trip).
  # endpoint_public_access  = true  → kubectl from your laptop / CI works
  #   without a VPN. Locked down by public_access_cidrs below.
  # public_access_cidrs — WHO CAN REACH THE PUBLIC API ENDPOINT:
  #   Default ["0.0.0.0/0"] keeps existing behaviour (open).
  #   Set in tfvars to: VPC CIDR + NAT EIP + office IP + CI runner IP.
  #   Example:
  #     ["10.0.0.0/16", "52.90.10.20/32", "203.0.113.5/32"]
  #     ^^^ VPC CIDR    ^^^ NAT EIP         ^^^ office/laptop
  # ------------------------------------------------------------------
  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.cluster_endpoint_public_cidrs
  }

  # ------------------------------------------------------------------
  # CONTROL PLANE LOGGING → CloudWatch /aws/eks/<cluster>/cluster
  # ------------------------------------------------------------------
  # api              — every kubectl / API request (4xx, 5xx, auth errors)
  # audit            — full RBAC audit trail — who created/deleted what
  # authenticator    — IAM → K8s identity mapping; debug "Unauthorized" 401s
  # controllerManager— replica reconciliation, pod lifecycle decisions
  # scheduler        — pod→node placement decisions
  #
  # Log retention is set in the monitoring module:
  #   aws_cloudwatch_log_group "/aws/eks/<cluster>/cluster" = 90 days
  # ------------------------------------------------------------------
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  # ------------------------------------------------------------------
  # ENCRYPTION — Secrets encrypted at rest with customer-managed KMS key
  # Covers: K8s Secrets (tokens, passwords stored as Secret objects)
  # ------------------------------------------------------------------
  dynamic "encryption_config" {
    for_each = var.kms_key_arn != "" ? [1] : []
    content {
      resources = ["secrets"]
      provider {
        key_arn = var.kms_key_arn
      }
    }
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  tags = {
    Name        = "${var.project_name}-cluster"
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }

  lifecycle {
    # Prevent Terraform from downgrading the cluster version if someone
    # manually upgraded it via the console or AWS CLI.
    ignore_changes = [version]
  }
}

# =========================================================================
# 2. LAUNCH TEMPLATES
# =========================================================================
# WHY LAUNCH TEMPLATES:
#   - Gives EC2 instances readable Name tags (without LT, nodes show as
#     "ip-10-x-x-x.ec2.internal" with no context in the console).
#   - Enforces IMDSv2 (http_tokens = "required") — prevents SSRF attacks
#     that steal instance credentials via the metadata service.
#   - http_put_response_hop_limit = 2 — needed for containers to reach IMDS
#     (default=1 blocks pods; 2 allows pods but not nested containers).
#   - instance_type is NOT set here — node group instance_types controls it.
#     Setting in BOTH causes: "Cannot specify instance types in both"
# =========================================================================

# --- Workers launch template ---
resource "aws_launch_template" "workers" {
  name_prefix = "${var.project_name}-workers-"
  description = "Launch template for EKS private worker nodes (application pods)"

  # IMDSv2 — required (tokens mandatory, no unauthenticated metadata reads)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2 enforced
    http_put_response_hop_limit = 2            # pods can reach IMDS
  }

  # Monitoring — enable detailed EC2 monitoring (1-minute CloudWatch metrics)
  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-worker-node"
      Environment = var.environment
      Role        = "worker"
      ManagedBy   = "terraform"
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

  tags = {
    Name        = "${var.project_name}-workers-lt"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Public nodes launch template ---
resource "aws_launch_template" "public" {
  name_prefix = "${var.project_name}-public-"
  description = "Launch template for EKS public subnet nodes (ALB ip-mode ENI support)"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-public-node"
      Environment = var.environment
      Role        = "public-alb-support"
      ManagedBy   = "terraform"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "${var.project_name}-public-volume"
      Environment = var.environment
      Backup      = "false"
    }
  }

  tags = {
    Name        = "${var.project_name}-public-lt"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =========================================================================
# 3. NODE GROUP: Workers (Private Subnets)
# =========================================================================
# PURPOSE: Runs all application pods.
#   - frontend (Next.js)
#   - backend services (user, product, cart, order, payment, notification)
#   - ArgoCD, Fluent Bit, Secrets Store CSI driver
#   - CloudWatch Agent (Container Insights), ADOT collector
#
# NETWORKING:
#   Private subnets → outbound through NAT Gateway.
#   Pods reach Aurora (RDS Proxy), ElastiCache via private routing.
#   No direct inbound from internet.
#
# LABELS:   node-role=worker, workload=application
# TAINTS:   none — all pods schedule here by default unless excluded
#
# UPDATE STRATEGY:
#   maxUnavailable=1 → rolling update; 1 node drained at a time.
#   Pods are gracefully evicted before node is terminated.
# =========================================================================
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

  # Rolling update: replace one node at a time to maintain availability
  update_config {
    max_unavailable = 1
  }

  instance_types = [var.worker_instance_type]

  # AMI type: AL2_x86_64 — Amazon Linux 2 (EKS-optimised)
  # AL2023 is the newer default but AL2 has broader ecosystem support
  ami_type = "AL2_x86_64"

  # Disk size: 50 GB — enough for container image cache + logs
  # EKS default (20 GB) fills up on busy nodes with multiple large images
  disk_size = var.worker_disk_size_gb

  launch_template {
    id      = aws_launch_template.workers.id
    version = aws_launch_template.workers.latest_version
  }

  labels = {
    "node-role"                = "worker"
    "workload"                 = "application"
    "kubernetes.io/os"         = "linux"
    "node.kubernetes.io/lifecycle" = "on-demand"
  }

  tags = {
    Name        = "${var.project_name}-workers"
    Environment = var.environment
    ManagedBy   = "terraform"
    # Cluster Autoscaler tag — required for auto-discovery
    "k8s.io/cluster-autoscaler/enabled"                        = "true"
    "k8s.io/cluster-autoscaler/${var.project_name}-cluster"    = "owned"
  }

  depends_on = [
    aws_eks_cluster.ecommerce,
    var.private_route_dependency,
  ]

  lifecycle {
    # Autoscaler changes desired_size dynamically — Terraform must not
    # reset it back on every apply or it will fight the autoscaler.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# =========================================================================
# 4. NODE GROUP: Public (Public Subnets)
# =========================================================================
# PURPOSE: Supports ALB ip-mode target routing.
#
# WHY PUBLIC NODES ARE NEEDED:
#   The AWS Load Balancer Controller with target-type=ip registers pod IPs
#   directly as ALB targets. The ALB health-checks those IPs via ENIs that
#   must live in the SAME subnets as the ALB (public subnets). Without at
#   least one node here the LB Controller has no ENI to attach in the
#   public subnet and silently falls back to instance mode.
#
# WHAT RUNS HERE:
#   No application pods. System daemonsets only (Fluent Bit, Node Exporter).
#   The label "node-role=public" can be referenced in nodeAffinity rules.
#
# NETWORKING:
#   Public subnets → outbound via Internet Gateway (no NAT cost for these
#   nodes). Pods here still talk to Aurora via private subnet routing.
# =========================================================================
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

  update_config {
    max_unavailable = 1
  }

  instance_types = [var.public_node_instance_type]
  ami_type       = "AL2_x86_64"
  disk_size      = 20   # Public nodes: 20 GB is sufficient (no app images)

  launch_template {
    id      = aws_launch_template.public.id
    version = aws_launch_template.public.latest_version
  }

  labels = {
    "node-role"                    = "public"
    "workload"                     = "alb-support"
    "kubernetes.io/os"             = "linux"
    "node.kubernetes.io/lifecycle" = "on-demand"
  }

  tags = {
    Name        = "${var.project_name}-public-nodes"
    Environment = var.environment
    ManagedBy   = "terraform"
    "k8s.io/cluster-autoscaler/enabled"                        = "true"
    "k8s.io/cluster-autoscaler/${var.project_name}-cluster"    = "owned"
  }

  depends_on = [
    aws_eks_cluster.ecommerce,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# =========================================================================
# 5. NODE GROUP: DB Nodes (Database Subnets) — COMMENTED OUT
# =========================================================================
# REASON: Aurora RDS is AWS-managed. No pods need to run inside database
# subnets today. Pods reach Aurora via RDS Proxy over private routing.
#
# ENABLE WHEN: A future workload requires database-subnet placement
#   (Kafka, data-pipeline jobs, migration tooling, db-sidecar pods).
#
# HOW TO ENABLE:
#   1. Uncomment the block below
#   2. Set create_db_nodes = true in dev.tfvars / prod.tfvars
#   3. terraform apply
#
# NODE COUNT (when enabled): desired=2, min=2, max=3
# TAINT: dedicated=database:NoSchedule — nothing schedules here unless
#        the pod explicitly tolerates it (zero impact on existing pods).
# =========================================================================

# resource "aws_eks_node_group" "db_nodes" {
#   count = var.create_db_nodes ? 1 : 0
#
#   cluster_name    = aws_eks_cluster.ecommerce.name
#   node_group_name = "${var.project_name}-db-nodes"
#   node_role_arn   = var.node_role_arn
#   subnet_ids      = var.db_subnet_ids
#
#   scaling_config {
#     desired_size = 2
#     max_size     = 3
#     min_size     = 2
#   }
#
#   update_config { max_unavailable = 1 }
#
#   instance_types = [var.db_node_instance_type]
#   ami_type       = "AL2_x86_64"
#   disk_size      = 20
#
#   taint {
#     key    = "dedicated"
#     value  = "database"
#     effect = "NO_SCHEDULE"
#   }
#
#   labels = {
#     "node-role" = "database"
#     "workload"  = "db-workloads"
#   }
#
#   tags = {
#     Name        = "${var.project_name}-db-nodes"
#     Environment = var.environment
#     ManagedBy   = "terraform"
#   }
#
#   depends_on = [
#     aws_eks_cluster.ecommerce,
#     var.database_route_dependency,
#   ]
# }

# =========================================================================
# 6. NODE GROUP: AI / GPS Nodes — COMMENTED OUT
# =========================================================================
# REASON: No AI/ML workloads deployed yet.
#
# PLANNED FOR:
#   AI inference, recommendation engine, GPS analytics, data pipelines.
#
# PLANNED CONFIG:
#   Instance   : p3.2xlarge (GPU) or c5.4xlarge (CPU-heavy AI)
#   Subnets    : private (same as workers — no internet exposure)
#   Desired=2, Min=1, Max=4
#   Taint      : dedicated=ai-gpu:NoSchedule
#   Labels     : node-role=ai-gpu, workload=ai-inference
#
# HOW TO ENABLE:
#   1. Add variable "create_ai_nodes" (bool, default false) to variables.tf
#   2. Uncomment the block below
#   3. Set create_ai_nodes = true in tfvars
#   4. terraform apply
# =========================================================================

# resource "aws_eks_node_group" "ai_gps_nodes" {
#   count = var.create_ai_nodes ? 1 : 0
#
#   cluster_name    = aws_eks_cluster.ecommerce.name
#   node_group_name = "${var.project_name}-ai-gps-nodes"
#   node_role_arn   = var.node_role_arn
#   subnet_ids      = var.private_subnet_ids
#
#   scaling_config {
#     desired_size = 2
#     max_size     = 4
#     min_size     = 1
#   }
#
#   update_config { max_unavailable = 1 }
#
#   # Switch to p3.2xlarge for GPU when AI workloads are ready.
#   instance_types = ["c5.4xlarge"]
#   ami_type       = "AL2_x86_64"
#   disk_size      = 100   # larger for ML model storage
#
#   taint {
#     key    = "dedicated"
#     value  = "ai-gpu"
#     effect = "NO_SCHEDULE"
#   }
#
#   labels = {
#     "node-role" = "ai-gpu"
#     "workload"  = "ai-inference"
#   }
#
#   tags = {
#     Name        = "${var.project_name}-ai-gps-nodes"
#     Environment = var.environment
#     ManagedBy   = "terraform"
#   }
#
#   depends_on = [aws_eks_cluster.ecommerce]
# }

# =========================================================================
# 7. OIDC PROVIDER — IRSA Foundation
# =========================================================================
# WHY:
#   OIDC (OpenID Connect) lets EKS pods assume IAM roles WITHOUT storing
#   AWS credentials in pods or Secrets. Flow:
#     Pod token → OIDC endpoint → AWS STS → IAM role → AWS APIs
#
#   Every IRSA role in iam-irsa/main.tf trusts THIS provider ARN.
#   Without it: all IRSA roles are useless → LB Controller, EBS CSI,
#   Cluster Autoscaler, Secrets Store CSI all fail at startup.
#
# THUMBPRINT:
#   SHA-1 fingerprint of the OIDC endpoint's TLS certificate root CA.
#   Fetched dynamically so it stays valid across AWS certificate rotations.
#   AWS ignores the thumbprint for EKS (it validates via the OIDC discovery
#   endpoint), but the field is still required by the API.
# =========================================================================
data "tls_certificate" "eks" {
  url = aws_eks_cluster.ecommerce.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "ecommerce" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.ecommerce.identity[0].oidc[0].issuer

  tags = {
    Name        = "${var.project_name}-oidc-provider"
    Environment = var.environment
    ManagedBy   = "terraform"
    Purpose     = "IRSA — pod IAM role binding via service account tokens"
  }
}

# =========================================================================
# 8. CORE EKS ADDONS — vpc-cni, coredns, kube-proxy
# =========================================================================
# These three are AWS-managed addons (patched + tested by AWS, not Helm).
# They must be installed before any application workloads.
#
# vpc-cni      — assigns real VPC IP addresses to pods (not overlays).
#                Required for ALB ip-mode target registration to work.
#                Managed by aws-node DaemonSet on every node.
#
# coredns      — in-cluster DNS (service discovery).
#                Every pod uses it to resolve service names like
#                "user-service.ecommerce.svc.cluster.local".
#                Runs 2 replicas in kube-system for HA.
#
# kube-proxy   — iptables/ipvs rules for ClusterIP service routing.
#                Every node needs it to forward pod→service traffic.
#
# resolve_conflicts_on_update = "PRESERVE" — if you've manually tweaked
#   addon config (e.g. vpc-cni WARM_ENI_TARGET), Terraform won't overwrite
#   it on every apply. Use "OVERWRITE" only when you want Terraform to win.
#
# NOTE: aws-ebs-csi-driver is in the eks-addons module (not here) because
#   it needs the OIDC provider ARN for IRSA, which creates a circular
#   dependency if placed in this module before OIDC is created.
# =========================================================================
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.ecommerce.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Name        = "${var.project_name}-vpc-cni"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.ecommerce.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Name        = "${var.project_name}-coredns"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [aws_eks_node_group.workers]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.ecommerce.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Name        = "${var.project_name}-kube-proxy"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  depends_on = [aws_eks_node_group.workers]
}

# =========================================================================
# 9. KUBECONFIG AUTO-UPDATE
# =========================================================================
# WHY:
#   The Helm provider in eks-addons/main.tf reads ~/.kube/config to connect
#   to the cluster. Without this null_resource, the first `terraform apply`
#   creates the cluster but the Helm provider immediately fails with
#   "cluster unreachable" because kubeconfig still points at a non-existent
#   or previous cluster endpoint.
#
#   This runs `aws eks update-kubeconfig` automatically after the cluster
#   and both node groups are ready, so Helm can connect on the SAME apply.
#
# TRIGGERS:
#   Re-runs if the cluster name or endpoint changes (new cluster / region
#   change). Does NOT re-run on every apply (no timestamp trigger).
# =========================================================================
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
    aws_eks_addon.vpc_cni,
    aws_eks_addon.coredns,
    aws_eks_addon.kube_proxy,
  ]
}
