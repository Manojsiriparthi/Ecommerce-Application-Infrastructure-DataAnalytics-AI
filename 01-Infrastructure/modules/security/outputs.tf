output "kms_key_arn" {
  description = "KMS Key ARN"
  value       = aws_kms_key.main.arn
}

output "db_secret_arn" {
  description = "Secrets Manager Secret ARN"
  value       = aws_secretsmanager_secret.db_creds.arn
}

output "jwt_secret_ssm_path" {
  description = "SSM Parameter path for JWT secret (SecureString)"
  value       = aws_ssm_parameter.jwt_secret.name
}

output "internal_service_key_ssm_path" {
  description = "SSM Parameter path for internal service key (SecureString)"
  value       = aws_ssm_parameter.internal_service_key.name
}

output "ses_from_email_ssm_path" {
  description = "SSM Parameter path for SES sender email"
  value       = aws_ssm_parameter.ses_from_email.name
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID"
  value       = aws_guardduty_detector.ecommerce.id
}

output "vpc_flow_log_group" {
  description = "CloudWatch Log Group for VPC Flow Logs"
  value       = aws_cloudwatch_log_group.vpc_flow_logs.name
}

output "app_log_group" {
  description = "CloudWatch Log Group for application logs (Fluent Bit target)"
  value       = aws_cloudwatch_log_group.app_logs.name
}
