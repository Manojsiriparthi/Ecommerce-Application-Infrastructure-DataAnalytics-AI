# =============================================================================
# CloudWatch Dashboards — 20 Dashboards
# =============================================================================
# APPLICATION  (1-5) : overview · services · ALB · SLO · business
# INFRASTRUCTURE(6-10): infra-overview · EKS-cluster · EKS-nodes · EKS-pods · network
# DATABASE    (11-15): db-overview · postgresql · rds-proxy · redis · aurora-global
# SECURITY    (16-20): security-overview · WAF · IAM · secrets · compliance
# =============================================================================

locals {
  cluster     = "${var.project_name}-cluster"
  alb_enabled = trimspace(var.external_alb_arn_suffix) != ""
}

# =============================================================================
# 1. Application Overview
# =============================================================================
resource "aws_cloudwatch_dashboard" "app_overview" {
  dashboard_name = "${var.project_name}-01-app-overview"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Application Overview — ${var.project_name}\nALB traffic · Pod health · Error rates · Latency" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "ALB Requests/min", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "ALB 5xx Errors", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "ALB p50/p95/p99 Latency (s)", view = "timeSeries", region = var.region, period = 60,
        metrics = local.alb_enabled ? [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p50",  label = "p50" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p95",  label = "p95" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p99",  label = "p99" }],
        ] : [] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Healthy / Unhealthy Targets", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = local.alb_enabled ? [
          ["AWS/ApplicationELB", "HealthyHostCount",   "LoadBalancer", var.external_alb_arn_suffix],
          ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.external_alb_arn_suffix],
        ] : [] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Running Pods — ecommerce ns", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "pod_number_of_running_containers", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Pod Restarts — ecommerce ns", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
  ]})
}

# =============================================================================
# 2. Backend Services
# =============================================================================
resource "aws_cloudwatch_dashboard" "app_services" {
  dashboard_name = "${var.project_name}-02-app-services"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Backend Services — per-pod CPU · Memory · Restarts\nuser · product · cart · order · payment · notification · frontend" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "Pod CPU % — all services", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "user-service"],
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "product-service"],
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "cart-service"],
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "order-service"],
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "payment-service"],
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "notification-service"],
          ["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "frontend"],
        ] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "Pod Memory % — all services", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "user-service"],
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "product-service"],
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "cart-service"],
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "order-service"],
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "payment-service"],
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "notification-service"],
          ["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "frontend"],
        ] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "Pod Restarts — all services", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "user-service"],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "product-service"],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "cart-service"],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "order-service"],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "payment-service"],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "notification-service"],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce", "PodName", "frontend"],
        ] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "Pod Network Rx/Tx — ecommerce ns", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [
          ["ContainerInsights", "pod_network_rx_bytes", "ClusterName", local.cluster, "Namespace", "ecommerce"],
          ["ContainerInsights", "pod_network_tx_bytes", "ClusterName", local.cluster, "Namespace", "ecommerce"],
        ] } },
  ]})
}

# =============================================================================
# 3. ALB Detail
# =============================================================================
resource "aws_cloudwatch_dashboard" "app_alb" {
  dashboard_name = "${var.project_name}-03-app-alb"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# ALB Detail — Requests · Errors · Latency · Connections · Bytes" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "Total Requests/min", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "2xx / 4xx / 5xx Count", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [
          ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.external_alb_arn_suffix],
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.external_alb_arn_suffix],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix],
        ] : [] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Latency p50/p95/p99 (s)", view = "timeSeries", region = var.region, period = 60,
        metrics = local.alb_enabled ? [
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p50",  label = "p50" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p95",  label = "p95" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p99",  label = "p99" }],
        ] : [] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Healthy Hosts", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Active Connections", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Processed Bytes", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "ProcessedBytes", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
  ]})
}

# =============================================================================
# 4. SLO / Error Budget
# =============================================================================
resource "aws_cloudwatch_dashboard" "app_slo" {
  dashboard_name = "${var.project_name}-04-app-slo"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# SLO / Error Budget\nTargets: p99 latency < 200ms · Error rate < 0.1% · Availability > 99.9%" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "p99 Latency (SLO: < 200ms)", view = "timeSeries", region = var.region, period = 60,
        annotations = { horizontal = [{ value = 0.2, label = "200ms SLO", color = "#ff0000" }] },
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p99" }]] : [] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "5xx Error Count (SLO: < 10/min)", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        annotations = { horizontal = [{ value = 10, label = "SLO threshold", color = "#ff0000" }] },
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "ALB Availability (Healthy Hosts)", view = "timeSeries", region = var.region, period = 60, stat = "Minimum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "Pod Restarts (SLO: < 5 per 5min)", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        annotations = { horizontal = [{ value = 5, label = "SLO threshold", color = "#ff0000" }] },
        metrics = [["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
  ]})
}

# =============================================================================
# 5. Business Metrics
# =============================================================================
resource "aws_cloudwatch_dashboard" "app_business" {
  dashboard_name = "${var.project_name}-05-app-business"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Business Metrics\nPublish via: `aws cloudwatch put-metric-data --namespace EcommerceApp --metric-name OrdersCreated --value 1`" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "Orders Created / hour", view = "timeSeries", region = var.region, period = 3600, stat = "Sum",
        metrics = [["EcommerceApp", "OrdersCreated", "Environment", var.environment]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "Payments Processed / hour", view = "timeSeries", region = var.region, period = 3600, stat = "Sum",
        metrics = [["EcommerceApp", "PaymentsProcessed", "Environment", var.environment]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Payment Failures / hour", view = "timeSeries", region = var.region, period = 3600, stat = "Sum",
        metrics = [["EcommerceApp", "PaymentFailures", "Environment", var.environment]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "New User Registrations / hour", view = "timeSeries", region = var.region, period = 3600, stat = "Sum",
        metrics = [["EcommerceApp", "UserRegistrations", "Environment", var.environment]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Cart Add Events / hour", view = "timeSeries", region = var.region, period = 3600, stat = "Sum",
        metrics = [["EcommerceApp", "CartAddEvents", "Environment", var.environment]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Emails Sent / hour", view = "timeSeries", region = var.region, period = 3600, stat = "Sum",
        metrics = [["EcommerceApp", "EmailsSent", "Environment", var.environment]] } },
  ]})
}

# =============================================================================
# 6. Infrastructure Overview
# =============================================================================
resource "aws_cloudwatch_dashboard" "infra_overview" {
  dashboard_name = "${var.project_name}-06-infra-overview"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Infrastructure Overview — EKS · Aurora · Redis · NAT · VPC" } },
    { type = "metric", width = 6, height = 6, x = 0, y = 2,
      properties = { title = "EKS Node CPU %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", local.cluster]] } },
    { type = "metric", width = 6, height = 6, x = 6, y = 2,
      properties = { title = "EKS Node Memory %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", local.cluster]] } },
    { type = "metric", width = 6, height = 6, x = 12, y = 2,
      properties = { title = "Aurora CPU %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 6, height = 6, x = 18, y = 2,
      properties = { title = "Redis CPU %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "NAT Gateway Bytes In/Out", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [
          ["AWS/NATGateway", "BytesInFromDestination", "NatGatewayId", var.nat_gateway_id],
          ["AWS/NATGateway", "BytesOutToDestination",  "NatGatewayId", var.nat_gateway_id],
        ] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "NAT Port Allocation Errors", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", var.nat_gateway_id]] } },
  ]})
}

# =============================================================================
# 7. EKS Cluster
# =============================================================================
resource "aws_cloudwatch_dashboard" "eks_cluster" {
  dashboard_name = "${var.project_name}-07-eks-cluster"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# EKS Cluster — ${local.cluster}\nNode count · CPU/Memory reservation · Total pods · Network" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "Node Count", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "cluster_node_count", "ClusterName", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "Failed Node Count", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "cluster_failed_node_count", "ClusterName", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Total Running Pods", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "pod_number_of_running_containers", "ClusterName", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "CPU Reserved Capacity %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_cpu_reserved_capacity", "ClusterName", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Memory Reserved Capacity %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_memory_reserved_capacity", "ClusterName", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Cluster Network Total Bytes", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["ContainerInsights", "node_network_total_bytes", "ClusterName", local.cluster]] } },
  ]})
}

# =============================================================================
# 8. EKS Nodes
# =============================================================================
resource "aws_cloudwatch_dashboard" "eks_nodes" {
  dashboard_name = "${var.project_name}-08-eks-nodes"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# EKS Nodes — CPU · Memory · Disk · Network · Reserved capacity" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "Node CPU Utilization %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "Node Memory Utilization %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "Node Disk Utilization %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_filesystem_utilization", "ClusterName", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "Node Network Total Bytes", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["ContainerInsights", "node_network_total_bytes", "ClusterName", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 14,
      properties = { title = "CPU Reserved Capacity %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_cpu_reserved_capacity", "ClusterName", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 14,
      properties = { title = "Memory Reserved Capacity %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "node_memory_reserved_capacity", "ClusterName", local.cluster]] } },
  ]})
}

# =============================================================================
# 9. EKS Pods
# =============================================================================
resource "aws_cloudwatch_dashboard" "eks_pods" {
  dashboard_name = "${var.project_name}-09-eks-pods"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# EKS Pods — CPU · Memory · Restarts · Network · Namespace breakdown" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "Pod CPU % — ecommerce ns", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "pod_cpu_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "Pod Memory % — ecommerce ns", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "pod_memory_utilization", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Pod Restarts — ecommerce", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Pod Restarts — kube-system", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster, "Namespace", "kube-system"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Running Pods — ecommerce", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["ContainerInsights", "pod_number_of_running_containers", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 14,
      properties = { title = "Pod Network Rx — ecommerce", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["ContainerInsights", "pod_network_rx_bytes", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 14,
      properties = { title = "Pod Network Tx — ecommerce", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["ContainerInsights", "pod_network_tx_bytes", "ClusterName", local.cluster, "Namespace", "ecommerce"]] } },
  ]})
}

# =============================================================================
# 10. Network
# =============================================================================
resource "aws_cloudwatch_dashboard" "network" {
  dashboard_name = "${var.project_name}-10-network"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Network — NAT Gateway · ALB Connections · Pod Network · VPC Traffic" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "NAT In/Out Bytes", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [
          ["AWS/NATGateway", "BytesInFromDestination", "NatGatewayId", var.nat_gateway_id],
          ["AWS/NATGateway", "BytesOutToDestination",  "NatGatewayId", var.nat_gateway_id],
        ] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "NAT Active Connections", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["AWS/NATGateway", "ActiveConnectionCount", "NatGatewayId", var.nat_gateway_id]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "NAT Port Allocation Errors", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", var.nat_gateway_id]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "ALB Active Connections", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "ALB New Connections/min", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = local.alb_enabled ? [["AWS/ApplicationELB", "NewConnectionCount", "LoadBalancer", var.external_alb_arn_suffix]] : [] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 14,
      properties = { title = "Pod Network Rx — cluster total", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["ContainerInsights", "pod_network_rx_bytes", "ClusterName", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 14,
      properties = { title = "Pod Network Tx — cluster total", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["ContainerInsights", "pod_network_tx_bytes", "ClusterName", local.cluster]] } },
  ]})
}

# =============================================================================
# 11. Database Overview
# =============================================================================
resource "aws_cloudwatch_dashboard" "db_overview" {
  dashboard_name = "${var.project_name}-11-db-overview"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Database Overview — Aurora PostgreSQL · RDS Proxy · Redis" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "Aurora CPU %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "Aurora DB Connections", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Aurora Freeable Memory", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "FreeableMemory", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Aurora Replica Lag (ms)", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "AuroraReplicaLag", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Redis CPU %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Redis Cache Hit Rate %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "CacheHitRate", "ReplicationGroupId", "${var.project_name}-redis"]] } },
  ]})
}

# =============================================================================
# 12. PostgreSQL Deep-Dive
# =============================================================================
resource "aws_cloudwatch_dashboard" "postgresql" {
  dashboard_name = "${var.project_name}-12-postgresql"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# PostgreSQL (Aurora) — Writer vs Reader · IOPS · Latency · Replication · Deadlocks\nWriter→AZ-a · Reader-1→AZ-b · Reader-2→AZ-c" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "CPU — Writer vs Readers", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project_name}-writer",   { label = "writer"   }],
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project_name}-reader-1", { label = "reader-1" }],
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project_name}-reader-2", { label = "reader-2" }],
        ] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "Connections — Writer vs Readers", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.project_name}-writer"],
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.project_name}-reader-1"],
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "${var.project_name}-reader-2"],
        ] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Freeable Memory — Writer vs Readers", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", "${var.project_name}-writer"],
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", "${var.project_name}-reader-1"],
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", "${var.project_name}-reader-2"],
        ] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Replica Lag (ms)", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "AuroraReplicaLag", "DBInstanceIdentifier", "${var.project_name}-reader-1"],
          ["AWS/RDS", "AuroraReplicaLag", "DBInstanceIdentifier", "${var.project_name}-reader-2"],
        ] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Read / Write IOPS", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "ReadIOPS",  "DBClusterIdentifier", local.cluster],
          ["AWS/RDS", "WriteIOPS", "DBClusterIdentifier", local.cluster],
        ] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Read / Write Latency (ms)", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "ReadLatency",  "DBClusterIdentifier", local.cluster],
          ["AWS/RDS", "WriteLatency", "DBClusterIdentifier", local.cluster],
        ] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 14,
      properties = { title = "Network Receive / Transmit Throughput", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [
          ["AWS/RDS", "NetworkReceiveThroughput",  "DBClusterIdentifier", local.cluster],
          ["AWS/RDS", "NetworkTransmitThroughput", "DBClusterIdentifier", local.cluster],
        ] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 14,
      properties = { title = "Deadlocks + Rollbacks", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [
          ["AWS/RDS", "Deadlocks",              "DBClusterIdentifier", local.cluster],
          ["AWS/RDS", "RollbackSegmentHistory",  "DBClusterIdentifier", local.cluster],
        ] } },
  ]})
}

# =============================================================================
# 13. RDS Proxy
# =============================================================================
resource "aws_cloudwatch_dashboard" "rds_proxy" {
  dashboard_name = "${var.project_name}-13-rds-proxy"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# RDS Proxy — Connection pooling · Borrow timeouts · Query throughput\nProxy: ${var.project_name}-db-proxy" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "Client Connections", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "ClientConnections", "ProxyName", "${var.project_name}-db-proxy"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "DB Connections (Proxy → Aurora)", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "DatabaseConnections", "ProxyName", "${var.project_name}-db-proxy"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Connection Borrow Timeouts", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["AWS/RDS", "ConnectionBorrowTimeout", "ProxyName", "${var.project_name}-db-proxy"]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "Query Requests", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["AWS/RDS", "QueryRequests", "ProxyName", "${var.project_name}-db-proxy"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "Max Connections Allowed", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "MaxConnectionsAllowed", "ProxyName", "${var.project_name}-db-proxy"]] } },
  ]})
}

# =============================================================================
# 14. Redis / ElastiCache
# =============================================================================
resource "aws_cloudwatch_dashboard" "redis" {
  dashboard_name = "${var.project_name}-14-redis"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Redis (ElastiCache) — Hits · Misses · Memory · Evictions · Connections · Replication lag" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "CPU %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "Memory Usage %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "Cache Hit Rate %", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "CacheHitRate", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Cache Hits / Misses", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [
          ["AWS/ElastiCache", "CacheHits",   "ReplicationGroupId", "${var.project_name}-redis"],
          ["AWS/ElastiCache", "CacheMisses", "ReplicationGroupId", "${var.project_name}-redis"],
        ] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Evictions", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [["AWS/ElastiCache", "Evictions", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "Current Connections", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "CurrConnections", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 14,
      properties = { title = "Replication Lag (ms)", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/ElastiCache", "ReplicationLag", "ReplicationGroupId", "${var.project_name}-redis"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 14,
      properties = { title = "Network In/Out Bytes", view = "timeSeries", region = var.region, period = 60, stat = "Sum",
        metrics = [
          ["AWS/ElastiCache", "NetworkBytesIn",  "ReplicationGroupId", "${var.project_name}-redis"],
          ["AWS/ElastiCache", "NetworkBytesOut", "ReplicationGroupId", "${var.project_name}-redis"],
        ] } },
  ]})
}

# =============================================================================
# 15. Aurora Global DB (Cross-Region Replication)
# =============================================================================
resource "aws_cloudwatch_dashboard" "aurora_global" {
  dashboard_name = "${var.project_name}-15-aurora-global"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Aurora Global DB — Cross-Region Replication Lag · RPO Readiness\nPrimary → DR region (async, typically < 1 second)" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "Global DB Replication Lag (ms) — SLO: < 5000ms", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        annotations = { horizontal = [{ value = 5000, label = "Alert 5s", color = "#ff0000" }] },
        metrics = [["AWS/RDS", "AuroraGlobalDBReplicationLag", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "Local Replica Lag (ms) — SLO: < 1000ms", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        annotations = { horizontal = [{ value = 1000, label = "Alert 1s", color = "#ff6600" }] },
        metrics = [["AWS/RDS", "AuroraReplicaLag", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Aurora CPU — Primary", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "Write IOPS", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "WriteIOPS", "DBClusterIdentifier", local.cluster]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "DB Connections", view = "timeSeries", region = var.region, period = 60, stat = "Average",
        metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", local.cluster]] } },
  ]})
}

# =============================================================================
# 16. Security Overview
# =============================================================================
resource "aws_cloudwatch_dashboard" "security_overview" {
  dashboard_name = "${var.project_name}-16-security-overview"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Security Overview — WAF · GuardDuty · Secrets · IAM · KMS" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "WAF Blocked Requests", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "WAF Allowed Requests", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/WAFV2", "AllowedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "GuardDuty Findings", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/GuardDuty", "FindingCount"]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "Secrets Manager GetSecretValue Calls", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/SecretsManager", "CallCount", "Operation", "GetSecretValue"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "KMS Decrypt Requests", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/KMS", "NumberOfRequestsSucceeded"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "KMS Invalid Signature (Tampering)", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/KMS", "NumberOfRequestsWithoutValidSignature"]] } },
  ]})
}

# =============================================================================
# 17. WAF Detail
# =============================================================================
resource "aws_cloudwatch_dashboard" "security_waf" {
  dashboard_name = "${var.project_name}-17-security-waf"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# WAF — Allowed vs Blocked · Rule-level breakdown\nWebACL: ${var.project_name}-waf-${var.environment}" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "Allowed + Blocked Requests", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [
          ["AWS/WAFV2", "AllowedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"],
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"],
        ] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "Block Rate (Blocked / Total)", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"]] } },
    { type = "metric", width = 8, height = 6, x = 0, y = 8,
      properties = { title = "CommonRuleSet Blocks", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "AWSManagedRulesCommonRuleSet"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 8,
      properties = { title = "SQLiRuleSet Blocks", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "AWSManagedRulesSQLiRuleSet"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 8,
      properties = { title = "KnownBadInputs Blocks", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "AWSManagedRulesKnownBadInputsRuleSet"]] } },
  ]})
}

# =============================================================================
# 18. IAM + CloudTrail
# =============================================================================
resource "aws_cloudwatch_dashboard" "security_iam" {
  dashboard_name = "${var.project_name}-18-security-iam"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# IAM + CloudTrail — Access Denied · AssumeRole · Root login · Unauthorised API calls" } },
    { type = "log", width = 12, height = 6, x = 0, y = 2,
      properties = { title = "Access Denied Calls (CloudTrail)", view = "table", region = var.region,
        query = "SOURCE '/aws/cloudtrail/${var.project_name}' | fields @timestamp, errorCode, userIdentity.arn, eventName, sourceIPAddress | filter errorCode='AccessDenied' | sort @timestamp desc | limit 50" } },
    { type = "log", width = 12, height = 6, x = 12, y = 2,
      properties = { title = "AssumeRole Events (last 50)", view = "table", region = var.region,
        query = "SOURCE '/aws/cloudtrail/${var.project_name}' | fields @timestamp, userIdentity.arn, requestParameters.roleArn | filter eventName='AssumeRole' | sort @timestamp desc | limit 50" } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "IAM Access Denied Count", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["CloudTrailMetrics", "UnauthorizedAttemptCount"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "Root Account Usage", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["CloudTrailMetrics", "RootAccountUsageCount"]] } },
  ]})
}

# =============================================================================
# 19. Secrets + Encryption
# =============================================================================
resource "aws_cloudwatch_dashboard" "security_secrets" {
  dashboard_name = "${var.project_name}-19-security-secrets"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Secrets + Encryption — Secrets Manager · KMS · SSM Parameter Store" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "GetSecretValue Calls", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/SecretsManager", "CallCount", "Operation", "GetSecretValue"]] } },
    { type = "metric", width = 8, height = 6, x = 8, y = 2,
      properties = { title = "Secrets ResourceNotFound Errors", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/SecretsManager", "ResourceNotFoundExceptionCount"]] } },
    { type = "metric", width = 8, height = 6, x = 16, y = 2,
      properties = { title = "KMS Decrypt Calls", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/KMS", "NumberOfRequestsSucceeded"]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "SSM GetParameter Calls", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/SSM", "NumberOfRequestsSucceeded"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "KMS Invalid Signature Attempts", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/KMS", "NumberOfRequestsWithoutValidSignature"]] } },
  ]})
}

# =============================================================================
# 20. Compliance + Audit
# =============================================================================
resource "aws_cloudwatch_dashboard" "security_compliance" {
  dashboard_name = "${var.project_name}-20-security-compliance"
  dashboard_body = jsonencode({ widgets = [
    { type = "text", width = 24, height = 2, x = 0, y = 0,
      properties = { markdown = "# Compliance + Audit — GuardDuty · VPC Flow Logs · EKS Audit · CloudTrail validation" } },
    { type = "metric", width = 8, height = 6, x = 0, y = 2,
      properties = { title = "GuardDuty Finding Count", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/GuardDuty", "FindingCount"]] } },
    { type = "log", width = 16, height = 6, x = 8, y = 2,
      properties = { title = "VPC Flow Log — Rejected Traffic (top 20)", view = "table", region = var.region,
        query = "SOURCE 'vpc-flow-logs' | stats count(*) as rejectCount by srcAddr, dstAddr, dstPort | filter action='REJECT' | sort rejectCount desc | limit 20" } },
    { type = "log", width = 12, height = 6, x = 0, y = 8,
      properties = { title = "EKS Audit — Secrets Access", view = "table", region = var.region,
        query = "SOURCE '/aws/eks/${local.cluster}/cluster' | fields @timestamp, verb, objectRef.resource, user.username | filter objectRef.resource='secrets' | sort @timestamp desc | limit 30" } },
    { type = "metric", width = 12, height = 6, x = 12, y = 8,
      properties = { title = "CloudTrail Log Validation Failures", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["CloudTrailMetrics", "CloudTrailLogFileValidationFailureCount"]] } },
    { type = "metric", width = 12, height = 6, x = 0, y = 14,
      properties = { title = "S3 WAF Log Bucket Errors", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/S3", "5xxErrors", "BucketName", "${var.project_name}-waf-logs-${var.environment}"]] } },
    { type = "metric", width = 12, height = 6, x = 12, y = 14,
      properties = { title = "EKS API Server Errors (5xx)", view = "timeSeries", region = var.region, period = 300, stat = "Sum",
        metrics = [["AWS/EKS", "apiserver_request_total", "cluster", local.cluster, "code", "5xx"]] } },
  ]})
}
