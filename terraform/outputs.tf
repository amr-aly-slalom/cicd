output "aws_account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "The AWS account ID of the account where this Terraform is being applied."
}

output "redshift_kms_key_arn" {
  value       = module.kms["redshift"].key_arn
  description = "ARN of the KMS CMK used for Redshift encryption at rest"
}

output "redshift_sns_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN of the shared EDP CloudWatch alerts SNS topic"
}

output "sns_kms_key_arn" {
  value       = module.kms["sns"].key_arn
  description = "ARN of the KMS CMK used for SNS alert topic encryption at rest"
}

output "cloudwatch_logs_kms_key_arn" {
  value       = module.kms["cloudwatch_logs"].key_arn
  description = "ARN of the KMS CMK used for CloudWatch Log Group encryption at rest"
}

output "secretsmanager_kms_key_arn" {
  value       = module.kms["secretsmanager"].key_arn
  description = "ARN of the KMS CMK used for Secrets Manager secret encryption at rest"
}

output "dms_kms_key_arn" {
  value       = module.kms["dms"].key_arn
  description = "ARN of the KMS CMK used for AWS DMS resource encryption at rest"
}

output "platform_s3_kms_key_arn" {
  value       = module.kms["s3"].key_arn
  description = "ARN of the KMS CMK used for platform S3 bucket encryption at rest"
}

output "platform_s3_bucket_arn" {
  value       = module.platform_s3.s3_bucket_arn
  description = "ARN of the shared platform S3 bucket"
}

output "platform_s3_bucket_name" {
  value       = module.platform_s3.s3_bucket_id
  description = "Name of the shared platform S3 bucket (globally unique)"
}

