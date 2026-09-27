output "ebs_csi_addon_id" {
  description = "EBS CSI Driver addon ID"
  value       = aws_eks_addon.ebs_csi.id
}

output "lb_controller_release_name" {
  description = "AWS Load Balancer Controller Helm release name"
  value       = helm_release.lb_controller.name
}

output "cluster_autoscaler_release_name" {
  description = "Cluster Autoscaler Helm release name"
  value       = helm_release.cluster_autoscaler.name
}

output "vpa_release_name" {
  description = "VPA Helm release name"
  value       = helm_release.vpa.name
}

output "fluent_bit_release_name" {
  description = "Fluent Bit Helm release name"
  value       = helm_release.fluent_bit.name
}

