"""Shared test setup for airflow_local_settings.py."""

from __future__ import annotations

import sys
from pathlib import Path

# Mirrors how MWAA extracts plugins.zip so airflow/plugins/ (this file's
# parent) is on sys.path, and airflow_local_settings imports as top-level.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
