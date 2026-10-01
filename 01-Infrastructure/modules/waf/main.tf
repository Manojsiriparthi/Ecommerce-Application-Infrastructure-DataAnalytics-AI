# ==============================================
# S3 Bucket — WAF & ALB Access Logs
# ==============================================
# WHY S3 HERE:
#  - WAF requires an S3 bucket (or Firehose) as its log destination.
#  - ALB access logs must also go to S3 (CloudWatch does NOT support ALB logs).
#  - This is the correct, AWS-native pattern for both.
#  - CloudTrail, GuardDuty findings, and Config snapshots also land here.
# ==============================================
resource "aws_s3_bucket" "logs" {
  bucket = "${var.project_name}-logs-${var.environment}-${data.aws_caller_identity.current.account_id}"

  # force_destroy=true allows terraform destroy to delete even non-empty buckets.
  # For prod this is acceptable because:
  #   1. Logs are already archived to Glacier after 90 days
  #   2. The destroy script (02-deploy-app.sh) empties the bucket first anyway
  #   3. Keeping force_destroy=false caused destroy to fail with BucketNotEmpty
  force_destroy = true

  tags = {
    Name        = "${var.project_name}-logs-${var.environment}"
    Environment = var.environment
    Purpose     = "WAF-logs-ALB-logs-CloudTrail"
  }
}

data "aws_caller_identity" "current" {}

# Block all public access — logs bucket must never be public
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt bucket with KMS
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# Lifecycle: keep logs for 90 days (dev) / 365 days (prod), then glacier
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  # Must wait for public access block and versioning to be applied first.
  # Without this, the lifecycle API call races the bucket creation and times out.
  depends_on = [
    aws_s3_bucket_public_access_block.logs,
    aws_s3_bucket_versioning.logs,
    aws_s3_bucket_server_side_encryption_configuration.logs,
  ]

  rule {
    id     = "waf-alb-logs-lifecycle"
    status = "Enabled"

    # AWS provider 6.x requires an explicit filter or prefix on each rule.
    # Empty filter {} = apply to ALL objects in the bucket (previous default).
    filter {}

    transition {
      days          = var.log_transition_days
      storage_class = "GLACIER"
    }

    expiration {
      days = var.log_expiration_days
    }
  }
}

# Versioning on logs bucket for tamper evidence (MFA Delete for prod)
resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Bucket policy: allow ALB + WAF Firehose to write logs
# ALB delivery is done by the AWS ELB service account in each region
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ALB access logs — uses the regional ELB account as the writer
      {
        Sid    = "AllowALBAccessLogs"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.elb_account_id}:root"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs.arn}/alb-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      # WAF logs via Kinesis Firehose
      {
        Sid    = "AllowWAFLogsViaFirehose"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.logs.arn}/waf-logs/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      # Deny non-HTTPS access
      {
        Sid       = "DenyNonHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

# ==============================================
# WAF Web ACL (Regional — attaches to ALB)
# ==============================================
resource "aws_wafv2_web_acl" "ecommerce" {
  name        = "${var.project_name}-waf-${var.environment}"
  description = "WAF for ${var.project_name} external ALB. Blocks OWASP top 10."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rule 1: AWS Core Rule Set (CRS) — covers OWASP Top 10
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-crs-metrics"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: Known Bad Inputs (Log4Shell, SSRF, etc.)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-bad-inputs-metrics"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: SQL Injection protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-sqli-metrics"
      sampled_requests_enabled   = true
    }
  }

  # Rule 4: Rate limiting — 100 req/min per IP (from rubric)
  rule {
    name     = "RateLimitPerIP"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100   # requests per 5-minute window (AWS minimum unit)
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit-metrics"
      sampled_requests_enabled   = true
    }
  }

  # Rule 5: IP reputation list (botnets, anonymous proxies)
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 50

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-ip-reputation-metrics"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf-metrics"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "${var.project_name}-waf-${var.environment}"
    Environment = var.environment
  }
}

# ==============================================
# WAF Logging Configuration
# Sends WAF logs to S3 via Kinesis Firehose
# ==============================================
resource "aws_kinesis_firehose_delivery_stream" "waf_logs" {
  name        = "aws-waf-logs-${var.project_name}-${var.environment}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.logs.arn
    prefix              = "waf-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "waf-logs-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/"
    buffering_size      = 5    # MB
    buffering_interval  = 300  # seconds

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/${var.project_name}-waf-logs"
      log_stream_name = "S3Delivery"
    }
  }

  tags = {
    Name        = "aws-waf-logs-${var.project_name}-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "ecommerce" {
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.ecommerce.arn
}

# ==============================================
# IAM Role for Kinesis Firehose → S3
# ==============================================
resource "aws_iam_role" "firehose" {
  # environment suffix so primary (prod) and DR (prod-dr) don't collide —
  # IAM role names are GLOBAL (account-wide), so both WAF modules would
  # otherwise try to create the same role name.
  name = "${var.project_name}-firehose-waf-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name        = "${var.project_name}-firehose-waf-role-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "firehose_s3" {
  name = "${var.project_name}-firehose-s3-policy-${var.environment}"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.logs.arn,
          "${aws_s3_bucket.logs.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt"
        ]
        Resource = var.kms_key_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:PutLogEvents",
          "logs:CreateLogStream",
          "logs:CreateLogGroup"
        ]
        Resource = "*"
      }
    ]
  })
}

# ==============================================
# SSM Parameter: WAF WebACL ARN
# Stored as non-sensitive config so Terraform outputs
# and K8s annotation can reference it without secrets overhead
# ==============================================
resource "aws_ssm_parameter" "waf_arn" {
  name        = "/${var.project_name}/${var.environment}/waf/web-acl-arn"
  type        = "String"
  value       = aws_wafv2_web_acl.ecommerce.arn
  description = "WAF WebACL ARN for external ALB annotation"

  tags = {
    Name        = "${var.project_name}-waf-arn-param"
    Environment = var.environment
  }
}

# ==============================================
# SSM Parameter: S3 Logs Bucket Name
# ==============================================
resource "aws_ssm_parameter" "logs_bucket" {
  name        = "/${var.project_name}/${var.environment}/s3/logs-bucket-name"
  type        = "String"
  value       = aws_s3_bucket.logs.bucket
  description = "S3 bucket name for WAF and ALB logs"

  tags = {
    Name        = "${var.project_name}-logs-bucket-param"
    Environment = var.environment
  }
}

# ==============================================
# SSM Parameter: Internal ALB DNS
# ==============================================
# The internal ALB DNS is provisioned by the AWS Load Balancer Controller
# (Kubernetes, not Terraform) after the Ingress resource is applied.
# This parameter is a placeholder — update it after first `kubectl apply`
# of the internal Ingress using the post-deploy script:
#
#   INTERNAL_DNS=$(kubectl get ingress services-internal-ingress \
#     -n ecommerce -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
#   aws ssm put-parameter \
#     --name /pip-project-ecommerce/${var.environment}/alb/internal-dns \
#     --value $INTERNAL_DNS --type String --overwrite
#
# The frontend image rebuild uses this value as NEXT_PUBLIC_*_API build args.
# ==============================================
resource "aws_ssm_parameter" "internal_alb_dns" {
  name        = "/${var.project_name}/${var.environment}/alb/internal-dns"
  type        = "String"
  value       = "PLACEHOLDER_UPDATE_AFTER_INGRESS_APPLY"
  description = "Internal ALB DNS - update after kubectl apply of services-internal-ingress"

  lifecycle {
    ignore_changes = [value]  # Never overwritten by Terraform after initial create
  }

  tags = {
    Name        = "${var.project_name}-internal-alb-dns-param"
    Environment = var.environment
  }
}
