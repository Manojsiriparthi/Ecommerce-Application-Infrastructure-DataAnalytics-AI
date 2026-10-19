output "certificate_arn" {
  description = "ACM certificate ARN — available immediately, validates automatically after DNS propagates"
  value       = length(aws_acm_certificate.ecommerce) > 0 ? aws_acm_certificate.ecommerce[0].arn : ""
}

output "hosted_zone_id" {
  description = "Route53 hosted zone ID. Empty string when domain_name is not set."
  value       = length(aws_route53_zone.ecommerce) > 0 ? aws_route53_zone.ecommerce[0].zone_id : ""
}

output "name_servers" {
  description = "Route53 nameservers. Empty list when domain_name is not set."
  value       = length(aws_route53_zone.ecommerce) > 0 ? aws_route53_zone.ecommerce[0].name_servers : []
}

output "domain_name" {
  description = "The domain name this module manages. Empty string when not configured."
  value       = trimspace(var.domain_name)
}

output "cert_arn_ssm_path" {
  description = "SSM Parameter path for ACM certificate ARN. Empty when domain_name is not set."
  value       = length(aws_ssm_parameter.cert_arn) > 0 ? aws_ssm_parameter.cert_arn[0].name : ""
}

output "zone_id_ssm_path" {
  description = "SSM Parameter path for Route53 hosted zone ID. Empty when domain_name is not set."
  value       = length(aws_ssm_parameter.hosted_zone_id) > 0 ? aws_ssm_parameter.hosted_zone_id[0].name : ""
}
