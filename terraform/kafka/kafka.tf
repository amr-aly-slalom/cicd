# ─── Locals — Topics, Producers & Consumers ──────────────────────────────────

locals {
  _producer_files = {
    for f in fileset("${path.root}/../../kafka/producers", "**/*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../kafka/producers/${f}"))
  }

  # Expand each producer app's events into individual topic entries.
  # Key = assembled topic name; value = { app_key, app, event }.
  # Decommissioned apps (spec.decommission = true) and decommissioned events
  # (in spec.decommissionedEvents) are excluded before the map is built,
  # so they do not cause false-positive duplicate errors.
  topics_this_env = {
    for pair in flatten([
      for k, v in local._producer_files :
      !try(v.spec.decommission, false) && (
        can(v.spec.producer) ?
        contains(keys(v.spec.producer.environments), local.environment) :
        contains(local.connect_owned_apps_this_env, "${v.metadata.businessName}/${v.metadata.appName}")
        ) ? [
        for event in v.spec.events :
        {
          key     = "edp-${local.environment}.${v.metadata.businessName}.${v.metadata.appName}.${event.name}"
          app_key = k
          app     = v
          event   = event
        }
        if !contains(try(v.spec.decommissionedEvents, []), event.name)
      ] : []
    ]) :
    pair.key => pair
  }

  # Tracks events pending destruction (in decommissionedEvents but not in events).
  # Terraform destroys their topics naturally when the key disappears from topics_this_env.
  # Retained as a diagnostic anchor so operators can inspect the pending-destruction set.
  topics_decommissioned_this_env = {
    for pair in flatten([
      for k, v in local._producer_files :
      !try(v.spec.decommission, false) && (
        can(v.spec.producer) ?
        contains(keys(v.spec.producer.environments), local.environment) :
        contains(local.connect_owned_apps_this_env, "${v.metadata.businessName}/${v.metadata.appName}")
        ) ? [
        for event_name in try(v.spec.decommissionedEvents, []) :
        {
          key     = "edp-${local.environment}.${v.metadata.businessName}.${v.metadata.appName}.${event_name}"
          app_key = k
          app     = v
        }
      ] : []
    ]) :
    pair.key => pair
  }

  # One entry per active producer app that owns its own IAM role (has a producer block for this env).
  _producers_this_env = {
    for k, v in local._producer_files :
    k => v
    if !try(v.spec.decommission, false) && can(v.spec.producer) && contains(keys(v.spec.producer.environments), local.environment)
  }

  # Subset of _producers_this_env where IAM is not delegated to a KafkaConnectRegistration.
  _producers_needing_iam_this_env = {
    for k, v in local._producers_this_env :
    k => v
    if !contains(local.connect_owned_apps_this_env,
    "${v.metadata.businessName}/${v.metadata.appName}")
  }

  # Pre-computed per-app topic key list for IAM policy assembly (O(apps × topics)).
  _topic_keys_per_app = {
    for k in keys(local._producers_needing_iam_this_env) :
    k => [for topic_key, topic_val in local.topics_this_env : topic_key if topic_val.app_key == k]
  }

  _consumer_files = {
    for f in fileset("${path.root}/../../kafka/consumers", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../kafka/consumers/${f}"))
  }

  consumers_this_env = {
    for k, v in local._consumer_files :
    v.metadata.name => v
    if contains(keys(v.spec.consumer.environments), local.environment)
  }

  aws_producers_this_env = {
    for k, v in local._producers_needing_iam_this_env :
    k => v.spec.producer.environments[local.environment].iamRoles
    if(
      !try(v.spec.producer.onPrem, false) &&
      can(v.spec.producer.environments[local.environment].iamRoles)
    )
  }

  aws_consumers_this_env = {
    for k, v in local.consumers_this_env :
    k => v.spec.consumer.environments[local.environment].iamRoles
    if(
      !try(v.spec.consumer.onPrem, false) &&
      can(v.spec.consumer.environments[local.environment].iamRoles)
    )
  }

  onprem_producers_this_env = {
    for k, v in local._producers_needing_iam_this_env :
    k => {
      certificate_subjects = v.spec.producer.environments[local.environment].certificateSubject
    }
    if(
      try(v.spec.producer.onPrem, false) &&
      can(v.spec.producer.environments[local.environment].certificateSubject)
    )
  }

  onprem_consumers_this_env = {
    for k, v in local.consumers_this_env :
    k => {
      consumer_slug        = v.metadata.name
      certificate_subjects = v.spec.consumer.environments[local.environment].certificateSubject
    }
    if(
      try(v.spec.consumer.onPrem, false) &&
      can(v.spec.consumer.environments[local.environment].certificateSubject)
    )
  }

  # Slug collision detection: derived from (businessName, appName) per producer app.
  _producer_slug_list   = [for k, v in local._producers_needing_iam_this_env : "${v.metadata.businessName}-${v.metadata.appName}"]
  _producer_slug_unique = distinct(local._producer_slug_list)

  # Same slug-collision detection for consumer metadata.name values.
  _consumer_slug_list   = [for k in keys(local.consumers_this_env) : k]
  _consumer_slug_unique = distinct(local._consumer_slug_list)
}

# ─── Locals — Connect Registrations ──────────────────────────────────────────

locals {
  _connect_files = {
    for f in fileset("${path.root}/../../kafka/connect", "**/*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../kafka/connect/${f}"))
  }

  connect_registrations_this_env = {
    for k, v in local._connect_files :
    v.metadata.name => v
    if contains(keys(v.spec.connect.environments), local.environment)
  }

  # (businessName/appName) pairs fully owned by a connect registration in this env.
  # Used to suppress per-app IAM role creation above.
  connect_owned_apps_this_env = toset(flatten([
    for name, reg in local.connect_registrations_this_env : [
      for src in reg.spec.sources :
      "${src.businessName}/${src.appName}"
    ]
  ]))

  # Per-registration: all assembled business topic ARNs across source apps
  _connect_business_topic_arns = {
    for name, reg in local.connect_registrations_this_env :
    name => flatten([
      for src in reg.spec.sources : [
        for topic_key, topic_val in local.topics_this_env :
        "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${topic_key}"
        if(topic_val.app.metadata.businessName == src.businessName &&
        topic_val.app.metadata.appName == src.appName)
      ]
    ])
  }

  # Per-registration prefixed system topics to provision on MSK
  _connect_system_topics = {
    for pair in flatten([
      for name, reg in local.connect_registrations_this_env : concat(
        [
          { reg_name = name, suffix = "connect-configs", partitions = 1, cleanup = "compact", retention_ms = -1 },
          { reg_name = name, suffix = "connect-offsets", partitions = 25, cleanup = "compact", retention_ms = -1 },
          { reg_name = name, suffix = "connect-status", partitions = 5, cleanup = "compact,delete", retention_ms = 86400000 },
        ],
        try(reg.spec.variant, "standard") == "confluent" ? [
          { reg_name = name, suffix = "confluent-license", partitions = 1, cleanup = "compact", retention_ms = -1 },
        ] : []
      )
    ]) :
    "${pair.reg_name}-${pair.suffix}" => pair
  }

  aws_connect_this_env = {
    for name, reg in local.connect_registrations_this_env :
    name => reg.spec.connect.environments[local.environment].iamRoles
    if(!try(reg.spec.connect.onPrem, false) &&
    can(reg.spec.connect.environments[local.environment].iamRoles))
  }

  onprem_connect_this_env = {
    for name, reg in local.connect_registrations_this_env :
    name => {
      certificate_subjects = reg.spec.connect.environments[local.environment].certificateSubject
    }
    if(try(reg.spec.connect.onPrem, false) &&
    can(reg.spec.connect.environments[local.environment].certificateSubject))
  }

  # ConsumerRegistrations with type: kafka-connect active in this environment
  consumer_connect_this_env = {
    for k, v in local.consumers_this_env :
    v.metadata.name => v
    if try(v.spec.consumer.type, "standard") == "kafka-connect"
  }

  # Per consumer-connect registration: assembled business topic ARNs for consume access
  _consumer_connect_business_topic_arns = {
    for name, reg in local.consumer_connect_this_env :
    name => [
      for t in reg.spec.topics :
      "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/edp-${local.environment}.${t.businessName}.${t.appName}.${t.eventName}"
    ]
  }

  # Per consumer-connect registration: system topics to provision (same config as producer-side)
  _consumer_connect_system_topics = {
    for pair in flatten([
      for name, reg in local.consumer_connect_this_env : concat(
        [
          { reg_name = name, suffix = "connect-configs", partitions = 1, cleanup = "compact", retention_ms = -1 },
          { reg_name = name, suffix = "connect-offsets", partitions = 25, cleanup = "compact", retention_ms = -1 },
          { reg_name = name, suffix = "connect-status", partitions = 5, cleanup = "compact,delete", retention_ms = 86400000 },
        ],
        try(reg.spec.consumer.variant, "standard") == "confluent" ? [
          { reg_name = name, suffix = "confluent-license", partitions = 1, cleanup = "compact", retention_ms = -1 },
        ] : []
      )
    ]) :
    "${pair.reg_name}-${pair.suffix}" => pair
  }

  aws_consumer_connect_this_env = {
    for name, reg in local.consumer_connect_this_env :
    name => reg.spec.consumer.environments[local.environment].iamRoles
    if(!try(reg.spec.consumer.onPrem, false) &&
    can(reg.spec.consumer.environments[local.environment].iamRoles))
  }

  onprem_consumer_connect_this_env = {
    for name, reg in local.consumer_connect_this_env :
    name => {
      certificate_subjects = reg.spec.consumer.environments[local.environment].certificateSubject
    }
    if(try(reg.spec.consumer.onPrem, false) &&
    can(reg.spec.consumer.environments[local.environment].certificateSubject))
  }
}

# ─── Validations ──────────────────────────────────────────────────────────────

resource "terraform_data" "kafka_unique_name_check" {
  lifecycle {
    precondition {
      condition     = length(local._producer_slug_list) == length(local._producer_slug_unique)
      error_message = "Duplicate producer slug(s) detected: ${join(", ", setsubtract(toset(local._producer_slug_list), toset(local._producer_slug_unique)))}. Ensure each (businessName, appName) pair is unique across all active producer files."
    }

    precondition {
      condition     = length(local._consumer_slug_list) == length(local._consumer_slug_unique)
      error_message = "Duplicate consumer role-name slug(s) detected: ${join(", ", setsubtract(toset(local._consumer_slug_list), toset(local._consumer_slug_unique)))}. Rename the conflicting consumer(s) so their slugs are unique."
    }
  }
}

resource "terraform_data" "kafka_producer_name_length_check" {
  for_each = local._producers_needing_iam_this_env

  lifecycle {
    precondition {
      condition     = length("edp-${local.environment}-kafka-producer-${each.value.metadata.businessName}-${each.value.metadata.appName}") <= 64
      error_message = "IAM role name exceeds 64 characters. Shorten businessName or appName."
    }
  }
}

resource "terraform_data" "kafka_connect_name_length_check" {
  for_each = local.connect_registrations_this_env

  lifecycle {
    precondition {
      condition     = length("edp-${local.environment}-kafka-connect-${each.key}") <= 64
      error_message = "Connect IAM role name exceeds 64 characters. Shorten registration name."
    }
  }
}

# ─── Topics ───────────────────────────────────────────────────────────────────

resource "aws_msk_topic" "this" {
  for_each = local.topics_this_env

  cluster_arn        = aws_msk_cluster.this.arn
  name               = each.key
  partition_count    = each.value.event.partitions
  replication_factor = each.value.event.replicationFactor

  configs = jsonencode(merge(
    {
      "retention.ms"    = tostring(each.value.event.retentionMs)
      "retention.bytes" = tostring(try(each.value.event.retentionBytes, -1))
      "cleanup.policy"  = each.value.event.cleanupPolicy
    },
    can(each.value.event.maxMessageBytes) ? {
      "max.message.bytes" = tostring(each.value.event.maxMessageBytes)
    } : {}
  ))
}

resource "aws_msk_topic" "kafka_connect_system_topic" {
  for_each = merge(local._connect_system_topics, local._consumer_connect_system_topics)

  cluster_arn        = aws_msk_cluster.this.arn
  name               = each.key
  partition_count    = each.value.partitions
  replication_factor = 3

  configs = jsonencode({
    "cleanup.policy" = each.value.cleanup
    "retention.ms"   = tostring(each.value.retention_ms)
  })
}

# ─── Producer IAM ─────────────────────────────────────────────────────────────

resource "aws_iam_policy" "kafka_producer" {
  for_each = local._producers_needing_iam_this_env

  name        = "edp-${local.environment}-kafka-producer-${each.value.metadata.businessName}-${each.value.metadata.appName}"
  description = "Least-privilege MSK produce access for ${each.value.metadata.businessName}/${each.value.metadata.appName} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "ConnectToCluster"
          Effect = "Allow"
          Action = [
            "kafka-cluster:Connect",
            "kafka-cluster:DescribeCluster",
          ]
          Resource = aws_msk_cluster.this.arn
        },
      ],
      length(local._topic_keys_per_app[each.key]) > 0 ? [
        {
          Sid    = "ProduceToTopic"
          Effect = "Allow"
          Action = [
            "kafka-cluster:DescribeTopic",
            "kafka-cluster:WriteData",
          ]
          Resource = [for topic_key in local._topic_keys_per_app[each.key] : "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${topic_key}"]
        }
      ] : []
    )
  })
}

resource "aws_iam_role" "kafka_aws_producer" {
  for_each = local.aws_producers_this_env

  name        = "edp-${local.environment}-kafka-producer-${local._producers_needing_iam_this_env[each.key].metadata.businessName}-${local._producers_needing_iam_this_env[each.key].metadata.appName}"
  description = "MSK producer role for ${local._producers_needing_iam_this_env[each.key].metadata.businessName}/${local._producers_needing_iam_this_env[each.key].metadata.appName} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = each.value }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_aws_producer" {
  for_each = local.aws_producers_this_env

  role       = aws_iam_role.kafka_aws_producer[each.key].name
  policy_arn = aws_iam_policy.kafka_producer[each.key].arn
}

resource "aws_iam_role" "kafka_onprem_producer" {
  for_each = local.onprem_producers_this_env

  name        = "edp-${local.environment}-kafka-producer-${local._producers_needing_iam_this_env[each.key].metadata.businessName}-${local._producers_needing_iam_this_env[each.key].metadata.appName}"
  description = "MSK on-prem producer role for ${local._producers_needing_iam_this_env[each.key].metadata.businessName}/${local._producers_needing_iam_this_env[each.key].metadata.appName} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "rolesanywhere.amazonaws.com" }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
          "sts:SetSourceIdentity",
        ]
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:PrincipalTag/x509Subject/CN" = [for cn in each.value.certificate_subjects : split("CN=", cn)[1]]
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_onprem_producer" {
  for_each = local.onprem_producers_this_env

  role       = aws_iam_role.kafka_onprem_producer[each.key].name
  policy_arn = aws_iam_policy.kafka_producer[each.key].arn
}

# ─── Consumer IAM ─────────────────────────────────────────────────────────────

resource "aws_iam_policy" "kafka_consumer" {
  for_each = local.consumers_this_env

  name        = "edp-${local.environment}-kafka-consumer-${each.key}"
  description = "Least-privilege MSK consume access for ${each.key} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "ConnectToCluster"
          Effect = "Allow"
          Action = [
            "kafka-cluster:Connect",
            "kafka-cluster:DescribeCluster",
          ]
          Resource = aws_msk_cluster.this.arn
        },
      ],
      [
        for topic in each.value.spec.topics : {
          Sid    = "ReadTopic${replace(topic.businessName, "-", "")}X${replace(topic.appName, "-", "")}X${replace(topic.eventName, "-", "")}"
          Effect = "Allow"
          Action = [
            "kafka-cluster:DescribeTopic",
            "kafka-cluster:ReadData",
          ]
          Resource = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/edp-${local.environment}.${topic.businessName}.${topic.appName}.${topic.eventName}"
        }
      ],
      can(each.value.spec.consumer.consumerGroupPrefix) ? [
        {
          Sid    = "ConsumerGroup"
          Effect = "Allow"
          Action = [
            "kafka-cluster:AlterGroup",
            "kafka-cluster:DescribeGroup",
          ]
          Resource = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/${each.value.spec.consumer.consumerGroupPrefix}*"
        }
      ] : []
    )
  })
}

resource "aws_iam_role" "kafka_aws_consumer" {
  for_each = local.aws_consumers_this_env

  name        = "edp-${local.environment}-kafka-consumer-${each.key}"
  description = "MSK consumer role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = each.value }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_aws_consumer" {
  for_each = local.aws_consumers_this_env

  role       = aws_iam_role.kafka_aws_consumer[each.key].name
  policy_arn = aws_iam_policy.kafka_consumer[each.key].arn
}

resource "aws_iam_role" "kafka_onprem_consumer" {
  for_each = local.onprem_consumers_this_env

  name        = "edp-${local.environment}-kafka-consumer-${each.key}"
  description = "MSK on-prem consumer role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "rolesanywhere.amazonaws.com" }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
          "sts:SetSourceIdentity",
        ]
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:PrincipalTag/x509Subject/CN" = [for cn in each.value.certificate_subjects : split("CN=", cn)[1]]
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_onprem_consumer" {
  for_each = local.onprem_consumers_this_env

  role       = aws_iam_role.kafka_onprem_consumer[each.key].name
  policy_arn = aws_iam_policy.kafka_consumer[each.key].arn
}

# ─── Connect IAM ──────────────────────────────────────────────────────────────

resource "aws_iam_policy" "kafka_connect" {
  for_each = local.connect_registrations_this_env

  name        = "edp-${local.environment}-kafka-connect-${each.key}"
  description = "MSK connect access for ${each.key} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ConnectToCluster"
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
        Resource = aws_msk_cluster.this.arn
      }],
      length(local._connect_business_topic_arns[each.key]) > 0 ? [{
        Sid      = "ProduceBusinessTopics"
        Effect   = "Allow"
        Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
        Resource = local._connect_business_topic_arns[each.key]
      }] : [],
      [{
        Sid    = "SystemTopicsReadWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:DescribeConfigs",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
        ]
        Resource = [
          for suffix in concat(
            ["connect-configs", "connect-offsets", "connect-status"],
            try(each.value.spec.variant, "standard") == "confluent" ? ["confluent-license"] : []
          ) :
          "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${each.key}-${suffix}"
        ]
      }],
      [{
        Sid      = "SystemTopicsConsumerGroup"
        Effect   = "Allow"
        Action   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
        Resource = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/${each.key}-*"
      }]
    )
  })
}

resource "aws_iam_role" "kafka_aws_connect" {
  for_each = local.aws_connect_this_env

  name        = "edp-${local.environment}-kafka-connect-${each.key}"
  description = "MSK connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = each.value }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_aws_connect" {
  for_each   = local.aws_connect_this_env
  role       = aws_iam_role.kafka_aws_connect[each.key].name
  policy_arn = aws_iam_policy.kafka_connect[each.key].arn
}

resource "aws_iam_role" "kafka_onprem_connect" {
  for_each = local.onprem_connect_this_env

  name        = "edp-${local.environment}-kafka-connect-${each.key}"
  description = "MSK on-prem connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
      Condition = {
        "ForAnyValue:StringEquals" = {
          "aws:PrincipalTag/x509Subject/CN" = [
            for cn in each.value.certificate_subjects : split("CN=", cn)[1]
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_onprem_connect" {
  for_each   = local.onprem_connect_this_env
  role       = aws_iam_role.kafka_onprem_connect[each.key].name
  policy_arn = aws_iam_policy.kafka_connect[each.key].arn
}

resource "aws_iam_policy" "kafka_consumer_connect" {
  for_each = local.consumer_connect_this_env

  name        = "edp-${local.environment}-kafka-consumer-connect-${each.key}"
  description = "MSK consumer connect access for ${each.key} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ConnectToCluster"
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
        Resource = aws_msk_cluster.this.arn
      }],
      length(local._consumer_connect_business_topic_arns[each.key]) > 0 ? [{
        Sid      = "ConsumeBusinessTopics"
        Effect   = "Allow"
        Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
        Resource = local._consumer_connect_business_topic_arns[each.key]
      }] : [],
      [{
        Sid    = "SystemTopicsReadWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:DescribeConfigs",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
        ]
        Resource = [
          for suffix in concat(
            ["connect-configs", "connect-offsets", "connect-status"],
            try(each.value.spec.consumer.variant, "standard") == "confluent" ? ["confluent-license"] : []
          ) :
          "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${each.key}-${suffix}"
        ]
      }],
      [{
        Sid      = "SystemTopicsConsumerGroup"
        Effect   = "Allow"
        Action   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
        Resource = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/${each.key}-*"
      }]
    )
  })
}

resource "aws_iam_role" "kafka_consumer_connect_aws" {
  for_each = local.aws_consumer_connect_this_env

  name        = "edp-${local.environment}-kafka-consumer-connect-${each.key}"
  description = "MSK consumer connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = each.value }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_consumer_connect_aws" {
  for_each   = local.aws_consumer_connect_this_env
  role       = aws_iam_role.kafka_consumer_connect_aws[each.key].name
  policy_arn = aws_iam_policy.kafka_consumer_connect[each.key].arn
}

resource "aws_iam_role" "kafka_consumer_connect_onprem" {
  for_each = local.onprem_consumer_connect_this_env

  name        = "edp-${local.environment}-kafka-consumer-connect-${each.key}"
  description = "MSK on-prem consumer connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
      Condition = {
        "ForAnyValue:StringEquals" = {
          "aws:PrincipalTag/x509Subject/CN" = [
            for cn in each.value.certificate_subjects : split("CN=", cn)[1]
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_consumer_connect_onprem" {
  for_each   = local.onprem_consumer_connect_this_env
  role       = aws_iam_role.kafka_consumer_connect_onprem[each.key].name
  policy_arn = aws_iam_policy.kafka_consumer_connect[each.key].arn
}

# ─── E2E Canary ───────────────────────────────────────────────────────────────

resource "aws_iam_role" "canary_lambda_execution" {
  name        = "chedaws-edp-kafka-canary-lambda-${local.environment}"
  description = "Lambda execution role for Kafka E2E canary in ${local.environment}. No direct Kafka permissions - assumes the self-service producer and consumer wrapper roles via sts:AssumeRole."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "canary_lambda_execution" {
  #checkov:skip=CKV_AWS_355: cloudwatch:PutMetricData has no resource-level permissions, and Lambda VPC ENI management needs Resource "*" (as in the AWSLambdaVPCAccessExecutionRole managed policy) - the ENIs are created by the Lambda service at runtime
  #checkov:skip=CKV_AWS_290: Same statements - the ec2:Create/DeleteNetworkInterface grant for the function's VPC attachment, mirroring AWSLambdaVPCAccessExecutionRole
  name = "canary-lambda-execution-policy"
  role = aws_iam_role.canary_lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumeCanaryRoles"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          "arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-kafka-producer-platform-e2e",
          "arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-kafka-consumer-platform-e2e-canary-consumer",
        ]
      },
      {
        Sid      = "EmitMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
      },
      {
        Sid    = "ManageVpcEni"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
        ]
        Resource = "*"
      },
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:log-group:/chedaws-edp/kafka-e2e-canary/${local.environment}:*"
      },
      {
        Sid      = "ReadDeployArtefact"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${data.terraform_remote_state.core.outputs.platform_s3_bucket_arn}/e2e/kafka/canary/*"
      },
      {
        Sid    = "UsePlatformS3Key"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      },
    ]
  })
}

resource "aws_security_group" "canary_lambda" {
  name        = "chedaws-edp-kafka-canary-sg-${local.environment}"
  description = "Security group for Kafka E2E canary Lambda in ${local.environment}"
  vpc_id      = data.aws_vpc.this.id

  dynamic "egress" {
    for_each = [for s in data.aws_subnet.app : s.cidr_block]
    content {
      from_port   = 9098
      to_port     = 9098
      protocol    = "tcp"
      cidr_blocks = [egress.value]
      description = "MSK SASL/IAM from canary Lambda"
    }
  }

  # Lambda reaches AWS APIs (STS, CloudWatch, S3) via NAT, not a VPC endpoint;
  # restrict further only once VPC endpoints exist for these services.
  #trivy:ignore:AWS-0104
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "AWS APIs (STS, CloudWatch, S3) via NAT"
  }

  tags = {
    Name = "chedaws-edp-kafka-canary-sg-${local.environment}"
  }
}

resource "terraform_data" "build_kafka_canary_zip" {
  triggers_replace = [
    filemd5("${path.root}/../../lambda/kafka-e2e-canary/handler.py"),
    filemd5("${path.root}/../../lambda/kafka-e2e-canary/requirements.txt"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      python3 -m pip install -r ${path.root}/../../lambda/kafka-e2e-canary/requirements.txt \
          -t ${path.root}/../../lambda/kafka-e2e-canary/package/
      cp ${path.root}/../../lambda/kafka-e2e-canary/handler.py \
          ${path.root}/../../lambda/kafka-e2e-canary/package/
      (cd ${path.root}/../../lambda/kafka-e2e-canary/package && zip -r ../function.zip .)
    EOT
  }
}

resource "aws_s3_object" "canary_lambda" {
  depends_on             = [terraform_data.build_kafka_canary_zip]
  bucket                 = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  key                    = "e2e/kafka/canary/function.zip"
  source                 = "${path.root}/../../lambda/kafka-e2e-canary/function.zip"
  source_hash            = md5(join("", [filemd5("${path.root}/../../lambda/kafka-e2e-canary/handler.py"), filemd5("${path.root}/../../lambda/kafka-e2e-canary/requirements.txt")]))
  server_side_encryption = "aws:kms"
  kms_key_id             = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  # source is only where the zip is built locally; the object's content is
  # tracked by source_hash, a hash of the files the zip is built from. Ignoring
  # source keeps a change to that local path (e.g. this module moving
  # directory) from re-uploading a zip this checkout never built.
  lifecycle {
    ignore_changes = [source]
  }
}

resource "aws_cloudwatch_log_group" "kafka_e2e_canary" {
  name              = "/chedaws-edp/kafka-e2e-canary/${local.environment}"
  retention_in_days = local.log_retention_days
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "chedaws-edp-kafka-e2e-canary-logs-${local.environment}"
  }
}

#trivy:ignore:AWS-0066 X-Ray tracing not required for scheduled synthetic canary
resource "aws_lambda_function" "kafka_e2e_canary" {
  #checkov:skip=CKV_AWS_173: Lambda env vars contain non-secret config; KMS envelope encryption not required
  #checkov:skip=CKV_AWS_50: X-Ray tracing not required for scheduled synthetic canary
  #checkov:skip=CKV_AWS_272: Code-signing not used in this project
  #checkov:skip=CKV_AWS_116: Scheduled synthetic canary; DLQ not applicable
  function_name                  = "chedaws-edp-kafka-e2e-canary-${local.environment}"
  role                           = aws_iam_role.canary_lambda_execution.arn
  handler                        = "handler.lambda_handler"
  runtime                        = "python3.14"
  timeout                        = 60
  memory_size                    = 256
  reserved_concurrent_executions = 1

  s3_bucket         = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  s3_key            = aws_s3_object.canary_lambda.key
  s3_object_version = aws_s3_object.canary_lambda.version_id

  vpc_config {
    subnet_ids         = data.aws_subnets.app.ids
    security_group_ids = [aws_security_group.canary_lambda.id]
  }

  environment {
    variables = {
      ENVIRONMENT              = local.environment
      MSK_BOOTSTRAP_BROKERS    = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
      CANARY_PRODUCER_ROLE_ARN = "arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-kafka-producer-platform-e2e"
      CANARY_CONSUMER_ROLE_ARN = "arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-kafka-consumer-platform-e2e-canary-consumer"
      CANARY_TOPIC             = "edp-${local.environment}.platform.e2e.canary"
      SETTLE_PERIOD_SECONDS    = "5"
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.kafka_e2e_canary.name
    log_format = "Text"
  }

  depends_on = [aws_cloudwatch_log_group.kafka_e2e_canary]

  tags = {
    Name = "chedaws-edp-kafka-e2e-canary-${local.environment}"
  }
}

resource "aws_cloudwatch_event_rule" "kafka_e2e_canary" {
  name                = "chedaws-edp-kafka-e2e-canary-schedule-${local.environment}"
  description         = "Triggers Kafka E2E canary Lambda every 5 minutes in ${local.environment}"
  schedule_expression = "rate(5 minutes)"
  state               = "ENABLED"

  tags = {
    Name = "chedaws-edp-kafka-e2e-canary-schedule-${local.environment}"
  }
}

resource "aws_cloudwatch_event_target" "kafka_e2e_canary" {
  rule      = aws_cloudwatch_event_rule.kafka_e2e_canary.name
  target_id = "KafkaCanaryLambda"
  arn       = aws_lambda_function.kafka_e2e_canary.arn
}

resource "aws_lambda_permission" "canary_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kafka_e2e_canary.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.kafka_e2e_canary.arn
}

resource "aws_cloudwatch_metric_alarm" "kafka_e2e_test_failure" {
  alarm_name        = "chedaws-edp-kafka-e2e-canary-failure-${local.environment}"
  alarm_description = "Kafka E2E canary has failed or not run for 2 consecutive 5-minute cycles in ${local.environment}. Check CloudWatch Logs at /chedaws-edp/kafka-e2e-canary/${local.environment} for cycle_id, step, and error fields. Common causes: MSK broker unreachable, IAM role misconfiguration, or topic deletion."

  namespace   = "ChedawsEDP/KafkaE2ECanary"
  metric_name = "KafkaE2ETestSuccess"

  dimensions = {
    TopicName   = "edp-${local.environment}.platform.e2e.canary"
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-kafka-e2e-canary-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "canary_lambda_errors" {
  alarm_name        = "chedaws-edp-kafka-e2e-canary-lambda-errors-${local.environment}"
  alarm_description = "Kafka E2E canary Lambda invocation errors in ${local.environment}. Check /chedaws-edp/kafka-e2e-canary/${local.environment} for details."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"

  dimensions = {
    FunctionName = aws_lambda_function.kafka_e2e_canary.function_name
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-kafka-e2e-canary-lambda-errors-${local.environment}"
  }
}
