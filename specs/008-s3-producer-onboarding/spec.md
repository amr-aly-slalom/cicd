# Feature Specification: S3 Data Producer Self-Onboarding and E2E Verification

**Feature Branch**: `feat/s3-glue`

**Created**: 2026-07-30

**Status**: Draft

---

## Problem Statement

A subset of incoming data for the enterprise data platform lands in Amazon S3 as objects. Producers — teams that own source data — need write access to a specific prefix within the shared landing bucket (`chedaws-edp-landing-bucket-<env>`) before they can deliver data. For structured datasets (CSV, JSON, or Avro), an AWS Glue database and table must also be registered so that downstream consumers can discover and query those datasets via the data catalog.

Currently there is no self-service path: every new dataset requires manual platform team involvement to provision an IAM role, bucket prefix policy, and optional Glue resources. There is no schema enforcement, no audit trail, and no drift detection.

Once the self-onboarding infrastructure is provisioned, there is also no automated verification that the provisioned resources are correct and that Glue tables are actually queryable through Athena. Without a standing end-to-end test, silent regressions — such as a SerDe misconfiguration, a missing KMS grant, or a broken S3 location — go undetected until a real producer is affected.

This specification describes:

1. **A Git-based self-service platform** — modelled on the existing Kafka producer/consumer registration workflow in `kafka/` — where data producer teams declare their datasets in YAML files via Pull Request, and CI/CD provisions IAM access and optional Glue catalog resources without manual platform team intervention.

2. **A daily end-to-end verifier** — a scheduled Lambda that automatically validates the provisioned infrastructure is correct and queryable on every daily run.

---

## Goals

- **G-01**: Any producer team registers a new S3 namespace by opening a PR with `s3/<namespace>.yaml`; individual tables are registered by adding `s3/<namespace>/<name>.yaml`. No platform team action is required for provisioning.
- **G-02**: Write access is scoped to a deterministic S3 prefix (`<namespace>/<name>/`) within the landing bucket; producers cannot write outside their namespace prefix.
- **G-03**: Cross-account AWS producers receive access via IAM role assumption; on-premises producers authenticate via IAM Roles Anywhere.
- **G-04**: For structured datasets, a Glue database and table are provisioned automatically based on schema declarations in the table registration YAML.
- **G-05**: All dataset registrations are validated against a JSON Schema before any Terraform step runs.
- **G-06**: Dataset decommissioning is a deliberate two-phase process to prevent accidental data and catalog loss.
- **G-07**: Configuration drift in IAM and Glue resources is detectable via `terraform plan`.
- **G-08**: Prove end-to-end correctness of the provisioned infrastructure daily: IAM role assumption, S3 write access, Glue catalog registration, and Athena queryability — including data integrity — are validated automatically on every daily run.
- **G-09**: Detect regressions in any future change to Terraform code, Glue SerDe configuration, or KMS key policy, within 24 hours.
- **G-10**: Provide a self-contained, low-noise canary that runs continuously in all four environments without manual intervention and leaves no residual data in S3.

---

## User Scenarios & Testing

### User Story 1 — Producer Team Registers a New S3 Dataset (Priority: P1)

A data producer team (same-account AWS, cross-account AWS, or on-premises) needs write access to a scoped S3 namespace prefix in the landing bucket. They open a PR containing a namespace YAML at `s3/<namespace>.yaml` declaring the producer's identity and per-environment IAM identities, and a table YAML at `s3/<namespace>/<name>.yaml` declaring the dataset format and optional schema.

**Acceptance Scenarios**:

1. **Given** a namespace YAML at `s3/finance.yaml` with cross-account IAM role ARNs and a table YAML at `s3/finance/transactions.yaml`, **When** the PR is merged to `main`, **Then** a namespace IAM role `edp-<env>-s3-producer-finance` is created per declared environment, trusting the producer's role ARNs, with `s3:PutObject` and `s3:PutObjectTagging` scoped to `arn:aws:s3:::chedaws-edp-landing-bucket-<env>/finance/*`, plus `kms:GenerateDataKey` and `kms:Decrypt` on the landing bucket KMS key.
2. **Given** a table YAML with `spec.format: csv` but no `spec.schema` block, **When** CI validation runs, **Then** the PR is accepted and Glue resources are not provisioned.
3. **Given** a namespace YAML with `certificateSubject: ["CN=HOSTNAME"]` per environment, **When** applied, **Then** a namespace IAM role is created with an IAM Roles Anywhere trust policy conditioned on the certificate CN.
4. **Given** a YAML file using any snake_case attribute name (e.g., `domain_name`), **When** CI schema validation runs, **Then** the PR is blocked — unrecognised field names are rejected by `additionalProperties: false`.
5. **Given** two table YAMLs with the same `metadata.namespace` and `metadata.name`, **When** the CI validation job runs, **Then** the PR is blocked with a duplicate registration error before any Terraform step executes.

---

### User Story 2 — Producer Team Registers a Structured Dataset with Glue Catalog (Priority: P2)

A producer team delivers structured data (CSV, JSON, or Avro) and wants it discoverable in the AWS Glue Data Catalog so that downstream consumers can query it via Athena or similar tools. They add a `spec.schema` block to their table YAML declaring column names, types, and optional partitioning.

**Acceptance Scenarios**:

1. **Given** a table YAML with `spec.format: csv` and a `spec.schema.columns[]` list, **When** the PR is merged, **Then** a Glue database `edp_<env>_<namespace>` and a Glue table `<name>` are provisioned pointing to `s3://chedaws-edp-landing-bucket-<env>/<namespace>/<name>/`.
2. **Given** a table YAML with `spec.schema.partitionKeys: [year, month, day]`, **When** applied, **Then** the Glue table partition keys are set accordingly.
3. **Given** two table YAMLs sharing the same `metadata.namespace` but different `metadata.name`, **When** both are applied, **Then** both Glue tables exist under the shared `edp_<env>_<namespace>` Glue database without conflict.
4. **Given** a table YAML with `spec.format: avro` and a `spec.schema` block, **When** applied, **Then** the Glue table SerDe is set to the Avro SerDe and the declared schema columns are reflected.

---

### User Story 3 — Dataset Decommissioning (Priority: P3)

A producer team retires a dataset via a two-phase process, preventing accidental destruction of IAM access and Glue catalog entries.

**Acceptance Scenarios**:

1. **Given** a table YAML has `spec.decommission: true` set, **When** the PR is merged, **Then** the table-level IAM role (if any) and Glue resources for that dataset are destroyed; the namespace IAM role is unaffected; S3 objects are not deleted.
2. **Given** a table YAML file is deleted without `spec.decommission: true` having been set and merged first, **When** CI validation runs, **Then** the PR is blocked with a clear decommission guard error.
3. **Given** `spec.decommission: true` is set, **When** `terraform plan` runs, **Then** only the table-level IAM role (if any) and optional Glue resources are shown as destroyed.

---

### User Story 4 — Platform Team Detects Configuration Drift (Priority: P4)

Any out-of-band change to a managed IAM role, bucket policy condition, or Glue resource is visible as a corrective change in the next `terraform plan`.

**Acceptance Scenarios**:

1. **Given** a namespace IAM role's trust policy is manually changed to add an additional principal, **When** `terraform plan` runs, **Then** the plan shows a corrective update to restore the declared trust policy.
2. **Given** a Glue table's column list is manually altered in the console, **When** `terraform plan` runs, **Then** the plan shows a corrective update to restore the declared schema.

---

### User Story 5 — Platform Team Confirms Glue Tables Are Queryable After Deployment (Priority: P1)

After Terraform is applied in any environment, the platform team needs confidence that all three Glue tables (CSV, JSON, Avro) are correctly registered and that data written through the namespace IAM role can be retrieved and validated through Athena. The scheduled Lambda replaces the manual Athena console check.

**Acceptance Scenarios**:

1. **Given** Terraform has been applied and the `platform` namespace's three Glue tables exist, **When** the Lambda is invoked (scheduled or manual), **Then** the Lambda generates sample data, assumes the `platform` namespace IAM role, writes the data to each table's S3 prefix, queries each table through Athena, confirms that the returned rows match the written data exactly (column names and values), deletes the written S3 objects, and exits with no errors.
2. **Given** the Lambda completes all phases successfully for all three tables, **When** the run finishes, **Then** no CloudWatch alarm is triggered, the Lambda execution is logged as `PASS`, and no test data objects remain in the `platform/` S3 prefix.
3. **Given** a regression breaks one Glue table (e.g., wrong S3 location or SerDe misconfiguration), **When** the Lambda runs, **Then** the failing table's query or validation is reported, a CloudWatch alarm transitions to `ALARM`, and cleanup is still attempted for all tables regardless of validation outcome.

---

### User Story 6 — Platform Team Verifies Format-Specific SerDe Correctness (Priority: P2)

Each supported format (CSV, JSON, Avro) uses a distinct Glue SerDe. The three-table structure isolates format-specific failures, making it immediately clear which format is broken.

**Acceptance Scenarios**:

1. **Given** only the Avro Glue table is misconfigured (wrong SerDe), **When** the Lambda runs, **Then** the `e2e_avro` validation fails and is reported; `e2e_csv` and `e2e_json` are unaffected and pass.
2. **Given** the Lambda writes sample data for each format, **When** Athena returns results for each table, **Then** all declared column names and values match the data generated by the Lambda exactly.

---

### User Story 7 — Platform Team Can Query E2E Tables Manually During Development (Priority: P3)

During development and debugging, engineers can run ad-hoc Athena queries against the e2e test tables to verify schema. The dedicated `athena-query-results/e2e/` prefix keeps e2e test query results separate from production query results.

**Acceptance Scenarios**:

1. **Given** the Lambda has written sample data to the `e2e_csv` prefix, **When** an engineer runs `SELECT * FROM edp_<env>_platform.e2e_csv LIMIT 10` in the Athena Console, **Then** at least one row is returned and the query result is stored under `s3://chedaws-edp-landing-bucket-<env>/athena-query-results/e2e/`.
2. **Given** the Athena workgroup is configured to write results to `athena-query-results/e2e/`, **When** any e2e query runs (Lambda or manual), **Then** result files are written exclusively to that prefix.

---

### Edge Cases

- Two table YAMLs with the same `metadata.namespace` and `metadata.name`: blocked by native `for_each` key collision and a CI duplicate-detection script.
- `iamRoles` and `certificateSubject` declared in the same environment entry of a namespace YAML: blocked by JSON Schema (`oneOf` — mutually exclusive).
- IAM role name exceeding 64 characters: blocked by a `terraform_data` precondition.
- A `spec.schema` block present without a supported `spec.format` value: blocked by JSON Schema enum constraint.
- A table YAML file path that does not match its `metadata.namespace` / `metadata.name` values: blocked by CI path-validation script.
- A `spec.decommission: true` registration where the Glue database still has other active tables: Glue database is NOT destroyed (only the specific table is removed).
- A `metadata.namespace` value containing hyphens: the Glue database name is normalised (hyphens replaced with underscores). The S3 prefix and IAM role name retain hyphens as-is.
- If the Lambda fails after writing data but before Athena returns results: cleanup is attempted regardless of which phase failed.
- If cleanup itself fails: the Lambda logs the cleanup failure separately and raises a dedicated alarm; partial data left in the `platform/` prefix is flagged. The `WHERE id IN (...)` filter ensures stale leftover objects do not interfere with the next run.
- If the Lambda fails to assume the `platform` namespace IAM role: the Lambda logs an `sts:AssumeRole` failure, skips the write phase entirely, and raises the alarm.

---

## Requirements

### Functional Requirements — Self-Onboarding

- **FR-001**: Teams register an S3 namespace by opening a PR with a namespace YAML at `s3/<namespace>.yaml`; individual tables are registered by adding table YAMLs at `s3/<namespace>/<name>.yaml`. No manual platform team provisioning action is required.
- **FR-002**: All namespace and table YAML files are validated against their respective JSON Schemas before any infrastructure change is made.
- **FR-003**: All YAML attribute names use camelCase. snake_case names are rejected by `additionalProperties: false`.
- **FR-004**: Producer identity fields `namespace` live in `metadata` of the namespace YAML; `name` lives in `metadata` of the table YAML. `namespace` follows pattern `^[a-z][a-z0-9-]*$`; `name` follows pattern `^[a-z][a-z0-9_]*$` (underscores only).
- **FR-005**: The S3 prefix for each dataset is `<namespace>/<name>/`, derived from `metadata` and assembled by Terraform.
- **FR-006**: IAM access for AWS workloads is granted by creating one namespace-level `aws_iam_role` per (namespace, env), named `edp-<env>-s3-producer-<namespace>`, with trust policies listing the workload's role ARN(s). The namespace role grants `s3:PutObject` and `s3:PutObjectTagging` scoped to `<namespace>/*` plus `kms:GenerateDataKey` and `kms:Decrypt` on `alias/chedaws-edp-s3-<env>`. When a table YAML declares an optional `spec.producer` block, an additional table-level `aws_iam_role` named `edp-<env>-s3-producer-<namespace>-<name>` is provisioned, scoped to `<namespace>/<name>/*`.
- **FR-017**: Every namespace IAM role policy MUST also grant Athena query execution (`athena:StartQueryExecution`, `athena:GetQueryExecution`, `athena:GetQueryResults`, `athena:StopQueryExecution`), Glue catalog read (`glue:GetDatabase`, `glue:GetTable`, `glue:GetTables`, `glue:GetPartition`, `glue:GetPartitions`) scoped to the namespace's Glue database and its tables, `s3:GetObject` on `<namespace>/*`, and S3 read/write (`s3:GetObject`, `s3:PutObject`, `s3:ListBucket`) on `athena-query-results/<namespace>/*`. This allows producers to query their own data via Athena without requiring separate IAM grants.
- **FR-018**: Every table-level IAM role policy (when `spec.producer` is declared) MUST grant the same Athena and Glue read permissions as FR-017, but scoped to the single table: `s3:GetObject` on `<namespace>/<name>/*`, S3 read/write on `athena-query-results/<namespace>/<name>/*`, and Glue read scoped to the namespace database and the specific table ARN.
- **FR-007**: IAM access for on-premises workloads is granted via IAM Roles Anywhere: `rolesanywhere.amazonaws.com` as trust principal with a CN condition derived from `certificateSubject`.
- **FR-008**: The CI script verifies that for namespace YAMLs, `path.stem == metadata.name`; and for table YAMLs, `path.parent.name == metadata.namespace` and `path.stem == metadata.name`.
- **FR-009**: When `spec.format` is `csv`, `json`, or `avro` and `spec.schema.columns[]` is declared, a Glue database `edp_<env>_<namespace>` (hyphens in `namespace` normalised to underscores) and Glue table `<name>` are provisioned. The Glue database is shared across all datasets with the same `namespace` within the same environment.
- **FR-010**: Glue table columns, SerDe, and optional partition keys are derived from `spec.schema`; column types use Glue-native type strings (`string`, `int`, `bigint`, `double`, `boolean`, `timestamp`, `date`).
- **FR-011**: Decommission of a table YAML is a two-phase process: `spec.decommission: true` must be set and merged before the table YAML file is deleted; direct deletion without the guard is blocked by CI. Namespace YAMLs have no decommission guard.
- **FR-012**: When `spec.decommission: true` is processed, the table-level IAM role (if any) and Glue table (if any) are destroyed. The Glue database is destroyed only if it has no remaining active tables. The namespace IAM role is unaffected.
- **FR-013**: All AWS resources are tagged via `default_tags` in the AWS provider.
- **FR-014**: All Terraform for S3 producer resources lives under `terraform/` in semantically named files; `terraform-legacy/` is never modified.
- **FR-015**: The CI/CD pipeline runs JSON Schema validation and path checks on every PR before any `terraform plan` step executes.
- **FR-016**: `terraform apply` to `dev` runs automatically on pushes to `main`; `uat` and `prod` applies are gated behind GitHub Environment approvals.

### Functional Requirements — E2E Verifier

- **FR-E01**: A `platform` data namespace MUST be registered as a `Namespace` YAML at `s3/platform.yaml`. The `spec.producer.environments[env].iamRoles` field MUST list the ARN of the Lambda execution role (`arn:aws:iam::<account-id>:role/chedaws-edp-s3-e2e-verifier-<env>`).
- **FR-E02**: Three `Table` YAMLs MUST be created: `s3/platform/e2e_csv.yaml`, `s3/platform/e2e_json.yaml`, `s3/platform/e2e_avro.yaml`. Each MUST include a `spec.schema.columns` block so that Glue tables are provisioned.
- **FR-E03**: All three tables MUST share an identical column schema with at least four columns of mixed data types, including an integer `id` column as the first column (stable sort key for validation).
- **FR-E04**: On each scheduled run, the Lambda MUST dynamically generate sample data (at least three rows per table) whose values are deterministic within a single invocation.
- **FR-E05**: The Lambda MUST generate format-correct data: a CSV file with a header row, newline-delimited JSON (one object per line), and a valid Avro binary file.
- **FR-E06**: The Lambda MUST assume the `platform` namespace IAM role (`edp-<env>-s3-producer-platform`) to write data objects, using a single UUID per invocation: `platform/<name>/<uuid>/data.<ext>`.
- **FR-E07**: After writing, the Lambda MUST query each Glue table through Athena using `SELECT * FROM edp_<env>_platform.<name> WHERE id IN (<generated-ids>) ORDER BY id`. Validation MUST sort both generated and Athena result rows by `id` before comparing.
- **FR-E08**: After validation, the Lambda MUST delete all S3 objects it wrote under the run's UUID prefix. The Lambda execution role (not the namespace role) MUST have `s3:DeleteObject` permission on `platform/*`.
- **FR-E09**: Athena query results MUST be written to the `athena-query-results/e2e/` prefix within the existing landing S3 bucket.
- **FR-E10**: A Lambda function MUST be provisioned that, on a once-daily schedule (06:00 UTC), executes the full generate → write → query → validate → cleanup cycle for all three tables.
- **FR-E11**: If any phase fails, the Lambda MUST publish a failure metric to CloudWatch; a CloudWatch Alarm MUST transition to `ALARM` state and notify via the existing SNS topic.
- **FR-E12**: If cleanup fails independently of validation outcome, a separate CloudWatch metric and alarm MUST monitor this.
- **FR-E13**: The Lambda execution role MUST follow least-privilege: `sts:AssumeRole` on the platform namespace IAM role; Athena query execution; S3 read/write on `athena-query-results/e2e/`; `s3:DeleteObject` on `platform/*`; KMS decrypt/generate on `alias/chedaws-edp-s3-<env>`.
- **FR-E14**: The Lambda schedule, memory, and timeout MUST be sized per environment (256 MB/120 s dev/test; 512 MB/300 s uat/prod).
- **FR-E15**: The CloudWatch Log Group (`/chedaws-edp/s3-e2e-verifier/<env>`) MUST be encrypted using `module.kms["cloudwatch_logs"]`, with 30-day retention in dev/test and 90-day retention in uat/prod.
- **FR-E16**: All resources provisioned by the verifier (Lambda, IAM role, CloudWatch alarms, EventBridge rule, Athena workgroup) MUST be tagged via the AWS provider `default_tags`.
- **FR-E17**: All verifier infrastructure MUST be managed as Terraform code in `terraform/s3_e2e_verifier.tf`.

### Non-Functional Requirements

- **NFR-001**: IAM role names do not exceed 64 characters; enforced by a `terraform_data` precondition.
- **NFR-002**: The platform scales to at least 200 registered S3 producer datasets per environment.
- **NFR-003**: The CI pipeline completes end-to-end (validate → plan → apply for dev) in ≤ 15 minutes from PR merge.
- **NFR-004**: All IAM roles use least-privilege policies. Glue catalog encryption uses a dedicated customer-managed KMS key (`alias/chedaws-edp-glue-<env>`).
- **NFR-005**: The full e2e generate → write → query → validate → cleanup cycle completes within 5 minutes of Lambda invocation.
- **NFR-006**: Transient Athena failures do not trigger alarms — the Lambda retries once before marking a table as failed.

### Key Entities

- **Namespace**: A YAML document (`kind: Namespace`) at `s3/<namespace>.yaml` declaring producer identity for a data namespace.
- **Table**: A YAML document (`kind: Table`) at `s3/<namespace>/<name>.yaml` declaring a single logical dataset.
- **NamespaceIAMRole**: One `aws_iam_role` per (`namespace`, `env`) combination, named `edp-<env>-s3-producer-<namespace>`.
- **TableIAMRole**: An optional `aws_iam_role` per (`namespace`, `name`, `env`) combination, named `edp-<env>-s3-producer-<namespace>-<name>`.
- **GlueDatabase**: One `aws_glue_catalog_database` per (`env`, `namespace`) pair, named `edp_<env>_<namespace>`.
- **GlueTable**: One `aws_glue_catalog_table` per (`namespace`, `name`). Only provisioned when `spec.schema.columns[]` is present.
- **E2E Verifier Lambda**: `chedaws-edp-s3-e2e-verifier-<env>` — scheduled daily to validate the full onboarding infrastructure end-to-end.
- **Athena Workgroup**: `edp-e2e-<env>` — dedicated workgroup for e2e queries with enforced result prefix.

---

## Success Criteria

- **SC-001**: A producer team registers a new S3 dataset and has IAM access provisioned across declared environments without any manual platform team action, within 15 minutes of PR merge.
- **SC-002**: A structured dataset producer has a Glue database and table provisioned automatically upon PR merge, discoverable in the data catalog.
- **SC-003**: 100% of dataset registrations that reach `terraform apply` have previously passed JSON Schema validation and path checks.
- **SC-004**: A producer can write objects only to their declared namespace prefix; any attempt to write outside that prefix is denied.
- **SC-005**: Any out-of-band change to a managed IAM role or Glue resource is detected and reported in the next `terraform plan` run.
- **SC-006**: A dataset decommissioning PR that deletes the table YAML without the prior `spec.decommission: true` guard step is blocked by CI in 100% of cases.
- **SC-007**: All three e2e Glue tables are written to, queried, and validated successfully within 5 minutes of a manual Lambda invocation.
- **SC-008**: A deliberate regression (wrong SerDe, broken S3 prefix, or revoked KMS grant) is detected by the Lambda and triggers a CloudWatch alarm within 24 hours.
- **SC-009**: After every Lambda run, zero test data objects remain in the `platform/` S3 prefix; any cleanup failure is immediately surfaced via a dedicated CloudWatch alarm.

---

## Lifecycle Policy

- **Test data S3 objects** (`platform/*/`): Written dynamically and deleted each run. Cleanup alarm fires if objects persist.
- **Athena query results** (`athena-query-results/e2e/`): Expired after 7 days by a dedicated S3 lifecycle rule.
- **Lambda logs** (`/chedaws-edp/s3-e2e-verifier/<env>`): 30-day retention in dev/test; 90-day in uat/prod.

---

## Scope

### In Scope

- YAML-based `Namespace` and `Table` schemas and JSON Schema validators
- CI path-validation, duplicate-detection, and decommission-guard script
- Namespace-level IAM role provisioning for cross-account and on-premises producers
- Optional table-level IAM role provisioning when declared in the table YAML
- AWS Glue database and table provisioning for structured datasets (CSV, JSON, Avro)
- Two-phase decommission guard for table YAMLs
- Terraform resources in `terraform/s3_producers.tf`, `terraform/glue.tf`, and `terraform/s3_e2e_verifier.tf`
- GitHub Actions workflow for S3 producer registrations
- `s3/` registration directory with namespace and table YAMLs
- Daily scheduled Lambda verifier with CloudWatch alarms and dedicated Athena workgroup

### Out of Scope

- Data consumer access (to be delivered via AWS Lake Formation in a future feature)
- S3 object lifecycle management and data deletion
- Schema Registry or schema evolution enforcement beyond column declarations
- Network connectivity between external accounts / on-premises and the landing bucket
- Existing `terraform-legacy/` resources

---

## Key Decisions

| Decision | Choice | Reason |
|----------|--------|--------|
| Registration model | Namespace YAML at `s3/<namespace>.yaml` + table YAML at `s3/<namespace>/<name>.yaml` | Namespace producers need access to all their tables; namespace-level role avoids policy churn when new tables are added |
| S3 prefix formula | `<namespace>/<name>/` assembled by Terraform | Teams never construct full ARN strings |
| IAM model | Namespace-level role per (namespace, env) scoped to `<namespace>/*`; optional table-level role scoped to `<namespace>/<name>/*` | Namespace access avoids churn; table roles are additive; table roles are additive for workloads requiring narrower access |
| Glue catalog scope | One database per (`env`, `namespace`) named `edp_<env>_<namespace>`, one table per `name` | Env prefix prevents name collisions between environments sharing an AWS account |
| Glue KMS key | Dedicated `alias/chedaws-edp-glue-<env>` CMK | AWS Glue requires `glue.amazonaws.com` service principal; cannot reuse S3-only key |
| Decommission granularity | Two-phase guard for table YAMLs only; namespace YAML deletion is unguarded | Table decommission must be deliberate; namespace role can be deleted independently |
| E2E namespace | Dedicated `platform` namespace registered via the same YAML self-service path | Exercises the real onboarding flow; the e2e canary is itself a producer |
| E2E query isolation | `WHERE id IN (<generated-ids>)` filter | Hermetic validation even when stale objects from prior failed cleanup exist |
| E2E alarms | 3 per environment: validation, cleanup, Lambda errors | Separate alarms provide distinct failure signals; all route to existing EDP SNS topic |

---

## Assumptions

- `module.landing_s3` already exists and is managed by `terraform/s3.tf`; this feature adds namespace-scoped IAM roles, Glue resources, and a lifecycle rule for e2e Athena results.
- A dedicated KMS key `alias/chedaws-edp-glue-<env>` is created via a new `module.kms["glue"]` entry.
- IAM Roles Anywhere Trust Anchors and Profiles are already configured in each environment account.
- Dev and test environments share AWS account `381491832813`; UAT uses `339712719726`; prod uses `637423180765`.
- `aws_glue_data_catalog_encryption_settings` is an AWS account-level singleton; if encryption has already been configured manually in any account, the resource must be imported into Terraform state before applying.
- Glue column types are limited to the standard set: `string`, `int`, `bigint`, `double`, `boolean`, `timestamp`, `date`.
- Generating valid Avro binary at Lambda runtime requires `fastavro` bundled with the Lambda deployment package.
- The e2e tables use flat (non-partitioned) schemas. Partition key testing is out of scope for v1.

---

## Clarifications

### Session 2026-07-30

- Q: Should identity fields use `businessName`/`appName` or namespace-specific names? → A: `namespace` and `name` — reflects data namespace ownership and Glue catalog artifact semantics.
- Q: How should hyphens in `name` be handled? → A: Restrict `name` to `^[a-z][a-z0-9_]*$` (underscores only); consistent across S3 prefix, IAM role, and Glue table name with no silent normalisation.
- Q: What should the Glue database naming pattern be? → A: `edp_<env>_<namespace>` — env prefix included to prevent name collisions between environments sharing the same AWS account.
- Q: Where are producer identity details declared? → A: A namespace-level YAML at `s3/<namespace>.yaml` declares producer identity; table YAMLs declare format, schema, and optional `spec.producer` block for a narrower table-scoped role.
- Q: Should the Lambda use static pre-uploaded sample data or generate dynamically at runtime? → A: Dynamic — the Lambda generates sample data per run, assumes the `platform` namespace IAM role, writes to S3, queries through Athena, validates, and cleans up.
- Q: How should the Lambda validate Athena results when Athena does not guarantee row order? → A: Sort both generated and Athena result rows by the `id` column (ascending integer) before comparing.
- Q: What S3 object key strategy prevents concurrent invocations from interfering? → A: Generate a single UUID per invocation and write objects to `platform/<name>/<uuid>/data.<ext>`; cleanup deletes only objects under that UUID prefix.
- Q: What is the canonical `kind` field for dataset/table YAML registrations? → A: `Table` (formerly `DatasetRegistration`, then `TableRegistration`).
