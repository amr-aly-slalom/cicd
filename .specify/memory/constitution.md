<!--
SYNC IMPACT REPORT
==================
Version change: 1.4.0 → 1.5.0
Modified principles: none
Added sections: none
Removed sections: none
Development Workflow changes:
  - §5 Naming: Extended to cover Terraform resource local-name (ID) convention.
    Resource local names MUST reflect the resource's purpose; generic placeholders
    (e.g., "this") are prohibited where multiple resources of the same type serve
    different purposes.
Templates requiring updates:
  ✅ .specify/templates/plan-template.md — DRY & Modularity checklist item updated
     to include resource local-name (ID) verification.
  ✅ .specify/templates/spec-template.md — no changes required
  ✅ .specify/templates/tasks-template.md — no changes required
Follow-up TODOs: none
-->

# Chedaws EDP Infrastructure Constitution

## Core Principles

### I. Security (NON-NEGOTIABLE)

All AWS resources MUST be provisioned with least-privilege IAM policies.
Encryption at rest MUST be enabled on all data stores (S3, Redshift, Glue, DMS) using
customer-managed KMS keys. Encryption in transit MUST be enforced via TLS. Security
Groups MUST restrict ingress/egress to the minimum required ports and CIDR ranges.
No credentials, account IDs, or secrets MAY be hardcoded in Terraform source files;
all sensitive values MUST be sourced from AWS Secrets Manager, SSM Parameter Store,
or remote state. Every IAM role and policy MUST include a clear description of its
purpose.

**Rationale**: Enterprise data platforms handle sensitive business data and operate
under regulatory obligations. Compromised credentials or over-permissive access
are the most common vectors for cloud breaches.

### II. Observability

Every AWS resource provisioned in this repository MUST have appropriate
observability configured. Observability resources (Log Groups, Alarms, Dashboards,
SNS topics) MUST be managed as code and MUST NOT be created manually in the
AWS Console.

**Logging**: All compute and pipeline resources (ECS tasks, MWAA environments,
DMS replication instances, Glue jobs, MSK brokers) MUST emit structured logs to
CloudWatch Log Groups with a defined retention period. Log Group names MUST follow
the convention `/chedaws-edp/<component>/<env>`. CloudWatch Log Groups MUST be
encrypted using a customer-managed KMS key. Retention periods MUST be defined in
`locals.tf` per environment and MUST NOT be set to `0` (never expire) in any
environment.

**Alarms & Notifications**: Key operational metrics MUST have CloudWatch Alarms.
At a minimum:
- **ECS**: CPU utilisation, memory utilisation, and running task count anomalies.
- **DMS**: replication latency and replication task failure.
- **Glue**: job failure count and job duration.
- **MWAA**: failed task count and scheduler heartbeat.
- **MSK**: `UnderReplicatedPartitions` (per broker), `OfflinePartitionsCount`,
  and `ActiveControllerCount`.
- **Redshift**: `HealthStatus`, `CPUUtilization`, and `PercentageDiskSpaceUsed`.

All CloudWatch Alarm `alarm_actions` MUST route to an SNS topic provisioned as
code in this repository. The SNS topic MUST be encrypted with a KMS key. Alarms
MUST be active in all four environments (`dev`, `test`, `uat`, `prod`); the
`count` conditional MUST NOT be used to suppress alarms in lower environments.
Failures in dev and test environments are equally important to detect early.

**MSK Enhanced Monitoring**: MSK clusters MUST set `enhanced_monitoring` to at
least `PER_BROKER` level. Production clusters MUST use `PER_TOPIC_PER_BROKER`.

**Rationale**: Visibility into pipeline health and infrastructure behaviour is
essential for on-call response, SLA adherence, and capacity planning. Mandating
SNS routing and KMS encryption ensures notifications are reliable and compliant
with the Security principle. Requiring alarms in all environments ensures that
failures in dev and test are caught before they reach production, reducing the
blast radius of configuration regressions and cluster degradation.

### III. Durability

Every stateful AWS resource provisioned in this repository MUST have an explicit
lifecycle or retention policy. The policy MUST be driven by the resource's purpose
and documented in the feature spec or the resource's Terraform block comment.
Engineers choose the appropriate strategy; the following expectations apply per
service type:

- **S3 buckets**: Versioning MUST be enabled on all buckets used for data storage
  or artefact retention. A lifecycle configuration MUST be defined; the storage
  class transition strategy (e.g., `INTELLIGENT_TIERING`, `STANDARD_IA`,
  `GLACIER_IR`, `DEEP_ARCHIVE`, expiration, or a combination) MUST be chosen to
  match the bucket's access pattern and cost objectives, and documented in the
  feature spec. No specific storage class or transition threshold is mandated by
  this constitution — the choice belongs to the implementing engineer.
- **Redshift clusters**: Automated snapshots MUST be enabled with a retention
  period appropriate to the environment (minimum 7 days in production). The
  snapshot strategy (automated only, or automated plus manual) MUST be documented.
- **DMS replication tasks**: MUST use Multi-AZ where supported for production
  workloads. Log retention for replication task logs MUST be explicitly set.
- **CloudWatch Log Groups**: Retention periods are governed by §II Observability.
  Engineers MUST choose a retention period appropriate to the operational and
  compliance requirements of the service; indefinite retention (`0`) is prohibited.
- **Other stateful resources** (DynamoDB tables, RDS instances, ElasticSearch
  domains, etc.): A point-in-time recovery or snapshot strategy MUST be defined and
  documented if such resources are introduced in future features.

Terraform remote state MUST be stored in S3 with versioning and DynamoDB state
locking enabled.

**Rationale**: Data loss on an enterprise data platform is a critical failure.
Durability controls ensure recoverability within defined RPO/RTO targets. Allowing
engineers to choose the appropriate lifecycle strategy — rather than mandating a
single storage class — ensures policies reflect actual access patterns and cost
profiles rather than an arbitrary uniform rule.

### IV. Fault-Tolerance

Production ECS services MUST run with a minimum of two tasks across at least two
Availability Zones. MWAA environments in production MUST be configured for
high-availability mode. Glue jobs MUST define retry counts and timeout values.
DMS replication instances MUST be Multi-AZ in production. Resources MUST NOT
create hard dependencies between components that would cause a total platform
failure on a single-component outage.

**Rationale**: The EDP serves downstream consumers with real-time and scheduled
dependencies. Unplanned outages cascade across the platform; AZ-level resilience
prevents single points of failure.

### V. Cost Optimisation

All AWS resources MUST be sized per environment: development and test environments
MUST use smaller/cheaper instance types than UAT and production. Auto-scaling MUST
be configured where supported (ECS, Redshift serverless). Unused or orphaned
resources (e.g., old Glue job versions, stale ECS task definitions) MUST be
cleaned up. Cost allocation tags (`Environment`, `Project`, `Owner`, `CostCentre`)
MUST be applied to every taggable resource.

**Lifecycle policies for cost control**: Every S3 bucket and other stateful resource
MUST define a lifecycle or retention policy (see §III Durability). The policy
MUST include a cost rationale — engineers MUST choose the storage class transition
strategy that best balances retrieval frequency, latency tolerance, and cost for
the resource's specific purpose. Valid strategies include (but are not limited to):
`INTELLIGENT_TIERING` (unknown or mixed access patterns), `STANDARD_IA` + optional
`GLACIER` or `DEEP_ARCHIVE` tiers (predictable infrequent access), and expiration
(ephemeral artefacts). The chosen strategy and its rationale MUST be recorded in
the feature spec under Assumptions or a dedicated Lifecycle section.

**Rationale**: Enterprise data workloads can generate significant and unexpected
cloud spend. Systematic cost controls and environment-aware sizing prevent budget
overruns. Allowing engineers to select the lifecycle strategy appropriate to each
resource's purpose produces better cost outcomes than a single uniform rule, while
the documentation requirement ensures deliberate rather than accidental choices.

### VI. DRY & Modularity (NON-NEGOTIABLE)

All Terraform code MUST live under `terraform/` — the `terraform-legacy/`
directory is excluded and MUST NOT be modified. Any set of resources that is
provisioned for more than one purpose (e.g., multiple Glue jobs, multiple S3
buckets with the same configuration pattern) MUST be encapsulated in a reusable
module under `terraform/modules/`.

A module MUST NOT be created unless a reusability plan is documented. The
reusability plan MUST identify at least two distinct call sites — either both
already present in the codebase or one present and one committed in an active
feature spec or plan. Single-use modules are prohibited; resources consumed by
only one caller MUST be defined inline in the root configuration. The reusability
plan MUST be recorded in the module's `README.md` under a "Consumers" section.

Modules MUST expose a consistent interface via `variables.tf` and `outputs.tf`
and MUST include a `README.md` (with a "Consumers" section as above). Terraform
files within a module or account root MUST be named meaningfully (e.g.,
`glue_jobs.tf`, `ecs_services.tf`, `security_groups.tf`) so that related
resources are grouped in the same file. Arbitrary resource sprawl across a
single `main.tf` is prohibited for account-level configurations with more than
five distinct resource types.

**Rationale**: DRY code reduces the surface area for misconfiguration errors,
simplifies maintenance, and enables consistent enforcement of the other principles
across all components. Requiring a documented reusability plan prevents premature
abstraction — modules created for a single caller add indirection without benefit,
increase cognitive overhead, and complicate future refactoring.

## Technology Stack

- **IaC**: Terraform >= 1.0, HCL
- **Cloud Provider**: AWS (ap-southeast-2, Australia Sydney)
- **State Backend**: S3 + DynamoDB state lock
- **Environments**: `dev`, `test`, `uat`, `prod`
- **Target account workload**: `chedaws-wl-ndp`
- **Core AWS services**: S3, Redshift, DMS, Glue, MWAA, ECS, MSK, KMS, IAM,
  CloudWatch, SNS, Security Groups
- **Linting/Validation**: `tflint` (see `auto/tflint`)
- **Deployment role**: `InfraBuildRole` per target account

## Development Workflow

1. **Branch**: Create a feature branch per change. Branch names MUST follow
   `<type>/<short-description>` (e.g., `feat/add-glue-crawler-module`).
2. **Lint**: Run `tflint` (`auto/tflint`) before raising a pull request. All
   lint warnings MUST be resolved or explicitly suppressed with justification.
3. **Plan**: Run `terraform plan -var="env=<env>"` for all target environments
   affected by the change. Plan output MUST be reviewed and attached to the PR.
4. **Constitution Check**: Every PR reviewer MUST verify that the change adheres
   to all six Core Principles before approval.
5. **Naming**: Terraform files MUST be named to reflect the resources they contain.
   Acceptable names include `glue_jobs.tf`, `ecs_services.tf`, `s3_buckets.tf`,
   `security_groups.tf`, `iam_roles.tf`, `cloudwatch.tf`, `kms.tf`, etc.
   Terraform resource local names (the second label in a `resource` block, e.g.,
   the `"data_lake_bucket"` in `resource "aws_s3_bucket" "data_lake_bucket"`) MUST
   reflect the resource's purpose. Generic placeholders such as `"this"`, `"main"`,
   or `"default"` MUST NOT be used when more than one resource of the same type
   exists in the configuration root or module, as identical local names across
   different call sites produce Terraform address collisions. Each resource's local
   name MUST be unique within its resource type in the containing configuration and
   MUST describe what the resource does (e.g., `"audit_logs"`, `"raw_data"`,
   `"replication_task_orders"`).
6. **Tagging**: Common tags (e.g., `Environment`, `Application`, `ManagedBy`)
   MUST be defined centrally in the AWS provider `default_tags` block in
   `providers.tf`. This is the single authoritative source of truth for shared
   tags. A `local.common_tags` map MUST NOT be used; per-resource `tags`
   arguments MUST only contain resource-specific tags (e.g., `Name`).
7. **No direct edits to `terraform-legacy/`**: That directory is frozen.
8. **README**: The root `README.md` MUST be updated whenever a component is added,
   removed, or materially changed. It MUST remain compact — implementation detail
   and deep-dive content MUST live in module `README.md` files or feature specs,
   not in the root document.

## Governance

This constitution supersedes all other coding standards and verbal agreements for
the `chedaws-tf-edp-infra` repository. Amendments require:

1. A pull request updating this file with a version bump following semver rules
   (see version policy below).
2. Review and approval by at least one other team member with infrastructure
   ownership.
3. An updated Sync Impact Report (prepended as an HTML comment) documenting what
   changed and which downstream templates were updated.

**Version policy**:
- **MAJOR** bump: Removal or redefinition of an existing principle.
- **MINOR** bump: New principle or mandatory section added.
- **PATCH** bump: Clarification, wording fix, or non-semantic refinement.

All PRs and code reviews MUST verify compliance with the Core Principles before
merge. Complexity beyond what is required MUST be justified in the PR description.
Use `README.md` and module-level `README.md` files for runtime and operational
guidance.

**Version**: 1.5.0 | **Ratified**: 2026-06-26 | **Last Amended**: 2026-07-14
