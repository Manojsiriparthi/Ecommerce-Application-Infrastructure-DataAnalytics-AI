output "web_acl_arn" {
  description = "WAF WebACL ARN — attach to external ALB via annotation alb.ingress.kubernetes.io/wafv2-acl-arn"
  value       = aws_wafv2_web_acl.ecommerce.arn
}

output "web_acl_id" {
  description = "WAF WebACL ID"
  value       = aws_wafv2_web_acl.ecommerce.id
}

output "logs_bucket_name" {
  description = "S3 bucket name for WAF and ALB access logs"
  value       = aws_s3_bucket.logs.bucket
}

output "logs_bucket_arn" {
  description = "S3 bucket ARN for WAF and ALB access logs"
  value       = aws_s3_bucket.logs.arn
}

output "logs_bucket_domain" {
  description = "S3 bucket domain name (used in ALB access log config)"
  value       = aws_s3_bucket.logs.bucket_domain_name
}

output "waf_arn_ssm_path" {
  description = "SSM Parameter path for the WAF WebACL ARN"
  value       = aws_ssm_parameter.waf_arn.name
}

output "internal_alb_dns_ssm_path" {
  description = "SSM Parameter path for internal ALB DNS (update after Ingress apply)"
  value       = aws_ssm_parameter.internal_alb_dns.name
}
