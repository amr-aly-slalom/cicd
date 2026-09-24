# Tasks: Amazon MSK Cluster Provisioning

**Input**: Design documents from `specs/003-msk-cluster/`

**Plan**: [plan.md](./plan.md) | **Spec**: [spec.md](./spec.md) | **Data model**: [data-model.md](./data-model.md) | **Outputs contract**: [contracts/outputs.md](./contracts/outputs.md)

## Format: `[ID] [P?] [Story?] Description`

- **[P]**: Can be implemented in parallel (different files / no blocking dependency)
- **[Story]**: Which user story this task belongs to (US1–US4)
- Exact file paths are included in every task description

---

## Phase 1: Setup (locals.tf)

**Purpose**: Add all MSK-specific local values that every subsequent resource depends on. Must be complete before any `terraform/msk.tf` work begins.

- [X] T001 Add MSK sizing locals to `terraform/locals.tf`: `msk_kafka_version = "3.9.x"`; per-environment maps `msk_instance_type` (`kafka.m7g.large` dev/test, `kafka.m7g.2xlarge` uat/prod), `msk_broker_count` (2 dev/test, 3 uat/prod), `msk_storage_per_broker_gb` (100 dev/test, 500 uat/prod), `msk_storage_max_gb` (1024 dev/test, 16384 uat/prod), `msk_log_retention` (7 dev/test, 30 uat/prod), `msk_enhanced_monitoring` (`PER_BROKER` dev/test, `PER_TOPIC_PER_BROKER` uat/prod) — each map indexed by environment name and resolved via `[local.environment]`
- [X] T002 Add `msk = { service_principal = "kafka.amazonaws.com" }` to the `kms_services` map in `terraform/locals.tf` so the existing `module "kms"` `for_each` in `terraform/kms.tf` automatically provisions the MSK CMK; verify that the `kms` module sets `deletion_window_in_days = 30` for the MSK CMK (required by FR-012)

**Checkpoint**: Run `terraform plan` in any workspace — plan should show 1 new KMS key (`module.kms["msk"]`) and no errors on local value lookups.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Security group and log group must exist before `aws_msk_cluster.this` can reference them. Both can be authored in sequence in `terraform/msk.tf`.

- [X] T003 [US4] Create `terraform/msk.tf` and add `aws_security_group.msk` with two `dynamic "ingress"` blocks — one for port 9094 (TLS) and one for port 9098 (IAM) — iterating over `[for s in data.aws_subnet.app : s.cidr_block]`; add explicit egress block allowing all outbound; name the resource `chedaws-edp-msk-sg-${local.environment}`
- [X] T004 Add `aws_cloudwatch_log_group.msk` to `terraform/msk.tf` with `name = "/chedaws-edp/msk/${local.environment}"`, `retention_in_days = local.msk_log_retention`, and `kms_key_id = module.kms["cloudwatch_logs"].key_arn`

**Checkpoint**: `terraform plan` shows 3 new resources per workspace (KMS key + SG + log group). No cluster yet.

---

## Phase 3: User Story 1 — Deploy MSK Cluster Per Environment (Priority: P1) 🎯 MVP

**Goal**: Provision a correctly sized, named, and encrypted MSK cluster in the active workspace's VPC, with KMS at-rest encryption, TLS in-transit, IAM authentication, and broker logs flowing to CloudWatch.

**Independent Test**: Select the `dev` workspace, run `terraform apply`, and confirm an MSK cluster named `chedaws-edp-msk-dev` exists with 2 `kafka.m7g.large` brokers, 100 GiB EBS storage, KMS encryption (`module.kms["msk"]`), `bootstrap_brokers_sasl_iam` output populated, and broker logs appearing in `/chedaws-edp/msk/dev`.

- [X] T005 [US1] Add `aws_msk_cluster.this` to `terraform/msk.tf` with: `cluster_name = "chedaws-edp-msk-${local.environment}"`, `kafka_version = local.msk_kafka_version`, `number_of_broker_nodes = local.msk_broker_count`; `broker_node_group_info` block using `local.msk_instance_type`, `client_subnets = data.aws_subnets.app.ids`, `security_groups = [aws_security_group.msk.id]`, `storage_info { ebs_storage_info { volume_size = local.msk_storage_per_broker_gb } }`; `client_authentication { sasl { iam = true } }`; `encryption_info { encryption_at_rest_kms_key_arn = module.kms["msk"].key_arn; encryption_in_transit { client_broker = "TLS"; in_cluster = true } }`; `enhanced_monitoring = local.msk_enhanced_monitoring`; `logging_info { broker_logs { cloudwatch_logs { enabled = true; log_group = aws_cloudwatch_log_group.msk.name } } }`; `lifecycle { ignore_changes = [broker_node_group_info[0].storage_info] }`
- [X] T006 [P] [US1] Add five outputs to `terraform/outputs.tf`: `msk_cluster_arn`, `msk_cluster_name`, `msk_bootstrap_brokers_sasl_iam`, `msk_bootstrap_brokers_tls`, and `msk_current_version` — sourced from `aws_msk_cluster.this` attributes as defined in `specs/003-msk-cluster/contracts/outputs.md`

**Checkpoint**: `terraform apply` for `dev` completes without error. `terraform output msk_bootstrap_brokers_sasl_iam` returns comma-separated `host:9098` pairs. MSK cluster state = `ACTIVE`.

---

## Phase 4: User Story 2 — Environment-Appropriate High-Availability (Priority: P2)

**Goal**: Enforce correct broker-count/AZ distribution per environment (2-broker non-HA for dev/test; 3-broker 3-AZ HA for uat/prod) and alert on partition health.

**Independent Test**: Run `terraform plan` for `uat` workspace and confirm `number_of_broker_nodes = 3`. Apply `dev` and confirm brokers span a maximum of 2 AZs via `aws kafka describe-cluster`. Confirm 3 CloudWatch alarms exist for `dev` (2×UnderReplicated + 1×OfflinePartitions) and 5 for `uat` (3×UnderReplicated + 1×OfflinePartitions + 1×ActiveController). Note: disk alarms (T013) are added in Phase 5.

- [X] T007 [US2] Add a `lifecycle { precondition { condition = length(data.aws_subnets.app.ids) >= local.msk_broker_count; error_message = "The number of App-tier subnets (${length(data.aws_subnets.app.ids)}) is less than the required broker count (${local.msk_broker_count}) for environment '${local.environment}'. Ensure the VPC has enough App-tier subnets." } }` block to `aws_msk_cluster.this` in `terraform/msk.tf` (merge into the existing `lifecycle` block from T005) to fail the plan with a descriptive error if fewer App-tier subnets exist than required broker nodes
- [X] T008 [P] [US2] Add `aws_cloudwatch_metric_alarm.msk_under_replicated` to `terraform/msk.tf` using `count = local.msk_broker_count`; metric `UnderReplicatedPartitions`, namespace `AWS/Kafka`, threshold ≥ 1, comparison `GreaterThanOrEqualToThreshold`; dimensions `Cluster Name = aws_msk_cluster.this.cluster_name, Broker ID = tostring(count.index + 1)`; `evaluation_periods = 2`, `period = 60`, `treat_missing_data = "notBreaching"`, `alarm_actions = [aws_sns_topic.alerts.arn]`
- [X] T009 [P] [US2] Add `aws_cloudwatch_metric_alarm.msk_offline_partitions` to `terraform/msk.tf`; metric `OfflinePartitionsCount`, namespace `AWS/Kafka`, threshold ≥ 1; dimension `Cluster Name` only; `evaluation_periods = 2`, `period = 60`, `treat_missing_data = "notBreaching"`, `alarm_actions = [aws_sns_topic.alerts.arn]`
- [X] T010 [P] [US2] Add `aws_cloudwatch_metric_alarm.msk_active_controller` to `terraform/msk.tf` using `count = contains(["uat", "prod"], local.environment) ? 1 : 0`; metric `ActiveControllerCount`, namespace `AWS/Kafka`, threshold < 1, comparison `LessThanThreshold`; dimension `Cluster Name` only; same evaluation and notification settings as T008

**Checkpoint**: `terraform plan` for `dev` shows count=0 for `msk_active_controller` (no HA alarm in dev). `terraform plan` for `prod` shows count=1. Alarms exist in CloudWatch after apply.

---

## Phase 5: User Story 3 — Storage Auto-Scaling (Priority: P2)

**Goal**: Storage on every broker automatically expands before hitting 80% utilisation, without operator intervention and without cluster replacement.

**Independent Test**: After applying `dev`, run `aws application-autoscaling describe-scalable-targets --service-namespace kafka` and confirm a target is registered for the `dev` cluster ARN with `MaxCapacity = 1024`. Run `aws application-autoscaling describe-scaling-policies --service-namespace kafka` and confirm `TargetValue = 70.0`.

- [X] T011 [US3] Add `aws_appautoscaling_target.msk_storage` to `terraform/msk.tf` with `service_namespace = "kafka"`, `resource_id = aws_msk_cluster.this.arn`, `scalable_dimension = "kafka:broker-storage:VolumeSize"`, `min_capacity = local.msk_storage_per_broker_gb`, `max_capacity = local.msk_storage_max_gb`; add `depends_on = [aws_msk_cluster.this]`
- [X] T012 [US3] Add `aws_appautoscaling_policy.msk_storage` to `terraform/msk.tf` with `policy_type = "TargetTrackingScaling"`; `target_tracking_scaling_policy_configuration` block: `predefined_metric_specification { predefined_metric_type = "KafkaBrokerStorageUtilization" }`, `target_value = 70`, `disable_scale_in = true`, `scale_out_cooldown = 600`, `scale_in_cooldown = 600`; reference `aws_appautoscaling_target.msk_storage` for service_namespace, resource_id, scalable_dimension
- [X] T013 [P] [US3] Add `aws_cloudwatch_metric_alarm.msk_disk` to `terraform/msk.tf` using `count = local.msk_broker_count`; metric `KafkaDataLogsDiskUsed`, namespace `AWS/Kafka`, threshold ≥ 80 (percent), comparison `GreaterThanOrEqualToThreshold`; dimensions `Cluster Name = aws_msk_cluster.this.cluster_name, Broker ID = tostring(count.index + 1)`; `evaluation_periods = 2`, `period = 60`, `treat_missing_data = "notBreaching"`, `alarm_actions = [aws_sns_topic.alerts.arn]`

**Checkpoint**: `dev` workspace plan shows 3 new auto-scaling resources (target + policy + 2 disk alarms). `uat` plan shows 3 new auto-scaling resources + 3 disk alarms. `MaxCapacity` differs: 1024 (dev/test) vs 16384 (uat/prod).

---

## Phase 6: User Story 4 — Secure Connectivity for AWS Glue Streaming (Priority: P3)

**Goal**: Validate that the security group only permits App-tier consumers, IAM is the sole auth method, and the correct bootstrap endpoints are exported.

> **Note**: `aws_security_group.msk` (FR-013, FR-014) is implemented in T003 (Phase 2 Foundational) as a prerequisite for the MSK cluster. Tasks T014–T015 verify that the security requirements from T003 and T005 are correctly implemented.

**Independent Test**: From a host in an App-tier subnet, `nc -zv <bootstrap-broker> 9098` succeeds. From a host outside App-tier CIDRs, the same connection times out.

- [X] T014 [US4] Review `terraform/msk.tf`: confirm `aws_security_group.msk` dynamic ingress blocks reference `data.aws_subnet.app` (not `data.aws_subnet.db` or any hardcoded CIDR); confirm `aws_msk_cluster.this` `client_authentication` block contains only `sasl { iam = true }` with no `scram`, `tls`, or `unauthenticated` sub-blocks; confirm `terraform/outputs.tf` exposes `msk_bootstrap_brokers_sasl_iam` per `specs/003-msk-cluster/contracts/outputs.md`
- [X] T015 [P] [US4] Run `.\auto\tflint` from the repo root and resolve all warnings and errors across `terraform/msk.tf`, `terraform/locals.tf`, and `terraform/outputs.tf`

**Checkpoint**: `auto/tflint` reports 0 errors, 0 warnings. Code review confirms no DB-tier access and no non-IAM auth paths.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: End-to-end plan validation for all environments and post-apply acceptance verification.

- [ ] T016 Run `terraform plan` sequentially for all 4 workspaces from `terraform/` — `dev` and `test` must each show ~10 new resources (SG + log group + KMS + cluster + autoscaling ×2 + alarms ×5); `uat` and `prod` must each show ~11 new resources (same + active controller alarm); confirm zero destroy/replace operations
- [ ] T017 [P] Complete acceptance validation from `specs/003-msk-cluster/quickstart.md` Scenarios 1–8 against a deployed `dev` environment: cluster ACTIVE, auto-scaling registered, bootstrap endpoints reachable from App-tier, alarms created, KMS encryption confirmed, CloudWatch log streams appearing; Scenario 8 validates SC-006 — temporarily set `msk_instance_type uat = "kafka.m7g.4xlarge"` in `terraform/locals.tf`, run `terraform plan` for `uat`, confirm plan shows `~ 1 to update` (in-place) with no `-/+` destroy/recreate, then revert

---

## Dependencies & Execution Order

### Phase Dependencies

```
Phase 1: Setup                → no dependencies; start immediately
Phase 2: Foundational         → depends on Phase 1 (locals must exist before msk.tf resources compile)
Phase 3: US1                  → depends on Phase 2 (cluster references SG and log group)
Phase 4: US2                  → depends on Phase 3 (precondition added to cluster; alarms reference cluster name)
Phase 5: US3                  → depends on Phase 3 (auto-scaling target needs cluster ARN)
Phase 6: US4                  → depends on Phase 2 + Phase 3 (code review of SG and cluster auth)
Phase 7: Polish               → depends on all prior phases complete
```

### User Story Dependencies

| Story | Depends On | Can Parallel With |
|-------|------------|-------------------|
| **US1 (P1)** | Phase 2 complete | — |
| **US2 (P2)** | US1 complete (T005) | US3 (different resources) |
| **US3 (P2)** | US1 complete (T005) | US2 (different resources) |
| **US4 (P3)** | Phase 2 + US1 complete | — (review phase) |

### Within Each User Story

| Task | Depends On | Notes |
|------|------------|-------|
| T006 | T005 started | Different file (`outputs.tf`) — genuinely parallel |
| T007 | T005 merged | Modifies the `lifecycle` block created in T005 |
| T008, T009, T010 | T005 (cluster name) | Can be written in parallel within `msk.tf` |
| T011 | T005 (cluster ARN) | Auto-scaling target needs cluster resource |
| T012 | T011 | Policy references target |
| T013 | T005 (cluster name) | Parallel with T011/T012 |

---

## Parallel Execution Examples

### Parallel: User Story 2 Alarms (after T005 complete)

```bash
# Author all three alarm resources simultaneously:
Task T008: Add msk_under_replicated alarm (count = broker_count)
Task T009: Add msk_offline_partitions alarm (cluster-level)
Task T010: Add msk_active_controller alarm (uat/prod only)
```

### Parallel: US2 + US3 (after T005 complete)

```bash
# Two developers, same msk.tf file — review for conflicts before committing:
Developer A: T007 + T008 + T009 + T010 (US2 — alarms and precondition)
Developer B: T011 + T012 + T013 (US3 — auto-scaling and disk alarm)
```

### Parallel: Outputs + Cluster (during US1)

```bash
# T006 can be authored while T005 is still being written:
Task T005: aws_msk_cluster.this in terraform/msk.tf
Task T006: MSK outputs in terraform/outputs.tf  ← different file, no conflict
```

---

## Implementation Strategy

### MVP (Phase 1–3 only, T001–T006)

1. Add MSK locals to `terraform/locals.tf` (T001–T002)
2. Create SG + log group in `terraform/msk.tf` (T003–T004)
3. Add MSK cluster resource + outputs (T005–T006)
4. **STOP AND VALIDATE**: Apply `dev`, confirm cluster reaches `ACTIVE`, bootstrap endpoints in outputs
5. MVP delivers a running MSK cluster with KMS encryption, TLS in-transit, and IAM auth

### Incremental Delivery

1. **MVP**: T001–T006 → Working MSK cluster per environment
2. **Add HA validation**: T007–T010 → Subnet precondition + partition health alarms
3. **Add auto-scaling**: T011–T013 → Storage expands automatically before 80% threshold
4. **Add connectivity validation**: T014–T015 → Tflint clean, security reviewed
5. **Final validation**: T016–T017 → All 4 environments clean, acceptance criteria met

---

## Notes

- All 17 tasks target existing files (`terraform/locals.tf`, `terraform/outputs.tf`) or a single new file (`terraform/msk.tf`). No new modules are created.
- `lifecycle { ignore_changes = [broker_node_group_info[0].storage_info] }` in T005 is critical — without it, Terraform will attempt to reset auto-scaled EBS volumes back to the declared `msk_storage_per_broker_gb` on every apply.
- T007 (precondition) and T005 (lifecycle ignore_changes) both use the same `lifecycle` block — T007 adds `precondition` into the block established in T005.
- The AppAutoScaling `resource_id` for MSK is the cluster ARN (`aws_msk_cluster.this.arn`). Verify the exact format after first apply using `aws application-autoscaling describe-scalable-targets --service-namespace kafka` if the plan fails.
- `KafkaDataLogsDiskUsed` is a **percentage** metric (0–100), not bytes. The threshold of `80` in T013 means 80%.
- `msk_enhanced_monitoring` maps to `PER_BROKER` for dev/test and `PER_TOPIC_PER_BROKER` for uat/prod (constitutional minimum `PER_BROKER` met for all environments per clarification 2026-06-30).
