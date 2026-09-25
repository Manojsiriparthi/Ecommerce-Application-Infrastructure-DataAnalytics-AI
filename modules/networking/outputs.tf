output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "Database subnet IDs"
  value       = aws_subnet.database[*].id
}

output "db_subnet_group_name" {
  description = "DB subnet group name for Aurora"
  value       = aws_db_subnet_group.this.name
}

output "bastion_sg_id" {
  description = "Bastion security group ID"
  value       = aws_security_group.bastion.id
}

output "eks_sg_id" {
  description = "EKS security group ID"
  value       = aws_security_group.eks.id
}

output "aurora_sg_id" {
  description = "Aurora security group ID"
  value       = aws_security_group.aurora.id
}

output "jenkins_sg_id" {
  description = "Jenkins security group ID"
  value       = aws_security_group.jenkins.id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID - used as an explicit dependency so EKS node groups (private/db subnets) wait until the NAT route is actually available before bootstrapping"
  value       = aws_nat_gateway.this.id
}

output "private_route_table_association_ids" {
  description = "Private route table association IDs - forces node groups to wait until the private subnets actually have a route to the internet, not just until the subnets exist"
  value       = aws_route_table_association.private[*].id
}

output "database_route_table_association_ids" {
  description = "Database route table association IDs - same purpose as above, for the db_nodes node group"
  value       = aws_route_table_association.database[*].id
}
