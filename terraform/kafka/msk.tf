# ─── Security Group ───────────────────────────────────────────────────────────

resource "aws_security_group" "msk" {
  # checkov:skip=CKV_AWS_382: MSK is a fully managed AWS service. Brokers require
  # unrestricted outbound to reach the MSK management plane, KMS (port 443), and
  # CloudWatch Logs (port 443). Restrict egress further only after provisioning
  # VPC endpoints for all required AWS services (FR-014: "follows AWS defaults").
  name        = "chedaws-edp-msk-sg-${local.environment}"
  description = "Security group for chedaws-edp-msk-${local.environment} MSK cluster"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
    description = "Kafka TLS from VPC"
  }

  ingress {
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
    description = "Kafka SASL/IAM from VPC"
  }

  dynamic "ingress" {
    for_each = local.msk_external_source_ips
    content {
      from_port   = 9094
      to_port     = 9094
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "Kafka TLS from ${ingress.value}"
    }
  }

  dynamic "ingress" {
    for_each = local.msk_external_source_ips
    content {
      from_port   = 9098
      to_port     = 9098
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
      description = "Kafka SASL/IAM from ${ingress.value}"
    }
  }

  #trivy:ignore:AWS-0104 Same reason as the checkov:skip above (CKV_AWS_382)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "chedaws-edp-msk-sg-${local.environment}"
  }
}

# ─── Broker Log Group ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/chedaws-edp/msk/${local.environment}"
  retention_in_days = local.log_retention_days
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "chedaws-edp-msk-logs-${local.environment}"
  }
}

# ─── MSK Configuration ────────────────────────────────────────────────────────

resource "aws_msk_configuration" "this" {
  name           = "chedaws-edp-msk-config-${local.environment}"
  kafka_versions = [local.msk_kafka_version]

  server_properties = <<-EOT
    auto.create.topics.enable=false
    default.replication.factor=${local.msk_broker_count}
    min.insync.replicas=${local.msk_broker_count - 1}
    num.partitions=${local.msk_broker_count}
    offsets.retention.minutes=10080
  EOT
}

# ─── MSK Cluster ──────────────────────────────────────────────────────────────

resource "aws_msk_cluster" "this" {
  cluster_name           = "chedaws-edp-msk-${local.environment}"
  kafka_version          = local.msk_kafka_version
  number_of_broker_nodes = local.msk_broker_count

  broker_node_group_info {
    instance_type   = local.msk_instance_type
    client_subnets  = data.aws_subnets.app.ids
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = local.msk_storage_per_broker_gb
      }
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = data.aws_kms_alias.msk.target_key_arn

    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  enhanced_monitoring = local.msk_enhanced_monitoring

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  lifecycle {
    ignore_changes = [broker_node_group_info[0].storage_info]

    precondition {
      condition     = length(data.aws_subnets.app.ids) >= local.msk_broker_count
      error_message = "The number of App-tier subnets (${length(data.aws_subnets.app.ids)}) is less than the required broker count (${local.msk_broker_count}) for environment '${local.environment}'. Ensure the VPC has enough App-tier subnets."
    }
  }
}

# ─── Storage Auto-Scaling ─────────────────────────────────────────────────────

resource "aws_appautoscaling_target" "msk_storage" {
  service_namespace  = "kafka"
  resource_id        = aws_msk_cluster.this.arn
  scalable_dimension = "kafka:broker-storage:VolumeSize"
  min_capacity       = 1
  max_capacity       = local.msk_storage_max_gb

}

resource "aws_appautoscaling_policy" "msk_storage" {
  name               = "chedaws-edp-msk-storage-scaling-${local.environment}"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.msk_storage.service_namespace
  resource_id        = aws_appautoscaling_target.msk_storage.resource_id
  scalable_dimension = aws_appautoscaling_target.msk_storage.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "KafkaBrokerStorageUtilization"
    }

    target_value       = 70
    disable_scale_in   = true
    scale_out_cooldown = 600
    scale_in_cooldown  = 600
  }
}

# ─── CloudWatch Alarms ────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "msk_per_broker" {
  for_each = local.msk_per_broker_alarms

  alarm_name          = "chedaws-edp-msk-${each.key}-${local.environment}"
  alarm_description   = "MSK broker ${each.value.broker_id} ${each.value.description}"
  namespace           = "AWS/Kafka"
  metric_name         = each.value.metric_name
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  dimensions = {
    "Cluster Name" = aws_msk_cluster.this.cluster_name
    "Broker ID"    = tostring(each.value.broker_id)
  }
}

resource "aws_cloudwatch_metric_alarm" "msk_offline_partitions" {
  alarm_name          = "chedaws-edp-msk-offline-partitions-${local.environment}"
  alarm_description   = "MSK cluster has offline partitions"
  namespace           = "AWS/Kafka"
  metric_name         = "OfflinePartitionsCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  dimensions = {
    "Cluster Name" = aws_msk_cluster.this.cluster_name
  }
}

resource "aws_cloudwatch_metric_alarm" "msk_active_controller" {
  count = local.is_prod_like ? 1 : 0

  alarm_name          = "chedaws-edp-msk-active-controller-${local.environment}"
  alarm_description   = "MSK cluster has no active controller"
  namespace           = "AWS/Kafka"
  metric_name         = "ActiveControllerCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  dimensions = {
    "Cluster Name" = aws_msk_cluster.this.cluster_name
  }
}
