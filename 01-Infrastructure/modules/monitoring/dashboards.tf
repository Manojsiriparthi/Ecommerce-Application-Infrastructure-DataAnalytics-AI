# =============================================================================
# CloudWatch Dashboards — 3 dashboards (Infra / Application / Business)
# =============================================================================
# RUBRIC: Create 3 CloudWatch dashboards: infrastructure, application, business
# =============================================================================

# ── Dashboard 1: Infrastructure ───────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "infrastructure" {
  dashboard_name = "${var.project_name}-infrastructure"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: Aurora
      {
        type = "metric"; width = 8; height = 6; x = 0; y = 0
        properties = {
          title   = "Aurora CPU %"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", "${var.project_name}-cluster"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 8; y = 0
        properties = {
          title   = "Aurora Connections"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", "${var.project_name}-cluster"]]
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 16; y = 0
        properties = {
          title   = "Aurora Freeable Memory (MB)"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/RDS", "FreeableMemory", "DBClusterIdentifier", "${var.project_name}-cluster"]]
        }
      },
      # Row 2: Redis
      {
        type = "metric"; width = 8; height = 6; x = 0; y = 6
        properties = {
          title   = "Redis CPU %"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", "${var.project_name}-redis"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 8; y = 6
        properties = {
          title   = "Redis Memory %"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", "${var.project_name}-redis"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 16; y = 6
        properties = {
          title   = "Redis Cache Hit Rate %"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/ElastiCache", "CacheHitRate", "ReplicationGroupId", "${var.project_name}-redis"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      # Row 3: EKS Nodes
      {
        type = "metric"; width = 12; height = 6; x = 0; y = 12
        properties = {
          title   = "EKS Node CPU %"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", "${var.project_name}-cluster"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type = "metric"; width = 12; height = 6; x = 12; y = 12
        properties = {
          title   = "EKS Node Memory %"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", "${var.project_name}-cluster"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      # Row 4: NAT + VPC
      {
        type = "metric"; width = 12; height = 6; x = 0; y = 18
        properties = {
          title   = "NAT Gateway Bytes (In/Out)"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Sum"
          metrics = [
            ["AWS/NATGateway", "BytesInFromDestination", "NatGatewayId", var.nat_gateway_id],
            ["AWS/NATGateway", "BytesOutToDestination",  "NatGatewayId", var.nat_gateway_id],
          ]
        }
      },
      {
        type = "metric"; width = 12; height = 6; x = 12; y = 18
        properties = {
          title   = "NAT Gateway Error Drops"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Sum"
          metrics = [["AWS/NATGateway", "ErrorPortAllocation", "NatGatewayId", var.nat_gateway_id]]
        }
      },
    ]
  })
}

# ── Dashboard 2: Application ──────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "application" {
  dashboard_name = "${var.project_name}-application"

  dashboard_body = jsonencode({
    widgets = [
      # Row 1: ALB metrics (only meaningful when ALB exists)
      {
        type = "metric"; width = 8; height = 6; x = 0; y = 0
        properties = {
          title   = "ALB Request Count / min"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 8; y = 0
        properties = {
          title   = "ALB 5xx Error Count"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
          annotations = { horizontal = [{ value = 10, label = "Alert threshold", color = "#FF0000" }] }
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 16; y = 0
        properties = {
          title   = "ALB p50/p95/p99 Latency (s)"
          view    = "timeSeries"; region = var.region; period = 60
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p50",  label = "p50"  }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p95",  label = "p95"  }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p99",  label = "p99"  }],
          ] : []
          annotations = { horizontal = [{ value = 0.2, label = "SLO 200ms", color = "#FF6B35" }] }
        }
      },
      # Row 2: EKS Pods
      {
        type = "metric"; width = 8; height = 6; x = 0; y = 6
        properties = {
          title   = "EKS Running Pods"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [
            ["ContainerInsights", "pod_number_of_running_containers", "ClusterName", "${var.project_name}-cluster", "Namespace", "ecommerce"]
          ]
          annotations = { horizontal = [{ value = 7, label = "Expected (7 pods)", color = "#36A64F" }] }
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 8; y = 6
        properties = {
          title   = "EKS Pod Restarts"
          view    = "timeSeries"; region = var.region; period = 300; stat = "Sum"
          metrics = [
            ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", "${var.project_name}-cluster", "Namespace", "ecommerce"]
          ]
          annotations = { horizontal = [{ value = 5, label = "Alert threshold", color = "#FF0000" }] }
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 16; y = 6
        properties = {
          title   = "ALB Healthy / Unhealthy Targets"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "HealthyHostCount",   "LoadBalancer", var.external_alb_arn_suffix, { label = "Healthy",   color = "#36A64F" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.external_alb_arn_suffix, { label = "Unhealthy", color = "#FF0000" }],
          ] : []
        }
      },
      # Row 3: WAF
      {
        type = "metric"; width = 12; height = 6; x = 0; y = 12
        properties = {
          title   = "WAF Blocked vs Allowed Requests"
          view    = "timeSeries"; region = var.region; period = 300; stat = "Sum"
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL", { label = "Blocked", color = "#FF0000" }],
            ["AWS/WAFV2", "AllowedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL", { label = "Allowed", color = "#36A64F" }],
          ]
        }
      },
      {
        type = "metric"; width = 12; height = 6; x = 12; y = 12
        properties = {
          title   = "ALB 4xx Errors"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
          annotations = { horizontal = [{ value = 100, label = "Alert threshold", color = "#FFA500" }] }
        }
      },
    ]
  })
}

# ── Dashboard 3: Business ─────────────────────────────────────────────────────
# Business metrics via custom CloudWatch metrics published by the app.
# Initially shows infrastructure proxies (request count, DB connections)
# until the app publishes custom business metrics (orders/hour etc).
resource "aws_cloudwatch_dashboard" "business" {
  dashboard_name = "${var.project_name}-business"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text"; width = 24; height = 2; x = 0; y = 0
        properties = {
          markdown = <<-MD
            ## Business Metrics — ${var.project_name}
            Custom metrics published from application services via CloudWatch PutMetricData.
            To add app metrics: `aws cloudwatch put-metric-data --namespace EcommerceApp --metric-name OrdersPerHour --value 42`
          MD
        }
      },
      # API request rate as business proxy (until custom metrics added)
      {
        type = "metric"; width = 8; height = 6; x = 0; y = 2
        properties = {
          title   = "Total API Requests / min (Proxy for Traffic)"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 8; y = 2
        properties = {
          title   = "DB Connections (Proxy for Active Users)"
          view    = "timeSeries"; region = var.region; period = 60; stat = "Average"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", "${var.project_name}-cluster"]]
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 16; y = 2
        properties = {
          title   = "API Success Rate % (Derived)"
          view    = "timeSeries"; region = var.region; period = 300
          metrics = local.alb_enabled ? [
            [{ expression = "100-(m2/m1*100)", label = "Success Rate %", id = "e1", color = "#36A64F" }],
            ["AWS/ApplicationELB", "RequestCount",                 "LoadBalancer", var.external_alb_arn_suffix, { id = "m1", visible = false }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count",    "LoadBalancer", var.external_alb_arn_suffix, { id = "m2", visible = false }],
          ] : []
          yAxis = { left = { min = 0, max = 100 } }
          annotations = { horizontal = [{ value = 99.9, label = "SLO 99.9%", color = "#FF6B35" }] }
        }
      },
      # Custom business metrics (will show data once app publishes them)
      {
        type = "metric"; width = 8; height = 6; x = 0; y = 8
        properties = {
          title   = "Orders per Hour (Custom Metric)"
          view    = "timeSeries"; region = var.region; period = 3600; stat = "Sum"
          metrics = [["EcommerceApp", "OrdersCreated", "Environment", var.environment]]
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 8; y = 8
        properties = {
          title   = "Payments Processed per Hour (Custom Metric)"
          view    = "timeSeries"; region = var.region; period = 3600; stat = "Sum"
          metrics = [["EcommerceApp", "PaymentsProcessed", "Environment", var.environment]]
        }
      },
      {
        type = "metric"; width = 8; height = 6; x = 16; y = 8
        properties = {
          title   = "New User Registrations per Hour (Custom Metric)"
          view    = "timeSeries"; region = var.region; period = 3600; stat = "Sum"
          metrics = [["EcommerceApp", "UserRegistrations", "Environment", var.environment]]
        }
      },
      # Alarm status widget
      {
        type  = "alarm"; width = 24; height = 4; x = 0; y = 14
        properties = {
          title  = "Active Alarms"
          alarms = [
            "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-alb-external-5xx-high",
            "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-alb-response-time-high",
            "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-eks-node-cpu-high",
            "arn:aws:cloudwatch:${var.region}:${data.aws_caller_identity.current.account_id}:alarm:${var.project_name}-alb-unhealthy-hosts",
          ]
        }
      },
    ]
  })
}
