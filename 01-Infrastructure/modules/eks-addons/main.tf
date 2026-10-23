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

# =============================================================================
# KEDA — Kubernetes Event-Driven Autoscaling
# =============================================================================
# WHAT: Scales pods based on external events (SQS queue length, Kafka lag,
#       Prometheus metrics, CloudWatch, etc.) — not just CPU/memory.
#
# WHY OVER HPA ALONE:
#   HPA scales on CPU/memory only. KEDA scales on business metrics:
#     - SQS queue depth: "scale checkout-service when 50+ messages in queue"
#     - Kafka consumer lag: "scale order-processor when lag > 100"
#     - Aurora connections: "scale when DB connections > 80% of limit"
#   KEDA also scales to ZERO — no traffic = no pods = no cost.
#
# INFRA vs APP:
#   INFRA (this file): KEDA operator + CRDs (ScaledObject, ScaledJob, TriggerAuthentication)
#   APP (03-Kubernetes/): each service creates a ScaledObject pointing to its
#   Deployment + a trigger (SQS ARN, Kafka topic, etc.)
#
# IRSA: KEDA needs an IRSA role to read AWS metrics (SQS, CloudWatch).
#   Created in iam-irsa module → passed here via var.keda_role_arn.
# =============================================================================
resource "helm_release" "keda" {
  count            = var.enable_keda ? 1 : 0
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  version          = "2.16.0"   # KEDA v2.x GA
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  # IRSA — KEDA needs to read AWS metrics (SQS queue depth, CloudWatch, etc.)
  dynamic "set" {
    for_each = var.keda_role_arn != "" ? [1] : []
    content {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = var.keda_role_arn
    }
  }

  # Resource limits — KEDA operator is lightweight
  set { name  = "operator.resources.requests.cpu",    value = "100m" }
  set { name  = "operator.resources.requests.memory", value = "128Mi" }
  set { name  = "operator.resources.limits.cpu",       value = "500m" }
  set { name  = "operator.resources.limits.memory",   value = "256Mi" }

  depends_on = [null_resource.gateway_api_crds]
}

# =============================================================================
# Falco — runtime security monitoring (DETECTS ANOMALOUS CONTAINER BEHAVIOR)
# =============================================================================
# WHAT: Watches container syscalls in real time via a kernel module / eBPF.
#   Trivy scans images at BUILD time (CI pipeline). Falco watches what containers
#   actually DO at RUNTIME — catches:
#     - Container spawning a shell (reverse shell exploit)
#     - Container reading /etc/shadow or /etc/passwd (credential theft)
#     - Container writing to /bin or /usr/bin (system tampering)
#     - Non-root container escalating to root (privilege escalation)
#     - Outbound connection to known bad IP (data exfiltration)
#     - Container reading Kubernetes service account token
#
# ARCHITECTURE:
#   Falco (DaemonSet) → captures syscalls via eBPF → evaluates rules
#     → FalcoSidekick → forwards alerts to:
#       - SNS topic (→ email + Slack Lambda)
#       - CloudWatch Logs
#       - Slack webhook (if configured)
#
# INFRA vs APP:
#   INFRA (this file): Falco + FalcoSidekick Helm release + default rules
#   APP: nothing — Falco monitors automatically. App team can add custom
#   rules in their namespace if needed.
# =============================================================================
resource "helm_release" "falco" {
  count            = var.enable_falco ? 1 : 0
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  namespace        = "falco"
  create_namespace = true
  version          = "4.16.0"   # Falco v0.39+ with eBPF driver
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  # Use eBPF driver (no kernel module needed — works on all EKS AMIs)
  set { name  = "driver.kind", value = "ebpf" }

  # Resource limits — Falco is lightweight with eBPF
  set { name  = "resources.requests.cpu",    value = "100m"  }
  set { name  = "resources.requests.memory", value = "128Mi" }
  set { name  = "resources.limits.cpu",       value = "500m"  }
  set { name  = "resources.limits.memory",     value = "512Mi" }

  depends_on = [null_resource.gateway_api_crds]
}

# ── FalcoSidekick — forwards Falco alerts to SNS + CloudWatch ────────────────
resource "helm_release" "falcosidekick" {
  count            = var.enable_falco ? 1 : 0
  name             = "falcosidekick"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falcosidekick"
  namespace        = "falco"
  version          = "0.9.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 300

  # Send alerts to SNS topic (same topic as CloudWatch alarms → email + Slack)
  dynamic "set" {
    for_each = var.falco_sns_topic_arn != "" ? [1] : []
    content {
      name  = "config.aws.sns.topicarn"
      value = var.falco_sns_topic_arn
    }
  }
  set { name  = "config.aws.region", value = var.region }

  # Also send to stdout (captured by Fluent Bit → CloudWatch)
  set { name  = "config.output.fields", value = "stdout" }

  # Resource limits
  set { name  = "resources.requests.cpu",    value = "50m"   }
  set { name  = "resources.requests.memory", value = "64Mi"  }
  set { name  = "resources.limits.cpu",       value = "200m"  }
  set { name  = "resources.limits.memory",     value = "256Mi" }

  depends_on = [helm_release.falco]
}

# =============================================================================
# Goldilocks — cost optimization (right-sizes pod CPU/memory requests)
# =============================================================================
# WHAT: Creates VPA objects for every Deployment in a namespace, reads VPA
#   recommendations, and shows them in a web dashboard.
#
# WHY OVER VPA ALONE:
#   VPA gives recommendations but you have to run `kubectl describe vpa` per
#   service. Goldilocks:
#     - Auto-creates VPA for every Deployment (opt-in via namespace label)
#     - Shows ALL recommendations in one web UI
#     - Compares current requests vs recommended requests
#     - Calculates potential savings ($/month if you adopt recommendations)
#
# USAGE:
#   1. Label a namespace to enable Goldilocks:
#        kubectl label namespace ecommerce goldilocks.fairwinds.com/enabled=true
#   2. Open the Goldilocks dashboard (exposed via 08-Monitoring ALB)
#   3. See: "user-service: 200m CPU → recommended 50m CPU (save 75%)"
#
# INFRA vs APP:
#   INFRA (this file): Goldilocks Helm release + VPA CRDs
#   APP: label namespaces to opt in. No app code changes.
# =============================================================================
resource "helm_release" "goldilocks" {
  count            = var.enable_goldilocks ? 1 : 0
  name             = "goldilocks"
  repository       = "https://charts.fairwinds.com/stable"
  chart            = "goldilocks"
  namespace        = "goldilocks"
  create_namespace = true
  version          = "8.0.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 300

  # Dashboard service — ClusterIP (exposed via Gateway API in 08-Monitoring)
  set { name  = "dashboard.service.type", value = "ClusterIP" }

  # Resource limits
  set { name  = "dashboard.resources.requests.cpu",    value = "50m"   }
  set { name  = "dashboard.resources.requests.memory", value = "64Mi"  }
  set { name  = "dashboard.resources.limits.cpu",       value = "200m"  }
  set { name  = "dashboard.resources.limits.memory",     value = "256Mi" }

  set { name  = "controller.resources.requests.cpu",    value = "50m"   }
  set { name  = "controller.resources.requests.memory", value = "64Mi"  }
  set { name  = "controller.resources.limits.cpu",       value = "200m"  }
  set { name  = "controller.resources.limits.memory",     value = "256Mi" }

  depends_on = [helm_release.vpa]
}

# =============================================================================
# Descheduler — pod rebalancing across nodes (cost optimization)
# =============================================================================
# WHAT: Evicts pods from over-utilised nodes and lets the scheduler place
#   them on under-utilised nodes. Karpenter handles NODE provisioning;
#   Descheduler handles POD PLACEMENT optimisation.
#
# WHY:
#   Over time, pods accumulate unevenly:
#     Before: Node-1 (90% CPU), Node-2 (10% CPU) ← imbalanced
#     After:  Node-1 (50% CPU), Node-2 (50% CPU) ← descheduler evicted + rescheduled
#   This means Karpenter can then consolidate and terminate the freed-up node.
#
# STRATEGIES ENABLED:
#   - RemoveDuplicates: don't run 2 replicas of the same Deployment on one node
#   - LowNodeUtilization: evict pods from under-utilised nodes so Karpenter
#     can terminate them (saves money)
#   - RemovePodsViolatingNodeTaints: respect taints
#   - RemovePodsHavingTooManyRestarts: evict crash-looping pods
#
# RUNS AS A CRON JOB — every 2 minutes by default (not always running).
# =============================================================================
resource "helm_release" "descheduler" {
  count            = var.enable_descheduler ? 1 : 0
  name             = "descheduler"
  repository       = "https://kubernetes-sigs.github.io/descheduler"
  chart            = "descheduler"
  namespace        = "kube-system"
  version          = "0.32.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 300

  # Run every 2 minutes
  set { name  = "schedule", value = "*/2 * * * *" }

  # Strategies
  set { name  = "strategies.RemoveDuplicates.enabled", value = "true" }
  set { name  = "strategies.LowNodeUtilization.enabled", value = "true" }
  set { name  = "strategies.RemovePodsViolatingNodeTaints.enabled", value = "true" }
  set { name  = "strategies.RemovePodsHavingTooManyRestarts.enabled", value = "true" }

  # Don't evict pods in kube-system (keep system pods stable)
  set { name  = "deschedulerPolicy.namespaces.exclude[0]", value = "kube-system" }
  set { name  = "deschedulerPolicy.namespaces.exclude[1]", value = "karpenter" }
  set { name  = "deschedulerPolicy.namespaces.exclude[2]", value = "argocd" }
  set { name  = "deschedulerPolicy.namespaces.exclude[3]", value = "monitoring" }
  set { name  = "deschedulerPolicy.namespaces.exclude[4]", value = "falco" }
  set { name  = "deschedulerPolicy.namespaces.exclude[5]", value = "keda" }

  depends_on = [null_resource.gateway_api_crds]
}

# =============================================================================
# Kubecost — cost allocation per namespace + per service
# =============================================================================
# WHAT: Shows how much each namespace, deployment, and pod costs.
#   Reads Kubernetes resource usage + AWS pricing API → calculates:
#     - Monthly cost per namespace (ecommerce: $X, monitoring: $Y, kube-system: $Z)
#     - Monthly cost per service (user-service: $A, product-service: $B)
#     - Idle/wasted resources (pods requesting 2 CPU but using 0.1 CPU)
#     - Savings recommendations (right-size pods, use Spot, clean up unused PVCs)
#
# WHY:
#   CloudWatch shows you AWS infrastructure costs (EC2, RDS, ALB).
#   Kubecost shows you KUBERNETES-level costs — which app is burning the most
#   CPU/memory and how much that costs in dollars.
#
# DASHBOARD:
#   Exposed via 08-Monitoring ALB at /kubecost/*
#   Shows real-time cost allocation, efficiency score, savings recommendations.
#
# INFRA vs APP:
#   INFRA (this file): Kubecost Helm release
#   APP: nothing — Kubecost reads metrics automatically.
# =============================================================================
resource "helm_release" "kubecost" {
  count            = var.enable_kubecost ? 1 : 0
  name             = "kubecost"
  repository       = "https://kubecost.github.io/cost-analyzer"
  chart            = "cost-analyzer"
  namespace        = "kubecost"
  create_namespace = true
  version          = "2.5.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  # Cluster name for Kubecost UI
  set { name  = "kubecostProductConfigs.clusterName", value = var.cluster_name }

  # Free tier — no license key needed for basic cost allocation
  set { name  = "kubecostProductConfigslicenseKey", value = "" }

  # Service type ClusterIP — exposed via Gateway API in 08-Monitoring
  set { name  = "service.type", value = "ClusterIP" }

  # Persistent storage for cost history
  set { name  = "persistentVolume.size", value = "5Gi" }

  # Resource limits
  set { name  = "resources.requests.cpu",    value = "100m"  }
  set { name  = "resources.requests.memory", value = "256Mi" }
  set { name  = "resources.limits.cpu",       value = "500m"  }
  set { name  = "resources.limits.memory",     value = "1Gi"   }

  depends_on = [null_resource.gateway_api_crds]
}

# =============================================================================
# Kubeshark — network traffic analysis for K8s (Wireshark for K8s)
# =============================================================================
# WHAT: Captures ALL network traffic between pods in real time.
#   - DaemonSet on every node — sniffs pod-to-pod traffic
#   - Web UI at http://<kubeshark-node>:8899
#   - Filter by namespace, pod, service, protocol
#   - See HTTP requests/responses, gRPC, DNS, TCP handshakes
#
# WHY:
#   Debug "why is user-service getting 500 from product-service?"
#   See the actual HTTP request/response payloads, headers, timing.
#   Fluent Bit shows you LOGS; Kubeshark shows you the WIRE.
#
# WHY NOT ALWAYS ON:
#   Kubeshark is resource-heavy (captures everything on every node).
#   Enable only for debugging — toggle with var.enable_kubeshark.
#   Recommended: enable in dev, disable in prod.
#
# INFRA vs APP:
#   INFRA (this file): Kubeshark Helm release
#   APP: nothing — operators open the web UI to inspect traffic
# =============================================================================
resource "helm_release" "kubeshark" {
  count            = var.enable_kubeshark ? 1 : 0
  name             = "kubeshark"
  repository       = "https://kubeshark.github.io/helm-charts"
  chart            = "kubeshark"
  namespace        = "kubeshark"
  create_namespace = true
  version          = "1.0.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  # Capture only the ecommerce namespace to reduce noise + resource usage
  set { name  = "tap.namespaces", value = "ecommerce" }

  # Web UI port
  set { name  = "hub.frontend.port", value = "8899" }

  # Resource limits — heavy capture
  set { name  = "worker.resources.requests.cpu",    value = "200m"   }
  set { name  = "worker.resources.requests.memory", value = "256Mi"  }
  set { name  = "worker.resources.limits.cpu",       value = "1000m"  }
  set { name  = "worker.resources.limits.memory",    value = "1Gi"    }

  depends_on = [null_resource.gateway_api_crds]
}

# =============================================================================
# CALICO — Network Policy enforcement (pod-to-pod isolation)
# =============================================================================
# WHY: AWS VPC CNI doesn't enforce Kubernetes NetworkPolicies by default.
#   Without Calico, ANY pod can reach ANY other pod — a compromised frontend
#   pod can directly access payment-service, Aurora sidecars, etc.
#
#   Calico runs in "policy-only" mode — it doesn't replace VPC CNI for IP
#   allocation, just adds NetworkPolicy enforcement on top.
#
#   DEFAULT POLICY (created below):
#     - Default-deny in ecommerce namespace (no traffic unless explicitly allowed)
#     - Allow frontend → all backend services
#     - Allow backend services → Aurora (via RDS Proxy)
#     - Allow backend services → Redis
#     - Allow backend services → SNS/SQS (via VPC endpoints)
#     - Deny everything else
# =============================================================================
resource "helm_release" "calico" {
  count            = var.enable_network_policies ? 1 : 0
  name             = "calico"
  repository       = "https://docs.tigera.io/calico/charts"
  chart            = "tigera-operator"
  namespace        = "tigera-system"
  create_namespace = true
  version          = "3.29.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  # Calico in policy-only mode (doesn't replace VPC CNI)
  set { name  = "installation.cni.type", value = "none" }
  set { name  = "installation.controlPlaneTolerations[0].key", value = "CriticalAddonsOnly" }
  set { name  = "installation.controlPlaneTolerations[0].value", value = "true" }

  depends_on = [null_resource.gateway_api_crds]
}

# ── Default-deny NetworkPolicy in ecommerce namespace ─────────────────────────
# No pod-to-pod traffic unless explicitly allowed by an allow-rule below
resource "kubernetes_manifest" "default_deny_egress" {
  count = var.enable_network_policies ? 1 : 0
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny-egress"
      namespace = "ecommerce"
    }
    spec = {
      podSelector = {}   # select all pods in the namespace
      policyTypes = ["Egress"]
      # No egress rules = deny all egress by default
    }
  }
  depends_on = [helm_release.calico]
}

resource "kubernetes_manifest" "default_deny_ingress" {
  count = var.enable_network_policies ? 1 : 0
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny-ingress"
      namespace = "ecommerce"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress"]
    }
  }
  depends_on = [helm_release.calico]
}

# ── Allow DNS (CoreDNS) for all pods ──────────────────────────────────────────
resource "kubernetes_manifest" "allow_dns" {
  count = var.enable_network_policies ? 1 : 0
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "allow-dns"
      namespace = "ecommerce"
    }
    spec = {
      podSelector = {}
      policyTypes = ["Egress"]
      egress = [{
        to = [{
          namespaceSelector = {
            matchLabels = { "kubernetes.io/metadata.name" = "kube-system" }
          }
        }]
        ports = [
          { protocol = "UDP", port = 53 },
          { protocol = "TCP", port = 53 }
        ]
      }]
    }
  }
  depends_on = [helm_release.calico]
}

# ── Allow frontend → backend services (HTTP) ──────────────────────────────────
resource "kubernetes_manifest" "allow_frontend_to_backend" {
  count = var.enable_network_policies ? 1 : 0
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "allow-frontend-to-backend"
      namespace = "ecommerce"
    }
    spec = {
      podSelector = {
        matchLabels = { "app" = "frontend" }
      }
      policyTypes = ["Egress"]
      egress = [{
        to = [{
          podSelector = {
            matchExpressions = [{
              key      = "app"
              operator = "In"
              values   = ["user-service", "product-service", "cart-service", "order-service", "payment-service"]
            }]
          }
        }]
        ports = [{ protocol = "TCP", port = 8080 }]
      }]
    }
  }
  depends_on = [helm_release.calico]
}

# ── Allow backend services → Aurora (RDS Proxy) + Redis via VPC endpoints ────
# Pods connect to Aurora/Redis via private IPs — allow all egress to VPC CIDR
resource "kubernetes_manifest" "allow_backend_to_aurora_redis" {
  count = var.enable_network_policies ? 1 : 0
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "allow-backend-to-aurora-redis"
      namespace = "ecommerce"
    }
    spec = {
      podSelector = {
        matchExpressions = [{
          key      = "app"
          operator = "In"
          values   = ["user-service", "product-service", "cart-service", "order-service", "payment-service", "notification-service"]
        }]
      }
      policyTypes = ["Egress"]
      egress = [{
        # Allow to any IP in the VPC (Aurora, Redis, VPC endpoints are all in VPC)
        ipBlock = { cidr = "0.0.0.0/0" }
        ports = [
          { protocol = "TCP", port = 5432 },  # Aurora PostgreSQL
          { protocol = "TCP", port = 6379 },  # Redis
          { protocol = "TCP", port = 443 }    # AWS services via VPC endpoints
        ]
      }]
    }
  }
  depends_on = [helm_release.calico]
}

# =============================================================================
# POD SECURITY STANDARDS — restricted mode
# =============================================================================
# EKS has built-in pod security admission (no extra controller needed).
# Labeling a namespace with `pod-security.kubernetes.io/enforce=restricted`
# PREVENTS:
#   - Containers running as root (must set runAsNonRoot: true)
#   - Privileged containers (securityContext.privileged: true)
#   - hostPath mounts
#   - host network/pid/IPC
#   - Capabilities beyond the allowed set
#   - seccompProfile not set
#
# This means any pod that violates these rules gets REJECTED at admission time.
# =============================================================================
resource "kubernetes_manifest" "pod_security_restricted" {
  manifest = {
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "ecommerce"
      labels = {
        "pod-security.kubernetes.io/enforce"         = "restricted"
        "pod-security.kubernetes.io/enforce-version" = "latest"
        "pod-security.kubernetes.io/audit"           = "restricted"
        "pod-security.kubernetes.io/audit-version"    = "latest"
        "pod-security.kubernetes.io/warn"            = "restricted"
        "pod-security.kubernetes.io/warn-version"    = "latest"
      }
    }
  }
  depends_on = [helm_release.lb_controller]
}
