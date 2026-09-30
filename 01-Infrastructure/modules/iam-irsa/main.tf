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
