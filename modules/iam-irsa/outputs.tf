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
