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

# =============================================================================
# A-record — apex domain → external ALB (only after ALB is provisioned)
# =============================================================================
resource "aws_route53_record" "apex" {
  count   = local.alb_ready ? 1 : 0

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
  count   = local.alb_ready ? 1 : 0

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
  value       = aws_acm_certificate_validation.ecommerce[0].certificate_arn
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
