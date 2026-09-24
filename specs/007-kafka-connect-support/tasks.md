# Tasks: Kafka Connect Support

**Input**: Design documents from `specs/007-kafka-connect-support/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/connect-schema.json, quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Exact file paths are included in all task descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Establish the new directory structure and schema files that all user stories depend on.

- [X] T001 Create directory `kafka/connect/` in the repository root
- [X] T002 [P] Copy `specs/007-kafka-connect-support/contracts/connect-schema.json` to `kafka/schema/connect-schema.json`
- [X] T003 [P] Make `spec.producer` optional in `kafka/schema/producer-schema.json` — change `required` from `["events", "producer"]` to `["events"]`

**Checkpoint**: Directory structure and schema files are in place; all subsequent tasks can reference them.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core Terraform locals that both user stories 1 and 2 depend on — loading connect YAML files and deriving the set of connect-owned apps that suppresses per-app IAM generation.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T004 Create `terraform/kafka_connect.tf` with the `_connect_files`, `connect_registrations_this_env`, and `connect_owned_apps_this_env` locals as defined in plan.md §Terraform Design / Locals
- [X] T005 Add `_producers_needing_iam_this_env` local to `terraform/kafka_topics.tf` (filters `_producers_this_env` to exclude entries whose `businessName/appName` is in `connect_owned_apps_this_env`)
- [X] T006 Update `for_each` on `aws_iam_policy.kafka_producer`, `aws_iam_role.kafka_aws_producer`, `aws_iam_role.kafka_onprem_producer`, their policy attachments, and `terraform_data.kafka_producer_name_length_check` in `terraform/kafka_topics.tf` to reference `_producers_needing_iam_this_env` instead of `_producers_this_env`

**Checkpoint**: Foundation ready — the IAM suppression logic is in place; user story phases can now begin.

---

## Phase 3: User Story 1 — Register UE Kafka Connect server as shared producer (Priority: P1) 🎯 MVP

**Goal**: Replace the two per-app IAM roles for `ue/siq` and `ue/uiq` with a single on-prem connect role covering all five business topics plus the four Confluent system topics.

**Independent Test**: Run `terraform plan -var="env=test"` and confirm:
- **Destroy**: `aws_iam_role.kafka_onprem_producer["ue/siq"]`, `["ue/uiq"]`, their policies and attachments
- **Create**: `aws_iam_role.kafka_onprem_connect["ue-connect"]`, `aws_iam_policy.kafka_connect["ue-connect"]`, `aws_iam_role_policy_attachment.kafka_onprem_connect["ue-connect"]`
- **Create**: all four `aws_msk_topic.kafka_connect_system_topic["ue-connect-*"]` topics
- **No change**: all `aws_msk_topic.this["edp-test.ue.*"]` business topics

### Implementation for User Story 1

- [X] T007 [P] [US1] Create `kafka/connect/ue/ue-connect.yaml` — on-prem Confluent registration for `CN=IOVLVDC2KAFN1`, sourcing `ue/siq` and `ue/uiq`, active in `test` environment, with the full structure from plan.md §YAML Schema Design
- [X] T008 [P] [US1] Remove `spec.producer` block from `kafka/producers/ue/siq.yaml` (retain all `spec.events` entries unchanged)
- [X] T009 [P] [US1] Remove `spec.producer` block from `kafka/producers/ue/uiq.yaml` (retain all `spec.events` entries unchanged)
- [X] T010 [US1] Add `_connect_business_topic_arns`, `_connect_system_topics`, `aws_connect_this_env`, and `onprem_connect_this_env` locals to `terraform/kafka_connect.tf` (depends on T004, T007)
- [X] T011 [US1] Add `aws_msk_topic.kafka_connect_system_topic` resource to `terraform/kafka_connect.tf` — provisions prefixed system topics per registration with configs from research.md §2 (depends on T010)
- [X] T012 [US1] Add `aws_iam_policy.kafka_connect` resource to `terraform/kafka_connect.tf` — one policy per registration covering ConnectToCluster, ProduceBusinessTopics, SystemTopicsReadWrite, SystemTopicsConsumerGroup statements as defined in plan.md §Resources (depends on T010, T011)
- [X] T013 [US1] Add `aws_iam_role.kafka_onprem_connect` and `aws_iam_role_policy_attachment.kafka_onprem_connect` resources to `terraform/kafka_connect.tf` — IAM Roles Anywhere trust using `ForAnyValue:StringEquals` on CN (depends on T012)
- [X] T014 [US1] Add `aws_iam_role.kafka_aws_connect` and `aws_iam_role_policy_attachment.kafka_aws_connect` resources to `terraform/kafka_connect.tf` — AWS principal trust for cloud-based connect workers (depends on T012)
- [X] T015 [US1] Add `terraform_data.kafka_connect_name_length_check` precondition resource to `terraform/kafka_connect.tf` — enforces ≤ 64 char IAM role name (depends on T010)
- [X] T016 [US1] Add `kafka_connect_role_arns` and `kafka_connect_system_topic_names` outputs to `terraform/kafka_connect.tf` (depends on T013, T014, T011)

**Checkpoint**: User Story 1 is fully functional. One IAM role `edp-test-kafka-connect-ue-connect` replaces the two old producer roles. Four system topics provisioned. Business topics unchanged.

---

## Phase 4: User Story 2 — Register additional Kafka Connect servers consistently (Priority: P2)

**Goal**: Validate that the pattern from US1 is generic — adding a second connect server requires only a new YAML file with zero Terraform changes.

**Independent Test**: Add `kafka/connect/vpn/vpn-connect.yaml` (standard variant, cloud IAM roles), remove `producer` block from `kafka/producers/vpn/siq.yaml`, run `terraform plan -var="env=test"` and confirm only net-new `vpn-connect` resources are planned with no changes to `ue-connect` resources and no `vpn-connect-confluent-license` topic.

### Implementation for User Story 2

- [X] T017 [P] [US2] Create `kafka/connect/vpn/vpn-connect.yaml` — cloud-based standard registration sourcing `vpn/siq`, active in `test` environment with `iamRoles`, using the structure from quickstart.md §Scenario 2
- [X] T018 [P] [US2] Remove `spec.producer` block from `kafka/producers/vpn/siq.yaml` (retain all `spec.events` entries unchanged)
- [X] T019 [US2] Run `terraform plan -var="env=test"` and verify plan output: only `vpn-connect` resources are net-new, three system topics created (no confluent-license), `ue-connect` resources show no change (validation task — no code changes required; document findings as a comment in quickstart.md if any discrepancies found)

**Checkpoint**: User Stories 1 and 2 both work independently. Adding a new server registration requires only a YAML file.

---

## Phase 5: User Story 3 — Kafka Connect consumer registration with system topic permissions (Priority: P3)

**Goal**: Allow a consumer `ConsumerRegistration` YAML to declare `type: kafka-connect` so the consumer IAM role automatically receives system topic permissions in addition to consume permissions on business topics.

**Independent Test**: Author a Kafka Connect consumer YAML for an existing topic with `type: kafka-connect`, apply, and verify the consumer IAM role policy includes `Consume` on the referenced business topics and `DescribeTopic`/`WriteData`/`ReadData` on the three standard system topics. If `variant: confluent` is declared, `<name>-confluent-license` permissions are also included.

### Implementation for User Story 3

- [X] T020 [P] [US3] Add optional `type` field (`enum: ["standard", "kafka-connect"]`) and optional `variant` field (`enum: ["standard", "confluent"]`) to `kafka/schema/consumer-schema.json` — preserve `additionalProperties: false` and all existing required fields
- [X] T021 [US3] Add `_consumer_connect_system_topics` local and `_consumer_connect_business_topic_arns` local to `terraform/kafka_connect.tf` — derives system topics and business topic ARNs for connect-type consumer registrations, using the same topic configuration values (1/25/5 partitions, same retention/cleanup policy) from research.md §2 (depends on T004, T020)
- [X] T022 [US3] Add `aws_iam_policy.kafka_consumer_connect` resource to `terraform/kafka_connect.tf` — one policy per connect-type consumer registration covering ConnectToCluster, ConsumeBusinessTopics (`kafka-cluster:ReadData`/`DescribeTopic`), and SystemTopicsReadWrite (`DescribeTopic`/`WriteData`/`ReadData`) statements; include `<name>-confluent-license` permissions when `variant: confluent` (depends on T021)
- [X] T023 [US3] Add `aws_iam_role.kafka_consumer_connect_aws` and `aws_iam_role_policy_attachment.kafka_consumer_connect_aws` (cloud, `Principal: { AWS: [...] }` trust) and `aws_iam_role.kafka_consumer_connect_onprem` and `aws_iam_role_policy_attachment.kafka_consumer_connect_onprem` (on-prem, IAM Roles Anywhere + `ForAnyValue:StringEquals` CN trust) resources to `terraform/kafka_connect.tf`, following the same trust policy pattern as `kafka_aws_connect` and `kafka_onprem_connect` (depends on T022)

**Checkpoint**: All three user stories functional. Consumer-side Kafka Connect support complete.

---

## Phase 6: CI Validation Pipeline

**Purpose**: Update CI scripts and workflow to validate Kafka Connect YAMLs before any terraform plan.

- [X] T024 [P] Add connect schema validation loop to the `validate-yaml` job in `.github/workflows/kafka-topics.yaml` — iterates over `kafka/connect/**/*.yaml` and calls `check-jsonschema --schemafile kafka/schema/connect-schema.json` on each file
- [X] T025 Add the following five checks to `.github/scripts/validate-topic-names.py`:
  1. Load and validate all `kafka/connect/**/*.yaml` against `connect-schema.json`
  2. Assert `metadata.name` uniqueness across all connect files
  3. Assert every `{businessName, appName}` in `spec.sources` resolves to an existing `TopicRegistration` file
  4. Assert every `TopicRegistration` with no `producer` block appears as a source in exactly one active `KafkaConnectRegistration`
  5. Assert `edp-<env>-kafka-connect-<name>` ≤ 64 characters for all declared environments

**Checkpoint**: CI rejects invalid registrations (unresolved sources, orphaned TopicRegistrations, oversized names) before terraform plan runs.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Final verification, documentation, and constitution compliance checks.

- [X] T026 [P] Run `tflint` via `auto/tflint` on `terraform/kafka_connect.tf` and `terraform/kafka_topics.tf` and resolve all lint warnings
- [X] T027 [P] Validate all connect YAML files against `kafka/schema/connect-schema.json` using `check-jsonschema` and confirm exit 0
- [X] T028 [P] Run `python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/ kafka/connect/` and confirm exit 0 with no orphan errors
- [X] T029 Run `terraform plan -var="env=test"` for final review — confirm plan matches expected output from quickstart.md §Scenario 1 Step 2
- [X] T030 [P] Run quickstart.md §Scenario 3 negative tests — invalid source reference and orphaned TopicRegistration — and confirm both exit non-zero with informative error messages

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 completion — BLOCKS all user stories
- **User Story 1 (Phase 3)**: Depends on Phase 2 — no dependencies on US2 or US3
- **User Story 2 (Phase 4)**: Depends on Phase 2 — no dependencies on US1 or US3 (but validates that US1 resources are unaffected)
- **User Story 3 (Phase 5)**: Depends on Phase 2 — may follow US1/US2 in practice
- **CI Pipeline (Phase 6)**: Can be developed in parallel with US1/US2 after Phase 1; must complete before Polish
- **Polish (Phase 7)**: Depends on all desired user stories and CI pipeline being complete

### User Story Dependencies

- **US1 (P1)**: Can start after Phase 2 — no cross-story dependencies
- **US2 (P2)**: Can start after Phase 2 — independent of US1 (validates isolation, not US1 output)
- **US3 (P3)**: Can start after Phase 2 — modifies consumer schema (different file from US1/US2)

### Within User Story 1

- T007, T008, T009 can run in parallel (different files)
- T010 depends on T004 (Foundational) and T007 (connect YAML must exist to verify locals)
- T011 → T012 → T013/T014 (sequential — each resource depends on prior)
- T015 depends on T010; T016 depends on T013 and T014

### Parallel Opportunities

All [P]-marked tasks within a phase have no file conflicts and can run concurrently:
- Phase 1: T002 and T003 in parallel
- Phase 3: T007, T008, T009 in parallel; T013 and T014 in parallel after T012
- Phase 4: T017 and T018 in parallel
- Phase 5: T020 independent of other phases
- Phase 6: T024 and T025 can be authored in parallel
- Phase 7: T026, T027, T028, T030 all in parallel

---

## Parallel Example: User Story 1

```bash
# Step 1 — parallel file authoring (no dependencies):
Task T007: kafka/connect/ue/ue-connect.yaml
Task T008: kafka/producers/ue/siq.yaml (remove producer block)
Task T009: kafka/producers/ue/uiq.yaml (remove producer block)

# Step 2 — sequential Terraform locals (depends on T007):
Task T010: locals in terraform/kafka_connect.tf

# Step 3 — sequential resource chain:
Task T011: aws_msk_topic.kafka_connect_system_topic
Task T012: aws_iam_policy.kafka_connect
Task T013 + T014 (parallel): aws_iam_role.kafka_onprem_connect + aws_iam_role.kafka_aws_connect
Task T015: terraform_data precondition
Task T016: outputs
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001–T003)
2. Complete Phase 2: Foundational (T004–T006) — CRITICAL
3. Complete Phase 3: User Story 1 (T007–T016)
4. **STOP and VALIDATE**: Run quickstart.md §Scenario 1 Steps 1–5
5. Confirm one IAM role replaces two; four system topics created; business topics unchanged

### Incremental Delivery

1. Setup + Foundational → `terraform/kafka_connect.tf` scaffolded, IAM suppression logic in place
2. User Story 1 → `ue-connect` role live, validate with quickstart Scenario 1
3. User Story 2 → second registration validated end-to-end, quickstart Scenario 2 passes
4. CI Pipeline → schema and cross-file validation gates in place before terraform plan
5. User Story 3 → consumer-side connect support added
6. Polish → lint, final plan verification, quickstart negative tests

### Migration Note (UE Connect Server)

For the UE migration, the atomic approach (single PR: add `ue-connect.yaml` + remove producer blocks) is the default. If the UE team cannot tolerate even a brief access gap during `terraform apply`, use the two-phase approach documented in research.md §5: PR 1 adds the connect registration only; PR 2 removes the producer blocks after the new role is validated.

---

## Notes

- [P] tasks = different files, no dependencies — safe to run concurrently
- [Story] label maps each task to its user story for traceability
- Each user story is independently completable and testable
- Business topic resources (`aws_msk_topic.this`) remain on `topics_this_env` throughout — they are never affected by connect ownership changes
- `terraform-legacy/` MUST NOT be touched (constitution §VI)
- All IAM resources MUST include a `description` field (constitution §I)
- Tags via `default_tags` in provider block only — no `local.common_tags` (constitution §VI §6)
- Commit after each logical group; group YAML authoring (T007–T009) as one commit, Terraform resource chain (T010–T016) as a second commit
