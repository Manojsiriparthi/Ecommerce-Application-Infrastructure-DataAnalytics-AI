# ==============================================
# EBS CSI Driver Addon
# ==============================================
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = var.ebs_csi_role_arn
}

# ==============================================
# AWS Load Balancer Controller (BEST STABLE VERSION)
# ==============================================
resource "helm_release" "lb_controller" {
  name            = "aws-load-balancer-controller"
  repository      = "https://aws.github.io/eks-charts"
  chart           = "aws-load-balancer-controller"
  namespace       = "kube-system"
  version         = "1.6.2" # Stable chart version for v2.6.2 controller
  force_update    = true
  cleanup_on_fail = true
  atomic          = true
  timeout         = 900

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.lb_controller_role_arn
  }
  # Critical: skip webhook if existing to prevent deadlock
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }
}

# ==============================================
# Cluster Autoscaler (Helm)
# ==============================================
resource "helm_release" "cluster_autoscaler" {
  name            = "cluster-autoscaler"
  repository      = "https://kubernetes.github.io/autoscaler"
  chart           = "cluster-autoscaler"
  namespace       = "kube-system"
  force_update    = true
  cleanup_on_fail = true
  wait            = false

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "awsRegion"
    value = var.region
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.cluster_autoscaler_role_arn
  }
}

# ==============================================
# Metrics Server
# ==============================================
resource "helm_release" "metrics_server" {
  name            = "metrics-server"
  repository      = "https://kubernetes-sigs.github.io/metrics-server/"
  chart           = "metrics-server"
  namespace       = "kube-system"
  force_update    = true
  cleanup_on_fail = true
  wait            = false
}

# ==============================================
# VPA (Vertical Pod Autoscaler - STABLE VERSION)
# ==============================================
resource "helm_release" "vpa" {
  name            = "vpa"
  repository      = "https://charts.fairwinds.com/stable"
  chart           = "vpa"
  namespace       = "kube-system"
  version         = "3.0.0" # Stable chart version
  force_update    = true
  cleanup_on_fail = true
  wait            = false
}

# ==============================================
# Fluent Bit
# ==============================================
resource "helm_release" "fluent_bit" {
  name             = "aws-for-fluent-bit"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-for-fluent-bit"
  namespace        = "logging"
  create_namespace = true
  force_update     = true
  cleanup_on_fail  = true
  wait             = false

  set {
    name  = "cloudWatch.region"
    value = var.region
  }
  set {
    name  = "cloudWatch.logGroupName"
    value = "/aws/eks/${var.project_name}/fluentbit-logs"
  }
}

