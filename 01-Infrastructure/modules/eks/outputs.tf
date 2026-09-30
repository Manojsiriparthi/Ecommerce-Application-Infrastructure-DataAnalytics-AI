output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.ecommerce.name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.ecommerce.endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA data"
  value       = aws_eks_cluster.ecommerce.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = aws_iam_openid_connect_provider.ecommerce.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL for IRSA"
  value       = aws_iam_openid_connect_provider.ecommerce.url
}

output "workers_node_group_name" {
  description = "Private worker node group name"
  value       = aws_eks_node_group.workers.node_group_name
}

output "public_node_group_name" {
  description = "Public subnet node group name"
  value       = aws_eks_node_group.public.node_group_name
}

output "db_node_group_name" {
  description = "DB node group name (empty string when create_db_nodes = false)"
  value       = var.create_db_nodes ? aws_eks_node_group.db_nodes[0].node_group_name : ""
}

output "node_security_group_id" {
  description = <<-EOT
    The cluster security group ID that EKS automatically creates and attaches
    to ALL worker nodes at cluster creation time. This is separate from the
    Terraform-managed eks_sg (which only has the rules we define).
    Aurora must allow inbound :5432 from this SG so pods can reach the DB.
  EOT
  value = aws_eks_cluster.ecommerce.vpc_config[0].cluster_security_group_id
}
