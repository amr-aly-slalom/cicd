"""DbtOperator's cluster-policy-set attributes must survive DAG serialization -
a worker executes the deserialized copy from the metadata DB, not a re-parse
of the .py file. See operators.py's template_fields comment.
"""

from __future__ import annotations

from datetime import datetime
from typing import cast

from airflow.sdk import DAG
from airflow.serialization.serialized_objects import DagSerialization
from edp_dbt.operators import DbtOperator
from edp_dbt.redshift import redshift_auth_vars


def test_aws_conn_id_cache_root_and_env_vars_survive_serialization() -> None:
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        DbtOperator(
            task_id="build",
            args=["build"],
            project="recon",
            env_vars=redshift_auth_vars(db="edp"),
        )

    task = cast(DbtOperator, dag.get_task("build"))
    task.aws_conn_id = "finance"  # what the cluster policy sets before execute()

    deserialized = DagSerialization.deserialize_dag(DagSerialization.serialize_dag(dag))
    dtask = cast(DbtOperator, deserialized.get_task("build"))

    assert dtask.aws_conn_id == "finance"
    assert dtask.cache_root == task.cache_root
    # project/projects_root/_env_vars_ref are all read in execute(), on the
    # worker's deserialized copy - not __init__ - so they need the same
    # survival as aws_conn_id above. env_vars itself (a callable) can't
    # survive as a callable - see operators.py's docstring - only its
    # dotted-path string does, which _resolve_env_vars() re-imports.
    assert dtask.project == "recon"
    assert dtask.projects_root == task.projects_root
    assert dtask._env_vars_ref == [
        "module",
        "edp_dbt.redshift",
        "_auth_vars",
        {"db": "edp"},
    ]


def test_env_vars_partial_keywords_survive_serialization() -> None:
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        DbtOperator(
            task_id="build",
            args=["build"],
            project="recon",
            env_vars=redshift_auth_vars(db="edp_raw_dev"),
        )

    deserialized = DagSerialization.deserialize_dag(DagSerialization.serialize_dag(dag))
    dtask = cast(DbtOperator, deserialized.get_task("build"))

    assert dtask._env_vars_ref == [
        "module",
        "edp_dbt.redshift",
        "_auth_vars",
        {"db": "edp_raw_dev"},
    ]


def test_aws_conn_id_defaults_to_none_when_the_cluster_policy_never_ran() -> None:
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        DbtOperator(task_id="build", args=["build"], project="demo")

    deserialized = DagSerialization.deserialize_dag(DagSerialization.serialize_dag(dag))
    dtask = cast(DbtOperator, deserialized.get_task("build"))

    assert dtask.aws_conn_id is None


def test_raw_mode_project_none_survives_serialization() -> None:
    # dbt.cli's default path - project stays None all the way through a
    # worker's deserialized copy, so execute() correctly skips resolution.
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        DbtOperator(task_id="build", args=["build", "--project-dir", "/caller/own"])

    deserialized = DagSerialization.deserialize_dag(DagSerialization.serialize_dag(dag))
    dtask = cast(DbtOperator, deserialized.get_task("build"))

    assert dtask.project is None
    assert dtask.op_kwargs == {"args": ["build", "--project-dir", "/caller/own"]}
