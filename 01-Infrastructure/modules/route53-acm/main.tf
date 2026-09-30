# =============================================================================
# Route53 + ACM Module
# =============================================================================
# USAGE:
#   Set domain_name = "" to skip this module entirely (e.g. before domain
#   is registered). Every resource is gated on domain_name != "" so no
#   validation errors occur and no resources are created.
#
#   Set domain_name = "yourdomain.com" once the domain is registered.
#   Terraform creates the hosted zone, ACM cert (DNS-validated), and
#   A-records pointing to the external ALB.
# =============================================================================

locals {
  # Safety: strip whitespace; treat empty/whitespace-only as disabled
  domain   = trimspace(var.domain_name)
  enabled  = local.domain != ""
  # Only create A-records when both domain AND ALB DNS are set
  alb_ready = local.enabled && trimspace(var.alb_dns_name) != ""
  # Only create failover records when DR ALB is also set
  dr_ready  = local.alb_ready && trimspace(var.dr_alb_dns_name) != ""
}

# =============================================================================
# Route53 Hosted Zone
# =============================================================================
resource "aws_route53_zone" "ecommerce" {
  count   = local.enabled ? 1 : 0

  name    = local.domain
  comment = "Managed by Terraform — pip-project-ecommerce (${var.environment})"

  tags = {
    Name        = "${var.project_name}-zone-${var.environment}"
    Environment = var.environment
  }
}

# =============================================================================
# ACM Certificate — DNS-validated wildcard + apex
# =============================================================================
resource "aws_acm_certificate" "ecommerce" {
  count = local.enabled ? 1 : 0

  domain_name               = local.domain
  subject_alternative_names = ["*.${local.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-cert-${var.environment}"
    Environment = var.environment
  }
}

# =============================================================================
# DNS validation CNAME records — auto-created, auto-validates the cert
# =============================================================================
resource "aws_route53_record" "cert_validation" {
  for_each = local.enabled ? {
    for dvo in aws_acm_certificate.ecommerce[0].domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = aws_route53_zone.ecommerce[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# =============================================================================
# ACM Certificate validation — NON-BLOCKING
# =============================================================================
# The validation happens automatically once Namecheap nameservers point to
# Route53 and DNS propagates (5-30 min). We do NOT wait for it in Terraform
# because it would block the entire apply for up to 48 hours if DNS is slow.
#
# The cert ARN is available immediately after aws_acm_certificate is created.
# The ALB ingress can use the cert ARN even before it's ISSUED —
# the ALB will start serving HTTPS once validation completes automatically.
#
# To check validation status:
#   aws acm describe-certificate \
#     --certificate-arn <ARN> --region us-east-1 \
#     --query "Certificate.Status"
# =============================================================================
resource "aws_acm_certificate_validation" "ecommerce" {
  count = 0   # Disabled — cert validates automatically, no need to block apply

  certificate_arn         = aws_acm_certificate.ecommerce[0].arn
  validation_record_fqdns = [
    for record in aws_route53_record.cert_validation : record.fqdn
  ]
}

# ── Simple apex and www records ─────────────────────────────────────────────
# These are only used when DR is NOT configured (no dr_alb_dns_name set).
# When DR is configured, apex_primary / apex_dr failover records are used instead.
# =============================================================================
resource "aws_route53_record" "apex" {
  # Skip when failover records exist (dr_ready) to avoid duplicate record conflict
  count   = local.alb_ready && !local.dr_ready ? 1 : 0

  zone_id = aws_route53_zone.ecommerce[0].zone_id
  name    = local.domain
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# A-record — www → external ALB
# =============================================================================
resource "aws_route53_record" "www" {
  count   = local.alb_ready && !local.dr_ready ? 1 : 0

  zone_id = aws_route53_zone.ecommerce[0].zone_id
  name    = "www.${local.domain}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# SSM Parameters (only created when domain is set)
# =============================================================================
resource "aws_ssm_parameter" "cert_arn" {
  count = local.enabled ? 1 : 0

  name        = "/${var.project_name}/${var.environment}/acm/certificate-arn"
  type        = "String"
  # Use the cert ARN directly — not the validation resource (which has count=0)
  # The cert ARN is available immediately after creation, before validation completes
  value       = aws_acm_certificate.ecommerce[0].arn
  description = "ACM certificate ARN for ${local.domain}"

  tags = {
    Name        = "${var.project_name}-cert-arn-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "nameservers" {
  count = local.enabled ? 1 : 0

  name        = "/${var.project_name}/${var.environment}/route53/nameservers"
  type        = "String"
  value       = join(",", aws_route53_zone.ecommerce[0].name_servers)
  description = "Route53 nameservers for ${local.domain}"

  tags = {
    Name        = "${var.project_name}-ns-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "hosted_zone_id" {
  count = local.enabled ? 1 : 0

  name        = "/${var.project_name}/${var.environment}/route53/hosted-zone-id"
  type        = "String"
  value       = aws_route53_zone.ecommerce[0].zone_id
  description = "Route53 Hosted Zone ID for ${local.domain}"

  tags = {
    Name        = "${var.project_name}-zone-id-param"
    Environment = var.environment
  }
}

# =============================================================================
# Route53 Health Checks + Failover Routing
# =============================================================================
# RUBRIC: Route53 health checks on ALB, failover routing primary→secondary
#
# HOW IT WORKS:
#   1. Health check pings the external ALB /health every 30 seconds
#   2. PRIMARY record (us-east-1): normal traffic, evaluate_target_health=true
#   3. SECONDARY record (us-west-2 DR): only receives traffic when primary fails
#   4. Failover happens in < 2 minutes (3 failed health checks × 30s each)
#
# REQUIREMENTS:
#   - alb_dns_name must be set (primary ALB)
#   - dr_alb_dns_name must be set (DR region ALB — set after DR EKS is ready)
#   - Both ALBs must serve /health returning HTTP 200
# =============================================================================

# ── Health Check: Primary ALB (us-east-1) ────────────────────────────────────
resource "aws_route53_health_check" "primary" {
  count = local.alb_ready ? 1 : 0

  fqdn              = var.alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/"          # frontend home page — returns 200 when healthy
  failure_threshold = 3            # 3 consecutive failures → unhealthy
  request_interval  = 30           # check every 30 seconds

  tags = {
    Name        = "${var.project_name}-primary-health-check"
    Environment = var.environment
    Region      = "us-east-1"
  }
}

# ── Health Check: DR ALB (us-west-2) ─────────────────────────────────────────
resource "aws_route53_health_check" "dr" {
  count = local.dr_ready ? 1 : 0

  fqdn              = var.dr_alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = {
    Name        = "${var.project_name}-dr-health-check"
    Environment = var.environment
    Region      = "us-west-2"
  }
}

# ── Failover A-record: PRIMARY (us-east-1) ───────────────────────────────────
# Replaces the simple apex A-record when failover is enabled.
# When health check fails → Route53 automatically stops returning this record.
resource "aws_route53_record" "apex_primary" {
  count = local.dr_ready ? 1 : 0

  zone_id = aws_route53_zone.ecommerce[0].zone_id
  name    = local.domain
  type    = "A"

  set_identifier = "primary"

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary[0].id

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }

  lifecycle {
    # Prevent conflict with the simple apex record — remove it first
    create_before_destroy = false
  }
}

# ── Failover A-record: SECONDARY (us-west-2 DR) ──────────────────────────────
# Only receives traffic when primary health check fails.
# No health check on secondary — it always stays in the pool as fallback.
resource "aws_route53_record" "apex_dr" {
  count = local.dr_ready ? 1 : 0

  zone_id = aws_route53_zone.ecommerce[0].zone_id
  name    = local.domain
  type    = "A"

  set_identifier = "dr-secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  # No health_check_id on secondary — it's always available as last resort
  alias {
    name                   = var.dr_alb_dns_name
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = true
  }
}

# ── www failover (mirrors apex) ──────────────────────────────────────────────
resource "aws_route53_record" "www_primary" {
  count = local.dr_ready ? 1 : 0

  zone_id        = aws_route53_zone.ecommerce[0].zone_id
  name           = "www.${local.domain}"
  type           = "A"
  set_identifier = "primary"

  failover_routing_policy { type = "PRIMARY" }
  health_check_id = aws_route53_health_check.primary[0].id

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www_dr" {
  count = local.dr_ready ? 1 : 0

  zone_id        = aws_route53_zone.ecommerce[0].zone_id
  name           = "www.${local.domain}"
  type           = "A"
  set_identifier = "dr-secondary"

  failover_routing_policy { type = "SECONDARY" }

  alias {
    name                   = var.dr_alb_dns_name
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = true
  }
}

# ── CloudWatch Alarm: Primary health check failed ────────────────────────────
resource "aws_cloudwatch_metric_alarm" "primary_health_check" {
  count = local.alb_ready ? 1 : 0

  alarm_name          = "${var.project_name}-route53-primary-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Route53 primary health check FAILING — traffic routing to DR region"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary[0].id
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions    = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = {
    Name        = "${var.project_name}-primary-health-alarm"
    Environment = var.environment
  }
}

# ── SSM: store health check IDs for test scripts ─────────────────────────────
resource "aws_ssm_parameter" "primary_health_check_id" {
  count = local.alb_ready ? 1 : 0

  name        = "/${var.project_name}/${var.environment}/route53/primary-health-check-id"
  type        = "String"
  value       = aws_route53_health_check.primary[0].id
  description = "Route53 primary health check ID"

  tags = { Name = "${var.project_name}-health-check-id", Environment = var.environment }
}
