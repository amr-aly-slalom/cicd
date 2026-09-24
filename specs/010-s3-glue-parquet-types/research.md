# Research: S3 Glue Parquet and Full Column Type Support

**Feature**: 010-s3-glue-parquet-types
**Date**: 2026-08-14

---

## 1. Parquet SerDe Configuration for AWS Glue

**Decision**: Use the standard Hadoop/Hive Parquet classes (`ParquetHiveSerDe`).

**Rationale**: These are the canonical Parquet SerDe classes used by AWS Glue, Amazon Athena, and Amazon EMR. They are bundled in the Glue execution environment and produce Glue tables that Athena can query without additional configuration.

| Parameter | Value |
|-----------|-------|
| `input_format` | `org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat` |
| `output_format` | `org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat` |
| `serde_library` | `org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe` |
| `serde_parameters` | None required (unlike CSV which needs `field.delim`) |

**Alternatives considered**:
- `com.amazon.emr.hive.serde.CloudTrailSerde` — CloudTrail-specific, not applicable.
- Writing raw Parquet via `HiveIgnoreKeyTextOutputFormat` — incorrect; Parquet is columnar and requires its own output format.

---

## 2. Complete AWS Glue Column Type Set

**Decision**: Support all Hive metastore-compatible types that AWS Glue Data Catalog accepts.

**Rationale**: AWS Glue Data Catalog is built on the Apache Hive metastore type system. The full set covers all production use cases across JSON, CSV, Avro, and Parquet source formats.

### Primitive Types (14 total)

| Type | Description | Notes |
|------|-------------|-------|
| `boolean` | true/false | |
| `tinyint` | 1-byte signed integer | -128 to 127 |
| `smallint` | 2-byte signed integer | |
| `int` | 4-byte signed integer | Alias: `integer` (not used) |
| `bigint` | 8-byte signed integer | |
| `float` | 4-byte IEEE 754 float | |
| `double` | 8-byte IEEE 754 float | |
| `decimal` | Arbitrary-precision decimal | Bare or `decimal(p,s)` |
| `string` | Unbounded UTF-8 string | |
| `varchar` | Variable-length string | Bare or `varchar(n)` |
| `char` | Fixed-length string | Bare or `char(n)` |
| `binary` | Byte array | |
| `date` | ISO 8601 date (no time) | |
| `timestamp` | Date + time (nanosecond precision) | |

### Complex Types (4 families)

| Type | Example | Notes |
|------|---------|-------|
| `array<T>` | `array<string>` | Single element type |
| `map<K,V>` | `map<string,bigint>` | Key-value pairs |
| `struct<f:T,...>` | `struct<id:bigint,name:string>` | Named fields |
| `uniontype<T,...>` | `uniontype<int,string>` | Tagged union |

**Alternatives considered**:
- `integer` (synonym for `int`) — not added; Glue normalises to `int` and existing YAMLs use `int`.
- `interval` — technically valid in Hive but not supported by Athena; excluded to prevent user confusion.

---

## 3. JSON Schema Validation Strategy for Column Types

**Decision**: Replace the `enum` on `spec.schema.columns[].type` with a `pattern` (single regex) that covers all 14 primitives (bare + optional parameters) and all 4 complex type families.

**Rationale**:
- A fixed `enum` cannot express parameterised types like `decimal(10,2)`, `varchar(255)`, or `array<string>` — these would all fail validation.
- A single `pattern` is simpler and more maintainable than `anyOf` with multiple sub-schemas.
- JSON Schema Draft-07 uses ECMA 262 regex, which supports `\d` and `\s` — sufficient for this pattern.

**Chosen pattern**:
```
^(boolean|tinyint|smallint|int|bigint|float|double|decimal(\(\d+,\s*\d+\))?|string|varchar(\(\d+\))?|char(\(\d+\))?|binary|date|timestamp|(array|map|struct|uniontype)<.+>)$
```

In JSON-serialised form (backslash-escaped):
```json
"^(boolean|tinyint|smallint|int|bigint|float|double|decimal(\\(\\d+,\\s*\\d+\\))?|string|varchar(\\(\\d+\\))?|char(\\(\\d+\\))?|binary|date|timestamp|(array|map|struct|uniontype)<.+>)$"
```

**What this pattern accepts**:
- All 14 bare primitive names
- `decimal(10,2)`, `decimal(38, 10)` (optional precision/scale)
- `varchar(255)`, `varchar(65535)` (optional length)
- `char(1)`, `char(255)` (optional length)
- `array<string>`, `array<struct<id:bigint,name:string>>` (complex, recursive)
- `map<string,bigint>`, `struct<id:bigint,flag:boolean>`, `uniontype<int,string>`

**What this pattern rejects**:
- `foobar` (unknown type)
- `array<>` (empty type parameter)
- `decimal(abc)` (non-numeric precision)

**Alternatives considered**:
- `anyOf` with enum + multiple patterns — achieves the same result but is more verbose and harder to scan.
- No validation at schema level (rely entirely on Glue) — rejected; early validation prevents costly Terraform plan/apply errors.

---

## 4. Backward Compatibility

**Decision**: The pattern is a strict superset of the existing 7-type enum.

**Verification**: All 7 current types (`string`, `int`, `bigint`, `double`, `boolean`, `timestamp`, `date`) match the new pattern. Running a regex match against each confirms zero regressions for existing Table YAMLs.

---

## 5. E2E Verifier Impact

**Decision**: The E2E verifier Lambda MUST be extended to test the Parquet path end-to-end.

**Rationale**: The existing three E2E tables (`e2e_csv`, `e2e_json`, `e2e_avro`) each have a matching Lambda code path that serialises `SAMPLE_ROWS`, uploads to S3, queries via Athena, and validates results. Without an equivalent Parquet path, a SerDe misconfiguration or Glue table creation error on Parquet tables would go undetected in production (FR-008, User Story 4).

**Required changes**:

| Component | Change |
|-----------|--------|
| `requirements.txt` | Add `pyarrow==<latest stable>` (same bundling approach as `fastavro`) |
| `handler.py` — `_TABLE_EXT` map | Add `"e2e_parquet": "parquet"` entry so the upload key is `…/data.parquet` |
| `handler.py` — `tables` list | Add `"e2e_parquet"` so the table participates in write, query, and cleanup phases |
| `handler.py` — `serialize_parquet()` | New function: writes `SAMPLE_ROWS` to an `io.BytesIO` buffer using `pyarrow.Table.from_pylist` + `pyarrow.parquet.write_table` |
| `handler.py` — `write_table()` | Add `elif ext == "parquet": buf = serialize_parquet()` branch |
| `handler.py` — assume-role failure path | Add `"e2e_parquet"` to the list of tables immediately marked FAIL when assume-role fails |
| `s3/platform/e2e_parquet.yaml` | New Table YAML with `format: parquet` and the standard 4-column schema (`id int`, `name string`, `value double`, `active boolean`) — this is a permanent file (FR-007) |

**Alternatives considered**:
- Pandas + `to_parquet()` — requires `pandas` + `pyarrow` (larger ZIP); `pyarrow` alone suffices.
- `fastparquet` — less compatible with Athena/Hive metadata; `pyarrow` is the reference implementation for Hive Parquet.
