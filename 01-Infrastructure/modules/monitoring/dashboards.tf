# =============================================================================
# CloudWatch Dashboards — 3 dashboards (Infrastructure / Application / Business)
# =============================================================================
# RUBRIC: Create 3 CloudWatch dashboards
#
# NOTE: Dashboard bodies use jsonencode() — HCL map syntax uses commas, not
# semicolons. Each map key/value pair must be on its own line or comma-separated.
# =============================================================================

# ── Dashboard 1: Infrastructure ───────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "infrastructure" {
  dashboard_name = "${var.project_name}-infrastructure"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 0
        y      = 0
        properties = {
          title   = "Aurora CPU %"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", "${var.project_name}-cluster"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 8
        y      = 0
        properties = {
          title   = "Aurora Connections"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", "${var.project_name}-cluster"]]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 16
        y      = 0
        properties = {
          title   = "Aurora Freeable Memory (bytes)"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "FreeableMemory", "DBClusterIdentifier", "${var.project_name}-cluster"]]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 0
        y      = 6
        properties = {
          title   = "Redis CPU %"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", "${var.project_name}-redis"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 8
        y      = 6
        properties = {
          title   = "Redis Memory %"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/ElastiCache", "DatabaseMemoryUsagePercentage", "ReplicationGroupId", "${var.project_name}-redis"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 16
        y      = 6
        properties = {
          title   = "Redis Cache Hit Rate %"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/ElastiCache", "CacheHitRate", "ReplicationGroupId", "${var.project_name}-redis"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        x      = 0
        y      = 12
        properties = {
          title   = "EKS Node CPU %"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["ContainerInsights", "node_cpu_utilization", "ClusterName", "${var.project_name}-cluster"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        x      = 12
        y      = 12
        properties = {
          title   = "EKS Node Memory %"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["ContainerInsights", "node_memory_utilization", "ClusterName", "${var.project_name}-cluster"]]
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        x      = 0
        y      = 18
        properties = {
          title   = "NAT Gateway Bytes"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = [
            ["AWS/NATGateway", "BytesInFromDestination",  "NatGatewayId", var.nat_gateway_id],
            ["AWS/NATGateway", "BytesOutToDestination",   "NatGatewayId", var.nat_gateway_id],
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        x      = 12
        y      = 18
        properties = {
          title   = "NAT Gateway Error Drops"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Sum"
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
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 0
        y      = 0
        properties = {
          title   = "ALB Request Count / min"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 8
        y      = 0
        properties = {
          title   = "ALB 5xx Error Count"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 16
        y      = 0
        properties = {
          title   = "ALB p50/p95/p99 Latency (s)"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p95", label = "p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.external_alb_arn_suffix, { stat = "p99", label = "p99" }],
          ] : []
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 0
        y      = 6
        properties = {
          title   = "EKS Running Pods (ecommerce ns)"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [
            ["ContainerInsights", "pod_number_of_running_containers", "ClusterName", "${var.project_name}-cluster", "Namespace", "ecommerce"]
          ]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 8
        y      = 6
        properties = {
          title   = "EKS Pod Restarts"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", "${var.project_name}-cluster", "Namespace", "ecommerce"]
          ]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 16
        y      = 6
        properties = {
          title   = "ALB Healthy / Unhealthy Targets"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "HealthyHostCount",   "LoadBalancer", var.external_alb_arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.external_alb_arn_suffix],
          ] : []
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        x      = 0
        y      = 12
        properties = {
          title   = "WAF Blocked vs Allowed"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          stat    = "Sum"
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"],
            ["AWS/WAFV2", "AllowedRequests", "WebACL", "${var.project_name}-waf-${var.environment}", "Region", var.region, "Rule", "ALL"],
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        x      = 12
        y      = 12
        properties = {
          title   = "ALB 4xx Errors"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
        }
      },
    ]
  })
}

# ── Dashboard 3: Business ─────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "business" {
  dashboard_name = "${var.project_name}-business"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        width  = 24
        height = 2
        x      = 0
        y      = 0
        properties = {
          markdown = "## Business Metrics — ${var.project_name}\nCustom metrics from application services. Publish via: `aws cloudwatch put-metric-data --namespace EcommerceApp --metric-name OrdersCreated --value 1`"
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 0
        y      = 2
        properties = {
          title   = "Total API Requests / min"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Sum"
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.external_alb_arn_suffix]
          ] : []
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 8
        y      = 2
        properties = {
          title   = "DB Connections (Proxy for Active Users)"
          view    = "timeSeries"
          region  = var.region
          period  = 60
          stat    = "Average"
          metrics = [["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", "${var.project_name}-cluster"]]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 16
        y      = 2
        properties = {
          title   = "Orders Created per Hour (Custom Metric)"
          view    = "timeSeries"
          region  = var.region
          period  = 3600
          stat    = "Sum"
          metrics = [["EcommerceApp", "OrdersCreated", "Environment", var.environment]]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 0
        y      = 8
        properties = {
          title   = "Payments Processed per Hour"
          view    = "timeSeries"
          region  = var.region
          period  = 3600
          stat    = "Sum"
          metrics = [["EcommerceApp", "PaymentsProcessed", "Environment", var.environment]]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 8
        y      = 8
        properties = {
          title   = "New User Registrations per Hour"
          view    = "timeSeries"
          region  = var.region
          period  = 3600
          stat    = "Sum"
          metrics = [["EcommerceApp", "UserRegistrations", "Environment", var.environment]]
        }
      },
      {
        type   = "metric"
        width  = 8
        height = 6
        x      = 16
        y      = 8
        properties = {
          title   = "API Success Rate % (Derived)"
          view    = "timeSeries"
          region  = var.region
          period  = 300
          metrics = local.alb_enabled ? [
            ["AWS/ApplicationELB", "RequestCount",              "LoadBalancer", var.external_alb_arn_suffix, { id = "m1", visible = false, stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.external_alb_arn_suffix, { id = "m2", visible = false, stat = "Sum" }],
          ] : [
            ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", "${var.project_name}-cluster", { stat = "Average" }],
            ["AWS/RDS", "CPUUtilization",       "DBClusterIdentifier", "${var.project_name}-cluster", { stat = "Average" }],
          ]
          yAxis = { left = { min = 0, max = 100 } }
        }
      },
    ]
  })
}
