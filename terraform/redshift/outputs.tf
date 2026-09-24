output "redshift_cluster_identifier" {
  value       = aws_redshift_cluster.this.cluster_identifier
  description = "The cluster identifier used in AWS (e.g., chedaws-edp-dev)"
}

output "redshift_cluster_endpoint" {
  value       = aws_redshift_cluster.this.dns_name
  description = "The DNS endpoint of the Redshift cluster (host only, without port)"
}

output "redshift_cluster_port" {
  value       = aws_redshift_cluster.this.port
  description = "The port the cluster listens on (always 5439)"
}

output "redshift_database_name" {
  value       = aws_redshift_cluster.this.database_name
  description = "The name of the default database (edp)"
}

output "redshift_master_secret_arn" {
  value       = aws_secretsmanager_secret.redshift_password.arn
  description = "ARN of the Secrets Manager secret holding the master username and password (JSON: {username, password})"
}

output "redshift_security_group_id" {
  value       = aws_security_group.redshift.id
  description = "ID of the Redshift security group"
}

output "redshift_idc_svc_role_arn" {
  value       = aws_iam_role.redshift_idc_svc.arn
  description = "ARN of the Redshift IdC application service role"
}

output "redshift_idc_application_arn" {
  value       = aws_redshift_idc_application.this.redshift_idc_application_arn
  description = "ARN of the registered Redshift IdC application"
}

output "redshift_load_role_arns" {
  value       = data.aws_iam_roles.redshift_load.arns
  description = "ARNs of the Redshift load roles"
}
