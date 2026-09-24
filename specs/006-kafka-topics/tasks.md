---

description: "Task list for Kafka Topic Self-Service Platform"
---

# Tasks: Kafka Topic Self-Service Platform

**Input**: Design documents from `specs/005-kafka-topics/`

**Prerequisites**: [plan.md](plan.md) · [spec.md](spec.md) · [research.md](research.md) · [data-model.md](data-model.md) · [contracts/](contracts/) · [quickstart.md](quickstart.md)

**Status key**: `[x]` = complete, `[ ]` = outstanding

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Directory skeleton, schemas in live location, governance files.

- [x] T001 Create `kafka/producers/` and `kafka/consumers/` directory skeleton (add `.gitkeep` in each leaf)
- [x] T002 [P] Copy `specs/005-kafka-topics/contracts/producer-schema.json` → `kafka/schema/producer-schema.json`
- [x] T003 [P] Copy `specs/005-kafka-topics/contracts/consumer-schema.json` → `kafka/schema/consumer-schema.json`
- [x] T004 Create `kafka/CODEOWNERS` assigning `@chedaws-platform-team` as required reviewer for all files under `kafka/`
- [x] T005 Create `kafka/README.md` — onboarding guide covering: topic naming convention, how to open a producer PR, how to open a consumer PR, platform constants (Roles Anywhere Trust Anchor ARN, Profile ARN per account, bootstrap broker endpoints per environment, link to `terraform output`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Create the Terraform locals skeleton and CI script/workflow. No Kafka resources are created here — just confirms the pipeline is wired before any topic registration.

- [x] T006 Create `terraform/kafka_topics.tf` with the eight locals (`_producer_files`, `topics_this_env`, `topics_decommissioned_this_env`, `_producers_this_env`, `_topic_keys_per_app`, `_consumer_files`, `consumers_this_env`, `aws_producers_this_env`, `aws_consumers_this_env`, `onprem_producers_this_env`, `onprem_consumers_this_env`, `_producer_slug_list`, `_producer_slug_unique`, `_consumer_slug_list`, `_consumer_slug_unique`) — no resource blocks yet; verify `terraform validate` passes
- [x] T007 Add `terraform_data.kafka_unique_name_check` with preconditions for duplicate producer slug and duplicate consumer slug
- [x] T008 Add `terraform_data.kafka_producer_name_length_check` with precondition for IAM role name <= 64 characters
- [x] T009 Create `.github/scripts/validate-topic-names.py` enforcing: (1) producer file placement (`path.parent.name == metadata.businessName`, `path.stem == metadata.appName`), (2) consumer file placement (`path.parent.name == "consumers"`, `path.stem == metadata.name`), (3) event name pattern `^[a-z][a-z0-9-]*$`, (4) event name unique within app, (5) overlap guard (event not in both `spec.events` and `spec.decommissionedEvents`), (6) consumer cross-reference (every `{businessName, appName, eventName}` triple resolves to an active event), (7) decommission guard for deleted YAML files (`spec.decommission: true` must have been set), (8) duplicate producer slug detection, (9) duplicate consumer slug detection, (10) warning when consumer references > 80 topics
- [x] T010 Create `.github/workflows/kafka-topics.yaml` — dedicated workflow with `paths:` trigger on `kafka/**`, `terraform/kafka_topics.tf`, `terraform/kafka_e2e_canary.tf`, `lambda/kafka-e2e-canary/**`; includes `validate-yaml` job (`pip install check-jsonschema`, schema validation loops, call to `validate-topic-names.py`) followed by `dev-tfplan`/`dev-tfapply` (all pushes), `test-tfplan`/`test-tfapply` (main only), `uat` and `prod` plan + gated apply jobs (GitHub Environments `uat-kafka-approval`, `prod-kafka-approval`) gated on tag push

**Checkpoint**: `terraform validate` with locals-only `kafka_topics.tf` passes. CI `validate-yaml` job runs and passes on empty directories.

---

## Phase 3: User Story 1 — Producer Self-Service (Priority: P1)

**Goal**: Producer YAML → `aws_msk_topic` + IAM role + IAM policy + attachment, all three identity types.

- [x] T011 [US1] Add `resource "aws_msk_topic" "this"` block (`for_each = local.topics_this_env`; `cluster_arn`, `name = each.key`, `partition_count`, `replication_factor`, `configs = jsonencode(...)` with `retention.ms`, `retention.bytes`, `cleanup.policy`, optional `max.message.bytes`)
- [x] T012 [US1] Add `resource "aws_iam_policy" "kafka_producer"` block (`for_each = local._producers_this_env`; policy with ConnectToCluster + ProduceToTopic statements using `_topic_keys_per_app`; description)
- [x] T013 [US1] Add `resource "aws_iam_role" "kafka_aws_producer"` + `aws_iam_role_policy_attachment.kafka_aws_producer` blocks (`for_each = local.aws_producers_this_env`; trust policy lists `each.value` as AWS principal; description)
- [x] T014 [US1] Add `resource "aws_iam_role" "kafka_onprem_producer"` + `aws_iam_role_policy_attachment.kafka_onprem_producer` blocks (`for_each = local.onprem_producers_this_env`; trust policy principal `rolesanywhere.amazonaws.com` with CN condition; description)
- [x] T015 [US1] Add `output "kafka_producer_role_arns"` merging AWS and on-prem producer ARNs keyed by app key
- [x] T016 [US1] Add `output "topics_pending_destruction"` keyed on `topics_decommissioned_this_env`
- [x] T017 [US1] Create `kafka/producers/platform/e2e.yaml` — canary producer registration (`metadata.businessName: platform`, `metadata.appName: e2e`, event `canary` with `partitions: 1`, `retentionMs: 3600000`, `cleanupPolicy: delete`; `iamRoles` per env = canary Lambda execution role ARN)

**Checkpoint**: `terraform plan` for dev shows the expected resources for `edp-dev.platform.e2e.canary`. CI `validate-yaml` passes. Topic exists on MSK after apply.

---

## Phase 4: User Story 2 — Consumer Self-Service (Priority: P2)

**Goal**: Consumer YAML → IAM role + policy + attachment, AWS and on-prem identity types, with optional consumer group prefix.

- [x] T018 [US2] Add `resource "aws_iam_policy" "kafka_consumer"` block (`for_each = local.consumers_this_env`; policy with ConnectToCluster + per-topic ReadData statements using `topic.businessName`/`topic.appName`/`topic.eventName`; optional ConsumerGroup statement using `spec.consumer.consumerGroupPrefix`; description)
- [x] T019 [US2] Add `resource "aws_iam_role" "kafka_aws_consumer"` + `aws_iam_role_policy_attachment.kafka_aws_consumer` blocks (`for_each = local.aws_consumers_this_env`; trust policy lists `each.value` as AWS principal; description)
- [x] T020 [US2] Add `resource "aws_iam_role" "kafka_onprem_consumer"` + `aws_iam_role_policy_attachment.kafka_onprem_consumer` blocks (`for_each = local.onprem_consumers_this_env`; Roles Anywhere trust policy with CN condition; description)
- [x] T021 [US2] Add `output "kafka_consumer_role_arns"` merging AWS and on-prem consumer ARNs keyed by consumer slug
- [x] T022 [US2] Create `kafka/consumers/platform-e2e-canary-consumer.yaml` — canary consumer registration (`metadata.name: platform-e2e-canary-consumer`; topic ref `{businessName: platform, appName: e2e, eventName: canary}`; `consumerGroupPrefix: platform-e2e-canary`; `iamRoles` per env = canary Lambda execution role ARN)

**Checkpoint**: Consumer IAM role and policy exist in dev after apply. Policy document includes ReadData on the canary topic ARN and AlterGroup/DescribeGroup on `<cluster_arn>/group/platform-e2e-canary*`.

---

## Phase 5: User Story 3 — Decommission Guards (Priority: P3)

**Goal**: Both decommission guards work. CI blocks unguarded removals.

- [x] T023 [US3] Verify `local.topics_this_env` correctly excludes events in `spec.decommissionedEvents` and apps with `spec.decommission: true`; confirm by adding a test YAML with `decommissionedEvents: [canary]` and checking plan shows destroy for the canary topic only
- [x] T024 [US3] Verify decommission guard in `validate-topic-names.py` (whole-app): simulate deleting `kafka/producers/platform/e2e.yaml` locally (without `decommission: true`) and run the script with `--check-deletions`; confirm it exits non-zero with a clear error
- [x] T025 [US3] Verify overlap guard in `validate-topic-names.py`: create a YAML with an event name in both `spec.events` and `spec.decommissionedEvents`; confirm script exits non-zero
- [x] T026 [US3] Restore `kafka/producers/platform/e2e.yaml` to active state for ongoing use; update `kafka/README.md` to document both decommission procedures

**Checkpoint**: Both decommission guards are active. CI blocks all unguarded removals.

---

## Phase 6: User Story 4 — E2E Canary (Priority: P1)

**Goal**: Synthetic canary Lambda runs every 5 minutes via EventBridge; alarms route to SNS; Lambda ZIP stored in `module.platform_s3`.

- [x] T027 [US4] Create `lambda/kafka-e2e-canary/handler.py` — Python 3.12 handler implementing the 5-step cycle: assume CanaryProducerRole → flush (seek_to_end) → produce → wait → assume CanaryConsumerRole → consume → validate → emit `KafkaE2ETestSuccess` metric; `try/finally` ensures metric is always emitted
- [x] T028 [US4] Create `lambda/kafka-e2e-canary/requirements.txt` with `kafka-python-ng>=2.2.3`, `aws-msk-iam-sasl-signer-python>=1.0.2`, `boto3>=1.34.0`
- [x] T029 [US4] Create `terraform/kafka_e2e_canary.tf` containing: `aws_iam_role.canary_lambda_execution` (no direct Kafka permissions; `sts:AssumeRole` on producer + consumer role ARNs only), `aws_lambda_function.canary` (Python 3.12; timeout 60s; memory 256 MB; VPC App-tier subnets; ZIP from `module.platform_s3` at `e2e/kafka/canary/function.zip`), `aws_cloudwatch_event_rule.canary` (`rate(5 minutes)`, ENABLED), `aws_cloudwatch_log_group.canary` (`/chedaws-edp/kafka-e2e-canary/<env>`; KMS-encrypted; per-env retention), `aws_cloudwatch_metric_alarm.kafka_e2e_test_failure` (2-period evaluation; `treat_missing_data = "breaching"`; alarm action = `aws_sns_topic.alerts.arn`; no `count` gate), `aws_cloudwatch_metric_alarm.canary_lambda_errors` (Lambda Errors metric; `GreaterThanOrEqualToThreshold 1`; no `count` gate)

**Checkpoint**: Canary Lambda executes on schedule; `KafkaE2ETestSuccess = 1` appears in CloudWatch after a successful cycle; alarm in OK state under normal conditions.

---

## Phase 7: Drift Detection

**Goal**: Confirm `terraform plan` detects out-of-band changes.

- [x] T030 [US5] Verify `terraform plan` shows a corrective update after manually altering `retention.ms` on the `edp-dev.platform.e2e.canary` topic via AWS CLI; document the observed plan output as confirmation
- [x] T031 [US5] Document drift detection behaviour in `kafka/README.md` — explain that `terraform plan` detects out-of-band MSK topic config changes

---

## Phase 8: Polish & Cross-Cutting Concerns

- [x] T032 [P] Run `terraform fmt -recursive terraform/` — confirm `kafka_topics.tf` and `kafka_e2e_canary.tf` pass formatting check
- [ ] T033 [P] Run `tflint --minimum-failure-severity=error --recursive terraform/`; resolve or add justified `tflint-ignore` annotations for any issues in the new Terraform files
- [ ] T034 [P] Run `checkov` scan over `terraform/`; add justified `# checkov:skip` annotations for any accepted findings
- [x] T035 Update `kafka/README.md` to include: Roles Anywhere Trust Anchor ARN and Profile ARN per account (as platform constants), bootstrap broker endpoints per environment (from `terraform output`), IAM quota pre-increase instructions for the dev+test account
- [x] T036 Update root `README.md` to reference the Kafka self-service platform under the component list (one sentence + link to `kafka/README.md`)
- [ ] T037 Run all [quickstart.md](quickstart.md) validation scenarios against the dev environment; confirm all scenarios produce the expected outcomes
- [ ] T038 [P] Request IAM quota increases for account `381491832813` (dev+test) — raise IAM roles limit to 2,000 and managed policies limit to 3,000 via AWS Service Quotas; document request IDs in a PR comment

---

## Dependencies & Execution Order

- Phase 1 (Setup): No dependencies
- Phase 2 (Foundational): Depends on Phase 1 — **blocks all Terraform work**
- Phase 3 (US1 — Producer): Depends on Phase 2
- Phase 4 (US2 — Consumer): Depends on Phase 3 (consumer policy references `aws_msk_cluster.this.arn`; logically depends on topics existing)
- Phase 5 (US3 — Decommission): Depends on Phase 3 (requires a live topic to validate against)
- Phase 6 (US4 — Canary): Depends on Phase 3 and Phase 4 (canary uses both producer and consumer YAML registrations)
- Phase 7 (Drift): Depends on Phase 3 (requires a live topic)
- Phase 8 (Polish): Depends on Phases 3–7

### Parallel opportunities

- T002 and T003 (Phase 1): copy both schemas in parallel
- T013 and T014 (Phase 3): AWS and on-prem producer roles can be written in parallel — different locals maps
- T019 and T020 (Phase 4): AWS and on-prem consumer roles can be written in parallel
- T027, T028 (Phase 6): Lambda handler and requirements.txt can be written in parallel
- T033, T034, T035, T036 (Phase 8): all parallelisable

---

## Notes

- `[P]` tasks touch different files with no blocking dependencies within the same phase
- All new IAM resource names follow the pattern `edp-kafka-<type>-<businessName>-<appName>-<env>` for producers and `edp-kafka-consumer-<slug>-<env>` for consumers
- Tags are applied via `default_tags` in the AWS provider block — no `local.common_tags` on individual resources
- Consumer files are flat under `kafka/consumers/` — no subdirectories
- The `kafka_topics.tf` `for_each` key for consumer locals is `v.metadata.name` (not the filename key), ensuring the IAM resource names use the declared slug
