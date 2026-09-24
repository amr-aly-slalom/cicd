import csv
import io
import json
import logging
import os
import time
from uuid import uuid4

import boto3
import fastavro
import pyarrow as pa
import pyarrow.parquet as pq

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SAMPLE_ROWS = [
    {"id": 1, "name": "alpha", "value": 1.1, "active": True},
    {"id": 2, "name": "beta", "value": 2.2, "active": False},
    {"id": 3, "name": "gamma", "value": 3.3, "active": True},
]
_AVRO_SCHEMA = {
    "type": "record",
    "name": "E2ERecord",
    "fields": [
        {"name": "id", "type": "int"},
        {"name": "name", "type": "string"},
        {"name": "value", "type": "double"},
        {"name": "active", "type": "boolean"},
    ],
}

_TABLE_EXT = {
    "e2e_csv": "csv",
    "e2e_json": "json",
    "e2e_avro": "avro",
    "e2e_parquet": "parquet",
}


def generate_run_uuid():
    return str(uuid4())


def assume_namespace_role(sts_client):
    response = sts_client.assume_role(
        RoleArn=os.environ["NAMESPACE_ROLE_ARN"],
        RoleSessionName="s3-e2e-verifier",
    )
    creds = response["Credentials"]
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"],
    }


def serialize_csv(rows):
    buf = io.BytesIO()
    wrapper = io.TextIOWrapper(buf, encoding="utf-8", newline="")
    writer = csv.DictWriter(wrapper, fieldnames=["id", "name", "value", "active"])
    writer.writeheader()
    writer.writerows(rows)
    wrapper.flush()
    wrapper.detach()
    buf.seek(0)
    return buf


def serialize_json(rows):
    buf = io.BytesIO()
    for row in rows:
        buf.write((json.dumps(row) + "\n").encode("utf-8"))
    buf.seek(0)
    return buf


def serialize_avro(rows):
    buf = io.BytesIO()
    parsed_schema = fastavro.parse_schema(_AVRO_SCHEMA)
    fastavro.writer(buf, parsed_schema, rows)
    buf.seek(0)
    return buf


def serialize_parquet():
    table = pa.Table.from_pylist(SAMPLE_ROWS)
    buf = io.BytesIO()
    pq.write_table(table, buf)
    buf.seek(0)
    return buf


def write_table(table_name, rows, run_uuid, s3_client):
    ext = _TABLE_EXT[table_name]
    if table_name == "e2e_csv":
        data = serialize_csv(rows)
    elif table_name == "e2e_json":
        data = serialize_json(rows)
    elif ext == "parquet":
        data = serialize_parquet()
    else:
        data = serialize_avro(rows)

    key = f"platform/{table_name}/{run_uuid}/data.{ext}"
    logger.info(f"Writing S3 object [{key}]...")
    try:
        s3_client.put_object(
            Bucket=os.environ["LANDING_BUCKET"],
            Key=key,
            Body=data,
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=os.environ.get("KMS_KEY_ARN", "alias/aws/s3"),
        )
    except Exception as exc:
        logger.error(f"Failed to write S3 object [{key}]: [{exc}].")
        raise
    logger.info(f"Wrote S3 object [{key}].")
    return key


def athena_query_poll(query_execution_id, athena_client, timeout_seconds):
    deadline = time.time() + timeout_seconds
    while True:
        resp = athena_client.get_query_execution(QueryExecutionId=query_execution_id)
        state = resp["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            logger.info(f"Athena query [{query_execution_id}] finished successfully.")
            return
        if state in ("FAILED", "CANCELLED"):
            reason = resp["QueryExecution"]["Status"].get("StateChangeReason", "")
            logger.error(f"Athena query [{query_execution_id}] finished with failure: [{reason}].")
            raise RuntimeError(
                f"Athena query {query_execution_id} ended with state {state}: {reason}"
            )
        if time.time() >= deadline:
            athena_client.stop_query_execution(QueryExecutionId=query_execution_id)
            logger.error(f"Athena query [{query_execution_id}] timed out after [{timeout_seconds}s].")
            raise TimeoutError(
                f"Athena query {query_execution_id} timed out after {timeout_seconds}s"
            )
        time.sleep(2)


def query_table(table_name, athena_client):
    db = os.environ["GLUE_DATABASE"]
    workgroup = os.environ["ATHENA_WORKGROUP"]
    timeout = int(os.environ.get("ATHENA_QUERY_TIMEOUT_SECONDS", "90"))
    ids = ",".join(str(r["id"]) for r in SAMPLE_ROWS)
    sql = f"SELECT * FROM {db}.{table_name} WHERE id IN ({ids}) ORDER BY id"

    attempt = 0
    while True:
        attempt += 1
        logger.info(f"Submitting Athena query [{sql}] (attempt [{attempt}])...")
        resp = athena_client.start_query_execution(
            QueryString=sql,
            WorkGroup=workgroup,
        )
        qid = resp["QueryExecutionId"]
        try:
            athena_query_poll(qid, athena_client, timeout)
            break
        except RuntimeError:
            if attempt >= 2:
                raise
            logger.warning(f"Retrying Athena query for [{table_name}] after failed attempt [{attempt}].")
            time.sleep(2)

    results = athena_client.get_query_results(QueryExecutionId=qid)
    rows = results["ResultSet"]["Rows"]
    if not rows:
        return []

    headers = [c["VarCharValue"] for c in rows[0]["Data"]]
    output = []
    for row in rows[1:]:
        values = [c.get("VarCharValue", "") for c in row["Data"]]
        output.append(dict(zip(headers, values)))
    return output


def _coerce_row(raw_row):
    return {
        "id": int(raw_row["id"]),
        "name": raw_row["name"],
        "value": float(raw_row["value"]),
        "active": raw_row["active"].lower() in ("true", "1"),
    }


def validate_results(generated_rows, athena_rows):
    if len(athena_rows) != len(generated_rows):
        return False, f"Row count mismatch: expected {len(generated_rows)}, got {len(athena_rows)}"

    try:
        coerced = sorted([_coerce_row(r) for r in athena_rows], key=lambda r: r["id"])
    except Exception as exc:
        return False, f"Failed to coerce Athena results: {exc}"

    expected = sorted(generated_rows, key=lambda r: r["id"])

    expected_cols = sorted(expected[0].keys())
    actual_cols = sorted(coerced[0].keys())
    if expected_cols != actual_cols:
        return False, f"Column mismatch: expected {expected_cols}, got {actual_cols}"

    for i, (exp, act) in enumerate(zip(expected, coerced)):
        if exp != act:
            return False, f"Row {i} mismatch: expected {exp}, got {act}"

    return True, None


def cleanup_table(table_name, run_uuid, s3_client):
    ext = _TABLE_EXT[table_name]
    key = f"platform/{table_name}/{run_uuid}/data.{ext}"
    logger.info(f"Deleting S3 object [{key}]...")
    try:
        s3_client.delete_object(Bucket=os.environ["LANDING_BUCKET"], Key=key)
        logger.info(f"Deleted S3 object [{key}].")
        return True, None
    except Exception as exc:
        logger.error(f"Failed to delete S3 object [{key}]: [{exc}].")
        return False, f"{key}: {exc}"


def publish_metrics(test_success, cleanup_success, cw_client):
    env = os.environ["ENVIRONMENT"]
    cw_client.put_metric_data(
        Namespace="ChedawsEDP/S3E2EVerifier",
        MetricData=[
            {
                "MetricName": "S3E2ETestSuccess",
                "Dimensions": [{"Name": "Environment", "Value": env}],
                "Value": 1 if test_success else 0,
                "Unit": "Count",
            },
            {
                "MetricName": "S3E2ECleanupSuccess",
                "Dimensions": [{"Name": "Environment", "Value": env}],
                "Value": 1 if cleanup_success else 0,
                "Unit": "Count",
            },
        ],
    )


def lambda_handler(event, context):
    start = time.time()

    sts = boto3.client("sts")
    cw = boto3.client("cloudwatch")

    run_uuid = generate_run_uuid()
    table_results = []
    written_keys = {}

    # Assume namespace role for S3 writes and Athena queries
    try:
        domain_creds = assume_namespace_role(sts)
        domain_s3 = boto3.client("s3", **domain_creds)
        domain_athena = boto3.client("athena", **domain_creds)
    except Exception as exc:
        duration_ms = int((time.time() - start) * 1000)
        logger.error(f"Role assumption failed: [{exc}].")
        result = {
            "run_id": run_uuid,
            "status": "FAIL",
            "tables": [
                {"name": t, "outcome": "FAIL", "phase": "write", "detail": f"assume_role failed: {exc}"}
                for t in ["e2e_csv", "e2e_json", "e2e_avro", "e2e_parquet"]
            ],
            "cleanup": {"outcome": "SUCCESS", "errors": []},
            "duration_ms": duration_ms,
        }
        publish_metrics(False, True, cw)
        logger.info(json.dumps(result))
        return result

    tables = ["e2e_csv", "e2e_json", "e2e_avro", "e2e_parquet"]

    # Write phase
    for table in tables:
        try:
            key = write_table(table, SAMPLE_ROWS, run_uuid, domain_s3)
            written_keys[table] = key
        except Exception as exc:
            table_results.append({"name": table, "outcome": "FAIL", "phase": "write", "detail": str(exc)})

    # Query + validate phase (only for successfully written tables)
    for table in tables:
        if table in [r["name"] for r in table_results]:
            continue
        try:
            athena_rows = query_table(table, domain_athena)
            passed, detail = validate_results(SAMPLE_ROWS, athena_rows)
            table_results.append({
                "name": table,
                "outcome": "PASS" if passed else "FAIL",
                "phase": "validate",
                "detail": detail,
            })
        except Exception as exc:
            table_results.append({"name": table, "outcome": "FAIL", "phase": "query", "detail": str(exc)})

    # Cleanup phase (always, using namespace role)
    cleanup_errors = []
    for table, key in written_keys.items():
        success, err = cleanup_table(table, run_uuid, domain_s3)
        if not success:
            cleanup_errors.append(err)

    test_success = all(r["outcome"] == "PASS" for r in table_results)
    cleanup_success = len(cleanup_errors) == 0

    publish_metrics(test_success, cleanup_success, cw)

    duration_ms = int((time.time() - start) * 1000)
    result = {
        "run_id": run_uuid,
        "status": "PASS" if test_success else "FAIL",
        "tables": table_results,
        "cleanup": {
            "outcome": "SUCCESS" if cleanup_success else "FAIL",
            "errors": cleanup_errors,
        },
        "duration_ms": duration_ms,
    }
    logger.info(json.dumps(result))
    return result
