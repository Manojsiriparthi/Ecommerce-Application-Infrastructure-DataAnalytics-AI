# ==============================================
# ElastiCache Redis — Session & Cart Caching
# ==============================================
# WHY ELASTICACHE (Redis) FOR THIS PROJECT:
#
#  1. SESSION STORE (user-service)
#     JWT tokens are stateless — once issued, you cannot invalidate
#     them without a token blacklist. Redis stores blacklisted/logged-out
#     token JTIs with a TTL matching the JWT expiry (1 hour). Zero
#     Aurora queries needed per auth check.
#
#  2. CART CACHING (cart-service)
#     Cart data is read on every page view. Storing the active cart
#     in Redis (TTL 24h) means zero DB hits for the most frequent
#     operation. Cart is written to Aurora only on checkout. This is
#     the standard pattern for high-traffic e-commerce (Amazon, Shopify).
#
#  3. RATE-LIMIT COUNTERS (API gateway / services)
#     Redis atomic INCR + EXPIRE gives per-IP/per-user rate counters
#     that work correctly across all pod replicas — impossible with
#     in-process memory counters.
#
#  4. IDEMPOTENCY KEYS (payment-service)
#     Payment retries must not double-charge. Redis stores payment
#     idempotency keys with a short TTL (5 min) as the deduplication
#     store — far cheaper and faster than a DB unique constraint check.
#
#  IMPORTANT: ElastiCache is in PRIVATE subnets (same tier as EKS
#  workers), NOT database subnets. It is NOT a database — it is
#  ephemeral cache. Aurora lives in database subnets.
# ==============================================

# Security Group for ElastiCache
resource "aws_security_group" "elasticache" {
  name        = "${var.project_name}-elasticache-sg"
  description = "ElastiCache Redis — allow port 6379 from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS worker nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_sg_id]
  }

  egress {
    description = "Allow all outbound (for cluster bus port 16379)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-elasticache-sg"
    Environment = var.environment
  }
}

# Subnet Group — uses private subnets (NOT database subnets)
resource "aws_elasticache_subnet_group" "ecommerce" {
  name        = "${var.project_name}-redis-subnet-group"
  description = "Private subnet group for ElastiCache Redis"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name        = "${var.project_name}-redis-subnet-group"
    Environment = var.environment
  }
}

# Parameter Group — Redis 7.x with sensible defaults
resource "aws_elasticache_parameter_group" "ecommerce" {
  family      = "redis7"
  name        = "${var.project_name}-redis-params"
  description = "Redis parameter group for ${var.project_name}"

  # Require TLS-capable clients (enforced at cluster level too)
  parameter {
    name  = "tcp-keepalive"
    value = "300"
  }

  # Evict Least Recently Used keys when memory is full
  # (appropriate for a cache — never run out of memory silently)
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = {
    Name        = "${var.project_name}-redis-params"
    Environment = var.environment
  }
}

# ==============================================
# ElastiCache Replication Group (Redis Cluster Mode Disabled)
# — 1 primary + var.num_replicas read replicas across AZs
# — Multi-AZ with automatic failover enabled
# — In-transit and at-rest encryption both enabled
# — Auth token stored in Secrets Manager (not plain env var)
# ==============================================
resource "aws_elasticache_replication_group" "ecommerce" {
  replication_group_id = "${var.project_name}-redis"
  description          = "Redis cache for ${var.project_name} — sessions, cart, rate-limits"

  node_type            = var.node_type
  num_cache_clusters   = var.num_replicas + 1  # 1 primary + replicas
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.ecommerce.name
  subnet_group_name    = aws_elasticache_subnet_group.ecommerce.name
  security_group_ids   = [aws_security_group.elasticache.id]

  engine               = "redis"
  engine_version       = var.engine_version

  # High availability
  multi_az_enabled           = var.num_replicas > 0
  automatic_failover_enabled = var.num_replicas > 0

  # Security — in-transit TLS + at-rest KMS
  at_rest_encryption_enabled  = true
  transit_encryption_enabled  = true
  transit_encryption_mode     = "required"
  kms_key_id                  = var.kms_key_arn

  # Auth token from Secrets Manager (Terraform reads it here at provision time;
  # the actual token value is stored in Secrets Manager and pods retrieve it
  # via the Secrets Store CSI driver — never in env vars)
  auth_token                  = var.auth_token

  # Maintenance & backup
  maintenance_window       = var.maintenance_window
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = var.snapshot_window

  # Notifications
  notification_topic_arn = var.sns_topic_arn != "" ? var.sns_topic_arn : null

  apply_immediately = var.environment == "dev" ? true : false

  lifecycle {
    ignore_changes = [auth_token]  # Prevent accidental rotation from triggering replace
  }

  tags = {
    Name        = "${var.project_name}-redis"
    Environment = var.environment
    Purpose     = "session-cache,cart-cache,rate-limits,idempotency"
  }
}

# ==============================================
# Secrets Manager — Redis Auth Token
# ==============================================
# Stores the Redis AUTH token so pods never see it in env vars.
# Pods use the Secrets Store CSI driver + IRSA to fetch it at startup.
resource "aws_secretsmanager_secret" "redis_auth" {
  name                    = "${var.project_name}/${var.environment}/redis/auth-token"
  kms_key_id              = var.kms_key_arn
  description             = "Redis AUTH token for ElastiCache"
  recovery_window_in_days = 0

  tags = {
    Name        = "${var.project_name}-redis-auth-secret"
    Environment = var.environment
  }

  lifecycle {
    ignore_changes = [name]
  }
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = jsonencode({
    auth_token = var.auth_token
    host       = aws_elasticache_replication_group.ecommerce.primary_endpoint_address
    port       = "6379"
    tls        = "true"
  })
}

# ==============================================
# SSM Parameters — non-sensitive Redis config
# ==============================================
# Redis endpoint (hostname only — not a secret, just config)
resource "aws_ssm_parameter" "redis_host" {
  name        = "/${var.project_name}/${var.environment}/redis/primary-endpoint"
  type        = "String"
  value       = aws_elasticache_replication_group.ecommerce.primary_endpoint_address
  description = "ElastiCache Redis primary endpoint hostname"

  tags = {
    Name        = "${var.project_name}-redis-host-param"
    Environment = var.environment
  }
}

resource "aws_ssm_parameter" "redis_port" {
  name        = "/${var.project_name}/${var.environment}/redis/port"
  type        = "String"
  value       = "6379"
  description = "ElastiCache Redis port"

  tags = {
    Name        = "${var.project_name}-redis-port-param"
    Environment = var.environment
  }
}

# ==============================================
# CloudWatch Alarms for Redis
# ==============================================
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${var.project_name}-redis-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 70
  alarm_description   = "Redis CPU > 70% for 10 minutes"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.ecommerce.id
  }

  tags = {
    Name        = "${var.project_name}-redis-cpu-alarm"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${var.project_name}-redis-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Redis memory usage > 80%"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.ecommerce.id
  }

  tags = {
    Name        = "${var.project_name}-redis-memory-alarm"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_connections" {
  alarm_name          = "${var.project_name}-redis-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CurrConnections"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 1000
  alarm_description   = "Redis connections > 1000"
  alarm_actions       = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.ecommerce.id
  }

  tags = {
    Name        = "${var.project_name}-redis-connections-alarm"
    Environment = var.environment
  }
}
