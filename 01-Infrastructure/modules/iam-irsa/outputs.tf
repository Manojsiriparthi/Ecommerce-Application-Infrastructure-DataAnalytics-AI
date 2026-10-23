output "ebs_csi_role_arn" {
  description = "EBS CSI driver IRSA role ARN"
  value       = aws_iam_role.ebs_csi.arn
}

output "lb_controller_role_arn" {
  description = "LB Controller IRSA role ARN"
  value       = aws_iam_role.lb_controller.arn
}

output "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler IRSA role ARN"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "ecommerce_services_role_arn" {
  description = "IRSA role ARN for all backend pods — annotate ecommerce-services-sa with this value"
  value       = aws_iam_role.ecommerce_services.arn
}

output "secrets_store_csi_role_arn" {
  description = "IRSA role ARN for the Secrets Store CSI driver (kube-system)"
  value       = aws_iam_role.secrets_store_csi.arn
}

output "cloudwatch_observability_role_arn" {
  description = "IRSA role ARN for the amazon-cloudwatch-observability EKS addon (CloudWatch Agent + ADOT)"
  value       = aws_iam_role.cloudwatch_observability.arn
}

output "karpenter_role_arn" {
  description = "Karpenter controller IRSA role ARN — annotate karpenter SA with this"
  value       = aws_iam_role.karpenter.arn
}

output "karpenter_interruption_queue_name" {
  description = "SQS queue NAME for Karpenter interruption events — pass to eks_addons for Helm chart settings.interruptionQueueName"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "karpenter_interruption_queue_arn" {
  description = "SQS queue ARN for Karpenter interruption events"
  value       = aws_sqs_queue.karpenter_interruption.arn
}

output "keda_role_arn" {
  description = "KEDA IRSA role ARN — annotate keda-operator SA with this. Grants SQS + CloudWatch read for event-driven autoscaling."
  value       = aws_iam_role.keda.arn
}
