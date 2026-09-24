# Data Model: S3 Glue Parquet and Full Column Type Support

**Feature**: 010-s3-glue-parquet-types
**Date**: 2026-08-14

---

## Overview

This feature extends two existing data entities — the Table YAML declaration and the JSON Schema contract — rather than introducing new entities. The Glue Catalog Table resource is derived from these declarations; no new AWS resource types are introduced.

---

## Entity: Table YAML (`spec.format`)

**Location**: `s3/<namespace>/<name>.yaml`

The `spec.format` field controls which SerDe entry is selected from `_s3_serde_map` in `s3.tf`. The allowed values are expanded from 3 to 4.

| Field | Before | After |
|-------|--------|-------|
| `spec.format` allowed values | `csv`, `json`, `avro` | `csv`, `json`, `avro`, **`parquet`** |

**State transitions**: `format` is immutable after first `terraform apply`. Changing it on an existing table requires decommission + re-registration (existing behaviour, no change).

---

## Entity: Column Definition (`spec.schema.columns[].type`)

**Location**: `s3/<namespace>/<name>.yaml` → `spec.schema.columns[]`

The `type` field for each column is validated at YAML authoring time against the JSON Schema. The allowed value set is expanded.

### Before (7 types, fixed enum)
```
string | int | bigint | double | boolean | timestamp | date
```

### After (14 primitives + complex types, pattern-based)

**Primitive types** (bare token):

| Type | Storage | Use case |
|------|---------|----------|
| `boolean` | 1 bit / 1 byte | Flags, feature toggles |
| `tinyint` | 1 byte | Small codes, status values |
| `smallint` | 2 bytes | Short integers |
| `int` | 4 bytes | Standard integers |
| `bigint` | 8 bytes | Large IDs, timestamps as epoch |
| `float` | 4 bytes | Approximate decimals |
| `double` | 8 bytes | Precise floating-point |
| `decimal` | Variable | Financial amounts (use `decimal(p,s)` for precision) |
| `string` | Variable | Text, IDs, free-form |
| `varchar` | Variable | Bounded text (use `varchar(n)` for length) |
| `char` | Fixed | Fixed-length codes (use `char(n)` for length) |
| `binary` | Variable | Byte payloads |
| `date` | 4 bytes | Calendar date |
| `timestamp` | 8 bytes | Date + time |

**Parameterised forms** (also valid):
- `decimal(p,s)` — e.g., `decimal(10,2)` for 10-digit number with 2 decimal places
- `varchar(n)` — e.g., `varchar(255)`
- `char(n)` — e.g., `char(3)` for a 3-character code

**Complex types** (parametric, recursive):
- `array<element_type>` — ordered list
- `map<key_type,value_type>` — key-value pairs (key must be a primitive)
- `struct<field_name:type,...>` — named fields (nested records)
- `uniontype<type,...>` — tagged union

### Validation Rule

```
pattern: ^(boolean|tinyint|smallint|int|bigint|float|double|decimal(\(\d+,\s*\d+\))?|string|varchar(\(\d+\))?|char(\(\d+\))?|binary|date|timestamp|(array|map|struct|uniontype)<.+>)$
```

---

## Entity: SerDe Map (`_s3_serde_map` local in `s3.tf`)

The Terraform local `_s3_serde_map` is the lookup table that maps a `spec.format` value to the Glue storage descriptor parameters. One new entry is added.

| Key | `input_format` | `output_format` | `serde_library` | `serde_parameters` |
|-----|--------------|----------------|----------------|-------------------|
| `csv` | `TextInputFormat` | `HiveIgnoreKeyTextOutputFormat` | `LazySimpleSerDe` | `skip.header.line.count=1`, `field.delim=,` |
| `json` | `TextInputFormat` | `HiveIgnoreKeyTextOutputFormat` | `JsonSerDe` | — |
| `avro` | `AvroInputFormat` | `AvroOutputFormat` | `AvroSerDe` | — |
| **`parquet`** | `MapredParquetInputFormat` | `MapredParquetOutputFormat` | `ParquetHiveSerDe` | **—** |

Full class names:
- `MapredParquetInputFormat` → `org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat`
- `MapredParquetOutputFormat` → `org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat`
- `ParquetHiveSerDe` → `org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe`

---

## Entity: E2E Canary Table YAML (`s3/platform/e2e_parquet.yaml`)

**Location**: `s3/platform/e2e_parquet.yaml` (new permanent file)

Mirrors the structure of the three existing E2E canary tables (`e2e_csv`, `e2e_json`, `e2e_avro`). The same 4-column schema is used across all canary tables so that `SAMPLE_ROWS` in the Lambda can be shared without per-table schema translation.

| Field | Value |
|-------|-------|
| `metadata.namespace` | `platform` |
| `metadata.name` | `e2e_parquet` |
| `metadata.owner` | `platform-team` |
| `spec.format` | `parquet` |
| `spec.schema.columns` | `id int`, `name string`, `value double`, `active boolean` |

---

## Entity: E2E Verifier Lambda (`lambda/s3-e2e-verifier/handler.py`)

The Lambda is extended to add a fourth table path alongside the existing three. No new Lambda function or resource is created — only code changes to the existing handler.

### `_TABLE_EXT` map (after change)

| Key | Value (file extension) |
|-----|----------------------|
| `e2e_csv` | `csv` |
| `e2e_json` | `json` |
| `e2e_avro` | `avro` |
| **`e2e_parquet`** | **`parquet`** |

### `tables` list (after change)

```python
tables = ["e2e_csv", "e2e_json", "e2e_avro", "e2e_parquet"]
```

### New function: `serialize_parquet()`

Writes the shared `SAMPLE_ROWS` list (3 rows: `id int`, `name string`, `value double`, `active boolean`) into a `pyarrow.Table`, then serialises to Parquet bytes in an `io.BytesIO` buffer. The buffer is returned and used identically to the CSV/JSON/Avro buffers in `write_table()`.

### Dependency addition: `requirements.txt`

```
fastavro==1.9.7
pyarrow>=15.0,<20.0
```

`pyarrow` is bundled directly in the Lambda deployment ZIP (same pattern as `fastavro`). ZIP size must be verified to stay under 250 MB unzipped.

---

## Relationships

```
Table YAML (spec.format)
    │
    └─► _s3_serde_map[format]
             │
             └─► aws_glue_catalog_table.producer_dataset
                      (storage_descriptor.input_format,
                       output_format, ser_de_info)

Table YAML (spec.schema.columns[].type)
    │
    └─► aws_glue_catalog_table.producer_dataset
             (storage_descriptor.columns[].type,
              partition_keys[].type)

s3/platform/e2e_parquet.yaml
    │
    ├─► aws_glue_catalog_table.producer_dataset["platform/e2e_parquet"]
    │        (via _s3_serde_map["parquet"])
    │
    └─► lambda/s3-e2e-verifier/handler.py
             (tables list, _TABLE_EXT, serialize_parquet())
```

---

## Schema Contracts (canonical location)

The JSON Schema contracts that govern Table YAML validation live at:
- `specs/008-s3-producer-onboarding/contracts/table-schema.json`
- `specs/008-s3-producer-onboarding/contracts/producer-schema.json`

Updated versions are defined in this feature's contracts directory:
- `specs/010-s3-glue-parquet-types/contracts/table-schema.json`
- `specs/010-s3-glue-parquet-types/contracts/producer-schema.json`

The implementation task replaces the originals in `specs/008` with these updated versions.
