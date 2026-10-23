output "ebs_csi_addon_id" {
  description = "EBS CSI Driver addon ID"
  value       = aws_eks_addon.ebs_csi.id
}

output "lb_controller_release_name" {
  description = "AWS Load Balancer Controller Helm release name"
  value       = helm_release.lb_controller.name
}

output "cluster_autoscaler_release_name" {
  description = "Cluster Autoscaler Helm release name — DISABLED, replaced by Karpenter"
  value       = "cluster-autoscaler-disabled"
}

output "vpa_release_name" {
  description = "VPA Helm release name"
  value       = helm_release.vpa.name
}

output "fluent_bit_release_name" {
  description = "Fluent Bit Helm release name"
  value       = helm_release.fluent_bit.name
}

output "cloudwatch_observability_addon_id" {
  description = "Amazon CloudWatch Observability EKS addon ID (Container Insights + ADOT traces)"
  value       = aws_eks_addon.cloudwatch_observability.id
}

output "kube_state_metrics_release_name" {
  description = "Kube-State-Metrics Helm release name"
  value       = helm_release.kube_state_metrics.name
}

# -------------------------------------------------------------------------
# Gateway API
# -------------------------------------------------------------------------
output "gateway_class_name" {
  description = <<-EOT
    Name of the GatewayClass bound to the AWS Load Balancer Controller.
    App team Gateway manifests reference this via spec.gatewayClassName.

    Example Gateway manifest (app-owned, in 03-Kubernetes/):
      apiVersion: gateway.networking.k8s.io/v1
      kind: Gateway
      metadata:
        name: ecommerce-gateway
        namespace: ecommerce
      spec:
        gatewayClassName: <this value>      # e.g. "alb-gateway"
        listeners:
          - name: https
            protocol: HTTPS
            port: 443
            hostname: "shop.example.com"
            tls:
              mode: Terminate
              certificateRefs:
                - name: shop-tls   # K8s TLS Secret
  EOT
  value = var.gateway_class_name
}

output "lb_controller_version" {
  description = "AWS LBC Helm chart version (v2.14+ enables Gateway API GA)."
  value       = helm_release.lb_controller.version
}

# -------------------------------------------------------------------------
# Karpenter
# -------------------------------------------------------------------------
output "karpenter_release_name" {
  description = "Karpenter Helm release name"
  value       = helm_release.karpenter.name
}

# SQS queue + EventBridge rules are created in the iam-irsa module (single-apply design).
# See iam_irsa outputs: karpenter_interruption_queue_name, karpenter_interruption_queue_arn

# -------------------------------------------------------------------------
# KEDA / Trivy Operator / Kubeshark
# -------------------------------------------------------------------------
output "keda_release_name" {
  description = "KEDA Helm release name (event-driven autoscaling). Empty when disabled."
  value       = var.enable_keda ? helm_release.keda[0].name : ""
}

output "falco_release_name" {
  description = "Falco Helm release name (runtime security monitoring). Empty when disabled."
  value       = var.enable_falco ? helm_release.falco[0].name : ""
}

output "goldilocks_release_name" {
  description = "Goldilocks Helm release name (cost optimization — pod right-sizing). Empty when disabled."
  value       = var.enable_goldilocks ? helm_release.goldilocks[0].name : ""
}

output "descheduler_release_name" {
  description = "Descheduler Helm release name (pod rebalancing). Empty when disabled."
  value       = var.enable_descheduler ? helm_release.descheduler[0].name : ""
}

output "kubecost_release_name" {
  description = "Kubecost Helm release name (cost allocation per namespace). Empty when disabled."
  value       = var.enable_kubecost ? helm_release.kubecost[0].name : ""
}

output "kubeshark_release_name" {
  description = "Kubeshark Helm release name (network traffic analysis). Empty when disabled."
  value       = var.enable_kubeshark ? helm_release.kubeshark[0].name : ""
}