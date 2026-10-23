output "repository_urls" {
  description = "Map of service name → ECR repository URL"
  value = {
    for service, repo in aws_ecr_repository.services : service => repo.repository_url
  }
}

output "repository_arns" {
  description = "Map of service name → ECR repository ARN"
  value = {
    for service, repo in aws_ecr_repository.services : service => repo.arn
  }
}

output "all_repository_names" {
  description = "List of all ECR repository names"
  value       = [for repo in aws_ecr_repository.services : repo.name]
}
