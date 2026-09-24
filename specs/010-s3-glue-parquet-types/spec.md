# Feature Specification: S3 Glue Parquet and Full Column Type Support

**Feature Branch**: `feat/s3-parquet`

**Created**: 2026-08-14

**Status**: Draft

**Input**: User description: "Add support for 'parquet' data type for s3 glue tables. also use aws mcp to check all valid glue data types and allow them all. make necessary update to the schema and anywhere else needed"

## Clarifications

### Session 2026-08-14

- Q: Which Python library should the E2E verifier Lambda use to serialise Parquet test data? → A: `pyarrow` bundled directly in the Lambda deployment ZIP (Option A)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Register a Parquet-Format Table (Priority: P1)

A data producer wants to land Parquet files in the EDP landing bucket and have a corresponding Glue table created for querying with Athena. Today the producer YAML `spec.format` field only accepts `csv`, `json`, or `avro`; the producer cannot self-serve a Parquet table.

**Why this priority**: Parquet is the most common columnar format for analytics workloads. Without this, producers must fall back to row-oriented formats and lose the compression, predicate pushdown, and schema-on-read benefits that Athena and downstream Glue ETL jobs rely on.

**Independent Test**: Create a producer YAML with `spec.format: parquet`, run `terraform plan` for one environment, and verify a Glue table is created with the correct Parquet SerDe (ParquetHiveSerDe), input format, and output format — delivering a fully queryable table.

**Acceptance Scenarios**:

1. **Given** a valid Table YAML with `spec.format: parquet` and a `spec.schema`, **When** Terraform is applied, **Then** a Glue catalog table is created with `ParquetHiveSerDe` as the serialisation library, `MapredParquetInputFormat` as the input format, and `MapredParquetOutputFormat` as the output format.
2. **Given** a Table YAML with `spec.format: parquet` and no `spec.schema`, **When** Terraform is applied, **Then** no Glue table is created (consistent with existing behaviour for schema-less tables).
3. **Given** a Table YAML with an invalid format value (e.g., `spec.format: orc`), **When** the YAML is validated against the JSON schema, **Then** validation fails with a clear error indicating the value is not in the allowed set.

---

### User Story 2 - Declare Columns Using Any Valid Glue Primitive Type (Priority: P2)

A data producer wants to declare a column of a type not currently in the schema — such as `float`, `tinyint`, `smallint`, `decimal`, `varchar`, `char`, or `binary` — but the current `spec.schema.columns[].type` enum only allows 7 types and rejects any other value.

**Why this priority**: The restricted type list blocks accurate schema registration, leading to either incorrect type declarations or producers omitting the schema block entirely (losing Athena query capability). All Glue-native primitive types should be expressible.

**Independent Test**: Create a Table YAML with columns typed as `float`, `tinyint`, `varchar`, and `decimal`, validate against the JSON schema, and verify all values are accepted — delivering a schema that matches the producer's actual data.

**Acceptance Scenarios**:

1. **Given** a Table YAML column with `type: float`, **When** validated against the JSON schema, **Then** validation passes.
2. **Given** a Table YAML column with `type: tinyint`, `type: smallint`, `type: decimal`, `type: varchar`, `type: char`, or `type: binary`, **When** validated against the JSON schema, **Then** validation passes for each.
3. **Given** a Table YAML column with `type: foobar` (an invalid type), **When** validated, **Then** validation fails with a descriptive error.
4. **Given** a Glue table is created with a column typed `float` or `decimal`, **When** an Athena query runs against that table, **Then** the query executes without type-mismatch errors.

---

### User Story 3 - Declare Columns Using Glue Complex Types (Priority: P3)

A data producer working with semi-structured Parquet or Avro data wants to declare nested column types such as `array<string>`, `map<string,string>`, or `struct<field:string,count:bigint>` to accurately represent their data model in the Glue catalog.

**Why this priority**: Complex types are essential for nested data (e.g., JSON payloads, Avro records, Parquet nested groups). Blocking them forces producers to flatten schemas or use `string` as a catch-all, degrading query usability.

**Independent Test**: Create a Table YAML with at least one column of type `array<string>` and one of type `struct<id:bigint,name:string>`, validate against the JSON schema, and verify both are accepted.

**Acceptance Scenarios**:

1. **Given** a Table YAML column with `type: array<string>`, **When** validated against the JSON schema, **Then** validation passes.
2. **Given** a Table YAML column with a valid `struct<...>` or `map<key,value>` type string, **When** validated, **Then** validation passes.
3. **Given** a Table YAML column with a malformed type such as `array<>` or `struct<:>`, **When** validated, **Then** validation fails.

---

### User Story 4 - E2E Verification of Parquet Upload and Query (Priority: P2)

The platform team wants the E2E verifier Lambda to automatically test that a Parquet file can be uploaded to the landing bucket and queried via Athena, providing the same continuous assurance that already exists for CSV, JSON, and Avro formats.

**Why this priority**: Without a live E2E test, a Parquet SerDe misconfiguration or Glue table creation error could go undetected in production. The E2E verifier is the safety net that catches integration failures before they affect data consumers.

**Independent Test**: Deploy the updated Lambda with the `e2e_parquet` table YAML and Lambda changes applied, trigger the Lambda manually, and verify the CloudWatch log shows `"outcome": "PASS"` for `e2e_parquet` — delivering automated proof that Parquet end-to-end works.

**Acceptance Scenarios**:

1. **Given** the `e2e_parquet` Table YAML exists in `s3/platform/` with `spec.format: parquet` and the 4-column schema (id: int, name: string, value: double, active: boolean), **When** Terraform is applied, **Then** a Glue catalog table `e2e_parquet` is created in the `edp_<env>_platform` database with Parquet SerDe.
2. **Given** the Lambda is invoked, **When** the write phase runs, **Then** a valid Parquet file is uploaded to `platform/e2e_parquet/<run_uuid>/data.parquet` in the landing bucket, encrypted with the platform KMS key.
3. **Given** the Parquet file has been uploaded, **When** the Athena query runs against `e2e_parquet`, **Then** it returns the 3 expected rows with matching values and the table result shows `"outcome": "PASS"`.
4. **Given** the query phase completes, **When** the cleanup phase runs, **Then** the test Parquet object is deleted from S3 and `"outcome": "SUCCESS"` is reported for cleanup.

---

### Edge Cases

- What happens when a producer declares `spec.format: parquet` but the uploaded files are actually CSV? The Glue table is created correctly (format is a declaration, not enforced at write time); Athena queries fail gracefully with a SerDe deserialization error — no change from current behaviour with other formats.
- What happens when a column type `decimal` is used without precision/scale (e.g., `decimal` vs `decimal(10,2)`)? The bare `decimal` token is valid in Hive/Glue (defaults to `decimal(10,0)`); the spec allows it without requiring parameters.
- What happens if a complex type string is valid JSON schema pattern but invalid Glue syntax (e.g., `struct<a:>`)? Glue will reject it at catalog registration time; the JSON schema validation prevents the most obviously malformed values.
- What happens when an existing table YAML currently typed with the old 7-type enum is re-validated after this change? Validation continues to pass — the expanded enum is a strict superset.
- What happens if the `pyarrow` package pushes the Lambda deployment ZIP over 250 MB unzipped? The build step (`pip install`) would fail visibly. This must be validated during implementation by measuring the ZIP size before deploying.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The `spec.format` field in both `table-schema.json` and `producer-schema.json` MUST accept `parquet` as a valid value (in addition to the existing `csv`, `json`, `avro`).
- **FR-002**: The `spec.schema.columns[].type` field in both JSON schemas MUST accept all AWS Glue-native primitive types: `boolean`, `tinyint`, `smallint`, `int`, `bigint`, `float`, `double`, `decimal`, `string`, `varchar`, `char`, `binary`, `date`, `timestamp`.
- **FR-003**: The `spec.schema.columns[].type` field MUST accept Glue complex type expressions (`array<...>`, `map<...,...>`, `struct<...>`, `uniontype<...>`) using a pattern-based validation rule, as these types carry parameters that cannot be expressed as a fixed enum.
- **FR-004**: The Terraform SerDe map (`_s3_serde_map` in `s3.tf`) MUST include a `parquet` entry with the correct Parquet input format, output format, and serialisation library so that Glue tables are created with valid storage descriptors.
- **FR-005**: The column description text for `spec.schema.columns[].type` in both schemas MUST be updated to reflect the full supported type set.
- **FR-006**: No existing valid Table YAML (using any of the original 7 column types or 3 format values) MUST fail validation after this change — the change is strictly additive.
- **FR-007**: A `s3/platform/e2e_parquet.yaml` Table YAML MUST be added with `spec.format: parquet` and the same 4-column schema used by the other E2E tables (id: int, name: string, value: double, active: boolean).
- **FR-008**: The E2E verifier Lambda (`lambda/s3-e2e-verifier/handler.py`) MUST be extended to: (a) add `pyarrow` to `requirements.txt`; (b) add a `serialize_parquet()` function that writes the sample rows to an `io.BytesIO` buffer using `pyarrow`; (c) add `"e2e_parquet": "parquet"` to the `_TABLE_EXT` map; (d) add `"e2e_parquet"` to the `tables` list; (e) handle the parquet branch in `write_table()`; (f) update the assume-role failure path to include `e2e_parquet`.

### Key Entities *(include if feature involves data)*

- **Table YAML**: The declarative file (`s3/<namespace>/<name>.yaml`) that registers a dataset. Its `spec.format` field drives SerDe selection; its `spec.schema.columns[].type` fields drive Glue column type registration.
- **JSON Schema (table-schema.json / producer-schema.json)**: The validation contract for Table YAMLs. The `spec.format` enum and `spec.schema.columns[].type` enum/pattern live here.
- **SerDe map (`_s3_serde_map`)**: A Terraform local that maps format strings to Glue storage descriptor parameters (input format, output format, serialisation library, SerDe parameters).
- **Glue Catalog Table**: The AWS resource provisioned by Terraform when a Table YAML declares `spec.schema`. Its storage descriptor is derived directly from the format value and column type declarations.
- **E2E Verifier Lambda**: The scheduled Lambda (`lambda/s3-e2e-verifier/handler.py`) that writes test data in each registered format, queries via Athena, validates results, and cleans up. Extended to cover `e2e_parquet`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A Table YAML declaring `spec.format: parquet` passes JSON schema validation and produces a Glue catalog table with the correct Parquet SerDe on the first Terraform apply — zero manual remediation steps required.
- **SC-002**: All 14 Glue primitive column types (`boolean`, `tinyint`, `smallint`, `int`, `bigint`, `float`, `double`, `decimal`, `string`, `varchar`, `char`, `binary`, `date`, `timestamp`) are accepted by JSON schema validation.
- **SC-003**: Complex type expressions (`array<string>`, `map<string,bigint>`, `struct<id:bigint,name:string>`) pass JSON schema validation.
- **SC-004**: All existing Table YAML files in the `s3/` directory continue to pass validation unchanged after the schema update — 0 regressions.
- **SC-005**: `terraform plan` for all four environments (`dev`, `test`, `uat`, `prod`) produces no errors when at least one active Table YAML uses `format: parquet`.
- **SC-006**: The E2E verifier Lambda, when invoked after deployment, reports `"outcome": "PASS"` for `e2e_parquet` — Athena returns the expected 3 rows with matching values — with zero manual intervention.

## Assumptions

- AWS Glue accepts the Parquet SerDe class `org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe` with input format `org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat` and output format `org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat` — these are the standard Hive-on-Parquet classes used by Glue, EMR, and Athena.
- Parquet tables do not require SerDe parameters (no `serde_parameters` key in the map entry), consistent with the Avro entry.
- Complex types (`array`, `map`, `struct`, `uniontype`) carry parametric syntax that cannot be expressed as a fixed JSON schema `enum`. A regex pattern validation is sufficient for schema-level protection; Glue itself enforces deeper syntax validation at catalog registration time.
- The `decimal` type is accepted without requiring explicit precision/scale parameters in the YAML (e.g., `decimal` alone is valid Glue syntax, defaulting to `decimal(10,0)`).
- The `varchar` and `char` types similarly do not require length parameters in the YAML column type string at JSON schema validation level; Glue accepts bare `varchar` and `char` tokens.
- This change is backwards-compatible: no existing Table YAML needs to be modified.
- The E2E verifier Lambda MUST be extended to cover `e2e_parquet`. `pyarrow` is added to `requirements.txt` and bundled directly in the Lambda deployment ZIP, consistent with how `fastavro` is bundled for Avro. The combined deployment package (ZIP + all dependencies) MUST remain under Lambda's 250 MB unzipped limit; this MUST be verified during the build step.
- The `table-schema.json` contract in `specs/008-s3-producer-onboarding/contracts/` and the `producer-schema.json` in the same location are the authoritative source; both must be updated together.
