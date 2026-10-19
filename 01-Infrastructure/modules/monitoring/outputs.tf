output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.ecommerce.dashboard_name
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.ecommerce.dashboard_name}"
}

output "dlm_policy_id" {
  description = "EBS DLM lifecycle policy ID"
  value       = aws_dlm_lifecycle_policy.ebs_snapshots.id
}
