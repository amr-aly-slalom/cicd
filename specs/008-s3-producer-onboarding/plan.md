# Implementation Plan: S3 Data Producer Self-Onboarding

**Branch**: `feat/s3-glue` | **Date**: 2026-07-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/008-s3-producer-onboarding/spec.md`

---

## Summary

A Git-based self-service platform for S3 data producers, modelled on the existing Kafka producer registration workflow. Producer teams declare their namespace in a namespace YAML at `s3/<namespace>.yaml` (producer identity), and individual datasets in table YAMLs at `s3/<namespace>/<name>.yaml` (format, schema, optional table-level identity). CI validates the YAMLs against separate JSON Schemas and checks path/duplicate constraints, then Terraform provisions a namespace-scoped IAM role per (namespace, env) covering `<namespace>/*`. For structured datasets, an optional `spec.schema` block in the table YAML triggers Glue database and table provisioning. An optional `spec.producer` block in the table YAML provisions an additional narrower table-scoped role. Decommissioning is a two-phase process guarded by CI (table YAMLs only; namespace YAMLs have no guard). Data consumer access is explicitly deferred to a future Lake Formation feature.

---

## Technical Context

**Language/Version**: HCL (Terraform ≥ 1.0), Python 3.x (CI validation script)

**Primary Dependencies**:
- Terraform AWS provider (`hashicorp/aws`) — `aws_iam_role`, `aws_iam_policy`, `aws_glue_catalog_database`, `aws_glue_catalog_table`, `aws_glue_data_catalog_encryption_settings`
- `terraform-aws-modules/s3-bucket/aws` v5.14.1 — existing `module.landing_s3`, not modified by this feature
- Existing `module.kms` — new `glue` entry added to `local.kms_services`
- `jsonschema` Python package — CI validation script

**Storage**: `module.landing_s3` (existing S3 bucket); AWS Glue Data Catalog (new)

**Testing**: `terraform plan` per environment; `validate-s3-registrations.py` CI script; manual Athena queries for Glue table validation (see [quickstart.md](quickstart.md))

**Target Platform**: AWS (`ap-southeast-2`); four Terraform workspaces: `dev`, `test`, `uat`, `prod`

**Project Type**: Infrastructure-as-Code (Terraform) + Git-based self-service registration

**Performance Goals**: CI pipeline (validate → plan → apply dev) completes within 15 minutes of PR merge

**Constraints**: Namespace IAM role names ≤ 64 characters (`edp-<env>-s3-producer-<namespace>`); table IAM role names ≤ 64 characters (`edp-<env>-s3-producer-<namespace>-<name>`); `name` uses underscores only (`^[a-z][a-z0-9_]*$`); Glue column types limited to Glue-native scalars (v1); no ECS/Lambda/Glue Jobs introduced

**Scale/Scope**: ≥ 200 registered datasets per environment; Glue catalog: ≥ 1 database per (env, namespace) pair, ≥ 1 table per dataset with schema

---

## Constitution Check

*Verified against [Chedaws EDP Infrastructure Constitution](.specify/memory/constitution.md)*

- [x] **Security**: IAM policies are least-privilege — namespace role: `s3:PutObject` + `s3:PutObjectTagging` + `kms:GenerateDataKey` + `kms:Decrypt` scoped to `<namespace>/*` and the S3 KMS key ARN. Optional table role: same actions scoped to `<namespace>/<name>/*`. No broader bucket access. No hardcoded credentials. All IAM roles include mandatory descriptions. New Glue KMS CMK uses a dedicated `module.kms["glue"]` entry (customer-managed).
- [x] **Observability**: This feature introduces no compute or pipeline resources (no ECS tasks, Lambda, Glue jobs, MSK brokers). IAM roles and Glue catalog metadata resources require no CloudWatch alarms or log groups per the constitution. No observability gap.
- [x] **Durability**: `module.landing_s3` already has versioning and an `INTELLIGENT_TIERING` lifecycle rule (transition after 30 days, noncurrent version expiration after 30 days). Glue catalog is metadata; no lifecycle configuration required. Terraform state uses S3 + DynamoDB locking (existing backend, not modified).
- [x] **Fault-Tolerance**: No ECS, MWAA, or Glue jobs are introduced. Not applicable for this feature.
- [x] **Cost Optimisation**: IAM roles and Glue catalog entries have negligible cost. No instance sizing decisions. Tags applied via `default_tags` in AWS provider (no `local.common_tags`). Lifecycle for `module.landing_s3` already documented (INTELLIGENT_TIERING, rationale: unknown/mixed access patterns for landing data).
- [x] **DRY & Modularity**: All Terraform in `terraform/` (no `terraform-legacy/` modifications). New resources are inline in `terraform/s3_producers.tf` and `terraform/glue.tf` — no module created (first occurrence, single call site; a module is only warranted if a second pattern emerges). All resource local names are descriptive and unique within their type. KMS extension uses the existing `module.kms` for_each pattern.

**Complexity Tracking**: No violations requiring justification.

---

## Project Structure

### Documentation (this feature)

```text
specs/008-s3-producer-onboarding/
├── plan.md              ← this file
├── spec.md              ← feature specification
├── research.md          ← research decisions and resolved unknowns
├── data-model.md        ← entity model and Terraform variable relationships
├── quickstart.md        ← end-to-end validation scenarios
├── contracts/
│   ├── namespace-schema.json    ← JSON Schema for Namespace
│   └── table-schema.json   ← JSON Schema for Table
├── checklists/
│   └── requirements.md  ← specification quality checklist
└── tasks.md             ← implementation tasks (generated by /speckit-tasks)
```

### Source Code Layout

```text
s3/
├── <namespace>.yaml                      ← namespace YAML (kind: Namespace)
├── <namespace>/
│   └── <name>.yaml                   ← table YAML (kind: Table)
└── schema/
    ├── namespace-schema.json                 ← canonical namespace schema (copy of contracts/)
    └── table-schema.json                ← canonical dataset schema (copy of contracts/)

terraform/
├── s3_producers.tf                        ← IAM roles, policies, and precondition checks
├── glue.tf                                ← Glue databases, tables, catalog encryption
├── locals.tf                              ← extended with s3 namespace and table local maps
├── iam.tf                                 ← updated: add s3 on-prem namespace/table producers to Roles Anywhere profile
└── kms.tf                                 ← unchanged (module.kms for_each driven by locals.tf)

.github/
├── scripts/
│   └── validate-s3-registrations.py      ← CI validation script for s3/** changes
└── workflows/
    └── s3-producers.yaml                      ← CI/CD workflow for s3/** changes
```

**Structure Decision**: Single-project layout. All new files are either new Terraform root files (named by resource type per constitution §VI), a new `s3/` directory at the project root mirroring `kafka/`, or a new GitHub Actions workflow. No new modules — the pattern appears exactly once. No `producers/` subdirectory — namespace YAMLs reside directly under `s3/` and table YAMLs reside under `s3/<namespace>/`.

---

## Implementation Phases

### Phase 1 — KMS Extension

**Files**: `terraform/locals.tf`

Add `glue` entry to `local.kms_services`:

```hcl
glue = {
  service_principals = ["glue.amazonaws.com"]
}
```

`module.kms` is `for_each`-driven; adding the entry automatically creates `module.kms["glue"]` with alias `alias/chedaws-edp-glue-<env>`. No changes to `terraform/kms.tf` are required.

---

### Phase 2 — Registration Directory and Schemas

**Files**: `s3/.gitkeep`, `s3/schema/namespace-schema.json`, `s3/schema/table-schema.json`, `.github/scripts/validate-s3-registrations.py`

1. Create `s3/` directory with `.gitkeep` (the top-level `s3/` directory holds both namespace YAMLs and subdirectories)
2. Copy `specs/008-s3-producer-onboarding/contracts/namespace-schema.json` → `s3/schema/namespace-schema.json`
3. Copy `specs/008-s3-producer-onboarding/contracts/table-schema.json` → `s3/schema/table-schema.json`
4. Write `.github/scripts/validate-s3-registrations.py` with these checks:
   - Parse all `*.yaml` directly under `s3/` → namespace registrations; validate each against `s3/schema/namespace-schema.json` using `jsonschema`
   - Assert `path.stem == metadata.name` for every namespace YAML
   - Assert no two namespace YAMLs share the same `name`
   - Parse all `*/*.yaml` under `s3/` → table registrations; validate each against `s3/schema/table-schema.json` using `jsonschema`
   - Assert `path.parent.name == metadata.namespace` and `path.stem == metadata.name` for every table YAML
   - Assert no two active (non-decommissioned) table registrations share `(namespace, name)`
   - On git diff context (PR mode): if any **table** YAML is deleted, assert `spec.decommission: true` was in the file's last committed state (check via `git show HEAD:<path>`). Namespace YAML deletion has no decommission guard.

---

### Phase 3 — Terraform Locals

**Files**: `terraform/locals.tf`

Add the following local variable blocks (in a new `# ─── S3 Producer Locals` section, after the existing MSK locals):

```hcl
# Namespace registrations: s3/<namespace>.yaml
_s3_domain_files = {
  for f in fileset("${path.root}/../s3", "*.yaml") :
  trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../s3/${f}"))
}

s3_domains_this_env = {
  for k, v in local._s3_domain_files :
  k => v
  if contains(keys(v.spec.producer.environments), local.environment)
}

s3_aws_domains_this_env = {
  for k, v in local.s3_domains_this_env :
  k => v.spec.producer.environments[local.environment].iamRoles
  if can(v.spec.producer.environments[local.environment].iamRoles)
}

s3_onprem_domains_this_env = {
  for k, v in local.s3_domains_this_env :
  k => { certificate_subjects = v.spec.producer.environments[local.environment].certificateSubject }
  if can(v.spec.producer.environments[local.environment].certificateSubject)
}

# Table registrations: s3/<namespace>/<name>.yaml
_s3_table_files = {
  for f in fileset("${path.root}/../s3", "*/*.yaml") :
  trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../s3/${f}"))
}

s3_tables_active = {
  for k, v in local._s3_table_files :
  k => v
  if !try(v.spec.decommission, false)
}

# Tables whose namespace is registered for this environment (used for Glue)
s3_tables_this_env = {
  for k, v in local.s3_tables_active :
  k => v
  if contains(keys(local.s3_domains_this_env), v.metadata.namespace)
}

s3_tables_with_schema_this_env = {
  for k, v in local.s3_tables_this_env :
  k => v
  if can(v.spec.schema.columns)
}

# Optional table-level roles (table YAMLs declaring spec.producer)
s3_table_aws_producers_this_env = {
  for k, v in local.s3_tables_active :
  k => v.spec.producer.environments[local.environment].iamRoles
  if can(v.spec.producer.environments[local.environment].iamRoles)
}

s3_table_onprem_producers_this_env = {
  for k, v in local.s3_tables_active :
  k => { certificate_subjects = v.spec.producer.environments[local.environment].certificateSubject }
  if can(v.spec.producer.environments[local.environment].certificateSubject)
}

# Distinct (env, namespace) keys for Glue database provisioning.
_s3_glue_database_keys = toset([
  for k, v in local.s3_tables_with_schema_this_env :
  "${local.environment}_${replace(v.metadata.namespace, "-", "_")}"
])

_s3_domain_slug_list   = [for k, v in local.s3_domains_this_env : v.metadata.namespace]
_s3_domain_slug_unique = distinct(local._s3_domain_slug_list)
_s3_table_slug_list    = [for k, v in local.s3_tables_active : "${v.metadata.namespace}-${v.metadata.name}"]
_s3_table_slug_unique  = distinct(local._s3_table_slug_list)
```

---

### Phase 4 — S3 Producer Terraform Resources

**File**: `terraform/s3_producers.tf`

New file containing:

1. **Precondition — domain unique check** (`terraform_data.s3_domain_unique_check`)
   - Condition: `length(local._s3_domain_slug_list) == length(local._s3_domain_slug_unique)`

2. **Precondition — table unique check** (`terraform_data.s3_table_unique_check`)
   - Condition: `length(local._s3_table_slug_list) == length(local._s3_table_slug_unique)`

3. **Precondition — domain name length check** (`terraform_data.s3_domain_name_length_check`, `for_each = local.s3_domains_this_env`)
   - Condition: `length("edp-${local.environment}-s3-producer-${each.value.metadata.namespace}") <= 64`

4. **Precondition — table role name length check** (`terraform_data.s3_table_name_length_check`, `for_each = merge(local.s3_table_aws_producers_this_env, local.s3_table_onprem_producers_this_env)`)
   - Condition: `length("edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}") <= 64`
   - Covers both AWS and on-premises table roles

5. **Domain IAM Policy** (`aws_iam_policy.s3_domain_producer`, `for_each = local.s3_domains_this_env`)
   - Name: `edp-<env>-s3-producer-<namespace>`
   - Statements: `s3:PutObject` + `s3:PutObjectTagging` on `<bucket_arn>/<namespace>/*`; `kms:GenerateDataKey` + `kms:Decrypt` on `module.kms["s3"].key_arn`

6. **AWS Domain Roles** (`aws_iam_role.s3_domain_aws_producer`, `for_each = local.s3_aws_domains_this_env`)
   - Name: `edp-<env>-s3-producer-<namespace>`
   - Trust policy: `sts:AssumeRole` from each declared IAM role ARN
   - Description: `S3 namespace producer role for <namespace> in <env>`

7. **AWS Domain Role Attachment** (`aws_iam_role_policy_attachment.s3_domain_aws_producer`)

8. **On-Premises Domain Roles** (`aws_iam_role.s3_domain_onprem_producer`, `for_each = local.s3_onprem_domains_this_env`)
   - Name: `edp-<env>-s3-producer-<namespace>`
   - Trust policy: `rolesanywhere.amazonaws.com` with `ForAnyValue:StringEquals` on CN values
   - Description: `S3 namespace producer role for <namespace> in <env> (on-premises)`

9. **On-Premises Domain Role Attachment** (`aws_iam_role_policy_attachment.s3_domain_onprem_producer`)

10. **Optional Table IAM Policy** (`aws_iam_policy.s3_table_producer`, `for_each = local.s3_table_aws_producers_this_env` ∪ `local.s3_table_onprem_producers_this_env` deduplicated by key)
    - Name: `edp-<env>-s3-producer-<namespace>-<name>`
    - Statements: `s3:PutObject` + `s3:PutObjectTagging` on `<bucket_arn>/<namespace>/<name>/*`; `kms:GenerateDataKey` + `kms:Decrypt` on `module.kms["s3"].key_arn`

11. **Optional AWS Table Roles** (`aws_iam_role.s3_table_aws_producer`, `for_each = local.s3_table_aws_producers_this_env`)
    - Name: `edp-<env>-s3-producer-<namespace>-<name>`
    - Trust policy: `sts:AssumeRole` from declared role ARNs
    - Description: `S3 table producer role for <namespace>/<name> in <env>`

12. **Optional AWS Table Role Attachment** (`aws_iam_role_policy_attachment.s3_table_aws_producer`)

13. **Optional On-Premises Table Roles** (`aws_iam_role.s3_table_onprem_producer`, `for_each = local.s3_table_onprem_producers_this_env`)
    - Trust policy: `rolesanywhere.amazonaws.com` with CN condition
    - Description: `S3 table producer role for <namespace>/<name> in <env> (on-premises)`

14. **Optional On-Premises Table Role Attachment** (`aws_iam_role_policy_attachment.s3_table_onprem_producer`)

15. **Output** (`output.s3_producer_role_arns`) — merged map of all namespace and optional table S3 producer role ARNs for this environment

---

### Phase 5 — Glue Terraform Resources

**File**: `terraform/glue.tf`

New file containing:

1. **Glue Catalog Encryption** (`aws_glue_data_catalog_encryption_settings.edp_catalog`)
   - `sse_aws_kms_key_id = module.kms["glue"].key_arn`
   - `connection_password_encryption.kms_key_id = module.kms["glue"].key_arn`

2. **Glue Databases** (`aws_glue_catalog_database.producer_domain`, `for_each = local._s3_glue_database_keys`)
   - `for_each` key: `"${env}_${replace(namespace, "-", "_")}"` (e.g., `"dev_finance"`, `"dev_risk_analytics"`)
   - Name: `edp_${each.key}` → e.g., `edp_dev_finance`, `edp_dev_risk_analytics`
   - Description: `EDP landing datasets for <namespace> namespace in <env>`

3. **Glue Tables** (`aws_glue_catalog_table.producer_dataset`, `for_each = local.s3_tables_with_schema_this_env`)
   - Table name: `each.value.metadata.name`
   - Database: `edp_${local.environment}_${replace(each.value.metadata.namespace, "-", "_")}`
   - Table type: `EXTERNAL_TABLE`
   - Location: `s3://${module.landing_s3.s3_bucket_id}/${each.value.metadata.namespace}/${each.value.metadata.name}/`
   - SerDe, InputFormat, OutputFormat: derived from `each.value.spec.format` via a `local` lookup map
   - Columns: derived from `each.value.spec.schema.columns`
   - Partition keys: derived from `try(each.value.spec.schema.partitionKeys, [])`
   - `depends_on = [aws_glue_catalog_database.producer_domain]`

---

### Phase 6 — IAM Roles Anywhere Profile Update

**File**: `terraform/iam.tf`

Update `aws_rolesanywhere_profile.onprem` resource — add S3 on-premises namespace and table producer roles to the `role_arns` concat:

```hcl
resource "aws_rolesanywhere_profile" "onprem" {
  ...
  role_arns = concat(
    [for k, v in aws_iam_role.kafka_onprem_producer : v.arn],
    [for k, v in aws_iam_role.kafka_onprem_consumer : v.arn],
    [for k, v in aws_iam_role.kafka_onprem_connect : v.arn],
    [for k, v in aws_iam_role.kafka_consumer_connect_onprem : v.arn],
    [for k, v in aws_iam_role.s3_domain_onprem_producer : v.arn],   # ← new
    [for k, v in aws_iam_role.s3_table_onprem_producer : v.arn],    # ← new (optional table roles)
  )
}
```

---

### Phase 7 — GitHub Actions Workflow

**File**: `.github/workflows/s3-producers.yaml`

Trigger: `push` and `pull_request` on paths `s3/**` and `terraform/**`.

Jobs:
1. `validate` — run `python .github/scripts/validate-s3-registrations.py`
2. `plan-dev` (depends on `validate`) — `terraform plan -var="env=dev"`; post plan diff as PR comment
3. `plan-test`, `plan-uat`, `plan-prod` — same structure, different env
4. `apply-dev` (on `push` to `main`, depends on `validate`) — `terraform apply -var="env=dev" -auto-approve`
5. `apply-uat`, `apply-prod` — gated behind GitHub Environment approvals

---

### Phase 8 — Example Registration Files

**Files**: `s3/platform.yaml`, `s3/platform/e2e.yaml`

A namespace YAML for the `platform` namespace and a minimal table YAML for the `e2e` canary/smoke-test dataset, mirroring the `kafka/producers/platform/e2e.yaml` pattern.

---

## Key Design Decisions (from research.md)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Registration model | Namespace YAML at `s3/<namespace>.yaml` + table YAML at `s3/<namespace>/<name>.yaml` | Namespace producers need access to all their tables; namespace-level role avoids policy churn when new tables are added; no `producers/` subdirectory |
| Namespace IAM role scope | `<namespace>/*` (entire namespace prefix) | Covers all current and future tables without re-apply; Lake Formation will handle consumer permissions |
| Optional table role | Additive — both namespace and table roles provisioned when table YAML declares `spec.producer` | Narrower scope for workloads that should not access other tables in the namespace |
| Namespace YAML decommission | No guard — immediate destroy on deletion | Namespace role can be removed independently of tables; tables and Glue resources unaffected |
| `name` pattern | `^[a-z][a-z0-9_]*$` (underscores only) | Valid as Glue table name, S3 prefix, and IAM role segment with no normalisation; avoids silent transforms |
| Glue database naming | `edp_<env>_<namespace>` | Env prefix prevents name collisions between dev and test, which share account `381491832813` |
| Glue KMS key | New `module.kms["glue"]` | Cannot reuse S3 key; different service principal; per-service key isolation |
| S3 producer policy KMS actions | Include `kms:GenerateDataKey` + `kms:Decrypt` | Bucket policy requires KMS; without these the PutObject call fails at KMS layer |
| Glue catalog encryption | `aws_glue_data_catalog_encryption_settings` (account-level singleton) | AWS Glue encryption is account/region-scoped, not per-database |
| Glue SerDe | Hive SerDes for CSV/Avro, openx JsonSerDe for JSON | Athena compatibility; openx SerDe tolerates missing fields better than Hive JSON SerDe |
| Locals structure | Namespace and table locals separated by fileset pattern | Explicit separation of namespace vs. table resource creation |
| IAM role naming | Namespace: `edp-<env>-s3-producer-<namespace>`; Table: `edp-<env>-s3-producer-<namespace>-<name>` | Env as second segment matches existing Kafka role convention |
| Roles Anywhere update | Additive concat to existing profile | Single profile covers all on-prem workloads; minimal change |
| Module creation | None (inline resources only) | First occurrence; single call site; constitution prohibits single-use modules |
| Resource local names | Descriptive (e.g., `s3_domain_producer`, `s3_domain_aws_producer`, `producer_domain`) | Constitution §VI: no generic names when multiple resources of same type exist |

---

## Rollout Notes

- Phase 1 (KMS) must be applied first; `module.kms["glue"]` must exist before `glue.tf` references it.
- `aws_glue_data_catalog_encryption_settings` is an account-level singleton. If any target account already has Glue catalog encryption configured (check via `aws glue get-data-catalog-encryption-settings`), import it before applying: `terraform import aws_glue_data_catalog_encryption_settings.edp_catalog <account-id>`.
- Phase 5 (Glue) depends on Phase 1 (KMS) and Phase 3 (Locals).
- Phase 4 (S3 Producers) depends on Phase 3 (Locals) and Phase 2 (registration directories and schemas must exist for `fileset`).
- Phase 6 (Roles Anywhere) depends on Phase 4 (`aws_iam_role.s3_domain_onprem_producer` and `aws_iam_role.s3_table_onprem_producer` must be declared first).
- Phases 1–6 should be in a single Terraform PR to avoid intermediate states where the KMS key exists but the policy referencing it does not.
- The `s3/` directory with `.gitkeep` must exist before the first `terraform plan` run, because `fileset` on a non-existent directory produces a Terraform error.

---

## E2E Verifier — Implementation Plan

The following phases cover the daily-scheduled Lambda verifier that validates the provisioned infrastructure end-to-end. These phases are built on top of the self-onboarding infrastructure above and deploy together in the same `terraform apply`.

**Summary**: Provision a daily-scheduled Lambda verifier (`chedaws-edp-s3-e2e-verifier-<env>`) that validates the S3 producer self-onboarding infrastructure end-to-end. On each run, the Lambda generates three rows of sample data, assumes the `platform` namespace IAM role to write format-correct files (CSV, JSON, Avro) to the landing bucket, queries each Glue table through a dedicated Athena workgroup, compares returned rows against generated input (sorted by `id`), cleans up all written S3 objects, and publishes pass/fail metrics to CloudWatch. Three alarms per environment route to the existing EDP SNS topic.

**Technical Context**:
- Language/Version: Python 3.12 (Lambda runtime)
- Primary Dependencies: `boto3` (Lambda runtime), `fastavro` (bundled in ZIP for Avro serialisation)
- Storage: S3 (landing bucket `chedaws-edp-landing-bucket-<env>`), Athena query results prefix `athena-query-results/e2e/`
- Target Platform: AWS Lambda, ap-southeast-2, all four environments (dev, test, uat, prod)
- Performance Goals: Full generate → write → query → validate → cleanup cycle completes within 5 minutes of invocation
- Constraints: Lambda timeout 120 s (dev/test) / 300 s (uat/prod); Athena query poll timeout 90 s per table; one retry on transient Athena failures

### Phase A — YAML Registrations (drives Glue/IAM provisioning)

**Files**: `s3/platform.yaml`, `s3/platform/e2e_csv.yaml`, `s3/platform/e2e_json.yaml`, `s3/platform/e2e_avro.yaml`

These YAMLs are consumed by the existing `locals.tf` fileset logic and `s3_producers.tf` / `glue.tf` to provision:
- Glue database `edp_<env>_platform` per environment
- Glue tables `e2e_csv`, `e2e_json`, `e2e_avro` with 4-column schemas per environment
- Namespace IAM role `edp-<env>-s3-producer-platform` trusted by the Lambda execution role ARN

See [data-model.md §1](data-model.md#1-registration-yamls) for full YAML content.

**Key constraint**: The Lambda execution role ARN (`chedaws-edp-s3-e2e-verifier-<env>`) must exist before the namespace IAM role trust policy is meaningful. Both are provisioned in the same `terraform apply`; Terraform handles the dependency implicitly since the YAML hardcodes the ARN pattern.

---

### Phase B — Terraform Infrastructure (`terraform/s3_e2e_verifier.tf`)

**New file** with the following resource blocks (in order):

1. **`aws_iam_role.s3_e2e_verifier_lambda_execution`** — Lambda execution role, trust: `lambda.amazonaws.com`
2. **`aws_iam_role_policy.s3_e2e_verifier_lambda_execution`** — Inline policy (see [data-model.md §2.1](data-model.md#21-iam--lambda-execution-role))
3. **`aws_cloudwatch_log_group.s3_e2e_verifier`** — `/chedaws-edp/s3-e2e-verifier/<env>`, KMS-encrypted, retention from `local.s3_e2e_log_retention`
4. **`aws_s3_object.s3_e2e_verifier_lambda`** — Lambda ZIP in platform bucket
5. **`aws_lambda_function.s3_e2e_verifier`** — Python 3.12, env-sized memory/timeout, env vars (see [contracts/lambda-env-vars.md](contracts/lambda-env-vars.md)), logging to log group, `reserved_concurrent_executions = 1`, `depends_on = [aws_cloudwatch_log_group.s3_e2e_verifier]`
6. ~~`aws_athena_workgroup.s3_e2e_verifier`~~ — E2E verifier reuses `aws_athena_workgroup.s3_namespace_producer["platform"]` (`edp-<env>-platform`) provisioned in `s3_producers.tf`; no separate workgroup
7. **`aws_cloudwatch_event_rule.s3_e2e_verifier_schedule`** — daily `cron(0 6 * * ? *)`
8. **`aws_cloudwatch_event_target.s3_e2e_verifier`** — targets `aws_lambda_function.s3_e2e_verifier`
9. **`aws_lambda_permission.s3_e2e_verifier_eventbridge`** — allows EventBridge to invoke the Lambda
10. **`aws_cloudwatch_metric_alarm.s3_e2e_validation_failure`** — see [contracts/cloudwatch-metrics.md](contracts/cloudwatch-metrics.md)
11. **`aws_cloudwatch_metric_alarm.s3_e2e_cleanup_failure`**
12. **`aws_cloudwatch_metric_alarm.s3_e2e_lambda_errors`**

---

### Phase C — `locals.tf` Addition

Add `s3_e2e_log_retention = local.is_prod_like ? 30 : 7` to the `locals` block in `terraform/locals.tf`.

---

### Phase D — `s3.tf` Lifecycle Rule Addition

Append a new entry to the `lifecycle_rule` list in `module.landing_s3`:

```hcl
{
  id      = "athena-query-results-e2e-expiry"
  enabled = true
  prefix  = "athena-query-results/e2e/"

  expiration = {
    days = 7
  }
}
```

---

### Phase E — Lambda Source Code (`lambda/s3-e2e-verifier/`)

**`requirements.txt`**:
```
fastavro==1.9.7
```

**`handler.py`** implements the flow described in [data-model.md §3.1](data-model.md#31-lambda-execution-flow):
- Generate 3 deterministic sample rows
- Assume `DOMAIN_ROLE_ARN` via `sts:AssumeRole`
- For each table: serialise rows (CSV / NDJSON / Avro), upload to `platform/<table>/<uuid>/data.<ext>` using assumed credentials
- For each table: run `SELECT * FROM <GLUE_DATABASE>.<table> WHERE id IN (1,2,3) ORDER BY id` in workgroup `ATHENA_WORKGROUP`; poll up to `ATHENA_QUERY_TIMEOUT_SECONDS`; retry once on FAILED; compare column names and values
- Cleanup: `s3:DeleteObject` for each written key (using Lambda execution role, not namespace role)
- Emit `S3E2ETestSuccess` and `S3E2ECleanupSuccess` metrics
- Log structured JSON outcome (see [contracts/cloudwatch-metrics.md](contracts/cloudwatch-metrics.md#structured-log-schema))

---

### E2E Verifier Key Design Decisions

| Decision | Outcome | Reference |
|---|---|---|
| Avro library | `fastavro` bundled in ZIP | [research.md §13](research.md#13-avro-serialisation-at-lambda-runtime) |
| Athena isolation | `WHERE id IN (...)` filter | [research.md §14](research.md#14-athena-query-isolation-strategy) |
| Athena results | Dedicated workgroup `edp-e2e-<env>`, enforced prefix | [research.md §15](research.md#15-athena-workgroup-naming-and-result-location-enforcement) |
| Query polling | 90 s poll, 1 retry on FAILED | [research.md §16](research.md#16-lambda-athena-query-polling) |
| Lambda sizing | 256 MB / 120 s dev-test, 512 MB / 300 s uat-prod | [research.md §17](research.md#17-lambda-sizing-per-environment) |
| Deployment | Platform S3 bucket, `e2e/s3-e2e-verifier/function.zip` | [research.md §18](research.md#18-lambda-deployment-package-location) |
| IAM naming | `chedaws-edp-s3-e2e-verifier-<env>` (execution), `edp-<env>-s3-producer-platform` (namespace) | [research.md §19](research.md#19-iam-role-naming) |
| Alarms | 3 per environment, daily period, SNS routing | [research.md §20](research.md#20-cloudwatch-alarm-and-metric-design) |
| Log retention | 7 d dev/test, 30 d uat/prod | [research.md §21](research.md#21-log-group-naming-and-retention) |
| Lifecycle rule | 7-day expiry on `athena-query-results/e2e/` | [research.md §22](research.md#22-landing-bucket-lifecycle-rule-for-athena-results) |
| YAML structure | All 4 environments declared; per-env Lambda ARN as `iamRoles` | [research.md §23](research.md#23-s3platformyaml-yaml-structure) |
| Table schema | 4 columns (`id int`, `name string`, `value double`, `active boolean`), shared across formats | [research.md §24](research.md#24-table-schema-columns) |
| Module vs inline | Inline in `s3_e2e_verifier.tf` (single-use, no module) | [research.md §25](research.md#25-module-vs-inline-decision) |
