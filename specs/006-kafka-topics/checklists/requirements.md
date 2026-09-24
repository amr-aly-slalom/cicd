# Requirements Checklist: Kafka Topic Self-Service Platform

**Purpose**: Validate specification completeness and quality
**Feature**: [spec.md](../spec.md)

---

## Content Quality

- [x] No implementation details (languages, frameworks, APIs) leak into spec-level user stories
- [x] Focused on user value and business needs
- [x] All mandatory sections completed (user stories, requirements, success criteria, scope, key decisions)

---

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded (in/out of scope)
- [x] Dependencies and assumptions documented

---

## Functional Requirements Coverage

- [x] FR-001: Producer self-service via PR — no manual platform team action
- [x] FR-002: Consumer self-service via PR — no manual platform team action
- [x] FR-003: JSON Schema validation before any Terraform step
- [x] FR-004: All YAML attributes use camelCase; snake_case rejected
- [x] FR-005: `businessName`/`appName` in `metadata`; `spec` is configuration-only
- [x] FR-006: Assembled topic name `edp-<env>.<businessName>.<appName>.<eventName>`; teams never construct manually
- [x] FR-007: Producer file placement enforced (`kafka/producers/<businessName>/<appName>.yaml`)
- [x] FR-008: Consumer file placement enforced — flat layout (`kafka/consumers/<slug>.yaml`)
- [x] FR-009: IAM role-assumption model; no `aws_msk_cluster_policy`
- [x] FR-010: On-premises access via IAM Roles Anywhere
- [x] FR-011: Per-event decommission guard (`decommissionedEvents` before removal from `spec.events`)
- [x] FR-012: Whole-app decommission guard (`decommission: true` before file deletion)
- [x] FR-013: Duplicate-name enforcement — CI + `for_each` key collision + `terraform_data` precondition
- [x] FR-014: `aws_msk_topic` from `hashicorp/aws`; drift detection via `terraform plan`
- [x] FR-015: CI/CD `validate-yaml` runs before `terraform plan`
- [x] FR-016: `dev` auto-apply on merge; `uat`/`prod` gated behind GitHub Environment approvals
- [x] FR-017: `consumerGroupPrefix` enables group IAM actions when declared
- [x] FR-018: E2E canary Lambda uses self-service IAM pipeline; execution role has no direct Kafka permissions; ZIP in `module.platform_s3`
- [x] FR-019: `KafkaE2ETestFailure` alarm — 2 consecutive failures; `treat_missing_data = "breaching"`; active in all 4 environments; no `count` gate
- [x] FR-020: Tags via `default_tags` in AWS provider; no `local.common_tags`

---

## Non-Functional Requirements Coverage

- [x] NFR-001: IAM role name <= 64 characters; enforced by `terraform_data` precondition
- [x] NFR-002: Consumer IAM policy <= 6 KB; CI warns when > 80 topics referenced
- [x] NFR-003: Scales to 200 producer apps + 500 consumers per env; quota increase documented
- [x] NFR-004: CI pipeline <= 15 minutes end-to-end from PR merge

---

## Validation Rules Coverage

- [x] Event name pattern `^[a-z][a-z0-9-]*$`
- [x] `metadata.businessName` / `appName` pattern `^[a-z][a-z0-9-]*$`
- [x] `replicationFactor == 3` (JSON Schema `const: 3`)
- [x] `retentionMs` <= 2,592,000,000 ms (JSON Schema `maximum`)
- [x] `cleanupPolicy` in `{delete, compact, compact,delete}` (JSON Schema `enum`)
- [x] `iamRoles` XOR `certificateSubject` per env (JSON Schema `oneOf`)
- [x] `environments` non-empty (JSON Schema `minProperties: 1`)
- [x] `events` non-empty (JSON Schema `minItems: 1`)
- [x] Event names unique within `spec.events`
- [x] No event in both `spec.events` and `spec.decommissionedEvents` (overlap guard)
- [x] Consumer cross-reference validation
- [x] Duplicate producer slug detection (CI + Terraform)
- [x] Duplicate consumer slug detection (CI + Terraform)
- [x] Decommission guard for deleted YAML files

---

## Platform Infrastructure Coverage

- [x] Shared platform S3 bucket (`chedaws-edp-platform-<env>`) managed by `module.platform_s3`
- [x] KMS key (`alias/chedaws-edp-s3-<env>`) for S3 and CloudWatch log encryption
- [x] Lambda ZIP stored at `e2e/kafka/canary/function.zip` within platform S3 — no dedicated bucket
- [x] Canary Kafka access flows through self-service YAML pipeline — no standalone canary Kafka policies

---

## Security Principle Compliance

- [x] IAM policies are least-privilege (only required `kafka-cluster:*` actions per resource)
- [x] No secrets hardcoded; cross-account access via role assumption with explicit trust conditions
- [x] All IAM roles and policies include descriptions
- [x] Canary Lambda execution role has no direct Kafka permissions

---

## Observability Principle Compliance

- [x] CloudWatch Log Group for canary — KMS-encrypted; per-environment retention; naming convention
- [x] `KafkaE2ETestFailure` alarm routes to SNS; active in all 4 environments; no `count` gate
- [x] Lambda Errors alarm (`canary_lambda_errors`) for throttle/invocation-failure coverage
- [x] `treat_missing_data = "breaching"` crash guard on canary alarm
- [x] All observability resources managed as Terraform code

---

## Constitution Compliance

- [x] Security: IAM least-privilege; role assumption; no cluster policy; descriptions on all roles
- [x] Observability: CloudWatch alarms with SNS routing; Log Groups with KMS + retention; drift detection via `terraform plan`
- [x] Durability: Terraform state in S3 + DynamoDB; YAML files version-controlled in Git; `replicationFactor: 3`
- [x] Fault-Tolerance: Lambda stateless per-invocation; 2-period alarm suppresses transient failures
- [x] Cost Optimisation: Tags via `default_tags`; YAML-driven `for_each` — only declared resources provisioned; Lambda ZIP in shared platform S3
- [x] DRY & Modularity: All Kafka + IAM resources inline in `kafka_topics.tf`; canary in `kafka_e2e_canary.tf`; no new module (single-use resource set); `terraform-legacy/` not touched
