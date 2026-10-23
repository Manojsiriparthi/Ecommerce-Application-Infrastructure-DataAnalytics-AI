# ==============================================
# VPC
# ==============================================
resource "aws_vpc" "ecommerce" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                                   = "${var.project_name}-vpc"
    Environment                                            = var.environment
    # Required by EKS — allows cluster to discover this VPC and clean up ENIs on destroy
    "kubernetes.io/cluster/${var.project_name}-cluster"    = "shared"
  }

  lifecycle {
    prevent_destroy       = false
    create_before_destroy = false
  }
}

# ==============================================
# Internet Gateway
# ==============================================
resource "aws_internet_gateway" "ecommerce" {
  vpc_id = aws_vpc.ecommerce.id

  tags = {
    Name        = "${var.project_name}-igw"
    Environment = var.environment
  }
}

# ==============================================
# Public Subnets (3 AZs)
# ==============================================
resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.ecommerce.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project_name}-public-${count.index + 1}"
    Environment              = var.environment
    "kubernetes.io/role/elb" = "1"
  }
}

# ==============================================
# Private Subnets (3 AZs) - for EKS worker nodes
# ==============================================
resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.ecommerce.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                              = "${var.project_name}-private-${count.index + 1}"
    Environment                       = var.environment
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# ==============================================
# Database Subnets (3 AZs) - for EKS db nodes + Aurora
# NOTE: These subnets also host the EKS "db_nodes" node
# group, so they need a NAT route (see route table below)
# for nodes to bootstrap and join the cluster.
# ==============================================
resource "aws_subnet" "database" {
  count             = 3
  vpc_id            = aws_vpc.ecommerce.id
  cidr_block        = var.database_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name        = "${var.project_name}-db-${count.index + 1}"
    Environment = var.environment
  }
}

# ==============================================
# NAT Gateway (Single for cost - use 3 for full prod HA)
# ==============================================
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${var.project_name}-nat-eip"
    Environment = var.environment
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_nat_gateway" "ecommerce" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${var.project_name}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.ecommerce]

  lifecycle {
    create_before_destroy = true
  }
}

# ==============================================
# Route Tables - Public
# ==============================================
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.ecommerce.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ecommerce.id
  }

  tags = {
    Name        = "${var.project_name}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = 3
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ==============================================
# Route Tables - Private
# ==============================================
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.ecommerce.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ecommerce.id
  }

  tags = {
    Name        = "${var.project_name}-private-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "private" {
  count          = 3
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ==============================================
# Route Tables - Database
# FIXED: previously had NO internet route at all,
# which permanently blocked the EKS "db_nodes" node
# group from bootstrapping (nodes could never reach
# the EKS API / pull ECR images -> node group hung
# "Still creating..." until timeout). Aurora itself
# does not need this route (it never initiates
# outbound internet connections), so adding it here
# is safe for the database tier.
# ==============================================
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.ecommerce.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.ecommerce.id
  }

  tags = {
    Name        = "${var.project_name}-db-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "database" {
  count          = 3
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

# ==============================================
# DB Subnet Group (for Aurora)
# ==============================================
resource "aws_db_subnet_group" "ecommerce" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id

  tags = {
    Name        = "${var.project_name}-db-subnet-group"
    Environment = var.environment
  }
}

# ==============================================
# NACLs
# ==============================================
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.ecommerce.id
  subnet_ids = aws_subnet.public[*].id

  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name        = "${var.project_name}-public-nacl"
    Environment = var.environment
  }
}

resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.ecommerce.id
  subnet_ids = aws_subnet.private[*].id

  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }

  tags = {
    Name        = "${var.project_name}-private-nacl"
    Environment = var.environment
  }
}

resource "aws_network_acl" "database" {
  vpc_id     = aws_vpc.ecommerce.id
  subnet_ids = aws_subnet.database[*].id

  # Postgres from within the VPC (Aurora clients: EKS nodes, bastion)
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 5432
    to_port    = 5432
  }

  # Return traffic for outbound calls (EKS db_nodes -> internet via NAT)
  ingress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # Intra-VPC traffic (EKS API, VPC DNS resolver, etc.)
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = var.vpc_cidr
    from_port  = 0
    to_port    = 0
  }

  # HTTPS to internet via NAT (EKS API endpoint, ECR, STS, S3) -
  # REQUIRED for db_nodes to bootstrap and join the EKS cluster
  egress {
    rule_no    = 200
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  tags = {
    Name        = "${var.project_name}-db-nacl"
    Environment = var.environment
  }
}

# ==============================================
# Security Groups
# ==============================================

# --- Bastion SG (Public) ---
resource "aws_security_group" "bastion" {
  name                   = "${var.project_name}-bastion-sg"
  description            = "SSH access for bastion host"
  vpc_id                 = aws_vpc.ecommerce.id
  revoke_rules_on_delete = true   # Cleans up rules before deleting SG — prevents ENI dependency loops

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-bastion-sg"
    Environment = var.environment
  }
}

# --- EKS Cluster SG ---
# Attached to the EKS cluster via vpc_config.security_group_ids
# in modules/eks/main.tf (additional SG alongside the AWS-managed
# cluster SG). Self-referencing rule allows all node<->node and
# node<->control-plane traffic tagged with this SG.
resource "aws_security_group" "eks" {
  name                   = "${var.project_name}-eks-sg"
  description            = "EKS cluster security group"
  vpc_id                 = aws_vpc.ecommerce.id
  revoke_rules_on_delete = true

  ingress {
    description = "Allow HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "Node-to-node and node-to-control-plane (self)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-eks-sg"
    Environment = var.environment
  }
}

# --- Aurora DB SG ---
resource "aws_security_group" "aurora" {
  name                   = "${var.project_name}-aurora-sg"
  description            = "Aurora PostgreSQL access from private/db subnets"
  vpc_id                 = aws_vpc.ecommerce.id
  revoke_rules_on_delete = true

  ingress {
    description     = "PostgreSQL from EKS nodes (Terraform-managed SG)"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks.id]
  }

  # NOTE: EKS also auto-creates a second node SG (cluster_security_group_id)
  # that is NOT the same as aws_security_group.eks above. That SG is added
  # via a separate aws_security_group_rule in prod/main.tf (after EKS is
  # created) to avoid a circular dependency between the networking and eks modules.

  ingress {
    description     = "PostgreSQL from bastion"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-aurora-sg"
    Environment = var.environment
  }
}

# --- Jenkins SG (Private) ---
resource "aws_security_group" "jenkins" {
  name                   = "${var.project_name}-jenkins-sg"
  description            = "Jenkins server - HTTPS and Jenkins UI from bastion/VPC only"
  vpc_id                 = aws_vpc.ecommerce.id
  revoke_rules_on_delete = true

  ingress {
    description     = "Jenkins UI (8080) from bastion"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description = "HTTPS (443) from within VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-jenkins-sg"
    Environment = var.environment
  }
}

# =============================================================================
# VPC ENDPOINTS (PrivateLink) — keeps AWS service traffic private + saves NAT cost
# =============================================================================
# WHY:
#   Without VPC endpoints, pods in private subnets reach AWS services
#   (ECR, S3, Secrets Manager, SSM, CloudWatch, STS, KMS) via NAT Gateway.
#   That costs $0.045/GB data processing + traffic goes over the internet.
#
#   With VPC endpoints:
#     - Traffic stays WITHIN the AWS network (no internet round-trip)
#     - No NAT data processing charges for these services
#     - Faster (1-2ms latency vs 20-50ms via NAT + internet)
#     - More secure (no public internet exposure)
#
# ENDPOINT TYPES:
#   Interface endpoints (ENI in subnet, private DNS):
#     ECR API, ECR DKR, Secrets Manager, SSM, CloudWatch Logs, STS, KMS
#   Gateway endpoint (route table entry, no ENI):
#     S3 (gateway is free — no hourly charge, no data charge)
# =============================================================================

# ── Security Group for interface endpoints ────────────────────────────────────
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-vpc-endpoints-sg"
  description = "Allow HTTPS from VPC to VPC interface endpoints"
  vpc_id      = aws_vpc.ecommerce.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project_name}-vpc-endpoints-sg"
    Environment = var.environment
  }
}

# ── Interface endpoints (ECR, Secrets Manager, SSM, Logs, STS, KMS) ───────────
locals {
  interface_endpoints = [
    "ecr.api",            # ECR API — list/describe repos
    "ecr.dkr",            # ECR Docker — push/pull images
    "secretsmanager",     # Secrets Manager — read secrets
    "ssm",                # SSM Parameter Store — read parameters
    "logs",               # CloudWatch Logs — write pod logs
    "sts",                # STS — IRSA token exchange
    "kms",                # KMS — decrypt encrypted secrets
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each              = toset(local.interface_endpoints)
  vpc_id                = aws_vpc.ecommerce.id
  service_name          = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type     = "Interface"
  private_dns_enabled   = true
  subnet_ids            = aws_subnet.private[*].id
  security_group_ids    = [aws_security_group.vpc_endpoints.id]

  tags = {
    Name        = "${var.project_name}-${each.value}-endpoint"
    Environment = var.environment
    Service     = each.value
  }
}

# ── Gateway endpoint for S3 (free — no hourly charge) ────────────────────────
# Routes S3 traffic through the VPC instead of the internet gateway.
# This is the biggest cost saver — ECR images are stored in S3 behind the scenes.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.ecommerce.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]

  tags = {
    Name        = "${var.project_name}-s3-endpoint"
    Environment = var.environment
  }
}
