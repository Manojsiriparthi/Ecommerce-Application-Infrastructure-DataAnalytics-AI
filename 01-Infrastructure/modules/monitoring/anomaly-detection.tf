# =============================================================================
# Anomaly Detection Alarms
# =============================================================================
# RUBRIC: Configure anomaly detection for traffic patterns, CPU usage
#
# CloudWatch Anomaly Detection uses ML to build a model of "normal" behaviour
# from 2 weeks of historical data. Alarms trigger when metric deviates
# beyond N standard deviations from the model band.
#
# WHY ANOMALY DETECTION VS STATIC THRESHOLDS:
#   Static: "alert if CPU > 80%" — misses gradual drift, noisy on weekends
#   Anomaly: "alert if CPU is unusually high for THIS time of day" — smarter
# =============================================================================

# ── ALB Request Count Anomaly ─────────────────────────────────────────────────
# Detects unusual traffic spikes OR unexpected traffic drops
resource "aws_cloudwatch_metric_alarm" "alb_request_anomaly" {
  count               = local.alb_enabled ? 1 : 0
  alarm_name          = "${var.project_name}-alb-request-count-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "e1"
  alarm_description   = "ALB request count anomaly detected — traffic pattern is unusual (possible DDoS or viral traffic)"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions  = { LoadBalancer = var.external_alb_arn_suffix }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 3)"
    label       = "RequestCount (expected)"
    return_data = true
  }

  tags = { Name = "${var.project_name}-alb-anomaly", Environment = var.environment }
}

# ── Aurora CPU Anomaly ────────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "aurora_cpu_anomaly" {
  alarm_name          = "${var.project_name}-aurora-cpu-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "e1"
  alarm_description   = "Aurora CPU anomaly — database load is unusually high for this time of day"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/RDS"
      period      = 300
      stat        = "Average"
      dimensions  = { DBClusterIdentifier = "${var.project_name}-cluster" }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "CPU (expected band)"
    return_data = true
  }

  tags = { Name = "${var.project_name}-aurora-cpu-anomaly", Environment = var.environment }
}

# ── ALB Latency Anomaly ───────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_latency_anomaly" {
  count               = local.alb_enabled ? 1 : 0
  alarm_name          = "${var.project_name}-alb-latency-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 3
  threshold_metric_id = "e1"
  alarm_description   = "ALB response time anomaly — latency is unusually high (possible DB slowdown or pod issue)"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "TargetResponseTime"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "p95"
      dimensions  = { LoadBalancer = var.external_alb_arn_suffix }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "p95 Latency (expected)"
    return_data = true
  }

  tags = { Name = "${var.project_name}-latency-anomaly", Environment = var.environment }
}

# ── Aurora Connection Count Anomaly ──────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "aurora_connections_anomaly" {
  alarm_name          = "${var.project_name}-aurora-connections-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "e1"
  alarm_description   = "Aurora connection count anomaly — unusually high connections (possible connection leak)"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "DatabaseConnections"
      namespace   = "AWS/RDS"
      period      = 300
      stat        = "Average"
      dimensions  = { DBClusterIdentifier = "${var.project_name}-cluster" }
    }
  }

  metric_query {
    id          = "e1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    label       = "Connections (expected)"
    return_data = true
  }

  tags = { Name = "${var.project_name}-connections-anomaly", Environment = var.environment }
}

# =============================================================================
# Log Retention — Application: 30 days, Audit/Infra: 90 days
# =============================================================================
# RUBRIC: Implement log retention — application logs 30 days, audit logs 90 days
# =============================================================================

# Application logs — 30 days (pod stdout/stderr via Fluent Bit)
resource "aws_cloudwatch_log_group" "service_logs" {
  for_each = toset([
    "user-service",
    "product-service",
    "cart-service",
    "order-service",
    "payment-service",
    "notification-service",
    "frontend",
  ])

  name              = "/aws/eks/${var.project_name}/application/${each.key}"
  retention_in_days = 30   # Application logs: 30 days

  tags = {
    Name        = "${var.project_name}-${each.key}-logs"
    Environment = var.environment
    LogType     = "application"
    RetentionDays = "30"
  }
}

# Audit logs — 90 days (CloudTrail, VPC flow logs, GuardDuty)
resource "aws_cloudwatch_log_group" "audit_logs" {
  name              = "/aws/eks/${var.project_name}/audit"
  retention_in_days = 90   # Audit logs: 90 days

  tags = {
    Name          = "${var.project_name}-audit-logs"
    Environment   = var.environment
    LogType       = "audit"
    RetentionDays = "90"
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail_logs" {
  name              = "/aws/cloudtrail/${var.project_name}"
  retention_in_days = 90

  tags = {
    Name          = "${var.project_name}-cloudtrail-logs"
    Environment   = var.environment
    LogType       = "audit"
    RetentionDays = "90"
  }
}

# Lambda logs — 30 days
resource "aws_cloudwatch_log_group" "lambda_logs" {
  for_each = toset([
    "/aws/lambda/${var.project_name}-secrets-rotation",
    "/aws/lambda/${var.project_name}-ebs-backup",
  ])

  name              = each.key
  retention_in_days = 30

  tags = {
    Name        = "${var.project_name}-lambda-logs"
    Environment = var.environment
    LogType     = "lambda"
  }
}

# =============================================================================
# CloudWatch Logs Insights Saved Queries
# =============================================================================
# RUBRIC: Write CloudWatch Logs Insights queries (error rate trend, latency percentiles)
# =============================================================================

resource "aws_cloudwatch_query_definition" "api_error_rate" {
  name = "${var.project_name}/api-error-rate-trend"

  log_group_names = [
    "/aws/eks/${var.project_name}/application/user-service",
    "/aws/eks/${var.project_name}/application/product-service",
    "/aws/eks/${var.project_name}/application/cart-service",
    "/aws/eks/${var.project_name}/application/order-service",
    "/aws/eks/${var.project_name}/application/payment-service",
  ]

  query_string = <<-QUERY
    # API Error Rate Trend — shows 5xx error percentage per 5-minute window
    filter @message like /status.*5[0-9][0-9]/ or @message like /"statusCode":5/
    | stats
        count(*) as error_count,
        count(*) / 1 as error_rate
      by bin(5m)
    | sort @timestamp desc
  QUERY
}

resource "aws_cloudwatch_query_definition" "slow_requests" {
  name = "${var.project_name}/slow-requests-above-200ms"

  log_group_names = [
    "/aws/eks/${var.project_name}/application/user-service",
    "/aws/eks/${var.project_name}/application/product-service",
    "/aws/eks/${var.project_name}/application/order-service",
  ]

  query_string = <<-QUERY
    # Slow requests over 200ms — identify latency outliers
    filter @message like /duration/ or @message like /ms/
    | parse @message "duration: *ms" as duration_ms
    | filter duration_ms > 200
    | stats
        count(*) as slow_count,
        avg(duration_ms) as avg_ms,
        max(duration_ms) as max_ms,
        pct(duration_ms, 95) as p95_ms,
        pct(duration_ms, 99) as p99_ms
      by bin(5m)
    | sort @timestamp desc
  QUERY
}

resource "aws_cloudwatch_query_definition" "user_activity" {
  name = "${var.project_name}/user-registrations-and-logins"

  log_group_names = [
    "/aws/eks/${var.project_name}/application/user-service",
  ]

  query_string = <<-QUERY
    # User activity — registrations and logins per hour
    filter @message like /register/ or @message like /login/
    | parse @message "* /api/users/*" as method, endpoint
    | stats count(*) as request_count by endpoint, bin(1h)
    | sort @timestamp desc
  QUERY
}

resource "aws_cloudwatch_query_definition" "db_errors" {
  name = "${var.project_name}/database-connection-errors"

  log_group_names = [
    "/aws/eks/${var.project_name}/application/user-service",
    "/aws/eks/${var.project_name}/application/product-service",
    "/aws/eks/${var.project_name}/application/cart-service",
    "/aws/eks/${var.project_name}/application/order-service",
    "/aws/eks/${var.project_name}/application/payment-service",
  ]

  query_string = <<-QUERY
    # Database connection errors — Prisma P1001/P1002/P1008 errors
    filter @message like /P1001/ or @message like /P1002/ or @message like /database/
      and (@message like /error/ or @message like /Error/ or @message like /failed/)
    | stats count(*) as db_error_count by bin(5m)
    | sort @timestamp desc
    | limit 100
  QUERY
}

resource "aws_cloudwatch_query_definition" "pod_restarts" {
  name = "${var.project_name}/pod-oom-and-crash-loops"

  log_group_names = [
    "/aws/eks/${var.project_name}/application/user-service",
    "/aws/eks/${var.project_name}/application/product-service",
    "/aws/eks/${var.project_name}/application/cart-service",
  ]

  query_string = <<-QUERY
    # OOM kills and crash loops — find pods dying unexpectedly
    filter @message like /OOM/ or @message like /killed/ or @message like /CrashLoopBackOff/
      or @message like /SIGKILL/ or @message like /out of memory/
    | stats count(*) as crash_count by @logStream, bin(1h)
    | sort crash_count desc
  QUERY
}
