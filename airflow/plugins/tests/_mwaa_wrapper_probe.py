"""Run in a fresh subprocess by test_cluster_policy_wiring.py - never imported
directly. Parses one DAG file via the real DagBag and reports what the
cluster policy did.

Usage: python3 _mwaa_wrapper_probe.py <airflow_home> <dag_file> <output_json>
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any


def main() -> None:
    airflow_home, dag_file, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    os.environ["AIRFLOW_HOME"] = airflow_home

    from airflow.dag_processing.dagbag import DagBag

    import airflow  # noqa: F401  triggers airflow.settings.initialize()

    # The real scheduler's DagFileProcessorManager puts the whole dags
    # folder root on sys.path via its own local-dag-bundle setup before
    # ever processing a file - confirmed live (a namespaced DAG file
    # importing a top-level dags/ package). DagBag.process_file() called
    # directly, as this stand-in probe does, doesn't trigger that bundle
    # machinery at all, so it's reproduced by hand here - see edp_dbt's
    # import in probe_dag.py, which needs exactly this to resolve.
    sys.path.insert(0, os.path.join(airflow_home, "dags"))

    bag = DagBag(dag_folder=None, collect_dags=False)
    dags = bag.process_file(filepath=dag_file, only_if_updated=False)  # type: ignore[no-untyped-call]

    found_dags: list[dict[str, Any]] = [
        {
            "dag_id": d.dag_id,
            "dag_display_name": d.dag_display_name,
            "tasks": {t.task_id: getattr(t, "aws_conn_id", "<no attr>") for t in d.tasks},
        }
        for d in dags
    ]
    result = {"import_errors": bag.import_errors, "dags": found_dags}

    with open(out_path, "w") as f:
        json.dump(result, f)


if __name__ == "__main__":
    main()
