output "certificate_arn" {
  description = "Validated ACM certificate ARN — use in alb.ingress.kubernetes.io/certificate-arn annotation"
  value       = aws_acm_certificate_validation.ecommerce.certificate_arn
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.ecommerce.zone_id
}

output "name_servers" {
  description = "Route53 nameservers — configure at your registrar if domain was not bought via Route53"
  value       = aws_route53_zone.ecommerce.name_servers
}

output "domain_name" {
  description = "The domain name this module manages"
  value       = var.domain_name
}

output "cert_arn_ssm_path" {
  description = "SSM Parameter path for ACM certificate ARN"
  value       = aws_ssm_parameter.cert_arn.name
}

output "zone_id_ssm_path" {
  description = "SSM Parameter path for Route53 hosted zone ID"
  value       = aws_ssm_parameter.hosted_zone_id.name
}
