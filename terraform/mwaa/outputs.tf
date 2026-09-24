output "mwaa_environment_name" {
  value       = aws_mwaa_environment.airflow.name
  description = "Name of the MWAA Airflow environment (e.g., chedaws-edp-mwaa-dev)"
}

output "mwaa_webserver_url" {
  value       = aws_mwaa_environment.airflow.webserver_url
  description = "HTTPS URL of the MWAA Airflow web server (reachable via VPN or Direct Connect)"
}

output "mwaa_s3_bucket_name" {
  value       = module.mwaa_s3.s3_bucket_id
  description = "Name of the MWAA DAGs/plugins S3 bucket"
}

output "mwaa_execution_role_arn" {
  value       = aws_iam_role.mwaa_execution.arn
  description = "ARN of the MWAA execution IAM role"
}

output "mwaa_namespace_role_arns" {
  value       = { for k, v in aws_iam_role.mwaa_namespace : k => v.arn }
  description = "Map of namespace name to IAM role ARN for all active MWAA namespaces"
}

output "mwaa_namespace_ci_role_arns" {
  value       = { for k, v in aws_iam_role.mwaa_namespace_ci : k => v.arn }
  description = "Map of namespace name to CI-only IAM role ARN (S3 DAG prefix write; namespaces with ci_roles only)"
}

output "mwaa_fargate_cluster_arn" {
  value       = aws_ecs_cluster.mwaa_fargate.arn
  description = "ARN of the shared ECS Fargate cluster used by all MWAA Fargate-enabled namespaces"
}

output "mwaa_ecr_repository_urls" {
  value       = { for k, v in aws_ecr_repository.mwaa_namespace : k => v.repository_url }
  description = "Map of namespace name to ECR repository URL (Fargate-enabled namespaces only)"
}
