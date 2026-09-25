output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "EKS cluster CA data"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC provider URL"
  value       = aws_iam_openid_connect_provider.this.url
}

output "workers_node_group_name" {
  description = "Private worker node group name"
  value       = aws_eks_node_group.workers.node_group_name
}

output "db_node_group_name" {
  description = "Database-dedicated node group name"
  value       = aws_eks_node_group.db_nodes.node_group_name
}

output "public_node_group_name" {
  description = "Public subnet node group name"
  value       = aws_eks_node_group.public.node_group_name
}
