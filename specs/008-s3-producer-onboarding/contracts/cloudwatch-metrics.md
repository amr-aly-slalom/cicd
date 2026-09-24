# Contract: CloudWatch Custom Metrics

**Namespace**: `ChedawsEDP/S3E2EVerifier`  
**Published by**: `chedaws-edp-s3-e2e-verifier-<env>` Lambda, via `cloudwatch:PutMetricData`  
**Published on**: Every Lambda invocation (scheduled daily at 06:00 UTC)

---

## Metric: S3E2ETestSuccess

| Field | Value |
|---|---|
| MetricName | `S3E2ETestSuccess` |
| Unit | `Count` |
| Value | `1` (all three tables passed validation) or `0` (one or more tables failed) |
| Dimensions | `Environment = <env>` |

**Alarm**: `chedaws-edp-s3-e2e-validation-failure-<env>`  
- Threshold: Minimum < 1  
- Period: 86400 s, Evaluation periods: 1  
- `treat_missing_data`: `breaching` (no metric = Lambda did not run = alarm)

---

## Metric: S3E2ECleanupSuccess

| Field | Value |
|---|---|
| MetricName | `S3E2ECleanupSuccess` |
| Unit | `Count` |
| Value | `1` (all S3 delete operations succeeded) or `0` (one or more deletes failed) |
| Dimensions | `Environment = <env>` |

**Alarm**: `chedaws-edp-s3-e2e-cleanup-failure-<env>`  
- Threshold: Minimum < 1  
- Period: 86400 s, Evaluation periods: 1  
- `treat_missing_data`: `notBreaching` (no metric = Lambda did not run; covered by validation alarm)

---

## Structured Log Schema

Each invocation emits one JSON log line to `/chedaws-edp/s3-e2e-verifier/<env>`:

```json
{
  "run_id": "<uuid4>",
  "status": "PASS | FAIL",
  "tables": [
    {
      "name": "e2e_csv | e2e_json | e2e_avro",
      "outcome": "PASS | FAIL",
      "phase": "write | query | validate | cleanup",
      "detail": "<error message or null>"
    }
  ],
  "cleanup": {
    "outcome": "SUCCESS | FAIL",
    "errors": ["<optional list of S3 key + error pairs>"]
  },
  "duration_ms": 12345
}
```
