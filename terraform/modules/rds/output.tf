# ------------------------------------------------------------------------------
# INSTANCE IDENTITY & CONNECTIVITY
# ------------------------------------------------------------------------------
output "db_instance_id" {
  description = "The RDS instance ID."
  value       = aws_db_instance.this.id
}

output "db_instance_arn" {
  description = "The ARN of the RDS instance."
  value       = aws_db_instance.this.arn
}

output "db_instance_identifier" {
  description = "The RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "db_instance_resource_id" {
  description = "The RDS Resource ID of this instance, useful for IAM auth policies."
  value       = aws_db_instance.this.resource_id
}

output "db_instance_status" {
  description = "The RDS instance status."
  value       = aws_db_instance.this.status
}

output "db_instance_endpoint" {
  description = "The connection endpoint in the form of address:port."
  value       = aws_db_instance.this.endpoint
}

output "db_instance_address" {
  description = "The hostname of the RDS instance."
  value       = aws_db_instance.this.address
}

output "db_instance_port" {
  description = "The port the database is listening on."
  value       = aws_db_instance.this.port
}

output "db_instance_hosted_zone_id" {
  description = "The canonical hosted zone ID of the DB instance (for Route53 alias records)."
  value       = aws_db_instance.this.hosted_zone_id
}

output "db_name" {
  description = "The database name (null for read replicas)."
  value       = local.db_name
}

output "jdbc_connection_string" {
  description = "Engine-aware JDBC connection string (does not include credentials)."
  value       = local.jdbc_url
}

# ------------------------------------------------------------------------------
# CREDENTIALS
# ------------------------------------------------------------------------------
output "db_instance_username" {
  description = "The master username (null for read replicas)."
  value       = local.username
}

output "db_instance_password" {
  description = "The master password. Null when use_managed_master_password is enabled (see master_user_secret) or for read replicas."
  value       = local.password
  sensitive   = true
}

output "master_user_secret" {
  description = "RDS-managed master user secret metadata (Secrets Manager), populated only when use_managed_master_password is true."
  value       = try(aws_db_instance.this.master_user_secret, [])
  sensitive   = true
}

output "secrets_manager_secret_arn" {
  description = "ARN of the module-managed Secrets Manager secret holding DB credentials, if created."
  value       = try(aws_secretsmanager_secret.db_credentials[0].arn, null)
}

output "secrets_manager_secret_name" {
  description = "Name of the module-managed Secrets Manager secret holding DB credentials, if created."
  value       = try(aws_secretsmanager_secret.db_credentials[0].name, null)
}

# ------------------------------------------------------------------------------
# NETWORKING & GROUPS
# ------------------------------------------------------------------------------
output "db_subnet_group_id" {
  description = "The db subnet group name in use (module-created or user-supplied)."
  value       = try(aws_db_subnet_group.this[0].id, var.subnet_group_name)
}

output "db_subnet_group_arn" {
  description = "ARN of the module-created db subnet group, if created."
  value       = try(aws_db_subnet_group.this[0].arn, null)
}

output "db_parameter_group_id" {
  description = "The name of the DB parameter group in use."
  value       = aws_db_parameter_group.this.id
}

output "db_parameter_group_arn" {
  description = "ARN of the DB parameter group."
  value       = aws_db_parameter_group.this.arn
}

output "db_option_group_id" {
  description = "The name of the DB option group, if created."
  value       = try(aws_db_option_group.this[0].id, null)
}

output "db_option_group_arn" {
  description = "ARN of the DB option group, if created."
  value       = try(aws_db_option_group.this[0].arn, null)
}

output "vpc_security_group_ids" {
  description = "Security group IDs attached to the RDS instance."
  value       = aws_db_instance.this.vpc_security_group_ids
}

# ------------------------------------------------------------------------------
# IAM ROLES
# ------------------------------------------------------------------------------
output "monitoring_role_arn" {
  description = "ARN of the enhanced monitoring IAM role, if created."
  value       = try(aws_iam_role.rds_monitoring[0].arn, null)
}

output "integration_role_arns" {
  description = "Map of integration name to IAM role ARN, for engine integrations (S3 import/export, etc.)."
  value       = { for k, v in aws_iam_role.integration_roles : k => v.arn }
}

# ------------------------------------------------------------------------------
# CLOUDWATCH LOGS
# ------------------------------------------------------------------------------
output "cloudwatch_log_group_names" {
  description = "Map of exported log type to created CloudWatch log group name."
  value       = { for k, v in aws_cloudwatch_log_group.db_logs : k => v.name }
}

output "cloudwatch_log_group_arns" {
  description = "Map of exported log type to created CloudWatch log group ARN."
  value       = { for k, v in aws_cloudwatch_log_group.db_logs : k => v.arn }
}

# ------------------------------------------------------------------------------
# MISC
# ------------------------------------------------------------------------------
output "is_replica" {
  description = "Whether this instance was created as a read replica."
  value       = local.is_replica
}

output "engine" {
  description = "The RDS engine used, passed through for convenience in downstream modules."
  value       = var.engine
}