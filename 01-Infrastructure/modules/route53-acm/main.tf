# =============================================================================
# Route53 + ACM Module
# =============================================================================
# WHAT THIS MODULE DOES:
#
#   1. Creates a Route53 Hosted Zone for your domain
#      e.g. ecommerce-pip.com → creates NS + SOA records automatically
#
#   2. Requests an ACM certificate for:
#        - yourdomain.com
#        - *.yourdomain.com  (wildcard covers www, api, etc.)
#      DNS validation is used — Terraform creates the CNAME validation
#      records automatically. No email clicks needed.
#
#   3. Creates A-record aliases pointing to the external ALB:
#        yourdomain.com     → ALB
#        www.yourdomain.com → ALB
#
# DOMAIN REGISTRATION:
#   This module does NOT register the domain. You must buy it once:
#     AWS Console → Route53 → Domain Registration → Register Domain
#     Cost: ~$12-15/year for .com
#   After registration, set the nameservers to match what this hosted
#   zone outputs (they usually match automatically if bought via Route53).
#
# HOW ACM CERT ARN IS USED:
#   The cert ARN from this module's output is what the infra pipeline
#   patches into the frontend/ingress.yaml annotation:
#     alb.ingress.kubernetes.io/certificate-arn: <ACM_CERT_ARN>
#   This means HTTPS works automatically — no manual cert import.
# =============================================================================

# =============================================================================
# Route53 Hosted Zone
# =============================================================================
resource "aws_route53_zone" "ecommerce" {
  name    = var.domain_name
  comment = "Managed by Terraform — pip-project-ecommerce (${var.environment})"

  tags = {
    Name        = "${var.project_name}-zone-${var.environment}"
    Environment = var.environment
  }
}

# =============================================================================
# ACM Certificate — request with DNS validation
# =============================================================================
# WHY DNS validation (not email):
#   DNS validation is permanent — once the CNAME record exists, AWS can
#   re-validate automatically on renewal. No human action needed ever again.
#   Email validation expires and requires someone to click a link each renewal.
resource "aws_acm_certificate" "ecommerce" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    # Create the new cert before destroying the old one
    # so there is never a gap in HTTPS coverage
    create_before_destroy = true
  }

  tags = {
    Name        = "${var.project_name}-cert-${var.environment}"
    Environment = var.environment
  }
}

# =============================================================================
# DNS validation records
# ACM gives us CNAME records to add to Route53 to prove we own the domain.
# Terraform creates them automatically — the cert validates itself.
# =============================================================================
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.ecommerce.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.ecommerce.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Wait for certificate to be issued before proceeding
resource "aws_acm_certificate_validation" "ecommerce" {
  certificate_arn         = aws_acm_certificate.ecommerce.arn
  validation_record_fqdns = [
    for record in aws_route53_record.cert_validation : record.fqdn
  ]

  timeouts {
    create = "10m"
  }
}

# =============================================================================
# A-record — apex domain → external ALB
# e.g. ecommerce-pip.com → <alb-dns>
# =============================================================================
# NOTE: var.alb_dns_name and var.alb_zone_id are only available AFTER
# the EKS cluster + ALB controller + Ingress are applied.
# The infra pipeline runs terraform apply first (creates everything else),
# then the post-apply stage kubectl-applies the Ingresses which creates the ALB.
# On the SECOND terraform apply (or a targeted apply of this module),
# these records are created with the real ALB values.
# The lifecycle ignore_changes below prevents Terraform from destroying the
# record if the ALB DNS changes transiently.
resource "aws_route53_record" "apex" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = aws_route53_zone.ecommerce.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# A-record — www subdomain → external ALB
# e.g. www.ecommerce-pip.com → <alb-dns>
# =============================================================================
resource "aws_route53_record" "www" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = aws_route53_zone.ecommerce.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# =============================================================================
# SSM Parameters — store cert ARN and nameservers for pipeline use
# =============================================================================
# The infra pipeline reads cert_arn from SSM to patch ingress.yaml
# without needing a second terraform output parse.
resource "aws_ssm_parameter" "cert_arn" {
  name        = "/${var.project_name}/${var.environment}/acm/certificate-arn"
  type        = "String"
  value       = aws_acm_certificate_validation.ecommerce.certificate_arn
  description = "ACM certificate ARN for ${var.domain_name} — used in ALB Ingress annotation"

  tags = {
    Name        = "${var.project_name}-cert-arn-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "nameservers" {
  name        = "/${var.project_name}/${var.environment}/route53/nameservers"
  type        = "String"
  # Stored as comma-separated for easy reading
  value       = join(",", aws_route53_zone.ecommerce.name_servers)
  description = "Route53 nameservers — configure these at your registrar if not using Route53 Domains"

  tags = {
    Name        = "${var.project_name}-ns-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "hosted_zone_id" {
  name        = "/${var.project_name}/${var.environment}/route53/hosted-zone-id"
  type        = "String"
  value       = aws_route53_zone.ecommerce.zone_id
  description = "Route53 Hosted Zone ID for ${var.domain_name}"

  tags = {
    Name        = "${var.project_name}-zone-id-param"
    Environment = var.environment
  }
}
