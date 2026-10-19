# Account ID — used for building EventBridge rule ARNs in the SQS queue policy
data "aws_caller_identity" "current" {}

# ==============================================
# EBS CSI Driver IRSA Role
# ==============================================
resource "aws_iam_role" "ebs_csi" {
  name = "${var.project_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-ebs-csi-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi.name
}

# ==============================================
# AWS Load Balancer Controller IRSA Role
# ==============================================
resource "aws_iam_role" "lb_controller" {
  name = "${var.project_name}-lb-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-lb-controller-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  role       = aws_iam_role.lb_controller.name
}

# Additional EC2 permissions required by ALB controller to create/manage
# security groups for ALBs. Without this: ec2:CreateSecurityGroup 403 error.
resource "aws_iam_policy" "lb_controller_ec2" {
  name        = "${var.project_name}-lb-controller-ec2-policy"
  description = "EC2 permissions for AWS Load Balancer Controller to manage ALB security groups"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeAddresses",
        "ec2:DescribeAccountAttributes",
        "ec2:ModifyNetworkInterfaceAttribute",
        "wafv2:GetWebACL",
        "wafv2:GetWebACLForResource",
        "wafv2:AssociateWebACL",
        "wafv2:DisassociateWebACL",
        "wafv2:ListResourcesForWebACL",
        "waf-regional:GetWebACLForResource",
        "waf-regional:GetWebACL",
        "waf-regional:AssociateWebACL",
        "waf-regional:DisassociateWebACL",
        "shield:GetSubscriptionState",
        "cognito-idp:DescribeUserPoolClient",
        "acm:ListCertificates",
        "acm:DescribeCertificate",
        "iam:CreateServiceLinkedRole",
        "tag:GetResources",
        "tag:TagResources"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller_ec2" {
  policy_arn = aws_iam_policy.lb_controller_ec2.arn
  role       = aws_iam_role.lb_controller.name
}

# ==============================================
# Cluster Autoscaler IRSA Role
# ==============================================
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.project_name}-cluster-autoscaler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-cluster-autoscaler-role"
    Environment = var.environment
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name = "${var.project_name}-cluster-autoscaler-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeLaunchTemplateVersions"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
  role       = aws_iam_role.cluster_autoscaler.name
}

# ==============================================
# Ecommerce Services IRSA Role
# Used by: all backend pods via ecommerce-services-sa ServiceAccount
# Grants access to:
#   - Secrets Manager: DB creds, Redis auth token, JWT secret
#   - SSM Parameter Store: Redis host, SNS ARN, internal ALB DNS, etc.
#   - SNS: user-service, product-service, notification-service publish events
#   - SES: notification-service sends emails
# ==============================================
resource "aws_iam_role" "ecommerce_services" {
  name = "${var.project_name}-services-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:ecommerce:ecommerce-services-sa"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-services-role"
    Environment = var.environment
  }
}

resource "aws_iam_policy" "ecommerce_services" {
  name        = "${var.project_name}-services-policy"
  description = "Allows backend pods to read secrets, publish SNS, send SES"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ---- Secrets Manager: read project secrets ----
      # Pattern covers BOTH naming styles:
      #   pip-project-ecommerce-db-credentials (hyphen style, no path)
      #   pip-project-ecommerce/prod/redis/auth-token (path style)
      # The -* suffix covers the random 6-char suffix AWS appends to secret ARNs
      {
        Sid    = "ReadSecretsManager"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Include BOTH var.project_name AND the base "pip-project-ecommerce".
        # For the DR module, var.project_name is "pip-project-ecommerce-dr", but
        # the secrets are named with the base "pip-project-ecommerce/prod/..."
        # (same names, replicated to the DR region). Without the base-name ARN,
        # DR pods get AccessDeniedException on secretsmanager:GetSecretValue.
        Resource = [
          "arn:aws:secretsmanager:*:*:secret:${var.project_name}-*",
          "arn:aws:secretsmanager:*:*:secret:${var.project_name}/*",
          "arn:aws:secretsmanager:*:*:secret:pip-project-ecommerce-*",
          "arn:aws:secretsmanager:*:*:secret:pip-project-ecommerce/*"
        ]
      },
      # ---- SSM Parameter Store ----
      {
        Sid    = "ReadSSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:*:*:parameter/${var.project_name}/*",
          "arn:aws:ssm:*:*:parameter/pip-project-ecommerce/*"
        ]
      },
      # ---- KMS: decrypt secrets from Secrets Manager AND SSM SecureString ----
      {
        Sid    = "DecryptKMS"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            # sns added: publishing to a KMS-encrypted SNS topic calls
            # kms:GenerateDataKey VIA sns.amazonaws.com. Without this, login
            # (which publishes USER_LOGIN_SUCCESS) fails with KMSAccessDenied.
            "kms:ViaService" = [
              "secretsmanager.*.amazonaws.com",
              "ssm.*.amazonaws.com",
              "sns.*.amazonaws.com"
            ]
          }
        }
      },
      # ---- SNS: publish events (user registered, order placed, etc.) ----
      {
        Sid    = "PublishSNS"
        Effect = "Allow"
        Action = ["sns:Publish"]
        Resource = "arn:aws:sns:*:*:${var.project_name}-*"
      },
      # ---- SES: notification-service sends transactional emails ----
      {
        Sid    = "SendSES"
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        Resource = "*"
      },
      # ---- ECR: pull container images ----
      {
        Sid    = "PullECR"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecommerce_services" {
  policy_arn = aws_iam_policy.ecommerce_services.arn
  role       = aws_iam_role.ecommerce_services.name
}

# ==============================================
# Secrets Store CSI Driver IRSA Role
# Needed by the CSI driver itself (kube-system) to call
# Secrets Manager and SSM on behalf of pods
# ==============================================
resource "aws_iam_role" "secrets_store_csi" {
  name = "${var.project_name}-secrets-store-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:secrets-store-csi-driver"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-secrets-store-csi-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "secrets_store_csi" {
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  role       = aws_iam_role.secrets_store_csi.name
}

# Secrets Store CSI driver also needs SSM + KMS permissions
resource "aws_iam_policy" "secrets_store_csi_policy" {
  name        = "${var.project_name}-secrets-store-csi-policy"
  description = "SSM + KMS permissions for Secrets Store CSI driver"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        # Base-name ARNs included so the DR CSI role (var.project_name =
        # "pip-project-ecommerce-dr") can still read "pip-project-ecommerce/..."
        # secrets replicated into the DR region.
        Resource = [
          "arn:aws:secretsmanager:*:*:secret:${var.project_name}-*",
          "arn:aws:secretsmanager:*:*:secret:${var.project_name}/*",
          "arn:aws:secretsmanager:*:*:secret:pip-project-ecommerce-*",
          "arn:aws:secretsmanager:*:*:secret:pip-project-ecommerce/*"
        ]
      },
      {
        Sid    = "SSMRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = [
          "arn:aws:ssm:*:*:parameter/${var.project_name}/*",
          "arn:aws:ssm:*:*:parameter/pip-project-ecommerce/*"
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "kms:ViaService" = [
              "secretsmanager.*.amazonaws.com",
              "ssm.*.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "secrets_store_csi_custom" {
  policy_arn = aws_iam_policy.secrets_store_csi_policy.arn
  role       = aws_iam_role.secrets_store_csi.name
}

# ==============================================
# CloudWatch Observability IRSA Role
# Used by: amazon-cloudwatch-observability EKS addon
#   - CloudWatch Agent (node/pod metrics → Container Insights)
#   - ADOT collector (app traces → X-Ray)
#
# Service account: cloudwatch-agent (kube-system)
# AWS-managed policy covers all required CW, X-Ray, and EC2 permissions.
# ==============================================
resource "aws_iam_role" "cloudwatch_observability" {
  name = "${var.project_name}-cloudwatch-observability-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-cloudwatch-observability-role"
    Environment = var.environment
  }
}

# AWS-managed policy: grants Container Insights + ADOT all required permissions
# (CloudWatch PutMetricData, logs:*, xray:*, ec2:Describe*, etc.)
resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.cloudwatch_observability.name
}

# X-Ray write access for ADOT traces
resource "aws_iam_role_policy_attachment" "cloudwatch_observability_xray" {
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
  role       = aws_iam_role.cloudwatch_observability.name
}

# =============================================================================
# KARPENTER — SQS QUEUE + EVENTBRIDGE RULES (created before the role so the
# role policy can scope to the real queue ARN in a single terraform apply)
# =============================================================================
# WHY HERE (not in eks-addons):
#   The Karpenter IRSA role needs the SQS queue ARN to scope its sqs:ReceiveMessage
#   permission. If the queue were created in eks_addons (which runs AFTER iam_irsa),
#   the role policy would need a wildcard "*" or a second terraform apply.
#   By creating the queue here, the role policy is scoped correctly on apply #1.
#
# The queue NAME is output and passed to eks_addons for the Helm chart setting
# `settings.interruptionQueueName`.
# =============================================================================

# ── SQS queue for interruption events ────────────────────────────────────────
resource "aws_sqs_queue" "karpenter_interruption" {
  name                       = "${var.project_name}-karpenter-interruption"
  message_retention_seconds  = 300
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  tags = {
    Name        = "${var.project_name}-karpenter-interruption"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridge"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = "arn:aws:events:${var.region}:${data.aws_caller_identity.current.account_id}:rule/${var.project_name}-karpenter-*"
          }
        }
      }
    ]
  })
}

# ── EventBridge rules → forward interruption events to the SQS queue ──────────
resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "${var.project_name}-karpenter-spot-interruption"
  description = "Spot instance interruption warning (2 min before termination)"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = {
    Name        = "${var.project_name}-karpenter-spot-rule"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_scheduled_change" {
  name        = "${var.project_name}-karpenter-scheduled-change"
  description = "AWS health scheduled maintenance events"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
    detail = {
      service           = ["EC2"]
      eventTypeCategory = ["scheduledChange"]
    }
  })

  tags = {
    Name        = "${var.project_name}-karpenter-health-rule"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "karpenter_scheduled_change" {
  rule      = aws_cloudwatch_event_rule.karpenter_scheduled_change.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "${var.project_name}-karpenter-rebalance"
  description = "Spot rebalance recommendation — start migrating before interruption"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Rebalance Recommendation"]
  })

  tags = {
    Name        = "${var.project_name}-karpenter-rebalance-rule"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule      = aws_cloudwatch_event_rule.karpenter_rebalance.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ==============================================
# Karpenter IRSA Role
# ==============================================
# WHAT KARPENTER DOES WITH THESE PERMISSIONS:
#   ec2:RunInstances                → launch EC2 nodes for pending pods
#   ec2:CreateTags / DeleteTags      → tag nodes with cluster + workload metadata
#   ec2:Describe*                    → discover available instance types + AZs
#   iam:PassRole                     → pass the EKS node role to new EC2 instances
#   sqs:ReceiveMessage / DeleteMessage → read Spot interruption events from the
#                                       Karpenter interruption queue
#   pricing:GetProducts              → query AWS for Spot pricing
#
# SUBNET + SG DISCOVERY:
#   Karpenter discovers subnets and SGs by the cluster tag
#   karpenter.sh/discovery=<cluster-name>. The EKS module must add this tag
#   to its subnets (set in networking module) and the node SG.
# ==============================================
resource "aws_iam_role" "karpenter" {
  name = "${var.project_name}-karpenter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name        = "${var.project_name}-karpenter-role"
    Environment = var.environment
  }
}

resource "aws_iam_policy" "karpenter" {
  name        = "${var.project_name}-karpenter-policy"
  description = "Permissions for Karpenter controller — launch EC2 nodes, pass node role, read Spot interruption queue"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2RunInstances"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DeleteTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.region
          }
        }
      },
      {
        Sid    = "PassRoleToEC2"
        Effect = "Allow"
        Action = "iam:PassRole"
        # Karpenter must pass the EKS node role to new EC2 instances.
        # Scoped to the node role ARN only — not wildcard.
        Resource = var.karpenter_node_role_arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid    = "SpotInterruptionQueue"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        # Scoped to the actual Karpenter interruption queue ARN (created above
        # in this same module — single apply, no wildcard, no second pass)
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        Sid    = "Pricing"
        Effect = "Allow"
        Action = "pricing:GetProducts"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  policy_arn = aws_iam_policy.karpenter.arn
  role       = aws_iam_role.karpenter.name
}
