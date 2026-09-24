"""EDP shared dbt operator."""

from edp_dbt import dbt
from edp_dbt.operators import DEFAULT_DBT_VENV, DbtOperator
from edp_dbt.redshift import redshift_auth_vars

__all__ = [
    "DEFAULT_DBT_VENV",
    "DbtOperator",
    "dbt",
    "redshift_auth_vars",
]

__version__ = "0.5.0"
