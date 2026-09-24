output "s3_producer_role_arns" {
  value = merge(
    { for k, v in aws_iam_role.s3_namespace_aws_producer : k => v.arn },
    { for k, v in aws_iam_role.s3_namespace_onprem_producer : k => v.arn },
    { for k, v in aws_iam_role.s3_table_aws_producer : k => v.arn },
    { for k, v in aws_iam_role.s3_table_onprem_producer : k => v.arn },
  )
  description = "Map of all S3 producer role ARNs (namespace and optional table) for this environment"
}

output "s3_onprem_producer_role_arns" {
  value = merge(
    { for k, v in aws_iam_role.s3_namespace_onprem_producer : k => v.arn },
    { for k, v in aws_iam_role.s3_table_onprem_producer : k => v.arn },
  )
  description = "Map of on-prem S3 producer role ARNs (namespace and optional table) - read by terraform/kafka for the shared IAM Roles Anywhere profile"
}

