# Research: S3 Data Producer Self-Onboarding

**Feature**: `specs/008-s3-producer-onboarding`
**Branch**: `feat/s3-glue`
**Date**: 2026-07-30

---

## 1. KMS Key Strategy for Glue Catalog Encryption

**Decision**: Create a dedicated `module.kms["glue"]` key (alias `alias/chedaws-edp-glue-<env>`), separate from the existing `module.kms["s3"]` key.

**Rationale**: The existing S3 KMS key trusts only `s3.amazonaws.com`. The AWS Glue Data Catalog requires `glue.amazonaws.com` as a service principal in the key's trust policy. Adding Glue to the S3 key would mix concerns and deviate from the project's established pattern of one KMS key per service. The `local.kms_services` map in `locals.tf` already provides a clean extension point — adding `glue = { service_principals = ["glue.amazonaws.com"] }` instantiates a new key via `module.kms` with no structural change.

**Alternatives considered**:
- Reuse `module.kms["s3"]` key — rejected; requires modifying the S3 key's trust policy, mixing two service principals with different access scopes.
- Use AWS-managed key (`aws/glue`) — rejected; violates constitution principle I which mandates customer-managed KMS keys for all data stores.

**Impact on spec**: The spec assumption "Glue catalog encryption uses the same KMS key as the landing bucket" is superseded by this decision. A dedicated `module.kms["glue"]` key is the correct implementation.

---

## 2. S3 IAM Policy — KMS Permissions Required

**Decision**: The S3 producer IAM policy must include `kms:GenerateDataKey` and `kms:Decrypt` on `module.kms["s3"].key_arn` in addition to `s3:PutObject` and `s3:PutObjectTagging`.

**Rationale**: The existing `data.aws_iam_policy_document.s3_policy` on `module.landing_s3` denies any `PutObject` that does not use KMS encryption via the platform key (`DenyNonKMSAlgorithm` and `DenyNonPlatformKeyUploads` statements). A producer IAM role without `kms:GenerateDataKey` will fail at the S3 layer with an access-denied error from KMS, not from S3. Adding these KMS permissions to each producer policy is therefore mandatory, not optional.

**Scope of KMS grant**: The grant is on the S3 KMS key only, not on all keys in the account. The Glue KMS key (`module.kms["glue"]`) is an internal platform key and is not exposed to producer roles.

**Alternatives considered**:
- Grant KMS access via a shared key policy condition — rejected; this would require platform-side changes every time a new producer role is added, defeating the self-service goal.

---

## 3. Glue Catalog Encryption — Catalog-Level vs. Resource-Level

**Decision**: Enable Glue Data Catalog encryption using `aws_glue_data_catalog_encryption_settings` resource with `SSE-KMS` mode using `module.kms["glue"].key_arn`. This is a singleton resource per AWS account region.

**Rationale**: AWS Glue catalog encryption is an account/region-level setting, not per-database or per-table. There is no `aws_glue_catalog_database` or `aws_glue_catalog_table` argument for encryption. The `aws_glue_data_catalog_encryption_settings` resource must be provisioned once; Terraform will enforce it on every plan. Since this project uses a single AWS region (`ap-southeast-2`) per environment account, one resource covers all Glue catalog objects in that account.

**Consideration**: If other Glue databases already exist in the target accounts (outside this Terraform root), enabling catalog encryption will affect them. As of the current codebase survey, no other Glue catalog resources are managed in `terraform/` — this is the first Glue feature for the EDP.

---

## 4. Glue Table SerDe Mappings for Supported Formats

**Decision**: Use the following Hadoop/Hive SerDe mappings per format declared in `spec.format`:

| Format | InputFormat | OutputFormat | SerializationLibrary |
|--------|-------------|--------------|----------------------|
| `csv` | `org.apache.hadoop.mapred.TextInputFormat` | `org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat` | `org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe` |
| `json` | `org.apache.hadoop.mapred.TextInputFormat` | `org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat` | `org.openx.data.jsonserde.JsonSerDe` |
| `avro` | `org.apache.avro.mapred.AvroInputFormat` | `org.apache.avro.mapred.AvroOutputFormat` | `org.apache.hadoop.hive.serde2.avro.AvroSerDe` |

**Rationale**: These are the standard Athena/Glue-compatible SerDe libraries for each format. Athena uses the same Hive SerDe interface. The `openx` JSON SerDe is preferred over the Hive JSON SerDe because it tolerates missing fields and handles nested structures better in practice. Avro uses the native Avro input/output formats.

**Alternatives considered**:
- Parquet/ORC — deferred; not in scope for v1 (spec lists only CSV, JSON, Avro).
- `LazySimpleSerDe` for JSON — rejected; field name ordering issues make it fragile for JSON.

---

## 5. Terraform Locals Structure — File Scanning Pattern

**Decision**: Use two separate `fileset` patterns to scan namespace and table YAMLs independently:
- `fileset("${path.root}/../s3", "*.yaml")` → domain registrations (`_s3_domain_files`)
- `fileset("${path.root}/../s3", "*/*.yaml")` → table registrations (`_s3_table_files`)

Key maps for namespace resources:
- `_s3_domain_files` — all parsed domain YAMLs
- `s3_domains_this_env` — domains declaring the current environment
- `s3_aws_domains_this_env` — subset using IAM role ARN trust
- `s3_onprem_domains_this_env` — subset using IAM Roles Anywhere certificate subject

Key maps for table resources:
- `_s3_table_files` — all parsed table YAMLs
- `s3_tables_active` — active (non-decommissioned) tables
- `s3_tables_this_env` — active tables whose namespace is active in this env (for Glue provisioning)
- `s3_tables_with_schema_this_env` — subset declaring `spec.schema.columns`
- `s3_table_aws_producers_this_env` — tables declaring optional `spec.producer` with `iamRoles` in this env
- `s3_table_onprem_producers_this_env` — tables declaring optional `spec.producer` with `certificateSubject` in this env

**Rationale**: Separating domain and table scan patterns makes the Terraform plan/apply logic explicit. Domain locals drive domain-level IAM roles; table locals drive Glue catalog resources and optional table-scoped roles. The `s3_tables_this_env` filter cross-references `s3_domains_this_env` by `metadata.namespace` so that Glue tables are only provisioned in environments where the domain role exists.

---

## 6. Glue Database Naming Pattern

**Decision**: Glue database name formula is `edp_<env>_<namespace>` (hyphens in `namespace` normalised to underscores, since AWS Glue database names do not permit hyphens).

**Rationale**: Including `<env>` as a prefix in the database name prevents collisions between environments that share the same AWS account. `dev` and `test` both use account `381491832813` — without the env prefix, a `namespace: finance` dataset in `dev` and the same in `test` would both attempt to create a database named `edp_finance` in the same account. With the env prefix, they become `edp_dev_finance` and `edp_test_finance`, which are distinct resources. This is consistent with the naming pattern used for other EDP resources (e.g., `chedaws-edp-landing-bucket-<env>`, `edp-<env>-s3-producer-…`).

**`for_each` key**: The Terraform `for_each` key for `aws_glue_catalog_database.producer_domain` is `"${local.environment}_${replace(v.metadata.namespace, "-", "_")}"`, producing unique keys per environment workspace.

**Alternatives considered**:
- `edp_<namespace>` (no env) — rejected; causes Terraform state collisions in the shared dev/test account.
- `edp_<namespace>_<env>` (env suffix) — rejected; env-prefix is the established convention for all EDP resources.

---

## 7. Glue Database Lifecycle on Decommission

**Decision**: The `aws_glue_catalog_database.producer_domain` `for_each` key set is derived from the distinct `(env, namespace)` pairs of **active** (non-decommissioned) producers with schema declarations. When the last producer in a `namespace` domain is decommissioned, the Glue database is automatically removed from the `for_each` set and Terraform destroys it.

**Rationale**: This avoids the need for a separate decommission step for Glue databases. The database lifecycle is entirely driven by whether any active tables reference it — if the last table goes away, the database follows automatically.

**Edge case**: If a `namespace` has one dataset being decommissioned (`spec.decommission: true`) while another dataset in the same `namespace` has no schema (`spec.schema` absent), the database will persist as long as any schema-bearing dataset for that `namespace` is active. If no datasets with schema exist for a `namespace`, no database was ever created, so decommission is a no-op for the Glue layer.

---

## 8. IAM Role for On-Premises Producers — Roles Anywhere Profile Update

**Decision**: Update the existing `aws_rolesanywhere_profile.onprem` in `terraform/iam.tf` to include `[for k, v in aws_iam_role.s3_domain_onprem_producer : v.arn]` (and `[for k, v in aws_iam_role.s3_table_onprem_producer : v.arn]` for optional table roles) in the `role_arns` concat.

**Rationale**: The single `onprem` IAM Roles Anywhere profile covers all on-premises workloads. On-premises S3 namespace-level producers must be included so they can use the existing Trust Anchor and Profile when requesting short-lived credentials. Optional namespace-level table roles for on-premises producers are similarly included. This is a minimal additive change to the existing resource.

---

## 9. GitHub Actions Workflow Placement

**Decision**: New file `.github/workflows/s3-producers.yaml`. Mirrors the structure of the existing Kafka topics workflow.

**Rationale**: Separate workflow files per registration type allow independent triggering (e.g., only when `s3/producers/**` changes) and make CI logs easier to navigate.

---

## 10. CI Validation Script

**Decision**: New Python script `.github/scripts/validate-s3-registrations.py`. Performs:

1. **Namespace YAML validation**: Load all `s3/*.yaml`, validate each against `s3/schema/namespace-schema.json`, check `path.stem == metadata.name`, check no duplicate `name` values across namespace YAMLs.
2. **Table YAML validation**: Load all `s3/*/*.yaml`, validate each against `s3/schema/table-schema.json`, check `path.parent.name == metadata.namespace` and `path.stem == metadata.name`, check no duplicate `(namespace, name)` pairs across active (non-decommissioned) table YAMLs.
3. **Decommission guard** (table YAMLs only): On PR diff context, if any table YAML is deleted, verify `spec.decommission: true` was present in `git show HEAD:<path>`. Namespace YAML deletion has no decommission guard.

**Alternatives considered**:
- Integrate with the existing Kafka validation script — rejected; coupling two unrelated registration systems in one script would make it fragile and harder to maintain independently.

---

## 11. Terraform Resource Naming (constitution §VI compliance)

All new resource local names must be descriptive and unique within their type:

| Resource | Local Name |
|----------|------------|
| `aws_iam_policy` (domain S3 producer) | `s3_domain_producer` |
| `aws_iam_role` (AWS domain S3 producer) | `s3_domain_aws_producer` |
| `aws_iam_role` (on-prem domain S3 producer) | `s3_domain_onprem_producer` |
| `aws_iam_role_policy_attachment` (domain AWS) | `s3_domain_aws_producer` |
| `aws_iam_role_policy_attachment` (domain on-prem) | `s3_domain_onprem_producer` |
| `aws_iam_policy` (optional table S3 producer) | `s3_table_producer` |
| `aws_iam_role` (AWS optional table S3 producer) | `s3_table_aws_producer` |
| `aws_iam_role` (on-prem optional table S3 producer) | `s3_table_onprem_producer` |
| `aws_iam_role_policy_attachment` (table AWS) | `s3_table_aws_producer` |
| `aws_iam_role_policy_attachment` (table on-prem) | `s3_table_onprem_producer` |
| `aws_glue_catalog_database` | `producer_domain` |
| `aws_glue_catalog_table` | `producer_dataset` |
| `aws_glue_data_catalog_encryption_settings` | `edp_catalog` |
| `terraform_data` (domain unique check) | `s3_domain_unique_check` |
| `terraform_data` (table unique check) | `s3_table_unique_check` |
| `terraform_data` (domain name length check) | `s3_domain_name_length_check` |
| `terraform_data` (table role name length check) | `s3_table_name_length_check` |

---

## 12. Resolved Spec Assumption

The spec stated: "The KMS key `alias/chedaws-edp-s3-<env>` managed by `module.kms["s3"]` is used for Glue catalog encryption; no new KMS keys are needed."

**Correction**: A dedicated `module.kms["glue"]` key (`alias/chedaws-edp-glue-<env>`) must be created. The S3 KMS key trusts only `s3.amazonaws.com`; extending it to cover Glue would violate the per-service key isolation established by the existing `local.kms_services` pattern. See Decision 1 above.

---

## E2E Verifier Research Decisions

### 13. Avro Serialisation at Lambda Runtime

**Decision**: Use the `fastavro` Python library bundled with the Lambda deployment package.

**Rationale**: `fastavro` is a pure-Python, actively maintained Avro implementation with no native-code dependencies, making it straightforward to bundle in a Lambda ZIP. It supports `io.BytesIO` as a write target. The `apache-avro` package is the official library but is significantly heavier and slower; `fastavro` is the community standard for AWS Lambda usage.

**Alternatives considered**:
- `apache-avro` (official): rejected — larger wheel, slower parse, no meaningful advantage for this use case.
- Glue Avro SDK jar via subprocess: rejected — not applicable to Python Lambda; requires Java runtime.

---

### 14. Athena Query Isolation Strategy

**Decision**: Filter by run-scoped `id` values using `WHERE id IN (<generated-ids>) ORDER BY id`.

**Rationale**: Athena scans all objects under the Glue table's `location_uri` (`s3://.../platform/<name>/`). Using `WHERE id IN (...)` scopes results to rows written by the current invocation even when stale objects from a prior failed cleanup remain in the prefix. Sorting by the stable integer `id` column eliminates Athena's non-deterministic row ordering.

**Alternatives considered**:
- Partition by invocation UUID: rejected — adds partition management overhead, incompatible with the flat non-partitioned schema design decision.
- Rely on UUID object key prefix isolation: rejected — Athena reads all objects under the table's location, not just a sub-prefix.

---

### 15. Athena Workgroup Naming and Result Location Enforcement

**Decision**: Provision a dedicated `aws_athena_workgroup` named `edp-e2e-<env>`, with `result_configuration.output_location` set to `s3://chedaws-edp-landing-bucket-<env>/athena-query-results/e2e/` and `enforce_workgroup_configuration = true`.

**Rationale**: A dedicated workgroup isolates e2e query results from any future production Athena usage. Setting `enforce_workgroup_configuration = true` prevents callers from overriding the result location, ensuring results are always written to `athena-query-results/e2e/`.

**Alternatives considered**:
- Reuse the primary workgroup: rejected — commingles e2e results with production query results.
- Use a separate S3 bucket for results: rejected — the spec explicitly scopes Athena results to a prefix within the existing landing bucket.

---

### 16. Lambda Athena Query Polling

**Decision**: Use Athena's `StartQueryExecution` + polling loop (`GetQueryExecution` with 2-second sleep, up to 90 seconds total) with one retry on `FAILED` state before marking the table as failed.

**Rationale**: Athena is asynchronous; the Lambda must poll for completion. The 90-second poll window fits within the Lambda's timeout even when running three tables serially. One retry on `FAILED` handles transient failures without inflating complexity. `CANCELLED` state is treated as permanent failure (no retry).

**Alternatives considered**:
- AWS SDK `waiter`: not available for Athena query completion in boto3 — must implement manually.
- Step Functions: rejected — over-engineered for a single Lambda's internal polling loop.

---

### 17. Lambda Sizing per Environment

**Decision**:

| Environment | Memory (MB) | Timeout (s) | Schedule |
|---|---|---|---|
| dev | 256 | 120 | `cron(0 6 * * ? *)` |
| test | 256 | 120 | `cron(0 6 * * ? *)` |
| uat | 512 | 180 | `cron(0 6 * * ? *)` |
| prod | 512 | 300 | `cron(0 6 * * ? *)` |

**Rationale**: 256 MB is sufficient for Python + fastavro + boto3 in dev/test. 512 MB is used in uat/prod for faster execution. Timeout is padded in prod to absorb Athena cold-start variance. All environments run at 06:00 UTC to avoid interference during business hours.

---

### 18. Lambda Deployment Package Location

**Decision**: Store the Lambda ZIP in the platform S3 bucket (`chedaws-edp-platform-<env>-<account>-<region>`) under `e2e/s3-e2e-verifier/function.zip`, mirroring the Kafka canary pattern (`e2e/kafka/canary/function.zip`). Use `source_hash` derived from `md5(join("", [filemd5(handler.py), filemd5(requirements.txt)]))` to trigger updates when source changes.

---

### 19. IAM Role Naming

**Decision**: Follow the existing patterns:
- Lambda execution role: `chedaws-edp-s3-e2e-verifier-<env>` (matches the `chedaws-edp-<service>-<env>` infrastructure pattern)
- Namespace IAM role: `edp-<env>-s3-producer-platform` (provisioned by `s3_producers.tf` from the `s3/platform.yaml` YAML — follows `edp-<env>-s3-producer-<namespace>`)

**Rationale**: The Lambda execution role is a platform infrastructure role (not a self-service role), so it uses the `chedaws-edp-` prefix. The namespace role's name is dictated by the existing `s3_producers.tf` naming pattern.

---

### 20. CloudWatch Alarm and Metric Design

**Decision**: Three alarms per environment:
1. `chedaws-edp-s3-e2e-validation-failure-<env>` — on custom metric `S3E2ETestSuccess`, threshold < 1, `treat_missing_data = "breaching"`, period = 86400 s, evaluation_periods = 1.
2. `chedaws-edp-s3-e2e-cleanup-failure-<env>` — on custom metric `S3E2ECleanupSuccess`, threshold < 1, `treat_missing_data = "notBreaching"`, period = 86400 s, evaluation_periods = 1.
3. `chedaws-edp-s3-e2e-lambda-errors-<env>` — on `AWS/Lambda / Errors` for the verifier function, threshold ≥ 1, `treat_missing_data = "notBreaching"`, period = 86400 s, evaluation_periods = 1.

**Rationale**: The validation alarm uses `treat_missing_data = "breaching"` so that a Lambda that never runs (e.g., EventBridge misconfiguration) is treated as a failure. The cleanup alarm uses `notBreaching` because absence of a cleanup-failure metric means cleanup succeeded. All three alarms route to `aws_sns_topic.alerts.arn`.

---

### 21. Log Group Naming and Retention

**Decision**: Log group `/chedaws-edp/s3-e2e-verifier/<env>`, encrypted with `module.kms["cloudwatch_logs"].key_arn`. Retention: `local.s3_e2e_log_retention = local.is_prod_like ? 90 : 30` (30 days dev/test, 90 days uat/prod).

**Rationale**: The spec requires 30-day dev/test and 90-day uat/prod retention — distinct from the 7/30-day pattern used for other canaries. A dedicated local avoids misapplying the wrong retention value.

---

### 22. Landing Bucket Lifecycle Rule for Athena Results

**Decision**: Add a new lifecycle rule to `module.landing_s3` with `id = "athena-query-results-e2e-expiry"` targeting the `athena-query-results/e2e/` prefix, expiring objects after 7 days.

**Rationale**: Athena result files are diagnostic artifacts with no retrieval value after 7 days. The `terraform-aws-modules/s3-bucket` module accepts `lifecycle_rule` as a list, so appending a new entry is non-destructive.

---

### 23. `s3/platform.yaml` YAML Structure

**Decision**: Declare all four environments in `spec.producer.environments`, listing the Lambda execution role ARN per environment as the trusted principal. Account IDs: dev/test = `381491832813`, uat = `339712719726`, prod = `637423180765`.

**Rationale**: The `s3_aws_domains_this_env` local filters by `local.environment`, so listing all four environments is correct — only the current workspace's entry is activated.

---

### 24. Table Schema Columns

**Decision**: All three tables share the same four-column schema:

| Column | Type | Rationale |
|---|---|---|
| `id` | `int` | Stable sort/filter key |
| `name` | `string` | String type coverage |
| `value` | `double` | Floating-point type coverage |
| `active` | `boolean` | Boolean type coverage |

**Rationale**: Using the same schema across all three tables means the Lambda can reuse a single validation function for all formats. The four types cover the most common Glue-native scalar types relevant to SerDe mapping differences.

**Alternatives considered**:
- Different schemas per table: rejected — adds complexity without coverage benefit.
- Including `timestamp` or `date`: deferred to v2 — these types have known SerDe quirks with Avro.

---

### 25. Module vs Inline Decision

**Decision**: All resources for the S3 E2E verifier are defined inline in `terraform/s3_e2e_verifier.tf`. No new module is created.

**Rationale**: The verifier Lambda is a single-use infrastructure component. Constitution §VI prohibits single-use modules. The Kafka canary (`kafka_e2e_canary.tf`) follows the same inline pattern.
