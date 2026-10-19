output "sns_topic_arn" {
  description = "SNS topic ARN — passed as alarm_actions to every CloudWatch alarm (Aurora, EKS, ALB, NAT, ElastiCache)"
  value       = aws_sns_topic.pipeline_alerts.arn
}

output "sns_topic_name" {
  description = "SNS topic name"
  value       = aws_sns_topic.pipeline_alerts.name
}
