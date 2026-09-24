# Feature Specification: Kafka Topic Self-Service Platform

**Feature Branch**: `feat/kafka-topics`

**Created**: 2026-07-03

**Status**: Active

## Problem Statement

Amazon MSK clusters are deployed across four environments (`dev`, `test`, `uat`, `prod`) with `auto.create.topics.enable=false`. Streaming producers and consumers — running in other AWS accounts or on-premises data centres — need Kafka topics created and IAM access provisioned before they can stream data. Without a self-service workflow, both operations require manual platform team involvement: there is no audit trail, no schema enforcement, and no drift detection.

This specification describes a Git-based self-service platform where producers and consumers declare their needs in YAML files via Pull Request. A CI/CD pipeline validates those declarations and provisions the required Kafka topics and IAM access without manual intervention.

---

## Goals

- **G-01**: Any producer team registers a new Kafka app (with one or more events) by opening a PR with a single YAML file. No platform team action is needed for provisioning.
- **G-02**: Any consumer team requests read access to existing topics by opening a PR with a YAML file.
- **G-03**: Cross-account AWS producers and consumers receive access via IAM role assumption. Terraform creates one `aws_iam_role` per producer app per environment (trusting the external workload's role ARN) and one per consumer slug per environment. No `aws_msk_cluster_policy` is used.
- **G-04**: On-premises workloads authenticate via IAM Roles Anywhere. Terraform creates an IAM role with a `rolesanywhere.amazonaws.com` trust policy conditioned on the certificate CN.
- **G-05**: Topic configuration is managed as code with full drift detection via `terraform plan`.
- **G-06**: Topic decommissioning is a deliberate two-phase process that prevents accidental data loss — whole-app and per-event.
- **G-07**: All YAML registrations are validated against a JSON Schema before any Terraform step runs.
- **G-08**: A synthetic E2E canary validates MSK cluster health every 5 minutes across all environments.

---

## User Scenarios & Testing

### User Story 1 - Producer Team Registers a New App (Priority: P1)

A producer team (same-account AWS, cross-account AWS, or on-premises) needs Kafka topics created and write access provisioned. They open a PR containing a single YAML file at `kafka/producers/<businessName>/<appName>.yaml` declaring their app, its events, per-event topic config, and per-environment IAM identities.

**Why this priority**: This is the core capability. Without topic creation and produce access, no streaming data can flow.

**Acceptance Scenarios**:

1. **Given** a valid producer YAML at `kafka/producers/ue/siq.yaml` declaring `events: [{name: order-created, partitions: 6, ...}]`, **When** a PR is merged to `main`, **Then** the topic `edp-<env>.ue.siq.order-created` is created on each declared environment's MSK cluster with the declared per-event config.
2. **Given** a producer YAML with cross-account IAM role ARNs per environment under `spec.producer.environments.<env>.iamRoles`, **When** the pipeline applies, **Then** an IAM role `edp-kafka-producer-<businessName>-<appName>-<env>` is created in the MSK account with a trust policy listing the declared ARNs.
3. **Given** a PR where two producer YAMLs declare the same `metadata.businessName` and `metadata.appName`, **When** the CI validation job runs, **Then** the PR is blocked with a duplicate registration error before any Terraform step executes.
4. **Given** a producer YAML using any snake_case attribute name (e.g., `replication_factor`), **When** CI schema validation runs, **Then** the PR is blocked — unrecognised field names are rejected by `additionalProperties: false`.

---

### User Story 2 - Consumer Team Requests Read Access (Priority: P2)

A consumer team (same-account AWS, cross-account AWS, or on-premises) needs read access to one or more existing Kafka topics. They open a PR containing a flat consumer YAML at `kafka/consumers/<slug>.yaml` declaring the topics (by `businessName`, `appName`, `eventName`), their IAM identity per environment, and an optional consumer group prefix.

**Acceptance Scenarios**:

1. **Given** a valid consumer YAML referencing topics by `{businessName, appName, eventName}` and cross-account IAM role ARNs, **When** the PR is merged, **Then** an IAM role `edp-kafka-consumer-<slug>-<env>` is created per declared environment with read access to all referenced topics.
2. **Given** a consumer YAML with `consumerGroupPrefix: risk-engine`, **When** applied, **Then** the consumer's IAM policy includes `kafka-cluster:AlterGroup` and `kafka-cluster:DescribeGroup` on `<cluster_arn>/group/risk-engine*`.
3. **Given** a consumer YAML referencing a topic (`businessName`, `appName`, `eventName`) for which no active producer YAML exists, **When** CI validation runs, **Then** the PR is blocked with a clear error identifying the missing registration.
4. **Given** an on-premises consumer YAML with `onPrem: true` and `certificateSubject: "CN=..."` per environment, **When** applied, **Then** an IAM role is created with an IAM Roles Anywhere trust policy conditioned on the certificate CN.

---

### User Story 3 - Topic Decommissioning (Priority: P3)

A producer team retires topics via a two-phase process. Two scopes are supported: retiring a single event (per-event guard) and retiring an entire app (whole-app guard).

**Per-event decommission**: Move the event name from `spec.events` to `spec.decommissionedEvents` in Phase 1. Terraform destroys that event's topics. Remove the name from `decommissionedEvents` in a follow-up Phase 2 PR.

**Whole-app decommission**: Set `spec.decommission: true` in Phase 1. Terraform destroys all topics and the IAM role for that app. Delete the YAML file in a follow-up Phase 2 PR.

**Acceptance Scenarios**:

1. **Given** an event name is moved to `spec.decommissionedEvents`, **When** `terraform plan` runs, **Then** only that event's topics are shown as destroyed; other events and the IAM role remain.
2. **Given** an event name is removed directly from `spec.events` without first appearing in `decommissionedEvents`, **When** CI validation runs, **Then** the PR is blocked.
3. **Given** `spec.decommission: true` is set, **When** `terraform plan` runs, **Then** all of the app's topics and its IAM roles are destroyed across all declared environments.
4. **Given** a YAML file is deleted without `spec.decommission: true` being set, **When** CI validation runs, **Then** the PR is blocked.

---

### User Story 4 - Platform Team Validates Cluster Health via E2E Canary (Priority: P1)

The platform team needs continuous assurance that the MSK cluster is functional end-to-end. A synthetic canary Lambda runs every 5 minutes, produces a test message to `edp-<env>.platform.e2e.canary`, consumes it, validates the content, and emits a `KafkaE2ETestSuccess` CloudWatch metric. A `KafkaE2ETestFailure` alarm fires when 2 consecutive cycles fail.

**Acceptance Scenarios**:

1. **Given** the canary is deployed, **When** a test cycle executes, **Then** the Lambda assumes the CanaryProducerRole (via the self-service IAM pipeline), flushes residual messages, produces a uniquely identified message, waits a settle period, then assumes the CanaryConsumerRole to consume and validate.
2. **Given** the canary cannot produce a message, **When** the cycle completes, **Then** `KafkaE2ETestSuccess = 0` is emitted and the `KafkaE2ETestFailure` alarm transitions to `ALARM` after 2 consecutive failures (10 minutes).
3. **Given** the Lambda crashes before emitting a metric, **When** the evaluation period ends, **Then** `treat_missing_data = "breaching"` ensures the alarm fires.

---

### User Story 5 - Platform Team Detects Configuration Drift (Priority: P4)

Any out-of-band change to a managed Kafka topic or IAM resource is visible as a corrective change in the next `terraform plan`.

**Acceptance Scenarios**:

1. **Given** a topic's `retention.ms` is changed manually on the MSK cluster, **When** `terraform plan` runs, **Then** the plan shows a corrective update to restore the declared value.
2. **Given** an IAM policy is manually detached from a producer role, **When** `terraform plan` runs, **Then** the plan shows reattachment.

---

### Edge Cases

- Two producer YAMLs with the same `metadata.businessName` and `metadata.appName`: blocked by native `for_each` key collision and `terraform_data` precondition in `kafka_topics.tf`; also blocked by `validate-topic-names.py` before Terraform runs.
- An event name appearing in both `spec.events` and `spec.decommissionedEvents` simultaneously: blocked by CI with an overlap error.
- A consumer YAML referencing an event listed in `decommissionedEvents` of the matching producer: blocked by CI cross-reference check.
- `replicationFactor` value other than 3: blocked by JSON Schema (`const: 3`).
- `onPrem: true` and `iamRoles` declared in the same environment entry: blocked by JSON Schema (`oneOf`).
- IAM role name exceeding 64 characters: blocked by `terraform_data.kafka_producer_name_length_check` precondition.

---

## Requirements

### Functional Requirements

- **FR-001**: Teams register a Kafka app by opening a PR with a YAML file at `kafka/producers/<businessName>/<appName>.yaml`; no manual platform team provisioning action is required.
- **FR-002**: Teams request consume access by opening a PR with a YAML file at `kafka/consumers/<slug>.yaml`; no manual platform team action is required.
- **FR-003**: All producer and consumer YAML files are validated against a JSON Schema before any infrastructure change is made.
- **FR-004**: All YAML attribute names use camelCase. snake_case names are rejected by `additionalProperties: false` in the JSON Schema.
- **FR-005**: Producer identity fields `businessName` and `appName` live in `metadata`. The `spec` object contains only configuration (`events`, `decommissionedEvents`, `decommission`, `producer`).
- **FR-006**: The assembled topic name formula is `edp-<local.environment>.<metadata.businessName>.<metadata.appName>.<event.name>`. Teams never manually specify assembled topic name strings.
- **FR-007**: Producer YAML files reside at `kafka/producers/<businessName>/<appName>.yaml`. The CI script verifies that `path.parent.name == metadata.businessName` and `path.stem == metadata.appName`.
- **FR-008**: Consumer YAML files reside at `kafka/consumers/<slug>.yaml` (flat, no subdirectories). The CI script verifies that `path.stem == metadata.name`.
- **FR-009**: IAM access for AWS workloads is granted by creating one `aws_iam_role` per producer app per environment and one per consumer slug per environment, with trust policies listing the workload's role ARN(s). No `aws_msk_cluster_policy` is used.
- **FR-010**: IAM access for on-premises workloads is granted via IAM Roles Anywhere: `rolesanywhere.amazonaws.com` as trust principal with a CN condition derived from `certificateSubject`.
- **FR-011**: Per-event decommission: an event name must be moved to `spec.decommissionedEvents` before it can be removed from `spec.events`. Direct removal is blocked by CI.
- **FR-012**: Whole-app decommission: `spec.decommission: true` must be set before the YAML file is deleted. Direct file deletion is blocked by CI.
- **FR-013**: Duplicate-name enforcement uses both native `for_each` key collision (Terraform) and `terraform_data` precondition blocks, in addition to CI-level checks in `validate-topic-names.py`.
- **FR-014**: All topic and IAM resources are managed as Terraform code using `aws_msk_topic` from `hashicorp/aws`; configuration drift is detectable via `terraform plan`.
- **FR-015**: The CI/CD pipeline runs `validate-yaml` on every PR before any `terraform plan` step executes.
- **FR-016**: `terraform apply` to `dev` runs automatically on pushes to `main`; `uat` and `prod` applies are gated behind GitHub Environment approvals.
- **FR-017**: Consumer IAM policies include `kafka-cluster:AlterGroup` and `kafka-cluster:DescribeGroup` on `<cluster_arn>/group/<consumerGroupPrefix>*` when `consumerGroupPrefix` is declared.
- **FR-018**: A synthetic E2E canary Lambda runs every 5 minutes in all four environments. It uses the self-service IAM pipeline (producer and consumer YAML registrations) — the Lambda execution role has no direct Kafka permissions. The Lambda ZIP is stored in `module.platform_s3` at prefix `e2e/kafka/canary/function.zip`.
- **FR-019**: The `KafkaE2ETestFailure` alarm fires after 2 consecutive failing cycles with `treat_missing_data = "breaching"`, routing to the existing SNS topic. It is active in all four environments with no `count` gate.
- **FR-020**: Tags on all AWS resources are applied via `default_tags` in the AWS provider. No `local.common_tags` map is used.

### Non-Functional Requirements

- **NFR-001**: IAM role and policy name lengths do not exceed 64 characters; enforced by `terraform_data.kafka_producer_name_length_check` precondition.
- **NFR-002**: Each `aws_iam_policy` document stays within the 6 KB limit; CI warns when a consumer YAML references more than 80 topics.
- **NFR-003**: The platform scales to at least 200 registered producer apps and 500 registered consumers per environment without hitting hard AWS API limits (soft quota increases for IAM roles and policies are pre-requested before reaching thresholds).
- **NFR-004**: The CI pipeline completes end-to-end (validate → plan → apply for dev) in ≤ 15 minutes from PR merge.

---

## Success Criteria

- **SC-001**: A producer team registers a new Kafka app and has all topics provisioned across declared environments without any manual platform team action, within the CI/CD pipeline completion window (~15 minutes from PR merge).
- **SC-002**: A consumer team requests and receives read access to existing topics without any manual platform team action.
- **SC-003**: 100% of topic and consumer registrations that reach `terraform apply` have previously passed JSON Schema validation and naming checks; zero unvalidated registrations are applied.
- **SC-004**: Any out-of-band configuration change to a managed Kafka topic or IAM resource is detected and reported in the next `terraform plan` run.
- **SC-005**: Two TopicRegistration documents with identical `metadata.businessName` and `metadata.appName` are blocked by CI in 100% of cases.
- **SC-006**: A topic decommissioning PR that removes an event without the prior guard step is blocked by CI in 100% of cases.
- **SC-007**: A real MSK cluster failure causes the `KafkaE2ETestFailure` alarm to fire within 10 minutes.
- **SC-008**: The canary Lambda execution role has zero direct Kafka permissions at all times, verifiable by IAM policy audit.

---

## Scope

### In Scope

- Kafka topic provisioning via `aws_msk_topic` (hashicorp/aws provider)
- IAM role-assumption model for same-account, cross-account, and on-premises workloads
- JSON Schema validation and `validate-topic-names.py` CI script
- Two-phase decommission (per-event and whole-app)
- Duplicate-name enforcement (CI + Terraform preconditions)
- E2E synthetic canary Lambda (self-service IAM, shared S3 for ZIP)
- CloudWatch alarms and log groups for canary observability
- Platform shared S3 bucket (`chedaws-edp-platform-<env>`) and KMS key (`alias/chedaws-edp-s3-<env>`)
- `kafka-topics.yaml` GitHub Actions workflow

### Out of Scope

- Schema Registry management (Confluent or AWS Glue)
- Kafka ACL-based authorisation (MSK uses IAM authorisation only)
- Topic partition reassignment or rack-aware replication tuning
- Consumer group management beyond IAM group-prefix grants
- Network connectivity between external accounts/on-prem and MSK VPCs

---

## Key Decisions

| Decision | Choice | Reason |
|---|---|---|
| Terraform provider for topics | `aws_msk_topic` (`hashicorp/aws`) | Native AWS provider; no broker TCP connection required from CI runners; full drift detection |
| Producer model | One file per app at `kafka/producers/<businessName>/<appName>.yaml` | One IAM role per app per env; multiple events share a single role and policy |
| Topic config | Per-event in `spec.events[]` | Each event can have distinct partitions, retention, and cleanup policy |
| Field naming | camelCase throughout | Consistent with Kubernetes-style document convention (`apiVersion`, `kind`); `additionalProperties: false` enforces it |
| Producer identity placement | `metadata.businessName` / `metadata.appName` | Identity fields belong in `metadata`; `spec` is purely configuration |
| IAM model | Role assumption; one role per (app or consumer slug, env) | No 20 KB `aws_msk_cluster_policy` size limit; each role is an independent object |
| Topic naming | `edp-<env>.<businessName>.<appName>.<eventName>` assembled by Terraform | Teams never construct the string manually; env comes from `local.environment` |
| Duplicate enforcement | CI Python script + native `for_each` key collision + `terraform_data` precondition | Defence in depth: fast failure at PR time, hard stop at plan time |
| Decommission guard | Per-event (`decommissionedEvents`) and whole-app (`decommission: true`) | Two-phase process prevents accidental topic destruction; both granularities required |
| Canary IAM | Self-service pipeline (YAML registrations); no standalone Kafka policies | Canary validates the pipeline itself; execution role has zero direct Kafka permissions |
| Lambda ZIP location | `module.platform_s3` at `e2e/kafka/canary/function.zip` | Reuses existing shared platform S3 bucket; no dedicated bucket for a single function |
| Tags | `default_tags` in AWS provider | No `local.common_tags` map per project constitution |

---

## Assumptions

- MSK clusters named `chedaws-edp-msk-<env>` exist in each environment with `auto.create.topics.enable=false` and MSK IAM authentication enabled.
- IAM Roles Anywhere Trust Anchors and Profiles are already configured in each MSK account by the platform team; on-premises teams supply only certificate CN values.
- Network connectivity between external accounts / on-premises data centres and MSK VPCs is pre-provisioned and is out of scope.
- Dev and test environments share AWS account `381491832813`; UAT uses `339712719726`; prod uses `637423180765`.
- IAM quota increases to 2,000 roles and 3,000 managed policies must be requested for the dev+test account before onboarding beyond ~500 registrations in those environments.
- `replicationFactor` must equal 3, matching the MSK broker count across all environments; enforced by JSON Schema `const: 3`.
- `retentionMs` is capped at 2,592,000,000 ms (30 days) by the JSON Schema for all environments.
- The shared platform S3 bucket `chedaws-edp-platform-<env>` and its KMS key `alias/chedaws-edp-s3-<env>` are managed by `module.platform_s3` and exist before the canary Lambda is deployed.
