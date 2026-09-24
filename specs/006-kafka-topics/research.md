# Research: Kafka Topic Self-Service Platform

Key design decisions and their rationale.

---

## 1. `aws_msk_topic` vs Third-Party Kafka Provider

**Decision**: Use `aws_msk_topic` from `hashicorp/aws ~> 6.0`.

**Rationale**: The native provider resource communicates with the MSK management API over HTTPS — no TCP broker connection is needed from CI runners during `terraform plan` or `terraform apply`. This eliminates the VPC/security-group dependency that the `mongey/kafka` provider required (active TCP connection to brokers on port 9098). Full Terraform state and drift detection are provided natively. The resource was introduced in `hashicorp/aws` around v6.42; the pinned lock file already satisfies this minimum.

**Key argument difference from `mongey/kafka`**:
- `mongey/kafka` used `partitions` (map value) and `config` (map of string)
- `aws_msk_topic` uses `partition_count` (argument name) and `configs` (JSON-encoded string via `jsonencode`)

**Alternatives eliminated**:
- `mongey/kafka ~> 0.8`: third-party; required live broker TCP connection from CI — eliminated
- `null_resource` + AWS CLI: no state, no drift detection — eliminated

---

## 2. App-Centric Producer Model (One File Per App)

**Decision**: One YAML file per producer app at `kafka/producers/<businessName>/<appName>.yaml`, declaring all events for that app. A single IAM producer role per environment is granted access to all of the app's topics.

**Rationale**: Most apps produce multiple related events (e.g., `order-created`, `order-updated`, `order-cancelled`). Requiring a separate YAML file per event would multiply the number of PRs, YAML files, and IAM roles without adding value. The app-centric model reflects the ownership boundary — a team owns an app, not individual events. The composite uniqueness key `(businessName, appName)` is enforced structurally (file path) and by CI duplicate detection.

**Alternatives eliminated**:
- One file per topic/event: explosion of files and IAM roles; no alignment to team ownership
- One file per business unit: too coarse; different apps within a unit may have different owners and environments

---

## 3. Per-Event Topic Config

**Decision**: Each entry in `spec.events` declares its own `partitions`, `replicationFactor`, `retentionMs`, `cleanupPolicy`, and optional fields. There is no shared config block across all events.

**Rationale**: Events within the same app routinely have different operational requirements — a canary event may need 1 partition and 1-hour retention while an audit event needs 6 partitions and 7-day retention. Sharing config across events would force all events to use the most conservative settings, wasting broker storage or losing the ability to tune per-topic.

**Alternatives eliminated**:
- Shared `spec.topic` config block: inflexible; all events inherit identical settings — eliminated

---

## 4. camelCase Schema

**Decision**: All YAML attribute names use camelCase (`businessName`, `appName`, `replicationFactor`, `retentionMs`, `cleanupPolicy`, `iamRoles`, `certificateSubject`, `onPrem`, `consumerGroupPrefix`, `decommissionedEvents`).

**Rationale**: The top-level fields `apiVersion`, `kind`, and `metadata.name` are already camelCase, inherited from the Kubernetes-style document convention. Mixing camelCase at the top level with snake_case in `spec` creates cognitive load for authors. Unifying on camelCase throughout is consistent and enforced by `additionalProperties: false` — any snake_case attribute is immediately rejected at validation time, making partial-migration states impossible.

**Alternatives eliminated**:
- All snake_case: inconsistent with `apiVersion`, `kind` which cannot change without breaking the kind convention
- Mixed convention: requires documentation of which tier uses which style; high cognitive load

---

## 5. `metadata.businessName`/`appName` Placement

**Decision**: `businessName` and `appName` are identity fields and live in `metadata`. The `spec` object contains only configuration (`events`, `decommissionedEvents`, `decommission`, `producer`).

**Rationale**: In Kubernetes-style documents, `metadata` holds the identity and ownership attributes of a resource. `businessName` and `appName` together form the composite key that uniquely identifies a producer app registration — they are identity, not configuration. Having them in `spec` alongside `events` and `decommission` blurs the document structure. Moving them to `metadata` also makes the composite key `(apiVersion, kind, metadata.businessName, metadata.appName)` consistent with the consumer pattern `(apiVersion, kind, metadata.name)`.

**Alternatives eliminated**:
- `spec.businessName` / `spec.appName`: identity fields in the config block — eliminated
- `metadata.name` as combined slug (e.g., `platform-e2e`): requires an additional derived field and a format rule; two separate identity fields are more composable

---

## 6. Assembled Topic Naming

**Decision**: Topic name format `edp-<env>.<businessName>.<appName>.<eventName>`, assembled by Terraform from YAML identity fields and `local.environment`.

**Rationale**: The `edp-<env>` prefix separates topics by environment on the same cluster (if clusters are shared) and makes topic ownership immediately legible in MSK Console or CLI output. Teams never construct the assembled name — they declare the identity fields and the system assembles the name. The `env` segment comes from `local.environment` (`terraform.workspace`), never from the YAML, eliminating the risk of environment mismatch.

**Alternatives eliminated**:
- Teams specify assembled topic name strings directly: risk of typos, environment mismatches, and inconsistent naming — eliminated
- Three-segment `<domain>.<entity>.<event>` without env prefix: no env isolation; all envs share the same topic name space — eliminated

---

## 7. IAM Role-Assumption Model

**Decision**: One `aws_iam_role` per producer app per environment (trusting workload ARNs or Roles Anywhere) plus one per consumer slug per environment. No `aws_msk_cluster_policy`.

**Rationale**: The `aws_msk_cluster_policy` is a single resource-based policy document capped at 20 KB. At 200 producer apps × 500 consumer slugs, the cluster policy would exceed this hard limit. The role-assumption model has no aggregate document size limit — each IAM role and policy is an independent object. Each team assumes their MSK-account role to obtain Kafka credentials; this also enforces the principle of least privilege (each role only grants access to its own topics).

The model works uniformly for same-account, cross-account, and on-premises workloads; only the trust policy varies.

**Alternatives eliminated**:
- `aws_msk_cluster_policy`: hard 20 KB limit at scale — eliminated
- Kafka ACLs: MSK IAM-only auth; no Kafka ACL engine enabled — eliminated

---

## 8. Two-Phase Decommission Guard

**Decision**: Two granularities of decommission guard:
- **Per-event**: move event name to `spec.decommissionedEvents` (Phase 1), then remove from the list (Phase 2)
- **Whole-app**: set `spec.decommission: true` (Phase 1), then delete the file (Phase 2)

In both cases, the CI script (`validate-topic-names.py`) blocks Phase 2 without Phase 1 having been completed.

**Rationale**: Direct removal of an event from `spec.events` or direct deletion of a YAML file are indistinguishable from accidental removal without an explicit intent signal. The guard flag is the intent signal. The CI script enforces it by reading the prior git commit's version of the file. This provides a reviewable destruction gate — the platform team sees the intended destruction in the plan output and must approve.

**Alternatives eliminated**:
- CODEOWNERS-only protection: reviewers can miss accidental deletions — insufficient alone
- Terraform `prevent_destroy` lifecycle: blocks `apply` but does not enforce the YAML review gate — insufficient alone
- Single guard granularity (whole-app only): teams retiring a single event from a large app cannot do so without retiring all events — too coarse

---

## 9. Shared Platform S3 (vs Dedicated Lambda Bucket)

**Decision**: Store the canary Lambda ZIP in `module.platform_s3` at prefix `e2e/kafka/canary/function.zip`. No dedicated S3 bucket is provisioned for the canary.

**Rationale**: The platform team already manages a shared bucket (`chedaws-edp-platform-<env>`) for platform-internal artifacts. Creating a second single-purpose bucket for one Lambda ZIP would duplicate bucket management overhead (bucket policy, lifecycle rules, KMS key binding) without any functional benefit. The shared bucket already has appropriate access controls and encryption.

**Alternatives eliminated**:
- Dedicated S3 bucket for Lambda ZIP: unnecessary resource duplication when `module.platform_s3` is available — eliminated

---

## 10. `default_tags` Only (No `local.common_tags`)

**Decision**: All AWS resource tags are applied via the `default_tags` block on the AWS provider. No `local.common_tags` map is defined or referenced anywhere in the Kafka Terraform files.

**Rationale**: The project constitution requires tags to be applied centrally at the provider level to avoid tag duplication, inconsistency, and merge conflicts when tags change. A `local.common_tags` map requires every resource block to explicitly reference it via `tags = local.common_tags` — a pattern that is easy to omit and leads to untagged resources. `default_tags` applies automatically to every resource without any per-resource annotation.

**Alternatives eliminated**:
- `local.common_tags` per resource: error-prone; easy to omit; inconsistent with project constitution — eliminated
