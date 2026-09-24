"""Shared test setup for the edp_secrets plugin.

See edp_dbt/tests/conftest.py's own docstring - identical reasoning, same
sys.path shim mirroring how MWAA actually imports a dags/-rooted top-level
package in production.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
