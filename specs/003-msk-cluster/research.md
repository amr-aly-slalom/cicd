# Research: Amazon MSK Cluster Provisioning

**Feature**: 003-msk-cluster | **Date**: 2026-06-30

---

## Decision 1: Apache Kafka Version

**Decision**: `3.9.x`

**Rationale**: AWS marks `3.9.x` as "Recommended" in the MSK supported-versions table (released 2025-04-21). It is the last version to support both ZooKeeper and KRaft metadata management, giving the team flexibility to migrate to KRaft in a future feature. AWS has committed to extended support for a minimum of two years from its release date (minimum through April 2027), well beyond the project horizon. It includes tiered storage improvements, enhanced consumer group handling, and all security fixes from 3.x.

**Alternatives considered**:

| Version | Released | End-of-Support | Notes |
|---------|----------|----------------|-------|
| 3.7.x | 2024-05-29 | 2026-09-01 | Approaching EOL; KRaft GA on MSK |
| 3.8.x | 2025-02-20 | TBD | Stable, but not recommended |
| **3.9.x** | 2025-04-21 | TBD (≥Apr 2027) | **Selected — AWS Recommended** |
| 4.0.x | 2025-05-16 | TBD | Drops ZooKeeper; newer consumer rebalance protocol |
| 4.1.x | 2025-10-15 | TBD | Queues preview; Eligible Leader Replicas |

**Note**: 3.6.0 end-of-support was 2026-06-01 — already past as of this feature. Any version ≤ 3.6.0 must not be used. The local value `local.msk_kafka_version = "3.9.x"` must be updated to a newer version when upgrading clusters in future.

---

## Decision 2: MSK Storage Auto-Scaling Mechanism

**Decision**: `aws_appautoscaling_target` + `aws_appautoscaling_policy` with Application Auto Scaling (not inline in `aws_msk_cluster`)

**Rationale**: MSK EBS storage auto-scaling is managed by AWS Application Auto Scaling, not by a native block inside `aws_msk_cluster`. Two separate Terraform resources are required per cluster:

```
aws_appautoscaling_target (service_namespace = "kafka"):
  resource_id        = aws_msk_cluster.this.arn
  scalable_dimension = "kafka:broker-storage:VolumeSize"
  min_capacity       = <starting_volume_gb>
  max_capacity       = <max_volume_gb>

aws_appautoscaling_policy (policy_type = "TargetTrackingScaling"):
  predefined_metric_type = "KafkaBrokerStorageUtilization"
  target_value           = 70   # trigger at 70%; alarm threshold is 80%
  disable_scale_in       = true # MSK EBS volumes can only grow, never shrink
  scale_out_cooldown     = 600  # 10-minute cooldown between scale-outs
```

**Key constraint**: `disable_scale_in = true` is mandatory — MSK does not support shrinking EBS volumes once expanded. Attempting to set `disable_scale_in = false` would result in failed scale-in actions.

**Target tracking at 70%**: The auto-scaling target is set 10 percentage points below the CloudWatch alarm threshold of 80%. This gives auto-scaling time to expand the volume and complete the resize before the alarm fires. If auto-scaling fails to keep up (e.g., hitting the ceiling), the 80% alarm provides the operational safety net.

**Alternatives considered**:
- `provisioned_throughput` block inside `aws_msk_cluster` → This controls I/O throughput (MiB/s), not storage auto-scaling. Not applicable.
- Manual `terraform apply` on storage increase → Viable but requires operator intervention; does not satisfy FR-006/FR-007.

---

## Decision 3: CloudWatch Disk Alarm Design

**Decision**: Alarm on `KafkaDataLogsDiskUsed` percentage metric, threshold = 80, one alarm per broker per environment.

**Rationale**: `KafkaDataLogsDiskUsed` is confirmed as a **percentage** metric (0–100 scale) available at the `DEFAULT` monitoring level at no additional cost (CloudWatch namespace: `AWS/Kafka`). The metric has `Cluster Name` and `Broker ID` dimensions — meaning alarms must be created per broker, not per cluster. For environment sizes:
- dev/test: 2 broker alarms (`count = 2`)
- uat/prod: 3 broker alarms (`count = 3`)

Using `count = local.msk_broker_count[local.environment]` in Terraform, broker IDs are addressed as `tostring(count.index + 1)`.

**Important note on auto-scaling interaction**: The `aws_appautoscaling_policy` target tracking at 70% means routine growth triggers auto-scaling before the 80% alarm fires. The alarm at 80% is a safety net for cases where: (a) auto-scaling hits its maximum ceiling, (b) auto-scaling responds too slowly to a sudden burst, or (c) auto-scaling is disabled/broken.

**Metric confirmed details**:

| Metric | Namespace | Dimensions | Level | Unit |
|--------|-----------|------------|-------|------|
| `KafkaDataLogsDiskUsed` | `AWS/Kafka` | Cluster Name, Broker ID | DEFAULT | Percent |
| `UnderReplicatedPartitions` | `AWS/Kafka` | Cluster Name, Broker ID | DEFAULT | Count |
| `OfflinePartitionsCount` | `AWS/Kafka` | Cluster Name | DEFAULT | Count |
| `ActiveControllerCount` | `AWS/Kafka` | Cluster Name | DEFAULT | Count |

**Alternatives considered**:
- Alarm on `KafkaDataLogsDiskUsed` in bytes → Metric is not in bytes; it is a native percentage.
- CloudWatch Metric Math to compute percentage → Unnecessary; native percentage metric is available.
- Single cluster-level disk alarm → `KafkaDataLogsDiskUsed` requires `Broker ID` dimension; cluster-level is not directly available.

---

## Decision 4: IAM Authentication Terraform Syntax

**Decision**: `client_authentication { sasl { iam = true } }` within `aws_msk_cluster`

**Rationale**: MSK IAM authentication is enabled via the `sasl.iam` flag. When set to `true` with `encryption_in_transit.client_broker = "TLS"`, MSK exposes the `bootstrap_brokers_sasl_iam` output attribute, containing the port 9098 bootstrap endpoints. AWS Glue Streaming natively supports this authentication method via the MSK IAM auth library — no credential management required.

**TLS in-transit configuration**:
```
encryption_info {
  encryption_at_rest_kms_key_arn = module.kms["msk"].key_arn
  encryption_in_transit {
    client_broker = "TLS"
    in_cluster    = true   # default but made explicit for clarity
  }
}
```

`in_cluster = true` enforces TLS for broker-to-broker replication traffic, satisfying FR-011.

---

## Decision 5: Metadata Management (KRaft vs ZooKeeper)

**Decision**: Default mode for `3.9.x` (ZooKeeper)

**Rationale**: For Kafka 3.9.x, MSK supports both ZooKeeper and KRaft metadata modes. No explicit `configuration_info` block is required to use the default ZooKeeper mode. MSK manages ZooKeeper nodes automatically at no additional cost. KRaft mode is available as an upgrade path in a future feature (increases broker limit from 30 to 60 per cluster). No action required in `aws_msk_cluster` to use ZooKeeper mode; the default applies.

---

## Decision 6: Application Auto Scaling Resource ID Format

**Decision**: `resource_id = aws_msk_cluster.this.arn`

**Rationale**: For Amazon MSK, the Application Auto Scaling API uses the cluster ARN as the `ResourceId` parameter. In Terraform `aws_appautoscaling_target`, `resource_id` accepts the cluster ARN directly (not a composite string like `cluster/<name>/broker-storage`). This is confirmed by the AWS MSK Application Auto Scaling integration pattern.

**Verification note**: The implementer must confirm the exact `resource_id` format by running `aws application-autoscaling describe-scalable-targets --service-namespace kafka` after manually enabling storage auto-scaling on a test cluster in the AWS Console, then matching the `ResourceId` value returned.
