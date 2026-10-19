output "cluster_role_arn" {
  description = "EKS Cluster IAM role ARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "node_role_arn" {
  description = "EKS Node IAM role ARN"
  value       = aws_iam_role.eks_node.arn
}

output "node_role_name" {
  description = "EKS Node IAM role NAME — used by Karpenter EC2NodeClass spec.role"
  value       = aws_iam_role.eks_node.name
}

output "bastion_instance_profile_name" {
  description = "Bastion IAM instance profile name (SSM access)"
  value       = aws_iam_instance_profile.bastion.name
}

