# =============================================================================
# 08-Monitoring — Variables
# =============================================================================

variable "cluster_name" {
  description = "EKS cluster name (must already exist from 01-Infrastructure)"
  type        = string
  default     = "pip-project-ecommerce-cluster"
}

variable "region" {
  description = "AWS region — must match the EKS cluster region"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = <<-EOT
    Domain for the monitoring ALB. Must be a Route53 hosted zone you own.
    Example: "monitor.ecommerce-pip.com"
    Leave empty to use the ALB's raw DNS name (no custom domain).
  EOT
  type    = string
  default = ""
}

variable "allowed_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to access the monitoring ALB (ArgoCD, Grafana, etc.).
    ONLY these IPs can reach the UIs — everyone else gets connection refused.
    Set to your office/laptop IP:
      allowed_cidrs = ["203.0.113.45/32"]
    Add multiple:
      allowed_cidrs = ["203.0.113.45/32", "198.51.100.10/32"]
  EOT
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "enable_prometheus_grafana" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana + Alertmanager). Default true."
  type        = bool
  default     = true
}

variable "enable_elk" {
  description = "Install ELK stack (Elasticsearch + Kibana + Fluent Bit). Default true."
  type        = bool
  default     = true
}

variable "enable_argocd" {
  description = "Install ArgoCD. Set false if already installed via 03-Kubernetes. Default true."
  type        = bool
  default     = true
}

variable "enable_kubeshark" {
  description = "Install Kubeshark (network traffic analyzer). Default false — resource heavy."
  type        = bool
  default     = false
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Set via TF_VAR_grafana_admin_password."
  type        = string
  sensitive   = true
  default     = "admin"
}

variable "elk_elasticsearch_version" {
  description = "Elasticsearch version for ELK stack."
  type        = string
  default     = "8.15.0"
}

variable "alert_email" {
  description = "Email address for Prometheus Alertmanager notifications (critical alerts). Same as CloudWatch SNS email — but separate delivery path (Alertmanager → SES SMTP)."
  type        = string
  default     = ""
}
