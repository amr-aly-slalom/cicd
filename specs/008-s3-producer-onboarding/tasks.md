---

description: "Task list for S3 Data Producer Self-Onboarding and E2E Verification"
---

# Tasks: S3 Data Producer Self-Onboarding and E2E Verification

**Input**: Design documents from `specs/008-s3-producer-onboarding/`

**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, quickstart.md ✓

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Exact file paths are included in all descriptions

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Create the registration directory structure, copy the JSON Schema contracts, and extend the KMS key map — the prerequisites every subsequent phase depends on.

- [X] T001 Create `s3/` top-level directory with `s3/.gitkeep` (namespace YAMLs live directly here; table YAMLs live in `s3/<namespace>/`)
- [X] T002 [P] Copy `specs/008-s3-producer-onboarding/contracts/namespace-schema.json` → `s3/schema/namespace-schema.json`
- [X] T003 [P] Copy `specs/008-s3-producer-onboarding/contracts/table-schema.json` → `s3/schema/table-schema.json`
- [X] T004 Add `glue` entry to `local.kms_services` map in `terraform/locals.tf` (`service_principals = ["glue.amazonaws.com"]`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The CI validation script and Terraform local variable maps must exist before any IAM or Glue resources can be provisioned. All user story phases depend on these.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete

- [X] T005 Write `.github/scripts/validate-s3-registrations.py` — namespace YAML validation: load all `s3/*.yaml`, validate each against `s3/schema/namespace-schema.json` using `jsonschema`, assert `path.stem == metadata.namespace`, assert no two namespace YAMLs share the same `namespace` (fail with `DuplicateNamespaceError`)
- [X] T006 Add table YAML validation to `.github/scripts/validate-s3-registrations.py`: load all `s3/*/*.yaml`, validate each against `s3/schema/table-schema.json` using `jsonschema`, assert `path.parent.name == metadata.namespace` and `path.stem == metadata.name`, assert no two active (non-decommissioned) table YAMLs share `(namespace, name)` (fail with `DuplicateRegistrationError`)
- [X] T007 Add decommission guard to `.github/scripts/validate-s3-registrations.py`: on PR diff context, if any table YAML is deleted assert `spec.decommission: true` was present in `git show HEAD:<path>` (fail with `DecommissionGuardError`); namespace YAML deletion requires no guard
- [X] T008 Add S3 Producer Locals block to `terraform/locals.tf` — new `# ─── S3 Producer Locals` section after existing MSK locals, containing: `_s3_domain_files` (fileset `s3/*.yaml`), `s3_domains_this_env`, `s3_aws_domains_this_env`, `s3_onprem_domains_this_env`, `_s3_table_files` (fileset `s3/*/*.yaml`), `s3_tables_active`, `s3_tables_this_env`, `s3_tables_with_schema_this_env`, `s3_table_aws_producers_this_env`, `s3_table_onprem_producers_this_env`, `_s3_glue_database_keys`, `_s3_domain_slug_list`, `_s3_domain_slug_unique`, `_s3_table_slug_list`, `_s3_table_slug_unique` as specified in plan.md Phase 3

**Checkpoint**: Foundation ready — user story implementation can now begin

---

## Phase 3: User Story 1 — Producer Team Registers a New S3 Dataset (Priority: P1) 🎯 MVP

**Goal**: Provision a namespace-scoped IAM role (`edp-<env>-s3-producer-<namespace>`) covering `<namespace>/*` from the namespace YAML, and an optional table-scoped role (`edp-<env>-s3-producer-<namespace>-<name>`) covering `<namespace>/<name>/*` when the table YAML declares `spec.producer`.

### Implementation for User Story 1

- [X] T009 [US1] Create `terraform/s3_producers.tf` with `terraform_data.s3_domain_unique_check` precondition: condition `length(local._s3_domain_slug_list) == length(local._s3_domain_slug_unique)`, error message listing duplicate namespace names; and `terraform_data.s3_table_unique_check` precondition: condition `length(local._s3_table_slug_list) == length(local._s3_table_slug_unique)`, error message listing duplicate `(namespace, name)` pairs
- [X] T010 [US1] Add `terraform_data.s3_domain_name_length_check` (`for_each = local.s3_domains_this_env`) to `terraform/s3_producers.tf`: condition `length("edp-${local.environment}-s3-producer-${each.value.metadata.namespace}") <= 64`
- [X] T011 [US1] Add `aws_iam_policy.s3_domain_producer` (`for_each = local.s3_domains_this_env`) to `terraform/s3_producers.tf`: name `edp-<env>-s3-producer-<namespace>`, statements for `s3:PutObject` + `s3:PutObjectTagging` scoped to `<bucket_arn>/<namespace>/*`, and `kms:GenerateDataKey` + `kms:Decrypt` on `module.kms["s3"].key_arn`
- [X] T012 [US1] Add `aws_iam_role.s3_domain_aws_producer` (`for_each = local.s3_aws_domains_this_env`) to `terraform/s3_producers.tf`: name `edp-<env>-s3-producer-<namespace>`, trust policy `sts:AssumeRole` from each declared IAM role ARN, description `S3 namespace producer role for <namespace> in <env>`
- [X] T013 [US1] Add `aws_iam_role_policy_attachment.s3_domain_aws_producer` to `terraform/s3_producers.tf` attaching `aws_iam_policy.s3_domain_producer` to `aws_iam_role.s3_domain_aws_producer`
- [X] T014 [US1] Add `aws_iam_role.s3_domain_onprem_producer` (`for_each = local.s3_onprem_domains_this_env`) to `terraform/s3_producers.tf`: trust principal `rolesanywhere.amazonaws.com` with `ForAnyValue:StringEquals` condition on CN values, description `S3 namespace producer role for <namespace> in <env> (on-premises)`
- [X] T015 [US1] Add `aws_iam_role_policy_attachment.s3_domain_onprem_producer` to `terraform/s3_producers.tf` attaching `aws_iam_policy.s3_domain_producer` to `aws_iam_role.s3_domain_onprem_producer`
- [X] T016 [US1] Add `terraform_data.s3_table_name_length_check` (`for_each = merge(local.s3_table_aws_producers_this_env, local.s3_table_onprem_producers_this_env)`) to `terraform/s3_producers.tf`: condition `length("edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}") <= 64`
- [X] T017 [US1] Add `aws_iam_policy.s3_table_producer` to `terraform/s3_producers.tf` — `for_each` over the merged key set of `s3_table_aws_producers_this_env` and `s3_table_onprem_producers_this_env` (deduplicated via `toset`); name `edp-<env>-s3-producer-<namespace>-<name>`; statements for `s3:PutObject` + `s3:PutObjectTagging` scoped to `<bucket_arn>/<namespace>/<name>/*`; `kms:GenerateDataKey` + `kms:Decrypt` on `module.kms["s3"].key_arn`
- [X] T018 [US1] Add `aws_iam_role.s3_table_aws_producer` (`for_each = local.s3_table_aws_producers_this_env`) to `terraform/s3_producers.tf`: name `edp-<env>-s3-producer-<namespace>-<name>`, trust policy `sts:AssumeRole` from declared ARNs, description `S3 table producer role for <namespace>/<name> in <env>`
- [X] T019 [US1] Add `aws_iam_role_policy_attachment.s3_table_aws_producer` to `terraform/s3_producers.tf` attaching `aws_iam_policy.s3_table_producer` to `aws_iam_role.s3_table_aws_producer`
- [X] T020 [US1] Add `aws_iam_role.s3_table_onprem_producer` (`for_each = local.s3_table_onprem_producers_this_env`) to `terraform/s3_producers.tf`: trust principal `rolesanywhere.amazonaws.com` with `ForAnyValue:StringEquals` condition on CN values, description `S3 table producer role for <namespace>/<name> in <env> (on-premises)`
- [X] T021 [US1] Add `aws_iam_role_policy_attachment.s3_table_onprem_producer` to `terraform/s3_producers.tf` attaching `aws_iam_policy.s3_table_producer` to `aws_iam_role.s3_table_onprem_producer`
- [X] T022 [US1] Update `aws_rolesanywhere_profile.onprem` `role_arns` concat in `terraform/iam.tf` to include `[for k, v in aws_iam_role.s3_domain_onprem_producer : v.arn]` and `[for k, v in aws_iam_role.s3_table_onprem_producer : v.arn]`
- [X] T023 [US1] Add `output.s3_producer_role_arns` to `terraform/s3_producers.tf`: merged map of all namespace and optional table S3 producer role ARNs for this environment
- [X] T024 [P] [US1] Create example namespace registration `s3/platform.yaml` (`namespace: platform`, cross-account IAM role ARN for dev, mirrors the `kafka/producers/platform/` canary pattern)
- [X] T025 [P] [US1] Create example table registration `s3/platform/e2e.yaml` (`namespace: platform`, `name: e2e`, `spec.format: csv`, no `spec.producer` block — validates namespace role suffices)
- [ ] T026 [US1] Run `terraform -chdir=terraform plan -var="env=dev"` and verify plan shows expected namespace IAM role and policy creates with no errors; verify no table-scoped role appears for `e2e` (no `spec.producer` in table YAML)

**Checkpoint**: US1 complete — namespace-level IAM registration pipeline functional and independently testable

---

## Phase 4: User Story 2 — Structured Dataset with Glue Catalog (Priority: P2)

**Goal**: For table YAMLs declaring `spec.schema.columns`, provision a Glue database (`edp_<env>_<namespace>`) and Glue table (`<name>`) with correct SerDe, columns, and partition keys so downstream consumers can query via Athena.

### Implementation for User Story 2

- [X] T027 [US2] Create `terraform/glue.tf` with `aws_glue_data_catalog_encryption_settings.edp_catalog`: `sse_aws_kms_key_id = module.kms["glue"].key_arn`, `connection_password_encryption.kms_key_id = module.kms["glue"].key_arn`
- [X] T028 [US2] Add `aws_glue_catalog_database.producer_domain` (`for_each = local._s3_glue_database_keys`) to `terraform/glue.tf`: name `edp_${each.key}`, description `EDP landing datasets for <namespace> namespace in <env>`
- [X] T029 [US2] Add SerDe locals lookup map to `terraform/glue.tf`: maps `csv` → LazySimpleSerDe with `TextInputFormat`/`HiveIgnoreKeyTextOutputFormat`, `json` → openx `JsonSerDe` with `TextInputFormat`/`HiveIgnoreKeyTextOutputFormat`, `avro` → `AvroSerDe` with `AvroInputFormat`/`AvroOutputFormat` per research.md §4
- [X] T030 [US2] Add `aws_glue_catalog_table.producer_dataset` (`for_each = local.s3_tables_with_schema_this_env`) to `terraform/glue.tf`: database `edp_${local.environment}_${replace(each.value.metadata.namespace, "-", "_")}`, table name `each.value.metadata.name`, type `EXTERNAL_TABLE`, location `s3://${module.landing_s3.s3_bucket_id}/${each.value.metadata.namespace}/${each.value.metadata.name}/`, SerDe from lookup map, columns from `each.value.spec.schema.columns`, partition keys from `try(each.value.spec.schema.partitionKeys, [])`, `depends_on = [aws_glue_catalog_database.producer_domain]`
- [ ] T031 [US2] Run `terraform -chdir=terraform plan -var="env=dev"` with a schema-bearing table YAML and verify plan shows Glue database and table creates alongside the namespace IAM role

**Checkpoint**: US2 complete — Glue catalog provisioned for structured datasets, Athena-queryable

---

## Phase 5: User Story 3 — Dataset Decommissioning (Priority: P3)

- [ ] T032 [US3] Verify decommission guard in `.github/scripts/validate-s3-registrations.py` (T007) correctly reads `git show HEAD:<path>` for table YAMLs — run the script against a fixture directory with a table YAML deleted without the flag and confirm non-zero exit; confirm namespace YAML deletion produces zero exit (no guard)
- [ ] T033 [US3] Verify Terraform locals in `terraform/locals.tf` correctly exclude `spec.decommission: true` table registrations from `s3_tables_active` — confirm via `terraform -chdir=terraform plan` that a decommissioned table YAML yields a destroy-only plan for that table's resources while the namespace IAM role shows no change
- [ ] T034 [US3] Verify `_s3_glue_database_keys` in `terraform/locals.tf` excludes decommissioned datasets — confirm via plan output that the Glue database appears in destroys only when no remaining active schema-bearing tables exist in that (env, namespace)

**Checkpoint**: US3 complete — two-phase decommission workflow enforced for table YAMLs

---

## Phase 6: User Story 4 — Platform Team Detects Configuration Drift (Priority: P4)

- [ ] T035 [P] [US4] Verify `terraform -chdir=terraform plan -var="env=dev"` produces a clean no-change plan after a full apply
- [ ] T036 [P] [US4] Run `auto/tflint` against `terraform/` to confirm no linting violations introduced by `s3_producers.tf` and `glue.tf`

**Checkpoint**: US4 complete — drift detection confirmed working for all S3 producer resources

---

## Phase 7: GitHub Actions CI/CD Workflow

- [X] T037 Create `.github/workflows/s3-producers.yaml` with trigger on `push` and `pull_request` for paths `s3/**` and `terraform/**`
- [X] T038 Add `validate` job to `.github/workflows/s3-producers.yaml`: `python .github/scripts/validate-s3-registrations.py`
- [X] T039 [P] Add `plan-dev` job (depends on `validate`) to `.github/workflows/s3-producers.yaml`: `terraform plan -var="env=dev"` and post plan diff as PR comment
- [X] T040 [P] Add `plan-test`, `plan-uat`, `plan-prod` jobs (depends on `validate`) to `.github/workflows/s3-producers.yaml`: same structure as `plan-dev`, different env var
- [X] T041 Add `apply-dev` job (on `push` to `main`, depends on `validate`) to `.github/workflows/s3-producers.yaml`: `terraform apply -var="env=dev" -auto-approve`
- [X] T042 Add `apply-uat` and `apply-prod` jobs to `.github/workflows/s3-producers.yaml` gated behind GitHub Environment approvals

---

## Phase 8: E2E Verifier — Setup

**Purpose**: Create Lambda source directory structure and prerequisite Terraform/YAML changes

- [X] T043 Create `lambda/s3-e2e-verifier/` directory structure and add `requirements.txt` with `fastavro==1.9.7` (boto3 provided by Lambda runtime)
- [X] T044 [P] Add `s3_e2e_log_retention = local.is_prod_like ? 90 : 30` to the `locals` block in `terraform/locals.tf`
- [X] T045 [P] Append `athena-query-results-e2e-expiry` lifecycle rule entry (`id="athena-query-results-e2e-expiry"`, `prefix="athena-query-results/e2e/"`, `expiration.days=7`, `enabled=true`) to the `lifecycle_rule` list in `module.landing_s3` in `terraform/s3.tf`
- [X] T046 [P] Update `s3/platform.yaml` Namespace to include all 4 environments with Lambda execution role ARNs (`arn:aws:iam::<account>:role/chedaws-edp-s3-e2e-verifier-<env>`) per data-model.md §1.1
- [X] T047 [P] Create `s3/platform/e2e_csv.yaml` as Table (`format: csv`, schema columns: `id int`, `name string`, `value double`, `active boolean`) per data-model.md §1.2
- [X] T048 [P] Create `s3/platform/e2e_json.yaml` as Table (`format: json`, same 4-column schema) per data-model.md §1.3
- [X] T049 [P] Create `s3/platform/e2e_avro.yaml` as Table (`format: avro`, same 4-column schema) per data-model.md §1.4

**Checkpoint**: Foundation ready — YAML registrations and Terraform prerequisite changes complete

---

## Phase 9: E2E Verifier — User Story 5 (Core E2E Validation Cycle, Priority: P1) 🎯

**Goal**: A scheduled Lambda runs daily, generates sample data, assumes the platform namespace IAM role, writes CSV/JSON/Avro to each table's S3 prefix, queries all three tables via Athena, validates returned rows match generated input, cleans up written objects, and raises alarms on any failure.

### Terraform Resources — `terraform/s3_e2e_verifier.tf`

- [X] T050 [P] [US5] Create `aws_iam_role.s3_e2e_verifier_lambda_execution` (trust: `lambda.amazonaws.com`, name: `chedaws-edp-s3-e2e-verifier-${local.environment}`) and `aws_iam_role_policy.s3_e2e_verifier_lambda_execution` (inline policy: `sts:AssumeRole` on namespace role, `athena:StartQueryExecution/GetQueryExecution/GetQueryResults/StopQueryExecution`, `glue:GetTable/GetDatabase`, `s3:GetObject/ListBucket/PutObject` on `athena-query-results/e2e/*`, `s3:DeleteObject` on `platform/*`, `kms:Decrypt/GenerateDataKey` on `alias/chedaws-edp-s3-${local.environment}`, `logs:CreateLogGroup/CreateLogStream/PutLogEvents` on log group ARN) in `terraform/s3_e2e_verifier.tf`
- [X] T051 [P] [US5] Create `aws_cloudwatch_log_group.s3_e2e_verifier` (name: `/chedaws-edp/s3-e2e-verifier/${local.environment}`, `kms_key_id`: `module.kms["cloudwatch_logs"].key_arn`, `retention_in_days`: `local.s3_e2e_log_retention`) in `terraform/s3_e2e_verifier.tf`
- [X] T052 [P] [US5] Create `aws_s3_object.s3_e2e_verifier_lambda` (bucket: `module.platform_s3`, key: `e2e/s3-e2e-verifier/function.zip`, source: `../lambda/s3-e2e-verifier/function.zip`, `server_side_encryption: aws:kms`, `kms_key_id: module.kms["s3"].key_arn`, `source_hash` from `md5(join("", [filemd5("../lambda/s3-e2e-verifier/handler.py"), filemd5("../lambda/s3-e2e-verifier/requirements.txt")]))`) in `terraform/s3_e2e_verifier.tf`
- [X] T053 [US5] Create `aws_lambda_function.s3_e2e_verifier` (function_name: `chedaws-edp-s3-e2e-verifier-${local.environment}`, runtime: `python3.14`, handler: `handler.lambda_handler`, s3_bucket/s3_key from `aws_s3_object.s3_e2e_verifier_lambda`, env vars per contracts/lambda-env-vars.md, memory/timeout sized per environment: 256MB/120s dev-test and 512MB/300s uat-prod, `reserved_concurrent_executions = 1`, `depends_on = [aws_cloudwatch_log_group.s3_e2e_verifier]`) in `terraform/s3_e2e_verifier.tf`
- [X] T054 [P] [US5] Create `aws_athena_workgroup.s3_e2e_verifier` (name: `edp-e2e-${local.environment}`, `result_configuration.output_location`: `s3://${local.landing_bucket}/athena-query-results/e2e/`, `enforce_workgroup_configuration = true`, `result_configuration.encryption_configuration.encryption_option = SSE_KMS`, `kms_key`: `module.kms["s3"].key_arn`) in `terraform/s3_e2e_verifier.tf`
- [X] T055 [P] [US5] Create `aws_cloudwatch_event_rule.s3_e2e_verifier_schedule` (name: `chedaws-edp-s3-e2e-verifier-schedule-${local.environment}`, `schedule_expression = "cron(0 6 * * ? *)"`, `state = "ENABLED"`), `aws_cloudwatch_event_target.s3_e2e_verifier` (targets the Lambda ARN), and `aws_lambda_permission.s3_e2e_verifier_eventbridge` (principal: `events.amazonaws.com`, action: `lambda:InvokeFunction`) in `terraform/s3_e2e_verifier.tf`
- [X] T056 [P] [US5] Create `aws_cloudwatch_metric_alarm.s3_e2e_validation_failure` (alarm_name: `chedaws-edp-s3-e2e-validation-failure-${local.environment}`, namespace: `ChedawsEDP/S3E2EVerifier`, metric_name: `S3E2ETestSuccess`, statistic: `Minimum`, comparison: `LessThanThreshold`, threshold: `1`, period: `86400`, evaluation_periods: `1`, treat_missing_data: `breaching`, dimensions: `{Environment=local.environment}`, `alarm_actions = [aws_sns_topic.alerts.arn]`) in `terraform/s3_e2e_verifier.tf`
- [X] T057 [P] [US5] Create `aws_cloudwatch_metric_alarm.s3_e2e_cleanup_failure` (metric_name: `S3E2ECleanupSuccess`, statistic: `Minimum`, threshold: `1`, `treat_missing_data = "notBreaching"`, SNS actions) and `aws_cloudwatch_metric_alarm.s3_e2e_lambda_errors` (namespace: `AWS/Lambda`, metric_name: `Errors`, dimensions: `{FunctionName=aws_lambda_function.s3_e2e_verifier.function_name}`, statistic: `Sum`, comparison: `GreaterThanOrEqualToThreshold`, threshold: `1`, `treat_missing_data = "notBreaching"`, SNS actions) per contracts/cloudwatch-metrics.md in `terraform/s3_e2e_verifier.tf`

### Lambda Source — `lambda/s3-e2e-verifier/handler.py`

- [X] T058 [P] [US5] Implement `SAMPLE_ROWS` constant (3 rows: id 1-3, name alpha/beta/gamma, value 1.1/2.2/3.3, active True/False/True), `GENERATED_IDS = [1, 2, 3]`, `generate_run_uuid()` returning `str(uuid4())`, and `assume_domain_role(sts_client)` calling `sts:AssumeRole` on `os.environ["NAMESPACE_ROLE_ARN"]` and returning temporary credentials
- [X] T059 [P] [US5] Implement `serialize_csv(rows)` (csv.DictWriter to BytesIO with header row, fieldnames=[id,name,value,active]), `serialize_json(rows)` (json.dumps per row NDJSON to BytesIO), and `serialize_avro(rows)` (fastavro.writer to BytesIO using inlined E2ERecord Avro schema: type=record, fields=[id int, name string, value double, active boolean])
- [X] T060 [US5] Implement `write_table(table_name, rows, run_uuid, s3_client)` dispatching to format serialiser by table name, uploading to `platform/<table_name>/<run_uuid>/data.<ext>` with `ServerSideEncryption="aws:kms"` and KMS key ARN from env, returning the S3 key written
- [X] T061 [US5] Implement `athena_query_poll(query_execution_id, athena_client, timeout_seconds)` (polling GetQueryExecution every 2s until SUCCEEDED/FAILED/CANCELLED or timeout, one retry on FAILED state, raises on CANCELLED or second FAILED) and `query_table(table_name, athena_client)` (StartQueryExecution with `SELECT * FROM ${GLUE_DATABASE}.${table_name} WHERE id IN (1,2,3) ORDER BY id` in workgroup `ATHENA_WORKGROUP`, returns result rows as list of dicts)
- [X] T062 [US5] Implement `validate_results(generated_rows, athena_rows)` (sort both lists by `id` ascending, compare column names and values exactly, return `(passed: bool, detail: str)`) and `cleanup_table(table_name, run_uuid, s3_client)` (DeleteObject for `platform/<table_name>/<run_uuid>/data.<ext>` using Lambda execution role credentials, return `(success: bool, error: str|None)`)
- [X] T063 [US5] Implement `publish_metrics(test_success: bool, cleanup_success: bool, cw_client)` calling `cloudwatch:PutMetricData` for `S3E2ETestSuccess` (1 or 0) and `S3E2ECleanupSuccess` (1 or 0) in namespace `ChedawsEDP/S3E2EVerifier` with dimension `Environment=${ENVIRONMENT}` per contracts/cloudwatch-metrics.md
- [X] T064 [US5] Implement `lambda_handler(event, context)` orchestrating: generate run_uuid → assume_domain_role → write all 3 tables → query+validate each table → cleanup all written tables (always, even on failure) → publish_metrics → emit structured JSON log `{run_id, status, tables:[{name,outcome,phase,detail}], cleanup:{outcome,errors}, duration_ms}` per contracts/cloudwatch-metrics.md structured log schema
- [X] T065 [US5] Build `lambda/s3-e2e-verifier/function.zip` (`pip install -r requirements.txt -t package/ && cd package && zip -r ../function.zip . && cd .. && zip function.zip handler.py`)

**Checkpoint**: US5 complete — Lambda deployed and validated; `terraform apply` succeeds; Lambda can be invoked manually and completes the full generate→write→query→validate→cleanup cycle

---

## Phase 10: E2E Verifier — User Stories 6 & 7 (Format Isolation & Manual Querying)

- [ ] T066 [US6] Run quickstart.md E2E Scenario 3 (regression detection) to verify per-format SerDe isolation: temporarily set `s3/platform/e2e_avro.yaml` `spec.format: json`, run `terraform apply -var="env=dev"`, invoke Lambda manually, confirm `e2e_avro` FAIL and `e2e_csv`/`e2e_json` PASS in logs, then revert YAML and re-apply
- [ ] T067 [US7] Run quickstart.md E2E Scenario 2 (manual Athena query) and Scenario 5 (lifecycle rule verification) to confirm workgroup `edp-e2e-dev` enforces query results to `s3://chedaws-edp-landing-bucket-dev/athena-query-results/e2e/` and lifecycle rule `athena-query-results-e2e-expiry` is present with `Status: Enabled` and `Expiration.Days: 7`

**Checkpoint**: All user stories functionally complete and independently verified

---

## Phase 11: Polish & Cross-Cutting Concerns

- [ ] T068 [P] Run `auto/tflint` against `terraform/s3_e2e_verifier.tf`, `terraform/locals.tf`, and `terraform/s3.tf`; resolve all warnings before raising a PR
- [ ] T069 Run `terraform plan -var="env=dev"`, `terraform plan -var="env=test"`, `terraform plan -var="env=uat"`, `terraform plan -var="env=prod"` and verify expected resource additions per quickstart.md Terraform Plan Sanity Check
- [ ] T070 [P] Run quickstart.md E2E Scenario 1 (manual Lambda invocation) against dev environment and confirm `"status": "PASS"` with all three tables passing and `"cleanup": {"outcome": "SUCCESS"}` in decoded log output
- [ ] T071 [P] Run quickstart.md E2E Scenario 4 (CloudWatch alarms OK state) and Scenario 6 (zero residual S3 objects under `e2e/`) against dev environment post-invocation
- [X] T072 [P] Update root `README.md` to document the S3 E2E Verifier entry (component name, purpose, daily schedule, environments, relevant Terraform file)
- [ ] T073 [P] Verify quickstart.md Self-Onboarding Scenario 1 (namespace + table CSV no schema) end-to-end: validate locally, confirm plan shows namespace IAM role create, verify no Glue resources in plan
- [ ] T074 [P] Verify quickstart.md Self-Onboarding Scenario 5 (duplicate rejected): create two namespace YAMLs with same `namespace` locally, run `python .github/scripts/validate-s3-registrations.py`, confirm non-zero exit with `DuplicateNamespaceError`
- [ ] T075 [P] Verify quickstart.md Self-Onboarding Scenario 7 (optional table role): confirm table YAML with `spec.producer` provisions `edp-dev-s3-producer-<namespace>-<name>` in addition to namespace role

---

## Notes

- [P] tasks touch different files with no inter-task dependencies
- [Story] labels map tasks to user stories for traceability
- `function.zip` **must exist** before `terraform apply` — build it (T065) first
- All resources go in `terraform/s3_e2e_verifier.tf` — follow the Kafka canary pattern; do **not** scatter resources across `main.tf`
- No new Terraform module is created — all resources are inline per constitution §VI
- `terraform-legacy/` must never be modified
- All AWS resources are tagged via `default_tags` in the AWS provider (no `local.common_tags`)
- Account IDs: dev/test = `381491832813`, uat = `339712719726`, prod = `637423180765`
