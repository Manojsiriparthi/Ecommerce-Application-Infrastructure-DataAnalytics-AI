# =============================================================================
# 08-Monitoring — Monitoring + DevOps Tools
# =============================================================================
# INSTALLS (via Helm, flat Terraform — no modules):
#   1. kube-prometheus-stack  → Prometheus + Grafana + Alertmanager
#   2. ELK                    → Elasticsearch + Kibana + Fluent Bit
#   3. ArgoCD                 → GitOps CD controller
#   4. Kubeshark              → Network traffic analyzer (optional)
#
# EXPOSES (via Gateway API — creates a NEW ALB separate from the app ALB):
#   https://monitor.<domain> → ALB → Gateway → HTTPRoutes
#     /argocd/*     → argocd-server:443
#     /grafana/*    → grafana:3000
#     /prometheus/* → prometheus-server:9090
#     /kibana/*     → kibana:5601
#     /kubeshark/*  → kubeshark-frontend:8899
#
# SECURITY:
#   ALB security group allows port 443 ONLY from var.allowed_cidrs.
#   Default 0.0.0.0/0 (open) — restrict to your IP in monitoring.tfvars.
# =============================================================================

# =============================================================================
# 1. PROMETHEUS + GRAFANA (kube-prometheus-stack)
# =============================================================================
resource "helm_release" "prometheus_grafana" {
  count            = var.enable_prometheus_grafana ? 1 : 0
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true
  version          = "65.0.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 900

  # ── Grafana ───────────────────────────────────────────────────────────────
  set {
    name  = "grafana.enabled"
    value = "true"
  }
  set {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
  # Grafana service — ClusterIP (exposed via Gateway API, not direct LB)
  set {
    name  = "grafana.service.type"
    value = "ClusterIP"
  }
  # Provisions Prometheus + Alertmanager as data sources automatically
  set {
    name  = "grafana.grafana\\.additionalDataSources"
    value = "[]"
  }
  # Ingress disabled — we use Gateway API HTTPRoute instead
  set {
    name  = "grafana.ingress.enabled"
    value = "false"
  }

  # ── Prometheus ───────────────────────────────────────────────────────────
  # Retention: 15 days of metrics (enough for debugging + trend analysis)
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "15d"
  }
  # Storage: 20GB persistent volume for metrics
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = "20Gi"
  }
  # Scrape the ecommerce namespace automatically
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }

  # ── Alertmanager ──────────────────────────────────────────────────────────
  set {
    name  = "alertmanager.enabled"
    value = "true"
  }
}

# =============================================================================
# 2. ELK STACK (Elasticsearch + Kibana + Fluent Bit)
# =============================================================================
# WHY ELK + Prometheus/Grafana together:
#   Prometheus = metrics (CPU, memory, request rates, dashboards)
#   ELK        = logs (application stdout/stderr, searchable, structured)
#   Together they give you full observability: metrics + logs + traces

# ── Elasticsearch ────────────────────────────────────────────────────────────
resource "helm_release" "elasticsearch" {
  count            = var.enable_elk ? 1 : 0
  name             = "elasticsearch"
  repository       = "https://helm.elastic.co"
  chart            = "elasticsearch"
  namespace        = "elk"
  create_namespace = true
  version          = "8.15.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 900

  # Single-node for dev — scale to 3 for prod HA
  set {
    name  = "replicas"
    value = "1"
  }
  # Resources — Elasticsearch is memory-hungry
  set {
    name  = "resources.requests.cpu"
    value = "500m"
  }
  set {
    name  = "resources.requests.memory"
    value = "2Gi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "1000m"
  }
  set {
    name  = "resources.limits.memory"
    value = "3Gi"
  }
  # Persistent storage for indices
  set {
    name  = "volumeClaimTemplate.resources.requests.storage"
    value = "30Gi"
  }
  # Disable xpack security for simplicity (enable for prod with TLS)
  set {
    name  = "esConfig.elasticsearch.yml"
    value = "xpack.security.enabled: false\nxpack.ml.enabled: false"
  }
}

# ── Kibana ───────────────────────────────────────────────────────────────────
resource "helm_release" "kibana" {
  count            = var.enable_elk ? 1 : 0
  name             = "kibana"
  repository       = "https://helm.elastic.co"
  chart            = "kibana"
  namespace        = "elk"
  version          = "8.15.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  set {
    name  = "service.type"
    value = "ClusterIP"
  }
  set {
    name  = "resources.requests.cpu"
    value = "200m"
  }
  set {
    name  = "resources.requests.memory"
    value = "512Mi"
  }
  set {
    name  = "resources.limits.cpu"
    value = "500m"
  }
  set {
    name  = "resources.limits.memory"
    value = "1Gi"
  }

  depends_on = [helm_release.elasticsearch]
}

# ── Fluent Bit (log shipper → Elasticsearch) ─────────────────────────────────
# Sends all pod logs from the ecommerce namespace to Elasticsearch
resource "helm_release" "fluent_bit_elk" {
  count            = var.enable_elk ? 1 : 0
  name             = "fluent-bit"
  repository       = "https://fluent.github.io/helm-charts"
  chart            = "fluent-bit"
  namespace        = "elk"
  version          = "0.46.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 300

  # Output to Elasticsearch running in the same namespace
  set {
    name  = "config.outputs"
    value = <<-OUTPUT
      [OUTPUT]
        Name              es
        Match             kube.*
        Host              elasticsearch-master.elk.svc.cluster.local
        Port              9200
        Index             kubernetes-logs
        Type              _doc
        Suppress_Type_Name On
        Replace_Tag       On
    OUTPUT
  }

  # Input: read container logs from all nodes
  set {
    name  = "config.inputs"
    value = <<-INPUT
      [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        Mem_Buf_Limit     10MB
        Skip_Long_Lines   On
    INPUT
  }

  depends_on = [helm_release.elasticsearch]
}

# =============================================================================
# 3. ARGOCD (GitOps CD)
# =============================================================================
# NOTE: If ArgoCD is already installed via 03-Kubernetes/argocd/, set
#   enable_argocd = false here to avoid duplicate installation.
resource "helm_release" "argocd" {
  count            = var.enable_argocd ? 1 : 0
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.7.0"
  force_update     = true
  cleanup_on_fail  = true
  atomic           = true
  timeout          = 600

  # Service type ClusterIP — exposed via Gateway API, not direct LB
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }
}

# =============================================================================
# 4. KUBESHARK (network traffic analyzer — optional)
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

  set {
    name  = "tap.namespaces"
    value = "ecommerce"
  }
  set {
    name  = "hub.frontend.port"
    value = "8899"
  }
}

# =============================================================================
# 5. ALB SECURITY GROUP — IP restriction for the monitoring ALB
# =============================================================================
# The Gateway resource (below) creates an ALB. We can't control the ALB's
# security group directly via the Gateway spec, so we create a security group
# and attach it via the LoadBalancerConfiguration CRD (AWS-vended Gateway API).
#
# This SG allows port 443 ONLY from var.allowed_cidrs — your IP.
# Everyone else gets connection refused at the network level.
# =============================================================================
resource "aws_security_group" "monitoring_alb" {
  name        = "pip-project-ecommerce-monitoring-alb-sg"
  description = "Monitoring ALB — restricts access to allowed CIDRs only (ArgoCD, Grafana, Prometheus, Kibana, Kubeshark)"
  vpc_id      = data.aws_vpc.eks_vpc.id

  # Port 443 — HTTPS only
  dynamic "ingress" {
    for_each = var.allowed_cidrs
    content {
      description = "HTTPS from ${ingress.value}"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "pip-project-ecommerce-monitoring-alb-sg"
    ManagedBy   = "terraform"
    Purpose     = "monitoring-alb-ip-restriction"
  }
}

# =============================================================================
# 6. GATEWAY API — Gateway + HTTPRoutes (creates the ALB)
# =============================================================================
# Gateway creates a NEW ALB separate from the ecommerce app ALB.
# The GatewayClass "alb-gateway" was created by 01-Infrastructure/eks-addons.
# =============================================================================

# ── Gateway — creates the ALB for monitoring tools ──────────────────────────
resource "kubernetes_manifest" "monitoring_gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "monitoring-gateway"
      namespace = "monitoring"
      labels = {
        "app.kubernetes.io/name"       = "monitoring-gateway"
        "app.kubernetes.io/managed-by" = "terraform"
      }
      annotations = {
        # ALB annotations — internet-facing, IP target type
        "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
        "alb.ingress.kubernetes.io/target-type"     = "ip"
        "alb.ingress.kubernetes.io/listen-ports"    = '[{"HTTPS": 443}]'
        "alb.ingress.kubernetes.io/ssl-redirect"   = "443"
        # Security group for IP restriction
        "alb.ingress.kubernetes.io/security-groups" = aws_security_group.monitoring_alb.id
      }
    }
    spec = {
      gatewayClassName = "alb-gateway"
      listeners = [
        {
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          # hostname = var.domain_name != "" ? var.domain_name : null
          tls = {
            mode = "Terminate"
            certificateRefs = var.domain_name != "" ? [
              { name = "monitoring-tls" }
            ] : []
          }
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        }
      ]
    }
  }

  depends_on = [helm_release.prometheus_grafana]
}

# ── HTTPRoute: ArgoCD ─────────────────────────────────────────────────────────
resource "kubernetes_manifest" "route_argocd" {
  count = var.enable_argocd ? 1 : 0
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "argocd-route"
      namespace = "argocd"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/argocd" }
          }]
          backendRefs = [{
            name = "argocd-server"
            port = 443
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway, helm_release.argocd]
}

# ── HTTPRoute: Grafana ───────────────────────────────────────────────────────
resource "kubernetes_manifest" "route_grafana" {
  count = var.enable_prometheus_grafana ? 1 : 0
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "grafana-route"
      namespace = "monitoring"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/grafana" }
          }]
          backendRefs = [{
            name = "kube-prometheus-stack-grafana"
            port = 80
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway, helm_release.prometheus_grafana]
}

# ── HTTPRoute: Prometheus ────────────────────────────────────────────────────
resource "kubernetes_manifest" "route_prometheus" {
  count = var.enable_prometheus_grafana ? 1 : 0
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "prometheus-route"
      namespace = "monitoring"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/prometheus" }
          }]
          backendRefs = [{
            name = "kube-prometheus-stack-prometheus"
            port = 9090
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway, helm_release.prometheus_grafana]
}

# ── HTTPRoute: Kibana ────────────────────────────────────────────────────────
resource "kubernetes_manifest" "route_kibana" {
  count = var.enable_elk ? 1 : 0
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "kibana-route"
      namespace = "elk"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/kibana" }
          }]
          backendRefs = [{
            name = "kibana-kibana"
            port = 5601
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway, helm_release.kibana]
}

# ── HTTPRoute: Kubeshark ─────────────────────────────────────────────────────
resource "kubernetes_manifest" "route_kubeshark" {
  count = var.enable_kubeshark ? 1 : 0
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "kubeshark-route"
      namespace = "kubeshark"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/kubeshark" }
          }]
          backendRefs = [{
            name = "kubeshark-frontend"
            port = 8899
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway, helm_release.kubeshark]
}

# ── HTTPRoute: Goldilocks (cost optimization dashboard) ─────────────────────
resource "kubernetes_manifest" "route_goldilocks" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "goldilocks-route"
      namespace = "goldilocks"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/goldilocks" }
          }]
          backendRefs = [{
            name = "goldilocks-dashboard"
            port = 80
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway]
}

# ── HTTPRoute: Kubecost (cost allocation dashboard) ────────────────────────
resource "kubernetes_manifest" "route_kubecost" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "kubecost-route"
      namespace = "kubecost"
      labels = { "app.kubernetes.io/managed-by" = "terraform" }
    }
    spec = {
      parentRefs = [{ name = "monitoring-gateway", namespace = "monitoring" }]
      hostnames  = var.domain_name != "" ? [var.domain_name] : []
      rules = [
        {
          matches = [{
            path = { type = "PathPrefix", value = "/kubecost" }
          }]
          backendRefs = [{
            name = "kubecost-cost-analyzer"
            port = 9090
          }]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.monitoring_gateway]
}

# =============================================================================
# OUTPUTS
# =============================================================================
output "monitoring_alb_security_group_id" {
  description = "Security group ID for the monitoring ALB — restricts access to allowed_cidrs only"
  value       = aws_security_group.monitoring_alb.id
}

output "gateway_name" {
  description = "Gateway API Gateway name — the ALB is provisioned from this resource"
  value       = kubernetes_manifest.monitoring_gateway.manifest.metadata.name
}

output "how_to_access" {
  description = <<-EOT
    HOW TO ACCESS THE MONITORING UIs:

    After terraform apply, the ALB takes ~2 minutes to provision.
    Get the ALB DNS name:
      kubectl get gateway monitoring-gateway -n monitoring -o jsonpath='{.status.addresses[0].value}'

    Then open in your browser (only from IPs in allowed_cidrs):
      https://<alb-dns>/argocd     → ArgoCD (admin / initial admin password from secret)
      https://<alb-dns>/grafana    → Grafana (admin / var.grafana_admin_password)
      https://<alb-dns>/prometheus → Prometheus UI
      https://<alb-dns>/kibana     → Kibana (no login — xpack security disabled)
      https://<alb-dns>/kubeshark  → Kubeshark (no login)

    Get ArgoCD password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

    If you set domain_name, add a Route53 CNAME:
      monitor.yourdomain.com → <alb-dns>
  EOT
  value = "See description above"
}
