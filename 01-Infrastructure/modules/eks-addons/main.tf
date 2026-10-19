# ==============================================
# EBS CSI Driver Addon
# ==============================================
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = var.ebs_csi_role_arn
}

# ==============================================
# AWS Load Balancer Controller — v2.14+ (Gateway API GA)
# ==============================================
# v2.14 adds GA support for Kubernetes Gateway API:
#   HTTPRoute / GRPCRoute  → provisioned as AWS ALB
#   TCPRoute / UDPRoute    → provisioned as AWS NLB
#
# The controller auto-detects Gateway CRDs (installed below via
# null_resource.gateway_api_crds) and enables ALBGatewayAPI +
# NLBGatewayAPI feature gates automatically. No extra flags needed.
# ==============================================
resource "helm_release" "lb_controller" {
  name            = "aws-load-balancer-controller"
  repository      = "https://aws.github.io/eks-charts"
  chart           = "aws-load-balancer-controller"
  namespace       = "kube-system"
  version         = "1.11.0"   # chart 1.11.x = controller v2.14.x — Gateway API GA
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
    name  = "vpcId"
    value = var.vpc_id
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
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }

  # Gateway API feature gates — explicitly enabled (auto-detected but explicit is safer)
  set {
    name  = "featureGates"
    value = "ALBGatewayAPI=true,NLBGatewayAPI=true"
  }

  depends_on = [
    null_resource.gateway_api_crds,
    null_resource.gateway_api_lbc_crds,
  ]
}

# =============================================================================
# GATEWAY API — INFRA-LEVEL INSTALL
# =============================================================================
# INFRA OWNS (this file):
#   1. Gateway API standard CRDs (v1.6.0)
#   2. AWS-vended Gateway CRDs (TargetGroupConfiguration, LoadBalancerConfiguration,
#      ListenerRuleConfiguration)
#   3. GatewayClass resource — bound to AWS LBC
#
# APP TEAM OWNS (03-Kubernetes/, applied via ArgoCD):
#   - Gateway resource (listener, hostname, TLS)
#   - HTTPRoute per service (frontend, user, product, cart, order, payment, notification)
#   - GRPCRoute when AI/ML services are added
#
# WHY CRDs VIA null_resource NOT HELM:
#   CRDs must exist in the cluster BEFORE the LBC starts so it can detect them
#   and enable the Gateway API controllers. Helm chart for LBC depends_on
#   the null_resource, guaranteeing CRDs are applied first.
# =============================================================================

# ── 1. Standard Gateway API CRDs (v1.6.0 — matches LBC v2.14+) ────────────────
resource "null_resource" "gateway_api_crds" {
  triggers = {
    crd_version = "v1.6.0"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = <<-EOT
      set -e
      echo "[Gateway API] Applying standard CRDs v1.6.0..."
      kubectl apply --server-side=true --force-conflicts \
        -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
      echo "[Gateway API] Standard CRDs applied: Gateway, GatewayClass, HTTPRoute, GRPCRoute, TCPRoute, UDPRoute, TLSRoute"
    EOT
  }
}

# ── 2. AWS-vended CRDs (required by LBC for Gateway API features) ────────────
# TargetGroupConfiguration, LoadBalancerConfiguration, ListenerRuleConfiguration
resource "null_resource" "gateway_api_lbc_crds" {
  triggers = {
    lbc_version = "v2.14.0"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command = <<-EOT
      set -e
      echo "[Gateway API] Applying AWS-vended Gateway CRDs from LBC main branch..."
      kubectl apply --server-side=true --force-conflicts \
        -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/config/crd/gateway/gateway-crds.yaml
      echo "[Gateway API] AWS CRDs applied: TargetGroupConfiguration, LoadBalancerConfiguration, ListenerRuleConfiguration"
    EOT
  }

  depends_on = [null_resource.gateway_api_crds]
}

# ── 3. GatewayClass — infra-owned, app teams attach HTTPRoutes to it ──────────
# GatewayClass tells Kubernetes: "the AWS LBC is the controller that handles
# Gateways of this class." The app team's Gateway manifest references this
# class by name:  spec.gatewayClassName: alb-gateway
#
# controllerName MUST be exactly "eks.amazonaws.com/gateway-controller" —
# this is the value LBC v2.14+ registers itself with. Any other string and
# the GatewayClass sits in "NotAcceptedByController" status forever.
# =============================================================================
resource "kubernetes_manifest" "gateway_class_alb" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = var.gateway_class_name
      labels = {
        "app.kubernetes.io/name"       = "gateway-class"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      controllerName = "eks.amazonaws.com/gateway-controller"
      description    = "AWS ALB GatewayClass — provisions ALBs for HTTPRoute/GRPCRoute. App teams create HTTPRoute objects attaching to Gateways of this class."
    }
  }

  depends_on = [
    null_resource.gateway_api_crds,
    null_resource.gateway_api_lbc_crds,
  ]
}

# ==============================================
# Cluster Autoscaler (Helm) — DISABLED, replaced by Karpenter
# ==============================================
# WHY DISABLED:
#   Karpenter replaces Cluster Autoscaler. Running both at once causes
#   conflicts — both controllers try to scale the same pending pods, leading
#   to over-provisioning and thrashing.
#
#   Karpenter advantages over Cluster Autoscaler:
#     - Provisions EC2 directly via RunInstances (no ASG needed)
#     - Picks optimal instance type per pod (no pre-set instance_types list)
#     - Faster scale-up (~30s vs 5+ min for ASG-based CA)
#     - Consolidates underutilised nodes (scales down aggressively)
#     - Native Spot support with interruption queue
#
# KEEP THIS BLOCK COMMENTED — do not re-enable unless you remove Karpenter.
# ==============================================
# resource "helm_release" "cluster_autoscaler" {
#   name            = "cluster-autoscaler"
#   repository      = "https://kubernetes.github.io/autoscaler"
#   chart           = "cluster-autoscaler"
#   namespace       = "kube-system"
#   force_update    = true
#   cleanup_on_fail = true
#   wait            = false
#
#   set { name  = "autoDiscovery.clusterName", value = var.cluster_name }
#   set { name  = "awsRegion",                 value = var.region      }
#   set {
#     name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
#     value = var.cluster_autoscaler_role_arn
#   }
# }

# =============================================================================
# KARPENTER — modern node autoscaler (replaces Cluster Autoscaler)
# =============================================================================
# ARCHITECTURE:
#   1. SQS queue + EventBridge rules → created in the iam-irsa module
#      (so the Karpenter role policy can scope SQS permissions to the real
#      queue ARN in a SINGLE terraform apply — no wildcard, no second pass)
#   2. Helm release → installs Karpenter controller (deployment + webhook)
#   3. IRSA role → created in iam-irsa, grants ec2:RunInstances, iam:PassRole,
#      sqs:ReceiveMessage (scoped to the real queue ARN)
#   4. NodePool → which pods Karpenter should provision for, instance constraints
#   5. EC2NodeClass → AWS-specific node config (AMI, subnet, SG, tags)
#
# SCALE-UP FLOW:
#   Pod pending → scheduler can't fit it → Karpenter reads pod requirements
#   → picks optimal instance type → calls ec2:RunInstances → node joins cluster
#   → pod schedules within ~30 seconds
#
# SCALE-DOWN FLOW:
#   Karpenter monitors node utilisation → if a node is underutilised AND its pods
#   can move elsewhere → drains + terminates the node → saves money
#
# SQS QUEUE + EVENTBRIDGE RULES:
#   Created in iam-irsa module (alongside the Karpenter role) so the role's
#   SQS permission can be scoped to the actual queue ARN — works in one apply.
#   The queue NAME is passed here via var.karpenter_interruption_queue_name
#   for the Helm chart's settings.interruptionQueueName value.
# =============================================================================

# ── Karpenter Helm release (v1.x GA) ──────────────────────────────────────────
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository        = "oci://public.ecr.aws/karpenter/karpenter"
  chart             = "karpenter"
  namespace         = "karpenter"
  create_namespace  = true
  version           = "1.2.1"   # GA release — NodePool + EC2NodeClass CRDs
  force_update      = true
  cleanup_on_fail   = true
  atomic            = true
  timeout           = 600

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "settings.interruptionQueueName"
    value = var.karpenter_interruption_queue_name
  }

  # IRSA — annotate the karpenter service account with the IAM role ARN
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.karpenter_role_arn
  }

  # Resource limits — Karpenter controller is lightweight
  set { name  = "controller.resources.requests.cpu",    value = "100m" }
  set { name  = "controller.resources.requests.memory", value = "128Mi" }
  set { name  = "controller.resources.limits.cpu",       value = "500m" }
  set { name  = "controller.resources.limits.memory",     value = "512Mi" }

  depends_on = [null_resource.gateway_api_crds]
}

# ── Default NodePool — what pods Karpenter provisions for ───────────────────
# NodePool is the successor to the old Provisioner CRD (v0.x).
# It defines: which labels/taints new nodes get, instance constraints,
# and which pods are eligible (via labels).
#
# This default NodePool:
#   - Accepts any pod with no special constraints
#   - Uses On-Demand as the primary capacity type (Spot can be enabled later)
#   - Allows t3.medium / t3.large / t3.xlarge (matches worker nodes)
#   - Consolidates after 30s — empty nodes are removed 30s after going idle
resource "kubernetes_manifest" "karpenter_default_nodepool" {
  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
      labels = {
        "app.kubernetes.io/name"       = "karpenter"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-role"              = "karpenter"
            "karpenter.sh/discovery" = var.cluster_name
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          taints = []
          requirements = [
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["t"] },
            { key = "karpenter.k8s.aws/instance-family",  operator = "In", values = ["t3", "t3a"] },
            { key = "karpenter.k8s.aws/instance-size",     operator = "In", values = ["medium", "large", "xlarge"] },
            { key = "kubernetes.io/arch",                  operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type",          operator = "In", values = ["on-demand"] }
          ]
        }
      }
      limits = {
        cpu    = "20"
        memory = "80Gi"
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  }

  depends_on = [helm_release.karpenter]
}

# ── EC2NodeClass — AWS-specific node configuration ───────────────────────────
# EC2NodeClass tells Karpenter HOW to build EC2 instances:
#   - AMI: AL2023 (EKS-optimised, auto-resolves to latest for cluster version)
#   - Subnet: discovered via the karpenter.sh/discovery tag on subnets
#   - Security group: discovered via the karpenter.sh/discovery tag on SGs
#   - IAM: the existing EKS node role (no separate Karpenter instance profile)
#   - Tags: standard project tags for cost allocation
resource "kubernetes_manifest" "karpenter_default_ec2nodeclass" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
      labels = {
        "app.kubernetes.io/name"       = "karpenter"
        "app.kubernetes.io/managed-by" = "terraform"
      }
    }
    spec = {
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      role = var.karpenter_node_role_name
      tags = {
        Name        = "${var.project_name}-karpenter-node"
        Environment = var.environment
        ManagedBy   = "karpenter"
        Project     = var.project_name
      }
    }
  }

  depends_on = [helm_release.karpenter]
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

# ==============================================
# OBSERVABILITY ADDONS
# ==============================================

# -----------------------------------------------
# 1. Amazon CloudWatch Observability EKS Addon
# -----------------------------------------------
# WHY: Single EKS-managed addon that installs:
#   - CloudWatch Agent       → cluster & node metrics (CPU, mem, disk, net)
#   - AWS ADOT (OpenTelemetry) → distributed traces from app pods → X-Ray
#   - Container Insights      → pre-built CloudWatch dashboards for EKS
#
# This replaces a self-managed prometheus-stack for AWS-native
# observability. Metrics land in CloudWatch; traces go to X-Ray.
# -----------------------------------------------
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name             = var.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  service_account_role_arn = var.cloudwatch_observability_role_arn

  resolve_conflicts_on_update = "PRESERVE"

  tags = {
    Name        = "${var.project_name}-cloudwatch-observability"
    Environment = var.environment
  }
}

# -----------------------------------------------
# 2. Kube-State-Metrics (KSM)
# -----------------------------------------------
# WHY: CloudWatch Container Insights gives you node/pod resource metrics,
# but KSM exposes Kubernetes object-state metrics that CI does NOT cover:
#   - Deployment desired vs. ready replicas
#   - Pod restart counts per container
#   - HPA current/desired replica counts
#   - Job success/failure counts
#   - PVC binding status
# -----------------------------------------------
resource "helm_release" "kube_state_metrics" {
  name             = "kube-state-metrics"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-state-metrics"
  namespace        = "monitoring"
  create_namespace = true
  version          = "5.18.0"
  force_update     = true
  cleanup_on_fail  = true
  wait             = true

  set {
    name  = "service.type"
    value = "ClusterIP"
  }
  set {
    name  = "prometheus.monitor.enabled"
    value = "true"
  }
  set {
    name  = "collectors"
    value = "deployments\\,pods\\,replicasets\\,horizontalpodautoscalers\\,persistentvolumeclaims\\,jobs\\,nodes"
  }

  tags = {
    Name        = "${var.project_name}-kube-state-metrics"
    Environment = var.environment
  }
}

# -----------------------------------------------
# 3. VPA — Vertical Pod Autoscaler
# -----------------------------------------------
# WHY: HPA (horizontal) scales pod count; VPA (vertical) right-sizes
# CPU/memory requests per pod. Together they prevent:
#   - OOMKilled pods (under-requested memory)
#   - Throttled CPUs (under-requested CPU)
#   - Wasted capacity (over-requested resources blocking scheduling)
# -----------------------------------------------
resource "helm_release" "vpa" {
  name             = "vpa"
  repository       = "https://charts.fairwinds.com/stable"
  chart            = "vpa"
  namespace        = "kube-system"
  version          = "4.4.6"
  force_update     = true
  cleanup_on_fail  = true
  wait             = false

  set {
    name  = "updater.enabled"
    value = "true"
  }
  set {
    name  = "admissionController.enabled"
    value = "true"
  }
}

# ==============================================
# Secrets Store CSI Driver + AWS Provider
# ==============================================
resource "helm_release" "secrets_store_csi" {
  name             = "secrets-store-csi-driver"
  repository       = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart            = "secrets-store-csi-driver"
  namespace        = "kube-system"
  version          = "1.4.3"
  force_update     = true
  cleanup_on_fail  = true
  wait             = true

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }
  set {
    name  = "enableSecretRotation"
    value = "true"
  }
  set {
    name  = "rotationPollInterval"
    value = "120s"
  }

  depends_on = [helm_release.lb_controller]
}

resource "helm_release" "secrets_store_csi_aws_provider" {
  name             = "secrets-store-csi-driver-provider-aws"
  repository       = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart            = "secrets-store-csi-driver-provider-aws"
  namespace        = "kube-system"
  version          = "0.3.9"
  force_update     = true
  cleanup_on_fail  = true
  wait             = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.secrets_store_csi_role_arn
  }

  depends_on = [helm_release.secrets_store_csi]
}
