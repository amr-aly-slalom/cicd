output "msk_cluster_arn" {
  value       = aws_msk_cluster.this.arn
  description = "ARN of the MSK cluster (e.g., used in Glue Streaming connection configuration)"
}

output "msk_cluster_name" {
  value       = aws_msk_cluster.this.cluster_name
  description = "Name of the MSK cluster (e.g., chedaws-edp-msk-dev)"
}

output "msk_bootstrap_brokers_sasl_iam" {
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
  description = "Comma-separated IAM-authenticated bootstrap broker endpoints (port 9098). Primary endpoint for AWS Glue Streaming jobs and other IAM-authenticated consumers."
}

output "msk_bootstrap_brokers_tls" {
  value       = aws_msk_cluster.this.bootstrap_brokers_tls
  description = "Comma-separated TLS bootstrap broker endpoints (port 9094). For use by TLS-only clients that do not use IAM auth (e.g., administrative tooling, Kafka CLI)."
}

output "msk_current_version" {
  value       = aws_msk_cluster.this.current_version
  description = "Current MSK cluster version string (e.g., K13V1IB3VIYZZH). Required for in-place cluster updates via the AWS API."
}

output "kafka_topic_names" {
  value       = keys(local.topics_this_env)
  description = "All Kafka topic names managed in this environment"
}

output "topics_pending_destruction" {
  value       = keys(local.topics_decommissioned_this_env)
  description = "Topic names currently in decommissionedEvents - will be destroyed on next apply once removed from topics_this_env"
}

output "kafka_producer_role_arns" {
  value = merge(
    { for k, v in aws_iam_role.kafka_aws_producer : k => v.arn },
    { for k, v in aws_iam_role.kafka_onprem_producer : k => v.arn },
  )
  description = "Map of app key to producer IAM role ARN for this environment"
}

output "kafka_consumer_role_arns" {
  value = merge(
    { for k, v in aws_iam_role.kafka_aws_consumer : k => v.arn },
    { for k, v in aws_iam_role.kafka_onprem_consumer : k => v.arn },
  )
  description = "Map of consumer slug to consumer IAM role ARN for this environment"
}

output "kafka_connect_role_arns" {
  value = merge(
    { for k, v in aws_iam_role.kafka_aws_connect : k => v.arn },
    { for k, v in aws_iam_role.kafka_onprem_connect : k => v.arn },
    { for k, v in aws_iam_role.kafka_consumer_connect_aws : k => v.arn },
    { for k, v in aws_iam_role.kafka_consumer_connect_onprem : k => v.arn },
  )
  description = "Map of connect registration name to IAM role ARN for this environment"
}

output "kafka_connect_system_topic_names" {
  value       = keys(aws_msk_topic.kafka_connect_system_topic)
  description = "System topic names provisioned for Kafka Connect registrations in this environment"
}

output "rolesanywhere_profile_arn" {
  value       = aws_rolesanywhere_profile.onprem.arn
  description = "IAM Roles Anywhere profile ARN for on-prem workloads in this environment"
}
