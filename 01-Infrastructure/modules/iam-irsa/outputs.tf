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
