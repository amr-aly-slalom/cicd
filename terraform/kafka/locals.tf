locals {
  environment  = terraform.workspace
  is_prod_like = contains(["uat", "prod"], local.environment)

  aws_account_id     = data.aws_caller_identity.current.account_id
  log_retention_days = local.is_prod_like ? 30 : 7

  msk_kafka_version         = "3.9.x"
  msk_instance_type         = local.is_prod_like ? "kafka.m7g.2xlarge" : "kafka.m7g.large"
  msk_broker_count          = 3
  msk_storage_per_broker_gb = local.is_prod_like ? 500 : 100
  msk_storage_max_gb        = local.is_prod_like ? 16384 : 1024
  msk_enhanced_monitoring   = "PER_TOPIC_PER_BROKER"

  # Per-broker alarm definitions; flattened into a cartesian product below.
  _msk_per_broker_alarm_defs = {
    under-replicated = {
      metric_name = "UnderReplicatedPartitions"
      description = "has under-replicated partitions"
      threshold   = 1
    }
    disk = {
      metric_name = "KafkaDataLogsDiskUsed"
      description = "disk usage exceeds 80%"
      threshold   = 80
    }
  }

  # Produces keys like "disk-broker-1", "under-replicated-broker-2", etc.
  msk_per_broker_alarms = {
    for pair in setproduct(keys(local._msk_per_broker_alarm_defs), range(local.msk_broker_count)) :
    "${pair[0]}-broker-${pair[1] + 1}" => merge(
      local._msk_per_broker_alarm_defs[pair[0]],
      { broker_id = pair[1] + 1 }
    )
  }

  msk_external_source_ips = toset(flatten([
    # All producers active in this environment
    [for k, v in local._producers_needing_iam_this_env :
    try(v.spec.producer.environments[local.environment].sourceIps, [])],
    # All consumers active in this environment
    [for k, v in local.consumers_this_env :
    try(v.spec.consumer.environments[local.environment].sourceIps, [])],
    # All connect registrations active in this environment
    [for k, v in local.connect_registrations_this_env :
    try(v.spec.connect.environments[local.environment].sourceIps, [])],
    # All consumer-connect registrations active in this environment
    [for k, v in local.consumer_connect_this_env :
    try(v.spec.consumer.environments[local.environment].sourceIps, [])],
  ]))
}
