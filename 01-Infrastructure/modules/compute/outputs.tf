output "bastion_public_ip" {
  description = "Bastion host public IP"
  value       = aws_instance.bastion.public_ip
}

output "bastion_instance_id" {
  description = "Bastion host instance ID"
  value       = aws_instance.bastion.id
}

output "jenkins_private_ip" {
  description = "Jenkins server private IP"
  value       = aws_instance.jenkins.private_ip
}

output "jenkins_instance_id" {
  description = "Jenkins server instance ID"
  value       = aws_instance.jenkins.id
}

