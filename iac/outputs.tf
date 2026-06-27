output "ecr_repository_url" {
  description = "ECR Repository URL."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "Name of ECS-Clusters."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of ECS-Service."
  value       = aws_ecs_service.app.name
}

output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = aws_subnet.public[*].id
}
