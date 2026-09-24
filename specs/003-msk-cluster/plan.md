# Implementation Plan: Amazon MSK Cluster Provisioning

**Branch**: `feat/msk-cluster` | **Date**: 2026-06-30 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-msk-cluster/spec.md`

## Summary

Provision one Amazon MSK cluster per Terraform workspace (dev, test, uat, prod) using the AWS-recommended Kafka 3.9.x. Dev/test clusters use two `kafka.m7g.large` brokers across two AZs with 100 GiB starting EBS storage and a 1 TiB auto-scaling ceiling. UAT/prod clusters use three `kafka.m7g.2xlarge` brokers across three AZs with 500 GiB starting EBS storage and a 16 TiB auto-scaling ceiling. Brokers are placed in App-tier VPC subnets, co-located with existing Glue jobs, and protected by a dedicated security group allowing ports 9094 and 9098 exclusively from App-tier CIDR ranges. Authentication uses SASL/IAM over TLS; encryption at rest uses a new KMS CMK added to the existing `local.kms_services` map. Storage auto-scaling is managed by Application Auto Scaling targeting 70% utilisation. Four CloudWatch alarm types cover partition health and disk usage. All resources are defined inline in `terraform/msk.tf` per the constitution's single-consumer rule.

## Technical Context

**Language/Version**: Terraform >= 1.5.0, HCL; AWS Provider `~> 6.0`; Random Provider `~> 3.0`

**Primary Dependencies**: `aws_msk_cluster`, `aws_security_group`, `aws_cloudwatch_log_group`, `aws_appautoscaling_target`, `aws_appautoscaling_policy`, `aws_cloudwatch_metric_alarm`; existing `module "kms"` (extended via `local.kms_services`); existing `aws_sns_topic.alerts`; existing `data.aws_subnets.app` and `data.aws_subnet.app`

**Storage**: MSK EBS volumes (100/500 GiB → 1024/16384 GiB max) managed by AWS Application Auto Scaling; Terraform remote state on existing S3 + DynamoDB backend

**Testing**: `tflint` via `auto/tflint`; `terraform plan` for all 4 workspaces; post-apply verification commands in [quickstart.md](./quickstart.md)

**Target Platform**: AWS ap-southeast-2 (Sydney); 4 environments; dev/test account `381491832813`, uat account `339712719726`, prod account `637423180765`

**Project Type**: IaC — inline root configuration in `terraform/msk.tf`; no new Terraform module created

**Performance Goals**: Kafka 3.9.x on `kafka.m7g.2xlarge` supports ~500 MB/s throughput per broker (well above the 7.5 MB/s sustained / 22 MB/s peak workload requirement from spec)

**Constraints**: All MSK resources defined inline in `terraform/msk.tf`; reuse existing `data.aws_subnets.app` for broker subnet IDs; extend `local.kms_services` for the MSK CMK (no new `module "kms"` block); reuse `cloudwatch_logs` CMK and `aws_sns_topic.alerts` from spec-001 (Redshift); `lifecycle { ignore_changes = [broker_node_group_info[0].storage_info] }` required to prevent Terraform from reverting auto-scaled storage

**Scale/Scope**: 4 environments × ~10 resources each = ~40 total managed resources; 2–3 brokers per environment; auto-scaling handles storage growth as topics are onboarded

## Constitution Check

*GATE: All principles evaluated pre-design. Re-checked after Phase 1 design — all still pass.*

- [x] **Security**: MSK EBS volumes encrypted with a dedicated KMS CMK (`module.kms["msk"]`); encryption in transit set to `TLS` with `in_cluster = true`; SASL/IAM authentication only (no username/passwords); security group restricts ports 9094 and 9098 to App-tier CIDR ranges only; no secrets or account IDs hardcoded — all sourced from `local.*` values; IAM auth evaluated per-request by AWS, no stored credentials.

- [x] **Observability**: CloudWatch Log Group per environment under `/chedaws-edp/msk/<env>` with environment-tiered retention (7/7/30/30 days); 4 CloudWatch Alarm types covering `UnderReplicatedPartitions`, `OfflinePartitionsCount`, `ActiveControllerCount` (uat/prod), and `KafkaDataLogsDiskUsed` (per broker); all alarms publish to existing `aws_sns_topic.alerts`; follows `/chedaws-edp/<component>/<env>` convention.

- [x] **Durability**: MSK is a fully managed service with AWS-managed EBS durability; RF=3 for uat/prod (3 brokers); Application Auto Scaling prevents storage exhaustion; Terraform state on existing S3 + DynamoDB backend — no new state configuration required.

- [x] **Fault-Tolerance**: UAT/prod brokers span 3 AZs (3 nodes in `data.aws_subnets.app`); dev/test use 2 brokers across 2 AZs — explicitly accepted non-HA trade-off documented in spec (cost vs. resilience for non-production); `disable_scale_in = true` on storage auto-scaling prevents capacity reduction; `msk_active_controller` alarm only enabled for uat/prod (where HA guarantees apply).

- [x] **Cost Optimisation**: Dev/test: `kafka.m7g.large` (2 brokers), 100 GiB EBS, `PER_BROKER` monitoring level; uat/prod: `kafka.m7g.2xlarge` (3 brokers), 500 GiB EBS, `PER_TOPIC_PER_BROKER` monitoring; AppAutoScaling uses target tracking (no over-provisioning); storage starts at minimum viable size and scales on demand; `default_tags` in provider block apply cost allocation tags to all resources automatically.

- [x] **DRY & Modularity**: All MSK resources defined inline in `terraform/msk.tf` — single consumer (no other feature spec references MSK), no module created per constitution v1.1.1 single-consumer rule; MSK CMK added to existing `local.kms_services` map (extends the existing `module "kms"` `for_each` without a new block); reuses existing `data.aws_subnets.app` without modification; follows naming and layout patterns established in `redshift.tf`; no edits to `terraform-legacy/`.

## Project Structure

### Documentation (this feature)

```text
specs/003-msk-cluster/
├── plan.md              ← This file (/speckit.plan output)
├── research.md          ← Phase 0 output: Kafka version, auto-scaling, alarm design decisions
├── data-model.md        ← Phase 1 output: entity attributes, locals structure, validation rules
├── quickstart.md        ← Phase 1 output: validation scenarios and verification commands
├── contracts/
│   └── outputs.md       ← Phase 1 output: Terraform output definitions
├── checklists/
│   └── requirements.md  ← Spec quality checklist (all 12 items passing)
└── tasks.md             ← Phase 2 output (/speckit.tasks command — NOT created by /speckit.plan)
```

### Source Code

```text
terraform/
├── msk.tf               ← NEW — all MSK resources (see below)
├── locals.tf            ← MODIFIED — add msk_* sizing locals + "msk" entry in kms_services
├── outputs.tf           ← MODIFIED — add 5 MSK outputs (cluster ARN, name, bootstrap endpoints)
├── data.tf              ← UNCHANGED — existing data.aws_subnets.app and data.aws_subnet.app reused
├── kms.tf               ← UNCHANGED — existing module "kms" for_each auto-provisions MSK CMK
├── providers.tf         ← UNCHANGED
├── variables.tf         ← UNCHANGED
├── redshift.tf          ← UNCHANGED
└── sns.tf               ← UNCHANGED
```

**`terraform/msk.tf` resource layout** (in declaration order):

```text
# Security group
aws_security_group.msk                          — ports 9094, 9098; source = App-tier CIDRs

# Broker logging
aws_cloudwatch_log_group.msk                    — /chedaws-edp/msk/<env>; tiered retention

# Cluster
aws_msk_cluster.this                            — broker_node_group_info, auth, encryption,
                                                  enhanced_monitoring, logging_info
# Storage auto-scaling
aws_appautoscaling_target.msk_storage           — service_namespace = kafka
aws_appautoscaling_policy.msk_storage           — TargetTracking at 70% utilisation

# CloudWatch alarms
aws_cloudwatch_metric_alarm.msk_under_replicated[count]  — count = broker_count; per-broker
aws_cloudwatch_metric_alarm.msk_offline_partitions        — cluster-level
aws_cloudwatch_metric_alarm.msk_active_controller         — uat/prod only (count = 0 or 1)
aws_cloudwatch_metric_alarm.msk_disk[count]               — count = broker_count; per-broker
```

**`terraform/locals.tf` additions**:

```text
msk_kafka_version              — "3.9.x"
msk_instance_type[environment] — kafka.m7g.large (dev/test), kafka.m7g.2xlarge (uat/prod)
msk_broker_count[environment]  — 2 (dev/test), 3 (uat/prod)
msk_storage_per_broker_gb      — 100 GiB (dev/test), 500 GiB (uat/prod)
msk_storage_max_gb             — 1024 GiB (dev/test), 16384 GiB (uat/prod)
msk_log_retention              — 7d (dev/test), 30d (uat/prod)
msk_enhanced_monitoring        — PER_BROKER (dev/test), PER_TOPIC_PER_BROKER (uat/prod)
kms_services["msk"]            — added to existing map: service_principal = kafka.amazonaws.com
```
