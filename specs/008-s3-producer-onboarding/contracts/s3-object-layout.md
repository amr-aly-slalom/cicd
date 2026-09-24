# Contract: S3 Object Layout

## Test Data Objects (written by Lambda, deleted by Lambda)

**Bucket**: `chedaws-edp-landing-bucket-<env>`

```
platform/
├── e2e_csv/<run_uuid>/data.csv      ← CSV with header row, 3 data rows
├── e2e_json/<run_uuid>/data.json    ← NDJSON, 3 lines
└── e2e_avro/<run_uuid>/data.avro   ← Avro binary, 3 records
```

- `<run_uuid>` is generated fresh per invocation (`uuid4()`).
- All objects are encrypted with `alias/chedaws-edp-s3-<env>` (KMS SSE).
- Objects are written using assumed credentials from `edp-<env>-s3-producer-platform`.
- Objects are deleted using the Lambda execution role after validation (phase 6 in handler).
- In the event of cleanup failure, objects remain under their UUID prefix and do not affect subsequent runs (hermetic `WHERE id IN (...)` filter).

---

## Athena Query Result Objects (written by Athena, expired by lifecycle rule)

**Bucket**: `chedaws-edp-landing-bucket-<env>`

```
athena-query-results/
└── e2e/
    └── <QueryExecutionId>.csv
    └── <QueryExecutionId>.csv.metadata
```

- Written by Athena when the Lambda runs queries via workgroup `edp-e2e-<env>`.
- Also written when engineers run ad-hoc queries in the Athena console using the `edp-e2e-<env>` workgroup.
- Expired after **7 days** by the `athena-query-results-e2e-expiry` lifecycle rule on `module.landing_s3`.

---

## Glue Table Locations (provisioned by this feature, read by Athena)

| Glue Table | S3 Location |
|---|---|
| `edp_<env>_platform.e2e_csv` | `s3://chedaws-edp-landing-bucket-<env>/platform/e2e_csv/` |
| `edp_<env>_platform.e2e_json` | `s3://chedaws-edp-landing-bucket-<env>/platform/e2e_json/` |
| `edp_<env>_platform.e2e_avro` | `s3://chedaws-edp-landing-bucket-<env>/platform/e2e_avro/` |
