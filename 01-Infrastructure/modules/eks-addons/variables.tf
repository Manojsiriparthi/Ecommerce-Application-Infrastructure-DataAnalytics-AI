variable "project_name" {
  description = "Project name"
  type        = string
  default     = "pip-project-ecommerce"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "ebs_csi_role_arn" {
  description = "EBS CSI driver IRSA role ARN"
  type        = string
}

variable "lb_controller_role_arn" {
  description = "AWS Load Balancer Controller IRSA role ARN"
  type        = string
}

variable "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler IRSA role ARN"
  type        = string
}

variable "secrets_store_csi_role_arn" {
  description = "IRSA role ARN for the Secrets Store CSI driver provider"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID — passed explicitly to LB controller so it works when IMDSv2 blocks EC2 metadata auto-detection"
  type        = string
}

variable "environment" {
  description = "Environment name (dev / prod)"
  type        = string
}

variable "cloudwatch_observability_role_arn" {
  description = "IRSA role ARN for the amazon-cloudwatch-observability EKS addon (CloudWatch Agent + ADOT collector)"
  type        = string
}

variable "gateway_class_name" {
  description = <<-EOT
    Name of the GatewayClass created by this module and bound to the AWS LBC.
    App team Gateway manifests reference this via spec.gatewayClassName.
    Default "alb-gateway" — change only if you have multiple GatewayClasses.
  EOT
  type    = string
  default = "alb-gateway"
}

# -------------------------------------------------------------------------
# Karpenter — modern node autoscaler (replaces Cluster Autoscaler)
# -------------------------------------------------------------------------
variable "karpenter_role_arn" {
  description = "IRSA role ARN for the Karpenter controller service account."
  type        = string
}

variable "karpenter_node_role_name" {
  description = <<-EOT
    NAME (not ARN) of the IAM role Karpenter passes to new EC2 instances.
    Typically the same EKS node role name — e.g. "pip-project-ecommerce-node-role".
    Pass module.iam.node_role_name from the environment.
    Karpenter uses this in the EC2NodeClass spec.role field.
  EOT
  type    = string
}

variable "karpenter_interruption_queue_name" {
  description = <<-EOT
    NAME of the SQS queue that receives Spot interruption / rebalance / scheduled
    maintenance events for Karpenter. Created in the iam-irsa module (alongside
    the Karpenter role) so the role's SQS permission is scoped to the real ARN
    in a single terraform apply.
    Pass module.iam_irsa.karpenter_interruption_queue_name.
  EOT
  type    = string
}

# -------------------------------------------------------------------------
# KEDA — event-driven autoscaling
# -------------------------------------------------------------------------
variable "enable_keda" {
  description = "Enable KEDA operator (event-driven pod autoscaling on SQS/Kafka/metrics). Default true."
  type        = bool
  default     = true
}

variable "keda_role_arn" {
  description = "IRSA role ARN for KEDA — grants sqs:GetQueueAttributes, cloudwatch:GetMetricData. Leave empty to skip IRSA (KEDA works but AWS triggers need manual SA annotation)."
  type        = string
  default     = ""
}

# -------------------------------------------------------------------------
# Falco — runtime security monitoring
# -------------------------------------------------------------------------
variable "enable_falco" {
  description = "Enable Falco (runtime security — detects anomalous container behavior via eBPF). Default true."
  type        = bool
  default     = true
}

variable "falco_sns_topic_arn" {
  description = "SNS topic ARN for Falco alerts (same as CloudWatch alarm SNS → email + Slack). Leave empty to only send to CloudWatch Logs via Fluent Bit."
  type        = string
  default     = ""
}

# -------------------------------------------------------------------------
# Goldilocks — cost optimization (pod right-sizing)
# -------------------------------------------------------------------------
variable "enable_goldilocks" {
  description = "Enable Goldilocks (VPA recommendations dashboard — right-sizes pod CPU/memory). Default true."
  type        = bool
  default     = true
}

# -------------------------------------------------------------------------
# Descheduler — pod rebalancing (cost optimization)
# -------------------------------------------------------------------------
variable "enable_descheduler" {
  description = "Enable Descheduler (rebalances pods across nodes for better utilization). Default true."
  type        = bool
  default     = true
}

# -------------------------------------------------------------------------
# Kubecost — cost allocation per namespace + per service
# -------------------------------------------------------------------------
variable "enable_kubecost" {
  description = "Enable Kubecost (shows cost per namespace/service + savings recommendations). Default true."
  type        = bool
  default     = true
}

# -------------------------------------------------------------------------
# Kubeshark — network traffic analysis (dev/debugging)
# -------------------------------------------------------------------------
variable "enable_kubeshark" {
  description = "Enable Kubeshark (Wireshark for K8s — captures all pod network traffic). Default false — resource heavy, enable only for debugging."
  type        = bool
  default     = false
}

# -------------------------------------------------------------------------
# Network Policies — pod-to-pod isolation
# -------------------------------------------------------------------------
variable "enable_network_policies" {
  description = "Enable Calico + Network Policies (default-deny + allow rules per service). Default true for production."
  type        = bool
  default     = true
}
