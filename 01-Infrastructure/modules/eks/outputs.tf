# =========================================================================
# EKS MODULE OUTPUTS
# =========================================================================

# -------------------------------------------------------------------------
# Cluster Identity
# -------------------------------------------------------------------------
output "cluster_name" {
  description = "EKS cluster name — used by Helm provider, kubectl, and all eks-addons module calls."
  value       = aws_eks_cluster.ecommerce.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint URL — used by Helm and Kubernetes providers to connect."
  value       = aws_eks_cluster.ecommerce.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster."
  value       = aws_eks_cluster.ecommerce.version
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for the cluster — required by Helm / Kubernetes providers."
  value       = aws_eks_cluster.ecommerce.certificate_authority[0].data
}

output "cluster_arn" {
  description = "Full ARN of the EKS cluster — use in IAM policies that scope to this cluster."
  value       = aws_eks_cluster.ecommerce.arn
}

# -------------------------------------------------------------------------
# OIDC (IRSA Foundation)
# -------------------------------------------------------------------------
output "oidc_provider_arn" {
  description = <<-EOT
    OIDC provider ARN — used as the Principal.Federated value in every IRSA
    assume-role policy (iam-irsa module). Without this, pods cannot assume
    IAM roles and all AWS API calls from pods will fail with AccessDenied.
  EOT
  value = aws_iam_openid_connect_provider.ecommerce.arn
}

output "oidc_provider_url" {
  description = <<-EOT
    OIDC provider URL (without https://) — used in IRSA trust policy
    StringEquals conditions to scope the role to a specific service account.
    Pass to iam-irsa module as: replace(module.eks.oidc_provider_url, "https://", "")
  EOT
  value = aws_iam_openid_connect_provider.ecommerce.url
}

# -------------------------------------------------------------------------
# Node Groups
# -------------------------------------------------------------------------
output "workers_node_group_name" {
  description = "Private worker node group name — used by monitoring alarms and Cluster Autoscaler tags."
  value       = aws_eks_node_group.workers.node_group_name
}

output "workers_node_group_arn" {
  description = "Private worker node group ARN."
  value       = aws_eks_node_group.workers.arn
}

output "public_node_group_name" {
  description = "Public subnet node group name."
  value       = aws_eks_node_group.public.node_group_name
}

output "public_node_group_arn" {
  description = "Public subnet node group ARN."
  value       = aws_eks_node_group.public.arn
}

output "db_node_group_name" {
  description = "DB node group name — returns empty string; group is commented out (native RDS in use)."
  value       = ""
}

# -------------------------------------------------------------------------
# Security Groups
# -------------------------------------------------------------------------
output "node_security_group_id" {
  description = <<-EOT
    The cluster security group ID that EKS auto-creates and attaches to ALL
    worker nodes at cluster creation time.

    WHY THIS MATTERS:
      This SG is different from any Terraform-managed SG. Aurora's inbound
      rule for port 5432 must reference THIS SG ID so pods on any node can
      reach Aurora. Without it, pods get connection timeouts to the DB.

    Used in prod/main.tf:
      resource "aws_security_group_rule" "aurora_allow_eks_nodes" {
        source_security_group_id = module.eks.node_security_group_id
      }
  EOT
  value = aws_eks_cluster.ecommerce.vpc_config[0].cluster_security_group_id
}

# -------------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------------
output "cluster_log_types" {
  description = "Control plane log types enabled on this cluster (sent to CloudWatch)."
  value       = aws_eks_cluster.ecommerce.enabled_cluster_log_types
}

output "cloudwatch_log_group" {
  description = <<-EOT
    CloudWatch log group where all control plane logs are written.
    Log streams inside: kube-apiserver-*, kube-audit-*, authenticator-*,
    kube-controller-manager-*, kube-scheduler-*
  EOT
  value = "/aws/eks/${aws_eks_cluster.ecommerce.name}/cluster"
}
