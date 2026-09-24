# Data Model: Amazon MSK Cluster Provisioning

**Feature**: 003-msk-cluster | **Date**: 2026-06-30

---

## Entity Overview

```
locals.tf (msk_* locals + kms_services["msk"])
    │
    ├──► aws_security_group.msk
    │         │
    │         └──► data.aws_subnet.app (existing — CIDRs for ingress rules)
    │
    ├──► aws_cloudwatch_log_group.msk
    │         └──► module.kms["cloudwatch_logs"] (existing CMK, reused)
    │
    ├──► module.kms["msk"] (NEW entry in kms_services — provisioned by existing module block)
    │
    └──► aws_msk_cluster.this
              ├──► data.aws_subnets.app (existing — subnet IDs for broker placement)
              ├──► aws_security_group.msk
              ├──► module.kms["msk"]
              ├──► aws_cloudwatch_log_group.msk
              │
              └── [after cluster created]
                    ├──► aws_appautoscaling_target.msk_storage
                    │         └──► aws_appautoscaling_policy.msk_storage
                    │
                    ├──► aws_cloudwatch_metric_alarm.msk_under_replicated[count]
                    ├──► aws_cloudwatch_metric_alarm.msk_offline_partitions
                    ├──► aws_cloudwatch_metric_alarm.msk_active_controller (uat/prod only)
                    └──► aws_cloudwatch_metric_alarm.msk_disk[count]
                               └──► aws_sns_topic.alerts (existing)
```

---

## Entity 1: MSK Cluster (`aws_msk_cluster.this`)

**File**: `terraform/msk.tf`

| Attribute | dev | test | uat | prod |
|-----------|-----|------|-----|------|
| `cluster_name` | `chedaws-edp-msk-dev` | `chedaws-edp-msk-test` | `chedaws-edp-msk-uat` | `chedaws-edp-msk-prod` |
| `kafka_version` | `3.9.x` | `3.9.x` | `3.9.x` | `3.9.x` |
| `number_of_broker_nodes` | 2 | 2 | 3 | 3 |
| `broker_node_group_info.instance_type` | `kafka.m7g.large` | `kafka.m7g.large` | `kafka.m7g.2xlarge` | `kafka.m7g.2xlarge` |
| `broker_node_group_info.client_subnets` | `data.aws_subnets.app.ids` | `data.aws_subnets.app.ids` | `data.aws_subnets.app.ids` | `data.aws_subnets.app.ids` |
| `storage_info.ebs_storage_info.volume_size` | 100 GB | 100 GB | 500 GB | 500 GB |
| `client_authentication.sasl.iam` | `true` | `true` | `true` | `true` |
| `encryption_in_transit.client_broker` | `TLS` | `TLS` | `TLS` | `TLS` |
| `encryption_in_transit.in_cluster` | `true` | `true` | `true` | `true` |
| `encryption_at_rest_kms_key_arn` | `module.kms["msk"].key_arn` | same | same | same |
| `enhanced_monitoring` | `PER_BROKER` | `PER_BROKER` | `PER_TOPIC_PER_BROKER` | `PER_TOPIC_PER_BROKER` |
| `logging_info.broker_logs.cloudwatch_logs.log_group` | `/chedaws-edp/msk/dev` | `/chedaws-edp/msk/test` | `/chedaws-edp/msk/uat` | `/chedaws-edp/msk/prod` |

**Key outputs exported by the resource**:
- `arn` — used by `aws_appautoscaling_target.resource_id`
- `cluster_name` — used in CloudWatch alarm dimensions
- `bootstrap_brokers_sasl_iam` — IAM-authenticated endpoint (port 9098), exposed as Terraform output
- `bootstrap_brokers_tls` — TLS endpoint (port 9094), exposed as Terraform output
- `current_version` — MSK cluster version string for update management

**State / lifecycle notes**:
- `lifecycle { ignore_changes = [broker_node_group_info[0].storage_info] }` — prevents Terraform from reverting auto-scaled storage back to the declared `volume_size`. This is the standard pattern when Application Auto Scaling manages storage expansion.
- `number_of_broker_nodes` must be a multiple of the number of AZs covered by `client_subnets`. Implementation must verify that App-tier subnets span at least 2 AZs for dev/test and at least 3 AZs for uat/prod.

---

## Entity 2: Security Group (`aws_security_group.msk`)

**File**: `terraform/msk.tf`

| Attribute | Value |
|-----------|-------|
| Name | `chedaws-edp-msk-sg-<environment>` |
| Description | `Security group for chedaws-edp-msk-<environment> MSK cluster` |
| VPC | `local.vpc_id` |

**Ingress rules** (dynamic block over `data.aws_subnet.app`):

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 9094 | TCP | Per-subnet CIDR from `data.aws_subnet.app` | Kafka TLS endpoint |
| 9098 | TCP | Per-subnet CIDR from `data.aws_subnet.app` | Kafka SASL/IAM endpoint |

**Egress**: Default AWS all-outbound (no explicit egress rule — follows the existing security group pattern in `redshift.tf`).

**Pattern**: Follows `redshift.tf` `dynamic "ingress"` block pattern, iterating over `[for s in data.aws_subnet.app : s.cidr_block]` with two separate dynamic blocks (one for 9094, one for 9098).

---

## Entity 3: KMS CMK for MSK (`module.kms["msk"]`)

**File**: Addition to `terraform/locals.tf` (`kms_services` map); CMK provisioned by existing `module "kms"` block in `terraform/kms.tf`

| Attribute | Value |
|-----------|-------|
| Map key | `"msk"` |
| `service_principal` | `"kafka.amazonaws.com"` |
| Key alias | `alias/chedaws-edp-msk-<environment>` (generated inside module) |
| Key policy | Root IAM full access + `kafka.amazonaws.com` service principal with `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant` |
| Deletion window | 30 days |
| Key rotation | Enabled |

**Outputs consumed**:
- `module.kms["msk"].key_arn` → referenced by `aws_msk_cluster.this` `encryption_at_rest_kms_key_arn`

**No changes to `kms.tf`** — the existing `module "kms"` `for_each` block automatically provisions the new CMK once `"msk"` is added to `local.kms_services`.

---

## Entity 4: CloudWatch Log Group (`aws_cloudwatch_log_group.msk`)

**File**: `terraform/msk.tf`

| Attribute | dev/test | uat | prod |
|-----------|----------|-----|------|
| Name | `/chedaws-edp/msk/dev` or `msk/test` | `/chedaws-edp/msk/uat` | `/chedaws-edp/msk/prod` |
| `retention_in_days` | 7 | 30 | 30 |
| `kms_key_id` | `module.kms["cloudwatch_logs"].key_arn` | same | same |

**Note**: Reuses the existing CloudWatch Logs CMK from spec-001 (Redshift feature). No new CMK is created. The `aws_msk_cluster` `logging_info` block references this log group by name.

---

## Entity 5: Application Auto Scaling Target (`aws_appautoscaling_target.msk_storage`)

**File**: `terraform/msk.tf`

| Attribute | dev/test | uat/prod |
|-----------|----------|----------|
| `service_namespace` | `"kafka"` | `"kafka"` |
| `resource_id` | `aws_msk_cluster.this.arn` | `aws_msk_cluster.this.arn` |
| `scalable_dimension` | `"kafka:broker-storage:VolumeSize"` | `"kafka:broker-storage:VolumeSize"` |
| `min_capacity` | 100 (GB) | 500 (GB) |
| `max_capacity` | 1,024 (GB) | 16,384 (GB) |

**Lifecycle**: `depends_on = [aws_msk_cluster.this]`

---

## Entity 6: Application Auto Scaling Policy (`aws_appautoscaling_policy.msk_storage`)

**File**: `terraform/msk.tf`

| Attribute | Value |
|-----------|-------|
| Name | `chedaws-edp-msk-storage-autoscaling-<environment>` |
| `policy_type` | `"TargetTrackingScaling"` |
| `predefined_metric_type` | `"KafkaBrokerStorageUtilization"` |
| `target_value` | `70` (trigger at 70%, alarm fires at 80%) |
| `disable_scale_in` | `true` (MSK EBS cannot shrink) |
| `scale_out_cooldown` | `600` seconds |
| `scale_in_cooldown` | `600` seconds (unused due to `disable_scale_in`) |

---

## Entity 7: CloudWatch Alarms (`aws_cloudwatch_metric_alarm.*`)

**File**: `terraform/msk.tf`

### 7a. Under-Replicated Partitions (per broker)

| Attribute | Value |
|-----------|-------|
| Resource | `aws_cloudwatch_metric_alarm.msk_under_replicated` |
| Count | `local.msk_broker_count[local.environment]` (2 or 3) |
| Name | `chedaws-edp-msk-under-replicated-<environment>-<broker_id>` |
| Metric | `UnderReplicatedPartitions` |
| Namespace | `AWS/Kafka` |
| Threshold | `≥ 1` |
| Dimensions | `Cluster Name` = cluster name, `Broker ID` = `tostring(count.index + 1)` |
| Evaluation | 2 × 60 seconds |
| Missing data | `notBreaching` |
| Actions | `aws_sns_topic.alerts.arn` |

### 7b. Offline Partitions (cluster-level)

| Attribute | Value |
|-----------|-------|
| Resource | `aws_cloudwatch_metric_alarm.msk_offline_partitions` |
| Name | `chedaws-edp-msk-offline-partitions-<environment>` |
| Metric | `OfflinePartitionsCount` |
| Namespace | `AWS/Kafka` |
| Threshold | `≥ 1` |
| Dimensions | `Cluster Name` = cluster name only |
| Evaluation | 2 × 60 seconds |
| Missing data | `notBreaching` |
| Actions | `aws_sns_topic.alerts.arn` |

### 7c. Active Controller (uat/prod only)

| Attribute | Value |
|-----------|-------|
| Resource | `aws_cloudwatch_metric_alarm.msk_active_controller` |
| Count | `contains(["uat", "prod"], local.environment) ? 1 : 0` |
| Name | `chedaws-edp-msk-active-controller-<environment>` |
| Metric | `ActiveControllerCount` |
| Namespace | `AWS/Kafka` |
| Threshold | `< 1` (comparison: `LessThanThreshold`) |
| Dimensions | `Cluster Name` = cluster name only |
| Evaluation | 2 × 60 seconds |
| Missing data | `notBreaching` |
| Actions | `aws_sns_topic.alerts.arn` |

### 7d. Disk Used Percentage (per broker)

| Attribute | Value |
|-----------|-------|
| Resource | `aws_cloudwatch_metric_alarm.msk_disk` |
| Count | `local.msk_broker_count[local.environment]` (2 or 3) |
| Name | `chedaws-edp-msk-disk-<environment>-<broker_id>` |
| Metric | `KafkaDataLogsDiskUsed` |
| Namespace | `AWS/Kafka` |
| Threshold | `≥ 80` (percent) |
| Dimensions | `Cluster Name` = cluster name, `Broker ID` = `tostring(count.index + 1)` |
| Evaluation | 2 × 60 seconds |
| Missing data | `notBreaching` |
| Actions | `aws_sns_topic.alerts.arn` |

---

## locals.tf Changes

Add the following to the `locals {}` block in `terraform/locals.tf`:

```hcl
msk_kafka_version = "3.9.x"

msk_instance_type = {
  dev  = "kafka.m7g.large"
  test = "kafka.m7g.large"
  uat  = "kafka.m7g.2xlarge"
  prod = "kafka.m7g.2xlarge"
}[local.environment]

msk_broker_count = {
  dev  = 2
  test = 2
  uat  = 3
  prod = 3
}[local.environment]

msk_storage_per_broker_gb = {
  dev  = 100
  test = 100
  uat  = 500
  prod = 500
}[local.environment]

msk_storage_max_gb = {
  dev  = 1024
  test = 1024
  uat  = 16384
  prod = 16384
}[local.environment]

msk_log_retention = {
  dev  = 7
  test = 7
  uat  = 30
  prod = 30
}[local.environment]

msk_enhanced_monitoring = {
  dev  = "PER_BROKER"
  test = "PER_BROKER"
  uat  = "PER_TOPIC_PER_BROKER"
  prod = "PER_TOPIC_PER_BROKER"
}[local.environment]
```

And add `"msk"` to `kms_services`:

```hcl
kms_services = {
  redshift = { service_principal = "redshift.amazonaws.com" }
  sns      = { service_principal = "sns.amazonaws.com" }
  cloudwatch_logs = {
    service_principal = "logs.${data.aws_region.current.region}.amazonaws.com"
  }
  msk = { service_principal = "kafka.amazonaws.com" }   # ← NEW
}
```

---

## Validation Rules Derived from Spec

| Rule | Source | Implementation note |
|------|--------|---------------------|
| App-tier subnet count ≥ broker count | FR-004 + FR-009 | `local.msk_broker_count` must be ≤ `length(data.aws_subnets.app.ids)`; add a `precondition` or `validation` in locals |
| Broker count must be multiple of AZ count | AWS constraint | MSK enforces this at the API level; plan fails if violated |
| `number_of_broker_nodes` equals 2 (dev/test) or 3 (uat/prod) | FR-004 | Driven by `local.msk_broker_count` |
| `volume_size` in GiB (not GB) | Terraform docs | 100 GiB ≈ 107.4 GB; use 100 as the value in Terraform (Terraform `volume_size` is in GiB) |
