# =============================================================================
# 08-Monitoring — tfvars
# =============================================================================
# USAGE:
#   cd 08-Monitoring
#   terraform init
#   export TF_VAR_grafana_admin_password="your-secure-password"
#   terraform apply -var-file="monitoring.tfvars"
#
# PREREQUISITES:
#   1. 01-Infrastructure applied (EKS cluster + GatewayClass "alb-gateway" exist)
#   2. kubeconfig updated:
#        aws eks update-kubeconfig --name pip-project-ecommerce-cluster --region us-east-1
# =============================================================================

# ── Cluster connection ────────────────────────────────────────────────────────
cluster_name = "pip-project-ecommerce-cluster"
region       = "us-east-1"

# ── Domain (optional — leave empty to use raw ALB DNS name) ────────────────────
# Set to a Route53 hosted zone you own:
#   domain_name = "monitor.ecommerce-pip.com"
domain_name = ""

# ── IP restriction — ONLY these IPs can access the monitoring UIs ─────────────
# Get your IP: curl ifconfig.me
# Format: ["YOUR_IP/32"]
# Example: ["203.0.113.45/32", "198.51.100.10/32"]
#
# Default 0.0.0.0/0 = open to all (change before production!)
allowed_cidrs = ["0.0.0.0/0"]

# ── Tool toggles ──────────────────────────────────────────────────────────────
enable_prometheus_grafana = true
enable_elk                = true
enable_argocd             = true
enable_kubeshark           = false   # resource heavy — enable for debugging only

# ── ELK ──────────────────────────────────────────────────────────────────────
elk_elasticsearch_version = "8.15.0"

# ── Alertmanager notifications ────────────────────────────────────────────────
# Prometheus Alertmanager sends critical alerts to this email + Slack
alert_email = "manojchowdary932@gmail.com"

# NOTE: grafana_admin_password is set via TF_VAR_grafana_admin_password env var
# NOTE: Slack webhook URL + SES SMTP password set after apply:
#   kubectl create secret generic slack-webhook-secret -n monitoring \
#     --from-literal=slack-webhook-url='https://hooks.slack.com/services/XXX/XXX/XXX' \
#     --from-literal=smtp-password='your-ses-smtp-password'
