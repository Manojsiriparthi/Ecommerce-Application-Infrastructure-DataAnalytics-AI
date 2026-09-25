output "sns_topic_arn" {
  description = "SNS topic ARN for pipeline alerts"
  value       = aws_sns_topic.pipeline_alerts.arn
}

output "sqs_queue_arn" {
  description = "SQS queue ARN for Jenkins failures"
  value       = aws_sqs_queue.jenkins_failures.arn
}

output "sqs_queue_url" {
  description = "SQS queue URL for Jenkins failures"
  value       = aws_sqs_queue.jenkins_failures.id
}

output "sqs_dlq_arn" {
  description = "SQS Dead Letter Queue ARN"
  value       = aws_sqs_queue.jenkins_failures_dlq.arn
}
