"""Tests for the cluster policy (airflow_local_settings.py)."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace

from airflow_local_settings import _namespace_from_fileloc, dag_policy, task_policy

_MODULE_PATH = Path(__file__).resolve().parents[1] / "airflow_local_settings.py"


def test_module_can_be_loaded_a_second_time_in_the_same_process() -> None:
    """Airflow's generic plugins_manager execs every .py file under
    $AIRFLOW_HOME/plugins/ independently of import_local_settings() - this
    file runs twice in one process on real MWAA regardless of how it's first
    loaded. A second exec must not raise (pluggy rejects re-registering the
    same plugin name otherwise - see airflow_local_settings.py's own
    comment)."""
    from airflow.settings import get_policy_plugin_manager

    for _ in range(2):
        spec = importlib.util.spec_from_file_location("_reloaded_local_settings", _MODULE_PATH)
        assert spec and spec.loader
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

    assert get_policy_plugin_manager().get_plugin("AirflowLocalSettingsPolicy") is not None


def test_namespace_from_fileloc_extracts_first_segment_after_dags() -> None:
    assert _namespace_from_fileloc("/repo/airflow/dags/finance/load.py") == "finance"


def test_namespace_from_fileloc_ignores_subdirectories_past_the_namespace() -> None:
    assert _namespace_from_fileloc("/repo/airflow/dags/finance/sub/dir/load.py") == "finance"


def test_namespace_from_fileloc_returns_none_without_a_dags_marker() -> None:
    assert _namespace_from_fileloc("/repo/airflow/plugins/foo.py") is None


def test_namespace_from_fileloc_returns_none_for_empty_string() -> None:
    assert _namespace_from_fileloc("") is None


def test_dag_policy_prefixes_dag_id_with_namespace() -> None:
    dag = SimpleNamespace(
        fileloc="/repo/airflow/dags/finance/load.py", dag_id="load", dag_display_name="load"
    )

    dag_policy(dag)  # type: ignore[arg-type]

    assert dag.dag_id == "finance.load"


def test_dag_policy_prefixes_the_default_display_name_alongside_dag_id() -> None:
    # dag_display_name defaults to dag_id, but is a separate attrs field set
    # at DAG construction time - it doesn't track dag_id after the fact, so
    # this hook has to update it too or the UI's Dags list won't match the
    # (correctly prefixed) dag_id used everywhere else.
    dag = SimpleNamespace(
        fileloc="/repo/airflow/dags/finance/load.py", dag_id="load", dag_display_name="load"
    )

    dag_policy(dag)  # type: ignore[arg-type]

    assert dag.dag_display_name == "finance.load"


def test_dag_policy_preserves_an_explicit_custom_display_name() -> None:
    dag = SimpleNamespace(
        fileloc="/repo/airflow/dags/finance/load.py",
        dag_id="load",
        dag_display_name="Load Transactions",
    )

    dag_policy(dag)  # type: ignore[arg-type]

    assert dag.dag_id == "finance.load"
    assert dag.dag_display_name == "Load Transactions"


def test_dag_policy_leaves_dag_id_untouched_without_a_namespace() -> None:
    dag = SimpleNamespace(
        fileloc="/repo/airflow/plugins/foo.py", dag_id="load", dag_display_name="load"
    )

    dag_policy(dag)  # type: ignore[arg-type]

    assert dag.dag_id == "load"
    assert dag.dag_display_name == "load"


def test_task_policy_sets_aws_conn_id_to_the_namespace() -> None:
    task = SimpleNamespace(
        dag=SimpleNamespace(fileloc="/repo/airflow/dags/finance/load.py"),
        aws_conn_id=None,
    )

    task_policy(task)  # type: ignore[arg-type]

    assert task.aws_conn_id == "finance"


def test_task_policy_overrides_an_explicit_aws_conn_id() -> None:
    task = SimpleNamespace(
        dag=SimpleNamespace(fileloc="/repo/airflow/dags/finance/load.py"),
        aws_conn_id="whatever-the-author-wrote",
    )

    task_policy(task)  # type: ignore[arg-type]

    assert task.aws_conn_id == "finance"


def test_task_policy_skips_tasks_without_an_aws_conn_id_attribute() -> None:
    task = SimpleNamespace(dag=SimpleNamespace(fileloc="/repo/airflow/dags/finance/load.py"))

    task_policy(task)  # type: ignore[arg-type]

    assert not hasattr(task, "aws_conn_id")


def test_task_policy_leaves_aws_conn_id_untouched_without_a_namespace() -> None:
    task = SimpleNamespace(
        dag=SimpleNamespace(fileloc="/repo/airflow/plugins/foo.py"),
        aws_conn_id=None,
    )

    task_policy(task)  # type: ignore[arg-type]

    assert task.aws_conn_id is None
