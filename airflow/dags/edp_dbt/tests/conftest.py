"""Shared test setup for the edp_dbt plugin.

Everything here runs under the Airflow venv, not the dbt one - see
test_run_dbt.py's module docstring for why _run_dbt can't be imported (let
alone run for real) anywhere else.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Mirrors how MWAA actually imports this package in production: the dags/
# folder root (this file's grandparent) is always on sys.path, and edp_dbt
# is imported as a top-level package from there - confirmed live that a
# plain top-level import from dags/ works with no special loader (see
# airflow/dags/edp_dbt/README.md).
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
