# Implementation Plan: S3 Glue Parquet and Full Column Type Support

**Branch**: `feat/s3-parquet` | **Date**: 2026-08-14 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/010-s3-glue-parquet-types/spec.md`

## Summary

This feature extends the S3 producer onboarding platform in two orthogonal ways:

1. **Parquet format support**: Adds `parquet` as a valid `spec.format` value in the Table YAML schema and registers the corresponding Parquet SerDe entry (`ParquetHiveSerDe`) in the Terraform `_s3_serde_map` local, enabling Glue catalog tables to be created with the correct storage descriptor for Parquet files.

2. **Full Glue column type coverage**: Replaces the current 7-type fixed enum on `spec.schema.columns[].type` with a regex pattern that accepts all 14 Glue-native primitive types (bare and parameterised forms) and all 4 complex type families (`array`, `map`, `struct`, `uniontype`).

Both changes are strictly additive. Existing Table YAMLs require no modification.

---

## Technical Context

**Language/Version**: HCL (Terraform >= 1.0); JSON Schema Draft-07

**Primary Dependencies**: Terraform AWS provider (`aws_glue_catalog_table`); JSON Schema validation tooling used by producers to pre-validate their YAML files

**Storage**: AWS Glue Data Catalog (managed by Terraform); S3 landing bucket (no changes)

**Testing**: `terraform plan` per environment; JSON Schema regex validation; manual Glue console inspection

**Target Platform**: AWS ap-southeast-2; four environments: `dev`, `test`, `uat`, `prod`

**Project Type**: Infrastructure-as-Code (Terraform); schema contract definition

**Performance Goals**: None — this is a configuration extension, not a compute change

**Constraints**: Strictly backward-compatible; all existing Table YAMLs must continue to pass validation unchanged; no new billable AWS resources are introduced

**Scale/Scope**: ~10 existing table YAMLs affected by validation; 4 environments; 2 JSON Schema contract files updated

---

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- [x] **Security**: No new AWS resources are provisioned. Parquet data landing in S3 is encrypted by the existing KMS key (`module.kms["s3"]`) enforced by the existing S3 bucket policy. No IAM policy changes; the `_s3_serde_map` entry is a Terraform local, not a resource. PASS.

- [x] **Observability**: No new compute or pipeline resources. The existing Glue catalog table resource (`aws_glue_catalog_table.producer_dataset`) already has CloudWatch alarms via the Glue failure alarm defined in the constitution checklist scope. No new log groups or alarms are required for a SerDe configuration change. PASS (N/A - no new compute).

- [x] **Durability**: No new S3 buckets or stateful resources. Parquet files land in the existing `chedaws-edp-landing-bucket-<env>` bucket, which already has versioning and lifecycle rules defined. No new retention policy decisions are needed. PASS (N/A - no new stateful resources).

- [x] **Fault-Tolerance**: No ECS services, MWAA environments, Glue jobs, or DMS instances are added. The Glue catalog table is a metadata-only resource. PASS (N/A).

- [x] **Cost Optimisation**: No new billable resources. The Glue Data Catalog charges per table stored; adding one more format option does not change pricing for existing tables. Parquet files typically reduce S3 storage costs (columnar compression) — a net benefit. No tagging changes needed; existing tags from `default_tags` apply. PASS.

- [x] **DRY & Modularity**: The change adds a single entry to an existing map local (`_s3_serde_map`) in `s3.tf`. The format-to-SerDe mapping pattern is already established and consistent. No new module is warranted (single call site: `aws_glue_catalog_table.producer_dataset`). Terraform resource local names are unchanged. No edits to `terraform-legacy/`. PASS.

---

## Project Structure

### Documentation (this feature)

```text
specs/010-s3-glue-parquet-types/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0: SerDe classes, type set, validation strategy
├── data-model.md        # Phase 1: Entity changes, SerDe map, column type set
├── quickstart.md        # Phase 1: Validation scenarios
├── contracts/
│   ├── table-schema.json    # Updated Table YAML schema (v2)
│   └── producer-schema.json # Updated Producer YAML schema (v2)
└── tasks.md             # Phase 2 output (/speckit-tasks - NOT created by /speckit-plan)
```

### Source Code (repository root)

```text
specs/008-s3-producer-onboarding/contracts/
├── table-schema.json    # Replace with specs/010.../contracts/table-schema.json
└── producer-schema.json # Replace with specs/010.../contracts/producer-schema.json

terraform/
└── s3.tf                # Add parquet entry to _s3_serde_map local

s3/platform/
└── e2e_parquet.yaml     # New permanent E2E canary Table YAML (FR-007)

lambda/s3-e2e-verifier/
├── handler.py           # Add serialize_parquet(), extend _TABLE_EXT and tables list (FR-008)
└── requirements.txt     # Add pyarrow (FR-008)
```

**Structure Decision**: This feature touches five files in the source tree. No new modules, directories, or Terraform resource blocks are introduced beyond `e2e_parquet.yaml`. All Terraform changes are inline in existing structures (`_s3_serde_map` local in `s3.tf`; `spec.format` enum and column `type` pattern in the two JSON Schema contracts).

---

## Implementation Detail

### Change 1: `terraform/s3.tf` — add `parquet` to `_s3_serde_map`

Add the following entry to the `_s3_serde_map` local (after `avro`):

```hcl
parquet = {
  input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
  output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
  serde_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
}
```

No `serde_parameters` key is needed (consistent with `avro`). The `try(..., {})` in `ser_de_info.parameters` handles the absent key.

### Change 2: JSON Schema contracts — `spec.format` enum

In both `table-schema.json` and `producer-schema.json`, update the `spec.format` enum from:
```json
"enum": ["csv", "json", "avro"]
```
to:
```json
"enum": ["csv", "json", "avro", "parquet"]
```

### Change 3: JSON Schema contracts — column `type` validation

In both schemas, replace the `enum` on `spec.schema.columns[].type`:

**Before**:
```json
"enum": ["string", "int", "bigint", "double", "boolean", "timestamp", "date"]
```

**After**:
```json
"pattern": "^(boolean|tinyint|smallint|int|bigint|float|double|decimal(\\(\\d+,\\s*\\d+\\))?|string|varchar(\\(\\d+\\))?|char(\\(\\d+\\))?|binary|date|timestamp|(array|map|struct|uniontype)<.+>)$"
```

Update the `description` on the same field to document the full type set.

The updated canonical schemas are the files in `specs/010-s3-glue-parquet-types/contracts/`. The implementation task copies them over to `specs/008-s3-producer-onboarding/contracts/`.

### Change 4: `s3/platform/e2e_parquet.yaml` — new permanent E2E canary Table YAML

Add a new file `s3/platform/e2e_parquet.yaml` with `spec.format: parquet` and the standard 4-column schema (identical to the other three E2E canary tables). This is a permanent registration, not a test scaffold.

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: platform
  name: e2e_parquet
  owner: platform-team
  description: E2E canary table for Parquet format validation
spec:
  format: parquet
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

### Change 5: E2E verifier Lambda — add Parquet support

**File**: `lambda/s3-e2e-verifier/requirements.txt`
- Add `pyarrow>=15.0,<20.0` (same bundling approach as `fastavro`; version range consistent with data-model.md).

**File**: `lambda/s3-e2e-verifier/handler.py`
- Add `import pyarrow as pa` and `import pyarrow.parquet as pq` to imports.
- Add `"e2e_parquet": "parquet"` to `_TABLE_EXT` map (controls the upload key suffix).
- Add `"e2e_parquet"` to the `tables` list (participates in write, query, and cleanup phases).
- Add `serialize_parquet()` function:
  ```python
  def serialize_parquet():
      table = pa.Table.from_pylist(SAMPLE_ROWS)
      buf = io.BytesIO()
      pq.write_table(table, buf)
      buf.seek(0)
      return buf
  ```
- Extend `write_table()` with `elif ext == "parquet": buf = serialize_parquet()`.
- Add `"e2e_parquet"` to the assume-role failure path (alongside `e2e_csv`, `e2e_json`, `e2e_avro`).

**Lambda ZIP size guard**: After `pip install pyarrow`, measure the unzipped deployment package size. It MUST remain below 250 MB. `pyarrow` wheels are typically 30–60 MB; combined with the existing `fastavro` (~1 MB) and Lambda stdlib, the limit should not be reached, but MUST be verified during implementation.

---

## Complexity Tracking

> No constitution violations. Table left blank.
