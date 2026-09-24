import json
import logging
import os
import time
from uuid import uuid4

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

METRICS_NAMESPACE = os.environ.get("METRICS_NAMESPACE", "LakeFormationPermissionsVerifier")

SAMPLE_ROWS = [
    {"id": 1, "name": "alpha", "value": 1.1, "active": True},
    {"id": 2, "name": "beta", "value": 2.2, "active": False},
]

MECHANISMS = (
    {
        "key": "resource_permission",
        "label": "Named Data Catalog Resource Permission",
        "role_env_var": "TARGET_ROLE_ARN_RESOURCE_PERMISSION",
        "session_name": "lf-verifier-target-resource-permission",
        "metric_prefix": "ResourcePermission",
    },
    {
        "key": "lf_tag",
        "label": "LF-Tag Based Permission",
        "role_env_var": "TARGET_ROLE_ARN_LF_TAG",
        "session_name": "lf-verifier-target-lf-tag",
        "metric_prefix": "LfTag",
    },
)


def generate_run_uuid():
    return str(uuid4())


def _assume_role(sts_client, role_arn, session_name):
    response = sts_client.assume_role(RoleArn=role_arn, RoleSessionName=session_name)
    creds = response["Credentials"]
    return {
        "aws_access_key_id": creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token": creds["SessionToken"],
    }


def assume_setup_role(sts_client):
    return _assume_role(
        sts_client, os.environ["SETUP_ROLE_ARN"], "lf-verifier-setup"
    )


def assume_target_roles(sts_client):
    return {
        mechanism["key"]: _assume_role(
            sts_client, os.environ[mechanism["role_env_var"]], mechanism["session_name"]
        )
        for mechanism in MECHANISMS
    }


def athena_query_poll(query_execution_id, athena_client, timeout_seconds):
    deadline = time.time() + timeout_seconds
    while True:
        resp = athena_client.get_query_execution(QueryExecutionId=query_execution_id)
        state = resp["QueryExecution"]["Status"]["State"]
        if state == "SUCCEEDED":
            return None
        if state in ("FAILED", "CANCELLED"):
            reason = resp["QueryExecution"]["Status"].get("StateChangeReason", "")
            return reason
        if time.time() >= deadline:
            athena_client.stop_query_execution(QueryExecutionId=query_execution_id)
            raise TimeoutError(
                f"Athena query {query_execution_id} timed out after {timeout_seconds}s"
            )
        time.sleep(2)


def execute_athena_query(
    sql, athena_client, workgroup, catalog, database, timeout_seconds, expect_results=False
):
    logger.info(f"Submitting Athena query [{sql}]...")
    resp = athena_client.start_query_execution(
        QueryString=sql,
        WorkGroup=workgroup,
        QueryExecutionContext={"Catalog": catalog, "Database": database},
    )
    qid = resp["QueryExecutionId"]
    try:
        failure_reason = athena_query_poll(qid, athena_client, timeout_seconds)
    except TimeoutError:
        logger.error(f"Athena query [{qid}] timed out.")
        raise

    if failure_reason:
        logger.info(f"Athena query [{qid}] finished with failure: [{failure_reason}].")
    else:
        logger.info(f"Athena query [{qid}] finished successfully.")

    if failure_reason or not expect_results:
        return qid, failure_reason, []

    results = athena_client.get_query_results(QueryExecutionId=qid)
    rows = results["ResultSet"]["Rows"]
    if not rows:
        return qid, None, []

    headers = [c["VarCharValue"] for c in rows[0]["Data"]]
    output = []
    for row in rows[1:]:
        values = [c.get("VarCharValue", "") for c in row["Data"]]
        output.append(dict(zip(headers, values)))
    return qid, None, output


def _athena_catalog(catalog_id):
    return catalog_id.split(":", 1)[1] if ":" in catalog_id else catalog_id


def _is_access_denied(failure_reason):
    if not failure_reason:
        return False
    lowered = failure_reason.lower()
    return any(
        marker in lowered
        for marker in (
            "access denied",
            "accessdenied",
            "not authorized",
            "insufficient lake formation permission",
            "permission",
        )
    )


def s3tables_fq_table(quote):
    catalog = _athena_catalog(os.environ["S3TABLES_CATALOG_ID"])
    database = os.environ["S3TABLES_DATABASE_NAME"]
    table = os.environ["S3TABLES_TABLE_NAME"]
    return f"{quote}{catalog}{quote}.{quote}{database}{quote}.{quote}{table}{quote}"


def s3tables_ensure_table_exists(athena_client, workgroup, timeout_seconds):
    fq_table = s3tables_fq_table("`")
    sql = f"""CREATE TABLE IF NOT EXISTS {fq_table} (
        id int,
        name string,
        value double,
        active boolean,
        run_id string
    )
    TBLPROPERTIES ('table_type' = 'ICEBERG')"""

    _, failure_reason, _ = execute_athena_query(
        sql,
        athena_client,
        workgroup,
        _athena_catalog(os.environ["S3TABLES_CATALOG_ID"]),
        os.environ["S3TABLES_DATABASE_NAME"],
        timeout_seconds,
    )
    if failure_reason:
        raise RuntimeError(f"Failed to create S3 Tables probe table: {failure_reason}")
    logger.info(f"S3 Tables probe table [{fq_table}] ready.")


def s3tables_insert_rows(rows, run_uuid, athena_client, workgroup, timeout_seconds):
    fq_table = s3tables_fq_table('"')
    select_clauses = []
    for row in rows:
        active_str = "true" if row["active"] else "false"
        select_clauses.append(
            "SELECT "
            f"{int(row['id'])}, '{row['name']}', "
            f"CAST({float(row['value'])} AS double), {active_str}, '{run_uuid}'"
        )
    sql = f"INSERT INTO {fq_table} {' UNION ALL '.join(select_clauses)}"
    _, failure_reason, _ = execute_athena_query(
        sql,
        athena_client,
        workgroup,
        _athena_catalog(os.environ["S3TABLES_CATALOG_ID"]),
        os.environ["S3TABLES_DATABASE_NAME"],
        timeout_seconds,
    )
    if failure_reason:
        raise RuntimeError(f"Failed to insert S3 Tables probe rows: {failure_reason}")


def s3tables_select_rows(run_uuid, athena_client, workgroup, timeout_seconds):
    fq_table = s3tables_fq_table('"')
    sql = f"SELECT id, name, value, active FROM {fq_table} WHERE run_id = '{run_uuid}' ORDER BY id"
    _, failure_reason, rows = execute_athena_query(
        sql,
        athena_client,
        workgroup,
        _athena_catalog(os.environ["S3TABLES_CATALOG_ID"]),
        os.environ["S3TABLES_DATABASE_NAME"],
        timeout_seconds,
        expect_results=True,
    )
    return failure_reason, rows


def s3tables_attempt_insert(run_uuid, athena_client, workgroup, timeout_seconds):
    fq_table = s3tables_fq_table('"')
    sql = (
        f"INSERT INTO {fq_table} "
        f"SELECT 999, 'boundary-probe', CAST(9.9 AS double), true, '{run_uuid}'"
    )
    _, failure_reason, _ = execute_athena_query(
        sql,
        athena_client,
        workgroup,
        _athena_catalog(os.environ["S3TABLES_CATALOG_ID"]),
        os.environ["S3TABLES_DATABASE_NAME"],
        timeout_seconds,
    )
    return failure_reason


def s3tables_cleanup(run_uuid, athena_client, workgroup, timeout_seconds):
    fq_table = s3tables_fq_table('"')
    sql = f"DELETE FROM {fq_table} WHERE run_id = '{run_uuid}'"
    _, failure_reason, _ = execute_athena_query(
        sql,
        athena_client,
        workgroup,
        _athena_catalog(os.environ["S3TABLES_CATALOG_ID"]),
        os.environ["S3TABLES_DATABASE_NAME"],
        timeout_seconds,
    )
    return failure_reason is None


def _run_s3tables_mechanism_checks(run_uuid, target_athena, workgroup, timeout_seconds):
    mechanism_result = {
        "positive_check": {"outcome": "SKIPPED"},
        "negative_check": {"outcome": "SKIPPED"},
        "phase": None,
        "detail": None,
    }

    try:
        failure_reason, rows = s3tables_select_rows(
            run_uuid, target_athena, workgroup, timeout_seconds
        )
        if failure_reason:
            mechanism_result["phase"] = "positive_check"
            mechanism_result["detail"] = f"TARGET role SELECT unexpectedly failed: {failure_reason}"
            mechanism_result["positive_check"] = {"outcome": "FAIL", "detail": failure_reason}
        elif len(rows) != len(SAMPLE_ROWS):
            mechanism_result["phase"] = "positive_check"
            mechanism_result["detail"] = (
                f"TARGET role SELECT returned {len(rows)} rows, expected {len(SAMPLE_ROWS)}"
            )
            mechanism_result["positive_check"] = {"outcome": "FAIL", "detail": mechanism_result["detail"]}
        else:
            mechanism_result["positive_check"] = {"outcome": "PASS"}
    except Exception as exc:
        logger.error(f"S3 Tables positive_check for run [{run_uuid}] failed unexpectedly: [{exc}].")
        mechanism_result["phase"] = "positive_check"
        mechanism_result["detail"] = str(exc)
        mechanism_result["positive_check"] = {"outcome": "FAIL", "detail": str(exc)}

    try:
        failure_reason = s3tables_attempt_insert(
            run_uuid, target_athena, workgroup, timeout_seconds
        )
        if failure_reason is None:
            mechanism_result["phase"] = "negative_check"
            mechanism_result["detail"] = "TARGET role INSERT unexpectedly SUCCEEDED (over-permissioned)"
            mechanism_result["negative_check"] = {"outcome": "FAIL", "detail": mechanism_result["detail"]}
        elif not _is_access_denied(failure_reason):
            mechanism_result["phase"] = "negative_check"
            mechanism_result["detail"] = f"TARGET role INSERT failed for an unexpected reason: {failure_reason}"
            mechanism_result["negative_check"] = {"outcome": "FAIL", "detail": failure_reason}
        else:
            mechanism_result["negative_check"] = {"outcome": "PASS"}
    except Exception as exc:
        logger.error(f"S3 Tables negative_check for run [{run_uuid}] failed unexpectedly: [{exc}].")
        mechanism_result["phase"] = "negative_check"
        mechanism_result["detail"] = str(exc)
        mechanism_result["negative_check"] = {"outcome": "FAIL", "detail": str(exc)}

    mechanism_result["status"] = (
        "PASS"
        if mechanism_result["positive_check"].get("outcome") == "PASS"
        and mechanism_result["negative_check"].get("outcome") == "PASS"
        else "FAIL"
    )
    return mechanism_result


def run_s3tables_suite(setup_creds, target_creds_by_mechanism, region, workgroup, timeout_seconds):
    run_uuid = generate_run_uuid()
    setup_athena = boto3.client("athena", region_name=region, **setup_creds)

    result = {
        "run_id": run_uuid,
        "status": "FAIL",
        "phase": None,
        "detail": None,
        "cleanup": {"outcome": "SKIPPED"},
        "mechanisms": {
            mechanism["key"]: {
                "label": mechanism["label"],
                "status": "SKIPPED",
                "positive_check": {"outcome": "SKIPPED"},
                "negative_check": {"outcome": "SKIPPED"},
                "phase": None,
                "detail": None,
            }
            for mechanism in MECHANISMS
        },
    }

    try:
        s3tables_ensure_table_exists(setup_athena, workgroup, timeout_seconds)
        s3tables_insert_rows(SAMPLE_ROWS, run_uuid, setup_athena, workgroup, timeout_seconds)
    except Exception as exc:
        logger.error(f"S3 Tables suite setup for run [{run_uuid}] failed: [{exc}].")
        result["phase"] = "setup"
        result["detail"] = str(exc)
        result["cleanup"]["detail"] = "Setup failed; no data to clean"
        return result

    for mechanism in MECHANISMS:
        target_athena = boto3.client(
            "athena", region_name=region, **target_creds_by_mechanism[mechanism["key"]]
        )
        mechanism_result = _run_s3tables_mechanism_checks(
            run_uuid, target_athena, workgroup, timeout_seconds
        )
        result["mechanisms"][mechanism["key"]].update(mechanism_result)

    try:
        cleaned = s3tables_cleanup(run_uuid, setup_athena, workgroup, timeout_seconds)
        result["cleanup"] = {"outcome": "SUCCESS" if cleaned else "FAIL"}
    except Exception as exc:
        logger.error(f"S3 Tables cleanup for run [{run_uuid}] failed: [{exc}].")
        result["cleanup"] = {"outcome": "FAIL", "detail": str(exc)}

    if all(m["status"] == "PASS" for m in result["mechanisms"].values()):
        result["status"] = "PASS"
        result["phase"] = "complete"
    else:
        failing = [k for k, m in result["mechanisms"].items() if m["status"] != "PASS"]
        result["phase"] = f"mechanism_check:{','.join(failing)}"
        result["detail"] = "; ".join(
            f"{result['mechanisms'][k]['label']}: {result['mechanisms'][k]['detail']}"
            for k in failing
        )

    return result


def redshift_fq_table(quote):
    catalog = _athena_catalog(os.environ["REDSHIFT_CATALOG_ID"])
    database = os.environ["REDSHIFT_DATABASE_NAME"]
    table = os.environ["REDSHIFT_TABLE_NAME"]
    return f"{quote}{catalog}{quote}.{quote}{database}{quote}.{quote}{table}{quote}"


def redshift_data_execute(redshift_data_client, sql, timeout_seconds):
    logger.info(f"Executing Redshift statement [{sql}]...")
    resp = redshift_data_client.execute_statement(
        ClusterIdentifier=os.environ["REDSHIFT_CLUSTER_IDENTIFIER"],
        Database=os.environ["REDSHIFT_DB_NAME"],
        Sql=sql,
    )
    statement_id = resp["Id"]

    deadline = time.time() + timeout_seconds
    while True:
        status = redshift_data_client.describe_statement(Id=statement_id)
        state = status["Status"]
        if state == "FINISHED":
            logger.info(f"Redshift statement [{statement_id}] finished successfully.")
            return None
        if state in ("FAILED", "ABORTED"):
            reason = status.get("Error", f"Statement {state}")
            logger.info(f"Redshift statement [{statement_id}] finished with failure: [{reason}].")
            return reason
        if time.time() >= deadline:
            redshift_data_client.cancel_statement(Id=statement_id)
            logger.error(f"Redshift statement [{statement_id}] timed out after [{timeout_seconds}s].")
            raise TimeoutError(
                f"Redshift Data API statement {statement_id} timed out after {timeout_seconds}s"
            )
        time.sleep(2)


def _redshift_run_and_fetch(redshift_data_client, sql, timeout_seconds):
    logger.info(f"Executing Redshift statement [{sql}]...")
    resp = redshift_data_client.execute_statement(
        ClusterIdentifier=os.environ["REDSHIFT_CLUSTER_IDENTIFIER"],
        Database=os.environ["REDSHIFT_DB_NAME"],
        Sql=sql,
    )
    statement_id = resp["Id"]

    deadline = time.time() + timeout_seconds
    while True:
        status = redshift_data_client.describe_statement(Id=statement_id)
        state = status["Status"]
        if state == "FINISHED":
            logger.info(f"Redshift statement [{statement_id}] finished successfully.")
            result = redshift_data_client.get_statement_result(Id=statement_id)
            return None, result.get("Records", [])
        if state in ("FAILED", "ABORTED"):
            reason = status.get("Error", f"Statement {state}")
            logger.info(f"Redshift statement [{statement_id}] finished with failure: [{reason}].")
            return reason, []
        if time.time() >= deadline:
            redshift_data_client.cancel_statement(Id=statement_id)
            logger.error(f"Redshift statement [{statement_id}] timed out after [{timeout_seconds}s].")
            raise TimeoutError(
                f"Redshift Data API statement {statement_id} timed out after {timeout_seconds}s"
            )
        time.sleep(2)


def _redshift_wait_for_table_visible(redshift_data_client, schema, table, timeout_seconds):
    logger.info(f"Waiting for Redshift table [{schema}.{table}] to become visible...")
    check_sql = (
        f"SELECT 1 FROM pg_tables WHERE schemaname = '{schema}' AND tablename = '{table}'"
    )
    wait_budget = max(timeout_seconds, 60)
    deadline = time.time() + wait_budget
    while True:
        failure_reason, records = _redshift_run_and_fetch(redshift_data_client, check_sql, 30)
        if not failure_reason and records:
            logger.info(f"Redshift table [{schema}.{table}] is visible.")
            return
        if time.time() >= deadline:
            logger.error(f"Redshift table [{schema}.{table}] still not visible after [{wait_budget}s].")
            raise TimeoutError(
                f"Redshift probe table '{schema}.{table}' still not visible to a "
                f"fresh ExecuteStatement call after {wait_budget}s - CREATE TABLE "
                f"IF NOT EXISTS reported success but the table never propagated."
            )
        time.sleep(3)


def _redshift_qualified_table():
    schema = os.environ["REDSHIFT_DATABASE_NAME"]
    table = os.environ["REDSHIFT_TABLE_NAME"]
    return schema, table


def redshift_ensure_table_exists(redshift_data_client, timeout_seconds):
    schema, table = _redshift_qualified_table()
    sql = f"""CREATE TABLE IF NOT EXISTS {schema}.{table} (
        id INT,
        name VARCHAR(64),
        value DOUBLE PRECISION,
        active BOOLEAN,
        run_id VARCHAR(36)
    )"""
    failure_reason = redshift_data_execute(redshift_data_client, sql, timeout_seconds)
    if failure_reason:
        raise RuntimeError(f"Failed to create Redshift probe table: {failure_reason}")

    _redshift_wait_for_table_visible(redshift_data_client, schema, table, timeout_seconds)
    logger.info(f"Redshift probe table [{schema}.{table}] ready.")


def redshift_insert_rows(rows, run_uuid, redshift_data_client, timeout_seconds):
    schema, table = _redshift_qualified_table()
    values_clauses = []
    for row in rows:
        active_str = "true" if row["active"] else "false"
        values_clauses.append(
            f"({int(row['id'])}, '{row['name']}', {float(row['value'])}, "
            f"{active_str}, '{run_uuid}')"
        )
    sql = (
        f"INSERT INTO {schema}.{table} (id, name, value, active, run_id) "
        f"VALUES {', '.join(values_clauses)}"
    )
    failure_reason = redshift_data_execute(redshift_data_client, sql, timeout_seconds)
    if failure_reason:
        raise RuntimeError(f"Failed to insert Redshift probe rows: {failure_reason}")


def redshift_cleanup(run_uuid, redshift_data_client, timeout_seconds):
    schema, table = _redshift_qualified_table()
    sql = f"DELETE FROM {schema}.{table} WHERE run_id = '{run_uuid}'"
    failure_reason = redshift_data_execute(redshift_data_client, sql, timeout_seconds)
    return failure_reason is None


def redshift_select_probe(run_uuid, target_athena, workgroup, timeout_seconds):
    fq_table = redshift_fq_table('"')
    sql = f"SELECT id, name, value, active FROM {fq_table} WHERE run_id = '{run_uuid}' ORDER BY id"
    _, failure_reason, rows = execute_athena_query(
        sql,
        target_athena,
        workgroup,
        _athena_catalog(os.environ["REDSHIFT_CATALOG_ID"]),
        os.environ["REDSHIFT_DATABASE_NAME"],
        timeout_seconds,
        expect_results=True,
    )
    return failure_reason, rows


def redshift_attempt_insert(run_uuid, target_athena, workgroup, timeout_seconds):
    fq_table = redshift_fq_table('"')
    sql = (
        f"INSERT INTO {fq_table} (id, name, value, active, run_id) "
        f"VALUES (999, 'boundary-probe', 9.9, true, '{run_uuid}')"
    )
    _, failure_reason, _ = execute_athena_query(
        sql,
        target_athena,
        workgroup,
        _athena_catalog(os.environ["REDSHIFT_CATALOG_ID"]),
        os.environ["REDSHIFT_DATABASE_NAME"],
        timeout_seconds,
    )
    return failure_reason


def _run_redshift_mechanism_checks(run_uuid, target_athena, workgroup, timeout_seconds):
    mechanism_result = {
        "positive_check": {"outcome": "SKIPPED"},
        "negative_check": {"outcome": "SKIPPED"},
        "phase": None,
        "detail": None,
    }

    try:
        failure_reason, rows = redshift_select_probe(
            run_uuid, target_athena, workgroup, timeout_seconds
        )
        if failure_reason:
            mechanism_result["phase"] = "positive_check"
            mechanism_result["detail"] = f"TARGET role SELECT unexpectedly failed: {failure_reason}"
            mechanism_result["positive_check"] = {"outcome": "FAIL", "detail": failure_reason}
        elif len(rows) != len(SAMPLE_ROWS):
            mechanism_result["phase"] = "positive_check"
            mechanism_result["detail"] = (
                f"TARGET role SELECT returned {len(rows)} rows, expected {len(SAMPLE_ROWS)}"
            )
            mechanism_result["positive_check"] = {"outcome": "FAIL", "detail": mechanism_result["detail"]}
        else:
            mechanism_result["positive_check"] = {"outcome": "PASS"}
    except Exception as exc:
        logger.error(f"Redshift positive_check for run [{run_uuid}] failed unexpectedly: [{exc}].")
        mechanism_result["phase"] = "positive_check"
        mechanism_result["detail"] = str(exc)
        mechanism_result["positive_check"] = {"outcome": "FAIL", "detail": str(exc)}

    try:
        failure_reason = redshift_attempt_insert(
            run_uuid, target_athena, workgroup, timeout_seconds
        )
        if failure_reason is None:
            mechanism_result["phase"] = "negative_check"
            mechanism_result["detail"] = "TARGET role INSERT unexpectedly SUCCEEDED (over-permissioned)"
            mechanism_result["negative_check"] = {"outcome": "FAIL", "detail": mechanism_result["detail"]}
        elif not _is_access_denied(failure_reason):
            mechanism_result["negative_check"] = {
                "outcome": "INCONCLUSIVE",
                "detail": failure_reason,
            }
        else:
            mechanism_result["negative_check"] = {"outcome": "PASS"}
    except Exception as exc:
        logger.error(f"Redshift negative_check for run [{run_uuid}] failed unexpectedly: [{exc}].")
        mechanism_result["phase"] = "negative_check"
        mechanism_result["detail"] = str(exc)
        mechanism_result["negative_check"] = {"outcome": "FAIL", "detail": str(exc)}

    mechanism_result["status"] = (
        "PASS"
        if mechanism_result["positive_check"].get("outcome") == "PASS"
        and mechanism_result["negative_check"].get("outcome") in ("PASS", "INCONCLUSIVE")
        else "FAIL"
    )
    return mechanism_result


def run_redshift_suite(setup_creds, target_creds_by_mechanism, athena_region, workgroup, timeout_seconds):
    run_uuid = generate_run_uuid()
    redshift_data = boto3.client(
        "redshift-data", region_name=os.environ["REDSHIFT_REGION"], **setup_creds
    )
    setup_athena = boto3.client("athena", region_name=athena_region, **setup_creds)

    result = {
        "run_id": run_uuid,
        "status": "FAIL",
        "phase": None,
        "detail": None,
        "cleanup": {"outcome": "SKIPPED"},
        "mechanisms": {
            mechanism["key"]: {
                "label": mechanism["label"],
                "status": "SKIPPED",
                "positive_check": {"outcome": "SKIPPED"},
                "negative_check": {"outcome": "SKIPPED"},
                "phase": None,
                "detail": None,
            }
            for mechanism in MECHANISMS
        },
    }

    try:
        redshift_ensure_table_exists(redshift_data, timeout_seconds)
        redshift_insert_rows(SAMPLE_ROWS, run_uuid, redshift_data, timeout_seconds)
    except Exception as exc:
        logger.error(f"Redshift suite setup for run [{run_uuid}] failed: [{exc}].")
        result["phase"] = "setup"
        result["detail"] = str(exc)
        result["cleanup"]["detail"] = "Setup failed; no data to clean"
        return result

    try:
        warmup_fq_table = redshift_fq_table('"')
        execute_athena_query(
            f"SELECT 1 FROM {warmup_fq_table} LIMIT 1",
            setup_athena,
            workgroup,
            _athena_catalog(os.environ["REDSHIFT_CATALOG_ID"]),
            os.environ["REDSHIFT_DATABASE_NAME"],
            timeout_seconds,
        )
    except Exception as exc:
        # Best-effort only: warms the Athena engine for the mechanism checks
        # that follow, but isn't required for the suite's correctness.
        logger.warning(f"Redshift warm-up query for run [{run_uuid}] failed (non-fatal): [{exc}].")

    for mechanism in MECHANISMS:
        target_athena = boto3.client(
            "athena", region_name=athena_region, **target_creds_by_mechanism[mechanism["key"]]
        )
        mechanism_result = _run_redshift_mechanism_checks(
            run_uuid, target_athena, workgroup, timeout_seconds
        )
        result["mechanisms"][mechanism["key"]].update(mechanism_result)

    try:
        cleaned = redshift_cleanup(run_uuid, redshift_data, timeout_seconds)
        result["cleanup"] = {"outcome": "SUCCESS" if cleaned else "FAIL"}
    except Exception as exc:
        logger.error(f"Redshift cleanup for run [{run_uuid}] failed: [{exc}].")
        result["cleanup"] = {"outcome": "FAIL", "detail": str(exc)}

    if all(m["status"] == "PASS" for m in result["mechanisms"].values()):
        result["status"] = "PASS"
        result["phase"] = "complete"
    else:
        failing = [k for k, m in result["mechanisms"].items() if m["status"] != "PASS"]
        result["phase"] = f"mechanism_check:{','.join(failing)}"
        result["detail"] = "; ".join(
            f"{result['mechanisms'][k]['label']}: {result['mechanisms'][k]['detail']}"
            for k in failing
        )

    return result


def publish_metrics(s3tables_result, redshift_result, cw_client):
    env = os.environ["ENVIRONMENT"]

    def _metric(name, outcome_ok):
        return {
            "MetricName": name,
            "Dimensions": [{"Name": "Environment", "Value": env}],
            "Value": 1 if outcome_ok else 0,
            "Unit": "Count",
        }

    metric_data = []
    for service_name, service_result in (
        ("S3Tables", s3tables_result),
        ("Redshift", redshift_result),
    ):
        for mechanism in MECHANISMS:
            mechanism_result = service_result["mechanisms"][mechanism["key"]]
            prefix = f"{service_name}{mechanism['metric_prefix']}"
            metric_data.append(
                _metric(
                    f"{prefix}PositiveCheckSuccess",
                    mechanism_result["positive_check"].get("outcome") == "PASS",
                )
            )
            metric_data.append(
                _metric(
                    f"{prefix}NegativeCheckSuccess",
                    mechanism_result["negative_check"].get("outcome") in ("PASS", "INCONCLUSIVE"),
                )
            )
        metric_data.append(
            _metric(
                f"{service_name}CleanupSuccess",
                service_result["cleanup"].get("outcome") == "SUCCESS",
            )
        )

    cw_client.put_metric_data(Namespace=METRICS_NAMESPACE, MetricData=metric_data)


def lambda_handler(event, context):
    start = time.time()

    sts = boto3.client("sts")
    cw = boto3.client("cloudwatch")

    timeout = int(os.environ.get("ATHENA_QUERY_TIMEOUT_SECONDS", "90"))
    workgroup = os.environ["ATHENA_WORKGROUP"]

    try:
        setup_creds = assume_setup_role(sts)
        target_creds_by_mechanism = assume_target_roles(sts)
    except Exception as exc:
        duration_ms = int((time.time() - start) * 1000)
        logger.error(f"Role assumption failed: [{exc}].")
        result = {
            "status": "FAIL",
            "phase": "assume_role",
            "detail": str(exc),
            "s3tables": None,
            "redshift": None,
            "duration_ms": duration_ms,
        }
        logger.info(json.dumps(result))
        return result

    s3tables_result = run_s3tables_suite(
        setup_creds, target_creds_by_mechanism, os.environ["S3TABLES_REGION"], workgroup, timeout
    )
    redshift_result = run_redshift_suite(
        setup_creds, target_creds_by_mechanism, os.environ["REDSHIFT_REGION"], workgroup, timeout
    )

    publish_metrics(s3tables_result, redshift_result, cw)

    duration_ms = int((time.time() - start) * 1000)
    overall_status = (
        "PASS"
        if s3tables_result["status"] == "PASS" and redshift_result["status"] == "PASS"
        else "FAIL"
    )

    summary_lines = []
    for service_name, service_result in (("S3 Tables", s3tables_result), ("Redshift", redshift_result)):
        for mechanism in MECHANISMS:
            mechanism_result = service_result["mechanisms"][mechanism["key"]]
            summary_lines.append(
                f"{service_name} / {mechanism['label']}: {mechanism_result['status']}"
            )

    result = {
        "status": overall_status,
        "summary": summary_lines,
        "s3tables": s3tables_result,
        "redshift": redshift_result,
        "duration_ms": duration_ms,
    }
    logger.info(json.dumps(result))
    return result
