# =============================================================================
# ECR — Container Registry with scan-on-push + lifecycle policies
# =============================================================================
# WHAT THIS MODULE CREATES:
#   - 1 ECR repository per service (7 repos: frontend + 6 backend services)
#   - Scan-on-push enabled (Trivy/Inspector scans every image on push)
#   - Immutable tags (prevents overwriting — each tag is locked)
#   - Lifecycle policy (keep last 10 tagged, delete untagged after 1 day)
#   - KMS encryption at rest
#
# WHY SCAN-ON-PUSH:
#   Trivy in the CI pipeline scans images at build time. But if someone pushes
#   directly to ECR (bypassing CI), there's no scan. Scan-on-push catches that.
#   Also catches new CVEs published AFTER the image was built — re-scan on
#   push reveals them.
#
# WHY IMMUTABLE TAGS:
#   Prevents `docker push myrepo:v1` from overwriting an existing v1 tag.
#   If v1 is already pushed, you must use v2. This prevents accidental rollbacks
#   and ensures audit trail — every tag maps to exactly one image.
#
# WHY LIFECYCLE POLICY:
#   ECR charges $0.10/GB/month for storage. Each image ~500MB-1GB.
#   After 100 builds = 50-100 GB = $5-10/month wasted on old images.
#   Lifecycle policy keeps last 10 tagged images, deletes the rest.
# =============================================================================

locals {
  services = [
    "frontend",
    "user-service",
    "product-service",
    "cart-service",
    "order-service",
    "payment-service",
    "notification-service",
  ]
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
resource "aws_ecr_repository" "services" {
  for_each             = toset(local.services)
  name                 = "${var.project_name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"   # tags cannot be overwritten
  scan_on_push         = true          # vulnerability scan on every push

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "${var.project_name}-${each.value}"
    Environment = var.environment
    ManagedBy   = "terraform"
    Service     = each.value
  }
}

# ── Lifecycle Policy — keep last 10 tagged, delete untagged after 1 day ───────
resource "aws_ecr_lifecycle_policy" "services" {
  for_each = toset(local.services)
  repository = aws_ecr_repository.services[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images, expire the rest"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 10
          tagPrefixList = ["v", "latest", "main", "dev", "prod"]
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Registry scanning policy — enhanced scan with Inspector ──────────────────
# Enhanced scanning uses Amazon Inspector for deeper vulnerability analysis
# (OS packages + language packages: npm, pip, maven, etc.)
resource "aws_ecr_registry_scanning_configuration" "enhanced" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "${var.project_name}/*"
      filter_type = "WILDCARD"
    }
  }
}
