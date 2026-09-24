import json
import logging
import os
import time
from uuid import uuid4

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SAMPLE_ROWS = [
    {"id": 1, "name": "alpha", "value": 1.1, "active": True},
    {"id": 2, "name": "beta", "value": 2.2, "active": False},
    {"id": 3, "name": "gamma", "value": 3.3, "active": True},
]

def generate_run_uuid():
    return str(uuid4())

def assume_namespace_role(sts_client):
    response = sts_client.assume_role(
        RoleArn=os.environ["NAMESPACE_ROLE_ARN"],
        RoleSessionName="s3tables-e2e-verifier",
    )
    creds = response["Credentials"]
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"],
    }

def _get_region():
    """
    Region that holds the table bucket AND the s3tablescatalog federation.

    The S3 Tables -> Glue integration is per account AND per Region. If this
    Lambda runs in a different Region than the table bucket, the catalog will
    not exist from Athena's point of view.
    """
    return os.environ.get("TABLE_BUCKET_REGION") or os.environ["AWS_REGION"]

def _get_catalog():
    """
    Returns the S3 Tables catalog identifier registered in Glue Data Catalog.

    Enabling the integration creates a parent federated catalog named
    's3tablescatalog', with one child catalog per table bucket named
    's3tablescatalog/<bucket>'.

    Overrides:
      * GLUE_CATALOG_NAME       - use this exact catalog name verbatim.
      * TABLE_BUCKET_ACCOUNT_ID - prefix with '<account-id>:' which is required
                                  when the table bucket lives in a different
                                  account than the caller.
    """
    override = os.environ.get("GLUE_CATALOG_NAME")
    if override:
        return override

    bucket = os.environ["TABLE_BUCKET_NAME"]
    catalog = f"s3tablescatalog/{bucket}"

    account_id = os.environ.get("TABLE_BUCKET_ACCOUNT_ID")
    if account_id:
        catalog = f"{account_id}:{catalog}"
    return catalog

def preflight_check(creds):
    """
    Verifies the Glue catalog and namespace are visible to the assumed role
    BEFORE any Athena call, so failures name the actual missing resource
    instead of surfacing as an opaque "Catalog does not exist" from Athena.

    Both are provisioned by Terraform from the s3tables/ registry, so a
    failure here is a configuration problem, never something to create at
    runtime.

    The table is deliberately NOT checked here. This verifier owns the table
    now (see ensure_table_exists) and creates it on demand - a missing table is
    the expected state on first run, not a failure.

    Raises RuntimeError with an actionable message.
    """
    region = _get_region()
    catalog = _get_catalog()
    namespace = os.environ["TABLE_NAMESPACE"]
    bucket = os.environ["TABLE_BUCKET_NAME"]

    glue = boto3.client("glue", region_name=region, **creds)
    sts_ident = boto3.client("sts", region_name=region, **creds)

    identity = sts_ident.get_caller_identity()
    logger.info(
        f"Preflight: caller=[{identity['Arn']}] account=[{identity['Account']}] "
        f"region=[{region}] catalog=[{catalog}] namespace=[{namespace}]."
    )

    # 1. Is the per-bucket child catalog present and visible to this role?
    try:
        glue.get_catalog(CatalogId=catalog)
        logger.info(f"Preflight: catalog [{catalog}] resolved.")
    except AttributeError:
        # Older bundled boto3 without get_catalog; skip this probe.
        logger.warning(
            f"Preflight: boto3 in this runtime has no glue.get_catalog; "
            f"skipping catalog probe for [{catalog}]. Bundle a newer boto3 for better errors."
        )
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        logger.error(f"Preflight: catalog [{catalog}] not resolvable (Glue error: [{code}]).")
        raise RuntimeError(
            f"Glue catalog '{catalog}' is not resolvable from role "
            f"{identity['Arn']} in region {region} (Glue error: {code}). "
            "Check, in order: (1) S3 Tables integration with Glue Data Catalog "
            f"is enabled in account {identity['Account']} region {region}; "
            f"(2) table bucket '{bucket}' exists in that same region and the "
            "name matches exactly; (3) the role has glue:GetCatalog plus Lake "
            "Formation permissions on the catalog resource; (4) if the bucket "
            "is in another account, set TABLE_BUCKET_ACCOUNT_ID."
        ) from exc

    # 2. Is the namespace (database) present and visible to this role?
    try:
        glue.get_database(CatalogId=catalog, Name=namespace)
        logger.info(f"Preflight: namespace [{namespace}] resolved.")
    except ClientError as exc:
        code = exc.response["Error"]["Code"]
        logger.error(
            f"Preflight: namespace [{namespace}] not resolvable in catalog [{catalog}] "
            f"(Glue error: [{code}])."
        )
        raise RuntimeError(
            f"Namespace '{namespace}' is not resolvable in catalog '{catalog}' "
            f"(Glue error: {code}). The namespace is created by Terraform from "
            "s3tables/namespaces/<name>.yaml - check that the namespace file "
            "lists this environment in spec.environments, and that the role "
            "has glue:GetDatabase on the federated catalog."
        ) from exc

def _fully_qualified_table(quote):
    """
    Returns the fully qualified 3-part table reference using the given quote
    character:
        <q>s3tablescatalog/<bucket><q>.<q><namespace><q>.<q><table><q>

    The catalog name contains a '/', so every part MUST be quoted. Using the
    3-part name makes the reference unambiguous instead of relying on Athena to
    resolve it from QueryExecutionContext.

    Athena uses two different parsers, and they disagree on quoting:
      * DDL (CREATE TABLE)      -> Hive parser, wants backticks.
      * DML (INSERT/SELECT/...) -> Trino parser, rejects backticks with
        "backquoted identifiers are not supported; use double quotes".
    Use _ddl_table() and _dml_table() rather than calling this directly.
    """
    catalog = _get_catalog()
    namespace = os.environ["TABLE_NAMESPACE"]
    table = os.environ["TABLE_NAME"]
    q = quote
    return f"{q}{catalog}{q}.{q}{namespace}{q}.{q}{table}{q}"

def _ddl_table():
    """Backquoted reference for DDL statements (CREATE TABLE)."""
    return _fully_qualified_table("`")

def _dml_table():
    """Double-quoted reference for DML statements (INSERT, SELECT, DELETE)."""
    return _fully_qualified_table('"')

def athena_query_poll(query_execution_id, athena_client, timeout_seconds):
    """Polls Athena until the query completes, fails, or times out."""
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

def execute_athena_query(sql, athena_client, timeout_seconds, expect_results=False):
    """Executes an Athena query and optionally returns results."""
    workgroup = os.environ["ATHENA_WORKGROUP"]
    catalog = _get_catalog()

    logger.info(f"Submitting Athena query [{sql}]...")
    resp = athena_client.start_query_execution(
        QueryString=sql,
        WorkGroup=workgroup,
        QueryExecutionContext={
            "Catalog": catalog,
            "Database": os.environ["TABLE_NAMESPACE"],
        },
    )
    qid = resp["QueryExecutionId"]
    athena_query_poll(qid, athena_client, timeout_seconds)

    if not expect_results:
        return qid, []

    results = athena_client.get_query_results(QueryExecutionId=qid)
    rows = results["ResultSet"]["Rows"]
    if not rows:
        return qid, []

    headers = [c["VarCharValue"] for c in rows[0]["Data"]]
    output = []
    for row in rows[1:]:
        values = [c.get("VarCharValue", "") for c in row["Data"]]
        output.append(dict(zip(headers, values)))
    return qid, output

def ensure_table_exists(athena_client, timeout_seconds):
    """
    Creates the Iceberg table in the S3 table bucket if it does not already
    exist. This verifier owns the table (Terraform no longer does) - first run
    creates it, every subsequent run is a no-op via IF NOT EXISTS.

    Notes:
      * table_type = 'ICEBERG' is REQUIRED. Without it Athena parses this as a
        Hive table and rejects the statement with
        "No location was specified for table. An S3 location must be specified".
      * No LOCATION clause: S3 Tables manages the underlying storage.
      * All identifiers and column names must be lowercase for Glue/Lake
        Formation compatibility.
    """
    fq_table = _ddl_table()

    sql = f"""CREATE TABLE IF NOT EXISTS {fq_table} (
        id int,
        name string,
        value double,
        active boolean,
        run_id string
    )
    TBLPROPERTIES ('table_type' = 'ICEBERG')"""

    execute_athena_query(sql, athena_client, timeout_seconds)
    logger.info(f"Table [{fq_table}] ready.")

def insert_test_data(rows, run_uuid, athena_client, timeout_seconds):
    """Inserts test rows into the Iceberg table via Athena INSERT."""
    fq_table = _dml_table()

    select_clauses = []
    for row in rows:
        active_str = "true" if row["active"] else "false"
        select_clauses.append(
            "SELECT "
            f"{int(row['id'])}, "
            f"'{row['name']}', "
            f"CAST({float(row['value'])} AS double), "
            f"{active_str}, "
            f"'{run_uuid}'"
        )

    sql = f"INSERT INTO {fq_table} {' UNION ALL '.join(select_clauses)}"
    execute_athena_query(sql, athena_client, timeout_seconds)
    logger.info(f"Inserted [{len(rows)}] rows with run_id [{run_uuid}].")

def query_test_data(run_uuid, athena_client, timeout_seconds):
    """Queries back the test rows for the given run_id."""
    fq_table = _dml_table()
    sql = (
        f"SELECT id, name, value, active FROM {fq_table} "
        f"WHERE run_id = '{run_uuid}' ORDER BY id"
    )
    _, results = execute_athena_query(
        sql, athena_client, timeout_seconds, expect_results=True
    )
    logger.info(f"Queried [{len(results)}] rows with run_id [{run_uuid}].")
    return results

def cleanup_test_data(run_uuid, athena_client, timeout_seconds):
    """Deletes test rows for the given run_id from the Iceberg table."""
    fq_table = _dml_table()
    sql = f"DELETE FROM {fq_table} WHERE run_id = '{run_uuid}'"
    execute_athena_query(sql, athena_client, timeout_seconds)
    logger.info(f"Cleaned up rows with run_id [{run_uuid}].")

def _coerce_row(raw_row):
    """Coerces Athena string results back to typed values for comparison."""
    return {
        "id": int(raw_row["id"]),
        "name": raw_row["name"],
        "value": float(raw_row["value"]),
        "active": raw_row["active"].lower() in ("true", "1"),
    }

def validate_results(generated_rows, athena_rows):
    """Validates that Athena results match the expected rows."""
    if len(athena_rows) != len(generated_rows):
        return False, (
            f"Row count mismatch: expected {len(generated_rows)}, "
            f"got {len(athena_rows)}"
        )

    try:
        coerced = sorted([_coerce_row(r) for r in athena_rows], key=lambda r: r["id"])
    except Exception as exc:
        return False, f"Failed to coerce Athena results: {exc}"

    expected = sorted(generated_rows, key=lambda r: r["id"])

    for i, (exp, act) in enumerate(zip(expected, coerced)):
        if exp != act:
            return False, f"Row {i} mismatch: expected {exp}, got {act}"

    return True, None

def publish_metrics(test_success, cleanup_success, cw_client):
    """Publishes E2E test metrics to CloudWatch."""
    env = os.environ["ENVIRONMENT"]
    cw_client.put_metric_data(
        Namespace="ChedawsEDP/S3TablesE2EVerifier",
        MetricData=[
            {
                "MetricName": "S3TablesE2ETestSuccess",
                "Dimensions": [{"Name": "Environment", "Value": env}],
                "Value": 1 if test_success else 0,
                "Unit": "Count",
            },
            {
                "MetricName": "S3TablesE2ECleanupSuccess",
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
    timeout = int(os.environ.get("ATHENA_QUERY_TIMEOUT_SECONDS", "90"))

    # Phase: Assume role
    try:
        domain_creds = assume_namespace_role(sts)
        domain_athena = boto3.client(
            "athena", region_name=_get_region(), **domain_creds
        )
    except Exception as exc:
        duration_ms = int((time.time() - start) * 1000)
        logger.error(f"Role assumption for run [{run_uuid}] failed: [{exc}].")
        result = {
            "run_id": run_uuid,
            "status": "FAIL",
            "phase": "assume_role",
            "detail": str(exc),
            "cleanup": {"outcome": "SKIPPED", "detail": "No data written"},
            "duration_ms": duration_ms,
        }
        publish_metrics(False, True, cw)
        logger.info(json.dumps(result))
        return result

    # Phase: Preflight (catalog + namespace visibility)
    try:
        preflight_check(domain_creds)
    except Exception as exc:
        duration_ms = int((time.time() - start) * 1000)
        logger.error(f"Preflight check for run [{run_uuid}] failed: [{exc}].")
        result = {
            "run_id": run_uuid,
            "status": "FAIL",
            "phase": "preflight",
            "detail": str(exc),
            "cleanup": {"outcome": "SKIPPED", "detail": "No data written"},
            "duration_ms": duration_ms,
        }
        publish_metrics(False, True, cw)
        logger.info(json.dumps(result))
        return result

    # Phase: Ensure table exists (creates on first run, no-op afterward)
    try:
        ensure_table_exists(domain_athena, timeout)
    except (ClientError, RuntimeError, TimeoutError) as exc:
        duration_ms = int((time.time() - start) * 1000)
        logger.error(f"Table creation for run [{run_uuid}] failed: [{exc}].")
        result = {
            "run_id": run_uuid,
            "status": "FAIL",
            "phase": "create_table",
            "detail": str(exc),
            "cleanup": {"outcome": "SKIPPED", "detail": "No data written"},
            "duration_ms": duration_ms,
        }
        publish_metrics(False, True, cw)
        logger.info(json.dumps(result))
        return result

    # Phase: Insert test data
    try:
        insert_test_data(SAMPLE_ROWS, run_uuid, domain_athena, timeout)
    except Exception as exc:
        duration_ms = int((time.time() - start) * 1000)
        logger.error(f"Insert for run [{run_uuid}] failed: [{exc}].")
        result = {
            "run_id": run_uuid,
            "status": "FAIL",
            "phase": "insert",
            "detail": str(exc),
            "cleanup": {
                "outcome": "SKIPPED",
                "detail": "Insert failed; no data to clean",
            },
            "duration_ms": duration_ms,
        }
        publish_metrics(False, True, cw)
        logger.info(json.dumps(result))
        return result

    # Phase: Query and validate
    test_success = False
    test_detail = None
    try:
        athena_rows = query_test_data(run_uuid, domain_athena, timeout)
        test_success, test_detail = validate_results(SAMPLE_ROWS, athena_rows)
    except Exception as exc:
        logger.error(f"Query for run [{run_uuid}] failed: [{exc}].")
        test_detail = f"Query failed: {exc}"

    # Phase: Cleanup (always attempt if insert succeeded)
    cleanup_success = False
    cleanup_detail = None
    try:
        cleanup_test_data(run_uuid, domain_athena, timeout)
        cleanup_success = True
    except Exception as exc:
        logger.error(f"Cleanup for run [{run_uuid}] failed: [{exc}].")
        cleanup_detail = f"Cleanup failed: {exc}"

    publish_metrics(test_success, cleanup_success, cw)

    duration_ms = int((time.time() - start) * 1000)
    result = {
        "run_id": run_uuid,
        "status": "PASS" if test_success else "FAIL",
        "phase": "validate",
        "detail": test_detail,
        "cleanup": {
            "outcome": "SUCCESS" if cleanup_success else "FAIL",
            "detail": cleanup_detail,
        },
        "duration_ms": duration_ms,
    }
    logger.info(json.dumps(result))
    return result
