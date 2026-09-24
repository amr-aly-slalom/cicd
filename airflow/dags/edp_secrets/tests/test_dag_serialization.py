"""GetSecretOperator's cluster-policy-set aws_conn_id (and key) must survive
DAG serialization - a worker executes the deserialized copy from the
metadata DB, not a re-parse of the .py file. See edp_dbt/tests/
test_serialization.py for the same proof on DbtOperator.
"""

from __future__ import annotations

from datetime import datetime
from typing import cast

from airflow.sdk import DAG
from airflow.serialization.serialized_objects import DagSerialization
from edp_secrets.operators import GetSecretOperator


def test_get_secret_operator_aws_conn_id_and_key_survive_serialization() -> None:
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        GetSecretOperator(task_id="get", key="api/token")

    task = cast(GetSecretOperator, dag.get_task("get"))
    task.aws_conn_id = "finance"  # what the cluster policy sets before execute()

    deserialized = DagSerialization.deserialize_dag(DagSerialization.serialize_dag(dag))
    dtask = cast(GetSecretOperator, deserialized.get_task("get"))

    assert dtask.aws_conn_id == "finance"
    assert dtask.key == "api/token"


def test_aws_conn_id_defaults_to_none_when_the_cluster_policy_never_ran() -> None:
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        GetSecretOperator(task_id="get", key="api/token")

    deserialized = DagSerialization.deserialize_dag(DagSerialization.serialize_dag(dag))
    dtask = cast(GetSecretOperator, deserialized.get_task("get"))

    assert dtask.aws_conn_id is None
