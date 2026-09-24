"""Regression test for the cluster policy silently never applying on real
MWAA - see airflow_local_settings.py's own comment for the mechanism
(MWAA's base image shadows that module name; the plain dag_policy/
task_policy function convention alone is inert under that shadowing).

test_airflow_local_settings.py calls dag_policy/task_policy directly, which
can't catch this - it never touches whether Airflow's policy plugin manager
ends up knowing about them. This instead runs a real DagBag against a real
DAG file in a fresh subprocess, with a stand-in for MWAA's wrapper present.
The stand-in isn't AWS's actual file (avoids vendoring it and a network
dependency in tests) - it reproduces only what matters: loading the
customer file by path via exec_module without registering it in
sys.modules under the "airflow_local_settings" name.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from textwrap import dedent
from typing import Any, cast

_PLUGINS_DIR = Path(__file__).resolve().parents[1]
_DAGS_DIR = _PLUGINS_DIR.parent / "dags"
_PROBE = Path(__file__).resolve().parent / "_mwaa_wrapper_probe.py"

_DAG_FILE = dedent("""\
    from datetime import datetime
    from airflow.decorators import dag
    from edp_dbt import DbtOperator

    @dag(dag_id="probe_dag", schedule=None, start_date=datetime(2026, 1, 1), catchup=False)
    def probe_dag():
        DbtOperator(task_id="build", args=["build"], project="demo")

    probe_dag()
    """)

_STANDIN_MWAA_WRAPPER = dedent("""\
    # Stand-in for MWAA's own $AIRFLOW_HOME/config/airflow_local_settings.py.
    import importlib.util
    import os

    __all__: list[str] = []

    _airflow_home = os.environ.get("AIRFLOW_HOME", "/usr/local/airflow")
    _plugins_settings = os.path.join(_airflow_home, "plugins", "airflow_local_settings.py")
    if os.path.exists(_plugins_settings):
        _spec = importlib.util.spec_from_file_location(
            "customer_plugins_airflow_local_settings", _plugins_settings
        )
        if _spec and _spec.loader:
            _module = importlib.util.module_from_spec(_spec)
            _spec.loader.exec_module(_module)
    """)


def _run_probe(tmp_path: Path) -> dict[str, Any]:
    airflow_home = tmp_path / "airflow_home"
    dag_dir = airflow_home / "dags" / "testns"
    dag_dir.mkdir(parents=True)
    (dag_dir / "probe_dag.py").write_text(_DAG_FILE)

    # Matches plugins.zip extraction: our real airflow_local_settings.py at
    # $AIRFLOW_HOME/plugins.
    (airflow_home / "plugins").symlink_to(_PLUGINS_DIR)

    # edp_dbt (which the DAG file needs) lives under dags/, not plugins/ -
    # see airflow/dags/edp_dbt/README.md for why - so it needs to resolve
    # from the dags folder root, matching how MWAA's continuous dags/ sync
    # actually lays it out in production.
    (dag_dir.parent / "edp_dbt").symlink_to(_DAGS_DIR / "edp_dbt")

    config_dir = airflow_home / "config"
    config_dir.mkdir(parents=True)
    (config_dir / "airflow_local_settings.py").write_text(_STANDIN_MWAA_WRAPPER)

    out_path = tmp_path / "result.json"

    env = os.environ.copy()
    env["AIRFLOW__CORE__UNIT_TEST_MODE"] = "True"
    env["AIRFLOW__CORE__LOAD_EXAMPLES"] = "False"
    # Not on PYTHONPATH - only Airflow's own sys.path append of
    # $AIRFLOW_HOME/config (ahead of plugins) should resolve
    # "airflow_local_settings", exactly as on real MWAA.
    env.pop("PYTHONPATH", None)

    dag_file = dag_dir / "probe_dag.py"
    subprocess.run(  # noqa: S603
        [sys.executable, str(_PROBE), str(airflow_home), str(dag_file), str(out_path)],
        capture_output=True,
        text=True,
        env=env,
        check=True,
        cwd=tmp_path,
    )
    return cast("dict[str, Any]", json.loads(out_path.read_text()))


def test_cluster_policy_applies_despite_mwaas_wrapper_shadowing_the_module_name(
    tmp_path: Path,
) -> None:
    result = _run_probe(tmp_path)

    assert result["import_errors"] == {}
    (dag,) = result["dags"]
    assert dag["dag_id"] == "testns.probe_dag"
    assert dag["dag_display_name"] == "testns.probe_dag"
    assert dag["tasks"] == {"build": "testns"}
