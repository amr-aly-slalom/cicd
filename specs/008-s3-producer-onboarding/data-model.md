# Data Model: S3 Data Producer Self-Onboarding

**Feature**: `specs/008-s3-producer-onboarding`
**Date**: 2026-07-30

---

## Entities

### 1. Namespace (YAML Document)

The declarative source-of-truth for an S3 data namespace and its producer identity. Stored at `s3/<namespace>.yaml`.

| Field | Type | Required | Constraint |
|-------|------|----------|------------|
| `apiVersion` | string | Yes | `const: "s3.chedaws.io/v1"` |
| `kind` | string | Yes | `const: "Namespace"` |
| `metadata.name` | string | Yes | `^[a-z][a-z0-9-]*$` (hyphens allowed); must match file stem |
| `metadata.owner` | string | Yes | Team slug, non-empty |
| `metadata.description` | string | No | Human-readable namespace description |
| `spec.producer.environments` | object | Yes | At least one environment key (`dev`/`test`/`uat`/`prod`) |
| `spec.producer.environments.<env>.iamRoles` | string[] | Conditional | ARNs `^arn:aws:iam::[0-9]{12}:role/.+$`; mutually exclusive with `certificateSubject` |
| `spec.producer.environments.<env>.certificateSubject` | string[] | Conditional | `^CN=.+$`; mutually exclusive with `iamRoles` |

**Invariants**:
- `metadata.name` is unique across all namespace registrations (no two `s3/<namespace>.yaml` files with the same name)
- `iamRoles` and `certificateSubject` are mutually exclusive per environment entry (`oneOf`)
- Deleting a namespace YAML destroys the namespace IAM role immediately; no decommission guard

---

### 2. Table (YAML Document)

The declarative source-of-truth for a single logical dataset within a namespace. Stored at `s3/<namespace>/<name>.yaml`.

| Field | Type | Required | Constraint |
|-------|------|----------|------------|
| `apiVersion` | string | Yes | `const: "s3.chedaws.io/v1"` |
| `kind` | string | Yes | `const: "Table"` |
| `metadata.namespace` | string | Yes | `^[a-z][a-z0-9-]*$`; must match parent directory name |
| `metadata.name` | string | Yes | `^[a-z][a-z0-9_]*$` (underscores only, no hyphens); must match file stem |
| `metadata.owner` | string | Yes | Team slug, non-empty |
| `metadata.description` | string | No | Human-readable dataset description |
| `spec.format` | string | Yes | Enum: `csv`, `json`, `avro` |
| `spec.producer` | object | No | Optional — when present, provisions an additional table-scoped IAM role |
| `spec.producer.environments` | object | Conditional | Required when `spec.producer` is present; at least one env key |
| `spec.producer.environments.<env>.iamRoles` | string[] | Conditional | ARNs; mutually exclusive with `certificateSubject` |
| `spec.producer.environments.<env>.certificateSubject` | string[] | Conditional | `^CN=.+$`; mutually exclusive with `iamRoles` |
| `spec.schema` | object | No | Required for Glue provisioning |
| `spec.schema.columns` | array | Conditional | Non-empty; required when `spec.schema` is present |
| `spec.schema.columns[].name` | string | Yes | `^[a-z][a-z0-9_]*$` (snake_case) |
| `spec.schema.columns[].type` | string | Yes | Enum: `string`, `int`, `bigint`, `double`, `boolean`, `timestamp`, `date` |
| `spec.schema.columns[].comment` | string | No | Column description |
| `spec.schema.partitionKeys` | string[] | No | Subset of column names |
| `spec.decommission` | boolean | No | Two-phase guard for table YAML deletion |

**Invariants**:
- `(metadata.namespace, metadata.name)` is unique across all active (non-decommissioned) table registrations
- `metadata.name` uses underscores only — no normalisation needed for Glue table names
- `spec.schema.partitionKeys` entries must all appear in `spec.schema.columns[].name`
- `spec.producer.environments.<env>` entries: `iamRoles` and `certificateSubject` are mutually exclusive (`oneOf`)
- If `spec.decommission: true`, table-level IAM role (if any) and Glue resources are destroyed; namespace IAM role is unaffected

---

### 3. NamespaceIAMRole (Derived Terraform Resource)

One `aws_iam_role` per (namespace, env) pair. Provisioned from the namespace YAML.

| Attribute | Value |
|-----------|-------|
| Role name | `edp-<env>-s3-producer-<namespace>` |
| Max name length | 64 characters (enforced by `terraform_data` precondition) |
| Trust principal (AWS) | Each ARN in `spec.producer.environments.<env>.iamRoles` |
| Trust principal (on-prem) | `rolesanywhere.amazonaws.com` with CN condition |
| Description | `S3 namespace producer role for <namespace> in <env>` |

---

### 4. NamespaceIAMPolicy (Derived Terraform Resource)

One `aws_iam_policy` per (namespace, env) pair. Attached to `NamespaceIAMRole`.

| Attribute | Value |
|-----------|-------|
| Policy name | `edp-<env>-s3-producer-<namespace>` |
| S3 actions allowed | `s3:PutObject`, `s3:PutObjectTagging` |
| S3 resource scope | `arn:aws:s3:::chedaws-edp-landing-bucket-<env>/<namespace>/*` |
| KMS actions allowed | `kms:GenerateDataKey`, `kms:Decrypt` |
| KMS resource scope | `module.kms["s3"].key_arn` (the landing bucket KMS key) |

---

### 5. TableIAMRole (Optional Derived Terraform Resource)

One `aws_iam_role` per (namespace, name, env) combination. Provisioned only when the table YAML declares `spec.producer`.

| Attribute | Value |
|-----------|-------|
| Role name | `edp-<env>-s3-producer-<namespace>-<name>` |
| Max name length | 64 characters (enforced by `terraform_data` precondition) |
| Trust principal (AWS) | Each ARN in `spec.producer.environments.<env>.iamRoles` |
| Trust principal (on-prem) | `rolesanywhere.amazonaws.com` with CN condition |
| Description | `S3 table producer role for <namespace>/<name> in <env>` |

---

### 6. TableIAMPolicy (Optional Derived Terraform Resource)

One `aws_iam_policy` per (namespace, name, env) combination. Attached to `TableIAMRole`.

| Attribute | Value |
|-----------|-------|
| Policy name | `edp-<env>-s3-producer-<namespace>-<name>` |
| S3 actions allowed | `s3:PutObject`, `s3:PutObjectTagging` |
| S3 resource scope | `arn:aws:s3:::chedaws-edp-landing-bucket-<env>/<namespace>/<name>/*` |
| KMS actions allowed | `kms:GenerateDataKey`, `kms:Decrypt` |
| KMS resource scope | `module.kms["s3"].key_arn` |

---

### 7. GlueDatabase (Derived Terraform Resource)

One `aws_glue_catalog_database` per distinct `(env, namespace)` pair across all active schema-bearing table registrations.

| Attribute | Value |
|-----------|-------|
| Database name | `edp_<env>_<namespace>` (hyphens in `namespace` normalised to underscores) |
| Description | `EDP landing datasets for <namespace> namespace in <env>` |
| Location URI | `s3://chedaws-edp-landing-bucket-<env>/<namespace>/` |
| `for_each` key | `"${env}_${replace(namespace, "-", "_")}"` |
| Lifecycle | Destroyed automatically when no active schema-bearing tables remain for the `(env, namespace)` pair |

---

### 8. GlueTable (Derived Terraform Resource)

One `aws_glue_catalog_table` per active table registration that declares `spec.schema.columns`.

| Attribute | Value |
|-----------|-------|
| Database | `edp_<env>_<namespace>` |
| Table name | `<name>` (underscores only — no normalisation needed) |
| Table type | `EXTERNAL_TABLE` |
| Location | `s3://chedaws-edp-landing-bucket-<env>/<namespace>/<name>/` |
| Columns | Derived from `spec.schema.columns[]` |
| Partition keys | Derived from `spec.schema.partitionKeys` (empty list if absent) |
| InputFormat | Format-dependent (see research.md §4) |
| OutputFormat | Format-dependent (see research.md §4) |
| SerializationLibrary | Format-dependent (see research.md §4) |

---

### 9. GlueCatalogEncryption (Singleton Terraform Resource)

One `aws_glue_data_catalog_encryption_settings` per AWS account/region.

| Attribute | Value |
|-----------|-------|
| Resource local name | `edp_catalog` |
| Encryption at rest mode | `SSE-KMS` |
| KMS key | `module.kms["glue"].key_arn` |
| Connection password encryption | Enabled (same key) |

---

## State Transitions

### Namespace Lifecycle

```
[PR opened with s3/<namespace>.yaml]
        │
        ▼
  CI validation (namespace schema + path + duplicate check)
        │ PASS
        ▼
  Terraform plan (NamespaceIAMRole + NamespaceIAMPolicy created)
        │
        ▼
  ACTIVE (namespace role exists; producers can write to <namespace>/*)
        │
        │ [Team deletes s3/<namespace>.yaml — no decommission guard]
        ▼
  Terraform plan (NamespaceIAMRole + NamespaceIAMPolicy destroyed)
        │
        ▼
  DELETED
```

### Table Lifecycle

```
[PR opened with s3/<namespace>/<name>.yaml]
        │
        ▼
  CI validation (dataset schema + path + duplicate check)
        │ PASS
        ▼
  Terraform plan
  (TableIAMRole + TableIAMPolicy created if spec.producer present;
   GlueDatabase created if first schema-bearing table in namespace;
   GlueTable created if spec.schema present)
        │
        ▼
  ACTIVE
        │
        │ [Team sets spec.decommission: true, PR merged]
        ▼
  Terraform plan
  (TableIAMRole + TableIAMPolicy destroyed if existed;
   GlueTable destroyed if existed;
   GlueDatabase destroyed if no remaining schema-bearing tables for (env, namespace);
   NamespaceIAMRole unaffected)
        │
        ▼
  DECOMMISSIONING
        │
        │ [Team deletes YAML file — CI verifies prior decommission]
        ▼
  DELETED
```

---

---

## 10. E2E Verifier — Registration YAMLs

### 10.1 Namespace Registration — `s3/platform.yaml`

```yaml
apiVersion: s3.chedaws.io/v1
kind: Namespace
metadata:
  name: platform
  owner: platform-team
  description: E2E canary namespace for S3 producer self-onboarding validation
spec:
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/chedaws-edp-s3-e2e-verifier-dev
      test:
        iamRoles:
          - arn:aws:iam::381491832813:role/chedaws-edp-s3-e2e-verifier-test
      uat:
        iamRoles:
          - arn:aws:iam::339712719726:role/chedaws-edp-s3-e2e-verifier-uat
      prod:
        iamRoles:
          - arn:aws:iam::637423180765:role/chedaws-edp-s3-e2e-verifier-prod
```

**What this feature provisions from this YAML** (per environment):
- Glue database: `edp_<env>_platform`
- Namespace IAM role: `edp-<env>-s3-producer-platform`
  - Trust: Lambda execution role `chedaws-edp-s3-e2e-verifier-<env>`
  - Permissions: `s3:PutObject`, `s3:PutObjectTagging` on `platform/*`; `kms:GenerateDataKey`, `kms:Decrypt` on `alias/chedaws-edp-s3-<env>`

### 10.2 `s3/platform/e2e_csv.yaml`

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: platform
  name: e2e_csv
  owner: platform-team
  description: E2E canary table for CSV format validation
spec:
  format: csv
  schema:
    columns:
      - name: id
        type: int
        comment: "Stable sort and filter key for E2E validation"
      - name: name
        type: string
      - name: value
        type: double
      - name: active
        type: boolean
```

Glue table `e2e_csv` — SerDe: `LazySimpleSerDe` (CSV), location: `s3://.../platform/e2e_csv/`.

### 10.3 `s3/platform/e2e_json.yaml`

Same 4-column schema, `format: json`. Glue table `e2e_json` — SerDe: `openx JsonSerDe`.

### 10.4 `s3/platform/e2e_avro.yaml`

Same 4-column schema, `format: avro`. Glue table `e2e_avro` — SerDe: `AvroSerDe`.

---

## 11. E2E Verifier — AWS Resources

### 11.1 IAM — Lambda Execution Role

| Attribute | Value |
|---|---|
| Resource type | `aws_iam_role` |
| Local name | `s3_e2e_verifier_lambda_execution` |
| Role name | `chedaws-edp-s3-e2e-verifier-<env>` |
| Trust principal | `lambda.amazonaws.com` |

**Inline policy permissions**:
- `sts:AssumeRole` on `arn:aws:iam::<account>:role/edp-<env>-s3-producer-platform`
- `cloudwatch:PutMetricData` on `*`
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` on `/chedaws-edp/s3-e2e-verifier/<env>`

All S3 writes, Athena queries, Glue reads, KMS operations, and S3 cleanup flow through the assumed `edp-<env>-s3-producer-platform` namespace role.

### 11.2 Lambda Function

| Attribute | Value |
|---|---|
| Resource type | `aws_lambda_function` |
| Local name | `s3_e2e_verifier` |
| Function name | `chedaws-edp-s3-e2e-verifier-<env>` |
| Runtime | `python3.14` |
| Handler | `handler.lambda_handler` |
| Memory (dev/test) | 256 MB |
| Memory (uat/prod) | 512 MB |
| Timeout (dev/test) | 120 s |
| Timeout (uat/prod) | 300 s |
| Reserved concurrency | 1 |
| Source | `platform_s3 / e2e/s3-e2e-verifier/function.zip` |
| Log group | `/chedaws-edp/s3-e2e-verifier/<env>` |
| VPC | Not attached |

**Environment variables** — see [contracts/lambda-env-vars.md](contracts/lambda-env-vars.md).

### 11.3 CloudWatch Log Group

| Attribute | Value |
|---|---|
| Local name | `s3_e2e_verifier` |
| Name | `/chedaws-edp/s3-e2e-verifier/<env>` |
| Retention | 7 days (dev/test), 30 days (uat/prod) via `local.s3_e2e_log_retention` |
| KMS | `module.kms["cloudwatch_logs"].key_arn` |

### 11.4 S3 Object — Lambda ZIP

| Attribute | Value |
|---|---|
| Local name | `s3_e2e_verifier_lambda` |
| Bucket | `module.platform_s3` |
| Key | `e2e/s3-e2e-verifier/function.zip` |
| Encryption | SSE-KMS, `module.kms["s3"].key_arn` |

### 11.5 EventBridge Schedule

| Attribute | Value |
|---|---|
| Local name | `s3_e2e_verifier_schedule` |
| Name | `chedaws-edp-s3-e2e-verifier-schedule-<env>` |
| Schedule | `cron(0 6 * * ? *)` |
| State | `ENABLED` |

### 11.6 Athena Workgroup

The E2E verifier uses the per-namespace workgroup `edp-<env>-platform` provisioned by `aws_athena_workgroup.s3_namespace_producer["platform"]` in `terraform/s3_producers.tf`. No separate E2E-specific workgroup is created.

| Attribute | Value |
|---|---|
| Resource | `aws_athena_workgroup.s3_namespace_producer["platform"]` |
| Name | `edp-<env>-platform` |
| Result location | `s3://chedaws-edp-landing-bucket-<env>/athena-query-results/platform/` |
| Enforce workgroup | `true` |
| Encryption | SSE-KMS, `module.kms["s3"].key_arn` |

### 11.7 CloudWatch Alarms

| Local name | Alarm name | Metric | Threshold |
|---|---|---|---|
| `s3_e2e_validation_failure` | `chedaws-edp-s3-e2e-validation-failure-<env>` | `S3E2ETestSuccess` Min < 1 | `treat_missing_data = "breaching"` |
| `s3_e2e_cleanup_failure` | `chedaws-edp-s3-e2e-cleanup-failure-<env>` | `S3E2ECleanupSuccess` Min < 1 | `treat_missing_data = "notBreaching"` |
| `s3_e2e_lambda_errors` | `chedaws-edp-s3-e2e-lambda-errors-<env>` | `AWS/Lambda / Errors` Sum ≥ 1 | `treat_missing_data = "notBreaching"` |

All alarms: `alarm_actions = [aws_sns_topic.alerts.arn]`, `period = 86400`, `evaluation_periods = 1`.

### 11.8 Landing Bucket Lifecycle Rule Addition

| Attribute | Value |
|---|---|
| `id` | `athena-query-results-e2e-expiry` |
| `prefix` | `athena-query-results/e2e/` |
| `expiration.days` | 7 |
| `enabled` | `true` |

---

## 12. E2E Verifier — Lambda Source Code Structure

```
lambda/s3-e2e-verifier/
├── handler.py          # Main Lambda handler
└── requirements.txt    # fastavro==1.9.7 (boto3 provided by Lambda runtime)
```

### 12.1 Lambda Execution Flow

```
lambda_handler(event, context)
│
├── 1. Generate run_uuid = uuid4()
├── 2. Generate 3 sample rows (deterministic within invocation)
│      rows = [
│        {"id": 1, "name": "alpha", "value": 1.1, "active": True},
│        {"id": 2, "name": "beta",  "value": 2.2, "active": False},
│        {"id": 3, "name": "gamma", "value": 3.3, "active": True},
│      ]
│
├── 3. Assume namespace role (sts:AssumeRole → edp-<env>-s3-producer-platform)
│
├── 4. For each table in [e2e_csv, e2e_json, e2e_avro]:
│      a. Serialise rows → format-correct bytes (CSV / NDJSON / Avro)
│      b. Upload to s3://<landing>/platform/<table>/<uuid>/data.<ext>
│            using assumed-role credentials + KMS key
│
├── 5. For each table:
│      a. Start Athena query: SELECT * FROM edp_<env>_platform.<table>
│                             WHERE id IN (1,2,3) ORDER BY id
│         Workgroup: edp-e2e-<env>
│      b. Poll until SUCCEEDED / FAILED / timeout (90s), retry once on FAILED
│      c. Fetch result rows; sort by id
│      d. Compare column names and values against generated rows
│      e. Record table outcome: PASS / FAIL + failure detail
│
├── 6. Cleanup (always, regardless of validation outcome):
│      For each table: s3:DeleteObject platform/<table>/<uuid>/data.<ext>
│      Record cleanup outcome: SUCCESS / FAIL + any errors
│
├── 7. Emit metrics:
│      S3E2ETestSuccess = 1 if all tables PASS, else 0
│      S3E2ECleanupSuccess = 1 if all deletes succeeded, else 0
│      Dimension: Environment = <env>
│
└── 8. Log structured JSON:
       {run_id, status: PASS|FAIL, tables: [{name, outcome, phase, detail}],
        cleanup: {outcome, errors}, duration_ms}
```

### 12.2 Sample Row Schema (all three tables)

```python
SAMPLE_ROWS = [
    {"id": 1, "name": "alpha", "value": 1.1, "active": True},
    {"id": 2, "name": "beta",  "value": 2.2, "active": False},
    {"id": 3, "name": "gamma", "value": 3.3, "active": True},
]
GENERATED_IDS = [1, 2, 3]
```

### 12.3 Format Serialisation

| Table | Extension | Serialisation |
|---|---|---|
| `e2e_csv` | `.csv` | `csv.DictWriter` with header row; field order: `id,name,value,active` |
| `e2e_json` | `.json` | `json.dumps(row)` per line, `\n`-delimited (NDJSON) |
| `e2e_avro` | `.avro` | `fastavro.writer(buffer, schema, records)` with Avro schema matching Glue columns |

### 12.4 Avro Schema (inlined in handler.py)

```json
{
  "type": "record",
  "name": "E2ERecord",
  "fields": [
    {"name": "id",     "type": "int"},
    {"name": "name",   "type": "string"},
    {"name": "value",  "type": "double"},
    {"name": "active", "type": "boolean"}
  ]
}
```

---

## 13. E2E Verifier State Transitions

```
Lambda invocation
    │
    ├─ ASSUME_ROLE_FAIL → alarm (validation), no write, no cleanup
    │
    ├─ WRITE_FAIL (one or more tables)
    │       → alarm (validation), cleanup attempted for tables that were written
    │
    ├─ QUERY_FAIL (one or more tables after 1 retry)
    │       → alarm (validation), cleanup attempted for all written tables
    │
    ├─ VALIDATION_FAIL (column-name or value mismatch)
    │       → alarm (validation), cleanup attempted for all written tables
    │
    ├─ CLEANUP_FAIL (one or more deletes failed)
    │       → alarm (cleanup), partial data may remain in platform/ prefix
    │
    └─ ALL_PASS → no alarm, zero objects remain in platform/ prefix
```

---

## Terraform Local Variable Relationships

```
_s3_domain_files                           (all parsed namespace YAMLs from s3/*.yaml)
        │
        └── s3_domains_this_env            (domains declaring current env)
                │
                ├── s3_aws_domains_this_env
                │       → aws_iam_role.s3_domain_aws_producer
                │       → aws_iam_policy.s3_domain_producer
                │       → aws_iam_role_policy_attachment.s3_domain_aws_producer
                │
                └── s3_onprem_domains_this_env
                        → aws_iam_role.s3_domain_onprem_producer
                        → aws_iam_policy.s3_domain_producer (same policy)
                        → aws_iam_role_policy_attachment.s3_domain_onprem_producer

_s3_table_files                            (all parsed table YAMLs from s3/*/*.yaml)
        │
        └── s3_tables_active               (non-decommissioned)
                │
                ├── s3_tables_this_env     (cross-ref: namespace active in this env)
                │       │
                │       └── s3_tables_with_schema_this_env
                │               → aws_glue_catalog_table.producer_dataset
                │
                ├── s3_table_aws_producers_this_env
                │       → aws_iam_role.s3_table_aws_producer
                │       → aws_iam_policy.s3_table_producer
                │       → aws_iam_role_policy_attachment.s3_table_aws_producer
                │
                └── s3_table_onprem_producers_this_env
                        → aws_iam_role.s3_table_onprem_producer
                        → aws_iam_policy.s3_table_producer (same policy)
                        → aws_iam_role_policy_attachment.s3_table_onprem_producer

_s3_glue_database_keys                     (distinct "${env}_${namespace}" from schema tables)
        → aws_glue_catalog_database.producer_domain
```
