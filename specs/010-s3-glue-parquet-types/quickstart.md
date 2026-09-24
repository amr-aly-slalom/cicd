# Quickstart Validation Guide: S3 Glue Parquet and Full Column Type Support

**Feature**: 010-s3-glue-parquet-types
**Date**: 2026-08-14

---

## Prerequisites

- Terraform >= 1.0 installed
- AWS credentials configured for the `dev` environment (`InfraBuildRole`)
- A JSON Schema validator available (e.g., `ajv-cli`, VS Code with JSON Schema extension, or Python `jsonschema` library)
- Access to the AWS Glue console in ap-southeast-2 (for manual verification)

---

## Scenario 1: Parquet Table YAML Passes Schema Validation

**Goal**: Confirm `spec.format: parquet` is accepted by the updated JSON Schema, alongside complex and parameterised types.

### Step 1: Create a scratch YAML file (do not commit — use a non-production name)

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: platform
  name: scratch_parquet_test
  owner: platform-team
  description: Scratch file for schema validation only
spec:
  format: parquet
  schema:
    columns:
      - name: id
        type: bigint
      - name: name
        type: varchar(255)
      - name: score
        type: decimal(10,2)
      - name: tags
        type: array<string>
      - name: created_at
        type: timestamp
```

### Step 2: Validate against the updated schema

Using Python `jsonschema`:
```python
import json, yaml
from jsonschema import validate

schema = json.load(open('specs/010-s3-glue-parquet-types/contracts/table-schema.json'))
instance = yaml.safe_load(open('/tmp/e2e_parquet.yaml'))
validate(instance, schema)
print("PASS: schema validation succeeded")
```

**Expected**: No validation errors. The `parquet` format value, `varchar(255)`, `decimal(10,2)`, and `array<string>` types all pass.

---

## Scenario 2: Old-Style Types Still Pass (Backward Compatibility)

**Goal**: Confirm all 7 original types continue to pass validation.

### Step 1: Validate an existing table YAML

Run the JSON Schema validator against any existing file in `s3/platform/*.yaml` (e.g., `s3/platform/e2e_csv.yaml`).

**Expected**: Validation passes without modification. The new schema is a strict superset.

### Step 2: Validate the old enum values explicitly

Check that `string`, `int`, `bigint`, `double`, `boolean`, `timestamp`, `date` all match the new pattern:

```python
import re
pattern = r'^(boolean|tinyint|smallint|int|bigint|float|double|decimal(\(\d+,\s*\d+\))?|string|varchar(\(\d+\))?|char(\(\d+\))?|binary|date|timestamp|(array|map|struct|uniontype)<.+>)$'
old_types = ["string", "int", "bigint", "double", "boolean", "timestamp", "date"]
for t in old_types:
    assert re.match(pattern, t), f"FAIL: {t} did not match"
    print(f"PASS: {t}")
```

**Expected**: All 7 types print `PASS`.

---

## Scenario 3: Invalid Types Fail Validation

**Goal**: Confirm that unknown types are rejected.

### Step 1: Try an invalid type

Create a YAML with `type: foobar` in a column. Validate it against the schema.

**Expected**: Validation fails with a pattern mismatch error referencing the `type` field.

### Step 2: Try malformed complex types

Test `array<>` (empty type parameter) — expected to fail.
Test `decimal(abc)` (non-numeric precision) — expected to fail.

---

## Scenario 4: Terraform Plan Succeeds for Parquet E2E Canary Table

**Goal**: Confirm Terraform generates a valid Glue table resource for `s3/platform/e2e_parquet.yaml` — the permanent E2E canary table (FR-007).

### Step 1: Verify `s3/platform/e2e_parquet.yaml` is present

The file must exist with `spec.format: parquet` and the standard 4-column schema (`id int`, `name string`, `value double`, `active boolean`). This file is committed alongside the other `e2e_*.yaml` canary tables — it is NOT a temp file.

### Step 2: Run terraform plan

```powershell
cd terraform
terraform plan -var="env=dev" -out=tfplan
```

**Expected**: Plan shows `aws_glue_catalog_table.producer_dataset["platform/e2e_parquet"]` will be created. The resource should have:
- `input_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"`
- `output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"`
- `serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"`
- Columns: `id int`, `name string`, `value double`, `active boolean`

**Expected**: No Terraform errors. Zero unexpected changes to existing resources.

---

## Scenario 5: Terraform Plan Clean Across All Environments

**Goal**: Confirm no regressions in other environments.

```powershell
cd terraform
foreach ($env in @("dev", "test", "uat", "prod")) {
    terraform plan -var="env=$env" -detailed-exitcode
    Write-Host "env=$env exit code: $LASTEXITCODE"
}
```

**Expected**: Exit code 0 (no changes) or 2 (changes for new resources only). Exit code 1 indicates an error — investigate immediately.

---

## Scenario 6: New Column Types in Terraform Plan

**Goal**: Confirm a table using `float`, `tinyint`, `binary` produces valid Glue column declarations.

### Step 1: Create a test YAML with diverse new types

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: platform
  name: e2e_types
  owner: platform
spec:
  format: csv
  schema:
    columns:
      - name: flag
        type: boolean
      - name: tiny_code
        type: tinyint
      - name: short_val
        type: smallint
      - name: price
        type: float
      - name: payload
        type: binary
      - name: label
        type: char(3)
```

### Step 2: Run terraform plan

```powershell
terraform plan -var="env=dev"
```

**Expected**: `aws_glue_catalog_table.producer_dataset["platform/e2e_types"]` in the plan with correct column types. No errors.

### Step 3: Remove test YAML before committing.

---

## Scenario 7: E2E Verifier Lambda Reports PASS for Parquet

**Goal**: Confirm the updated Lambda serialises a Parquet file, uploads it, queries via Athena, and returns `"outcome": "PASS"` for `e2e_parquet` (FR-008, SC-006).

**Prerequisites**: Terraform applied in `dev` (so `e2e_parquet` Glue table exists), Lambda redeployed with `pyarrow` and Parquet code changes.

### Step 1: Invoke the Lambda manually

```powershell
aws lambda invoke `
  --function-name chedaws-edp-s3-e2e-verifier-dev `
  --payload '{}' `
  --cli-binary-format raw-in-base64-out `
  response.json
Get-Content response.json | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

### Step 2: Verify the result

**Expected** in `response.json`:

```json
{
  "status": "PASS",
  "tables": {
    "e2e_parquet": { "outcome": "PASS", "phase": "query" }
  }
}
```

All four tables (`e2e_csv`, `e2e_json`, `e2e_avro`, `e2e_parquet`) should report `"outcome": "PASS"`.

### Step 3: Check CloudWatch

Verify `S3E2ETestSuccess` metric in namespace `ChedawsEDP/S3E2EVerifier` (dimension `ENVIRONMENT=dev`) shows value `1`.

### Step 4: Verify cleanup

Confirm no test objects remain in the landing bucket under `platform/e2e_parquet/`:

```powershell
aws s3 ls s3://chedaws-edp-landing-bucket-dev/platform/e2e_parquet/ --recursive
```

**Expected**: Empty output (cleanup phase removed the test file).

---

## Post-Validation Cleanup

Remove any scratch test YAMLs (e.g., `s3/platform/e2e_types.yaml`) before raising a PR. `s3/platform/e2e_parquet.yaml` is a permanent file and MUST be committed — do not delete it.
