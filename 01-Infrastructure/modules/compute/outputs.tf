# =========================================================================
# COMPUTE MODULE OUTPUTS
# =========================================================================

# -------------------------------------------------------------------------
# Key Pair
# -------------------------------------------------------------------------
output "bastion_key_name" {
  description = "EC2 key pair name registered in AWS."
  value       = aws_key_pair.bastion.key_name
}

output "bastion_private_key_path" {
  description = <<-EOT
    Local path where the bastion private key (.pem) was saved.
    Use this to SSH:
      ssh -i <path> ec2-user@<bastion_public_ip>   # Amazon Linux
      ssh -i <path> ubuntu@<bastion_public_ip>      # Ubuntu
    NEVER commit this file to git.
  EOT
  value = local_sensitive_file.bastion_private_key.filename
}

output "bastion_public_key_openssh" {
  description = "Bastion public key in OpenSSH format (safe to share / commit)."
  value       = tls_private_key.bastion.public_key_openssh
}

# -------------------------------------------------------------------------
# Bastion Instance
# -------------------------------------------------------------------------
output "bastion_instance_id" {
  description = "Bastion EC2 instance ID."
  value       = aws_instance.bastion.id
}

output "bastion_public_ip" {
  description = <<-EOT
    Bastion public IP address.
    SSH: ssh -i <key_path> ec2-user@<this_value>
    SSM: aws ssm start-session --target ${aws_instance.bastion.id}
  EOT
  value = aws_instance.bastion.public_ip
}

output "bastion_private_ip" {
  description = "Bastion private IP — for routing rules inside the VPC."
  value       = aws_instance.bastion.private_ip
}

output "ssh_command" {
  description = "Ready-to-use SSH command for the bastion host."
  value       = "ssh -i ${local_sensitive_file.bastion_private_key.filename} ec2-user@${aws_instance.bastion.public_ip}"
}
