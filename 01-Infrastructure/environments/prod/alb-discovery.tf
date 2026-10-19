# ==============================================================================
# ALB HOSTNAME AUTO-DISCOVERY
# ==============================================================================
# WHY THIS EXISTS
#   The Route53 failover records + health checks need the CURRENT external ALB
#   hostnames for each region. Those hostnames CHANGE every time the ALB is
#   recreated (destroy/rebuild, or deleting the ingress). Previously they were
#   hardcoded in prod.tfvars (alb_dns_name / dr_alb_dns_name) and had to be
#   hand-edited after every rebuild. Forgetting to update caused the health
#   check to ping a dead ALB name → NXDomain → the domain stopped resolving.
#
#   These data sources read the LIVE ALB hostname straight from the Kubernetes
#   ingress in each cluster, so Route53 always points at the real ALB.
#
# APPLY ORDERING (important)
#   The ingress only has a hostname AFTER the app is deployed (02-deploy-app.sh
#   provisions the ALB). On a FRESH apply the cluster/app don't exist yet, so
#   discovery is gated behind var.discover_alb_from_ingress:
#     - false (default): data sources are NOT read (count=0); route53 uses the
#       tfvars values. Safe when there is no cluster to connect to.
#     - true: data sources read the live ingress; try() still guards against the
#       ALB not being ready, and locals fall back to tfvars if discovery is "".
#   Run order that "just works" (no manual tfvars edits after a rebuild):
#     1. terraform apply                         (infra; discover flag = false)
#     2. 02-deploy-app.sh both regions           (creates the ALBs)
#     3. terraform apply -var discover_alb_from_ingress=true
#        (route53 now auto-discovers the real ALBs in both regions)
# ==============================================================================

# GUARD: discovery only runs when var.discover_alb_from_ingress = true.
#   Fresh apply (no cluster/app yet)  → leave it false → uses tfvars values.
#   Re-apply after app is deployed    → set it true    → auto-discovers ALBs.
# This avoids the kubernetes provider trying (and failing) to reach a cluster
# that doesn't exist yet on the very first apply.
#   count = 0 means the data source is not read at all.

# ---- Primary (us-east-1) external ingress ----
data "kubernetes_ingress_v1" "frontend_primary" {
  count = var.discover_alb_from_ingress ? 1 : 0

  metadata {
    name      = "frontend-external-ingress"
    namespace = "ecommerce"
  }
}

# ---- DR (us-west-2) external ingress ----
data "kubernetes_ingress_v1" "frontend_dr" {
  count    = var.discover_alb_from_ingress ? 1 : 0
  provider = kubernetes.dr

  metadata {
    name      = "frontend-external-ingress"
    namespace = "ecommerce"
  }
}

locals {
  # Discovered hostnames (empty string if discovery disabled or ALB not ready).
  discovered_primary_alb = var.discover_alb_from_ingress ? try(
    data.kubernetes_ingress_v1.frontend_primary[0].status[0].load_balancer[0].ingress[0].hostname,
    ""
  ) : ""
  discovered_dr_alb = var.discover_alb_from_ingress ? try(
    data.kubernetes_ingress_v1.frontend_dr[0].status[0].load_balancer[0].ingress[0].hostname,
    ""
  ) : ""

  # Prefer the LIVE discovered hostname; fall back to the tfvars value.
  # This means: once the app is deployed, Route53 auto-follows the real ALB and
  # you never hand-edit prod.tfvars again. Before the app exists (fresh apply),
  # it uses whatever tfvars holds (may be empty → route53 skips failover records).
  effective_alb_dns_name    = local.discovered_primary_alb != "" ? local.discovered_primary_alb : var.alb_dns_name
  effective_dr_alb_dns_name = local.discovered_dr_alb != "" ? local.discovered_dr_alb : var.dr_alb_dns_name
}
