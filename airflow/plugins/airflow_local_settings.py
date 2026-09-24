# Airflow cluster policy, loaded automatically at process startup. Namespace
# is derived from the DAG file's path: dags/<namespace>/<file>.py.
#
# MWAA's base image ships its own $AIRFLOW_HOME/config/airflow_local_settings.py,
# which shadows this file as the module Airflow's import_local_settings()
# actually imports ($AIRFLOW_HOME/config precedes the plugins dir on sys.path).
# That wrapper does exec this file by path if present, but only for side
# effects - it never feeds dag_policy/task_policy into Airflow's policy
# system, so the plain "function named dag_policy" convention alone is inert
# on MWAA (github.com/aws/amazon-mwaa-docker-images, images/airflow/3.2.1/
# airflow_local_settings.py). Registering explicitly below is the fix.
# __all__ = [] stops import_local_settings() from *also* auto-registering us
# when there's no wrapper shadowing this file (local/test imports).
#
# Airflow's generic plugins_manager *separately* scans and execs every .py
# file under $AIRFLOW_HOME/plugins/ (unrelated to import_local_settings()),
# so this file runs a second time in the same process regardless of the
# above. get_plugin(...) below makes registration idempotent against that -
# pluggy raises on a second register() under the same name otherwise.

from __future__ import annotations

import types
from typing import TYPE_CHECKING

__all__: list[str] = []

if TYPE_CHECKING:
    from airflow.sdk import DAG, BaseOperator


def _namespace_from_fileloc(fileloc: str) -> str | None:
    marker = "/dags/"
    if marker not in fileloc:
        return None
    return fileloc.split(marker, 1)[1].split("/")[0]


def dag_policy(dag: DAG) -> None:
    namespace = _namespace_from_fileloc(dag.fileloc or "")
    if not namespace:
        return
    # dag_display_name (what the UI's Dags list shows, separate from dag_id
    # used in URLs/API) defaults to dag_id via a factory that runs at DAG
    # construction time, before this hook - so it's already frozen to the
    # unprefixed name by now and needs updating too, unless the author gave
    # it an explicit value of its own.
    if dag.dag_display_name == dag.dag_id:
        dag.dag_display_name = f"{namespace}.{dag.dag_display_name}"
    dag.dag_id = f"{namespace}.{dag.dag_id}"


def task_policy(task: BaseOperator) -> None:
    namespace = _namespace_from_fileloc(task.dag.fileloc or "")
    if namespace and hasattr(task, "aws_conn_id"):
        task.aws_conn_id = namespace


from airflow.policies import make_plugin_from_local_settings  # noqa: E402
from airflow.settings import get_policy_plugin_manager  # noqa: E402

_policy_plugin_manager = get_policy_plugin_manager()
if _policy_plugin_manager.get_plugin("AirflowLocalSettingsPolicy") is None:
    _policy_functions = types.SimpleNamespace(dag_policy=dag_policy, task_policy=task_policy)
    make_plugin_from_local_settings(
        _policy_plugin_manager, _policy_functions, {"dag_policy", "task_policy"}
    )
