"""Credentials for the database dbt connects to, via redshift_auth_vars(db=).

Written to explain cdc's `FATAL 28000 IAM authentication failed`
(cdc.e2e_dbt_config_manager_redshift / dbt_grant_staging_seed_privileges):
Redshift binds the credentials GetClusterCredentials issues to the database
they were requested for, so asking for `edp` and connecting to `edp_raw_dev`
is refused at login however wide the role's IAM policy is.

redshift_auth_vars(db=...) now uses one database for both halves. This DAG
exercises the three ways a DAG author writes it, all expected to pass:

  connect_edp             db="edp", the cluster's own database
  connect_raw             db="edp_raw_dev", a literal writable_databases entry
  connect_raw_templated   db="edp_raw_{{ var.value.environment }}", the same
                          database via the per-environment Airflow Variable

Each task runs `dbt debug`, which only opens a connection and reports, so
nothing is written to any database. The tasks are independent.

Manually triggered.
"""

from datetime import datetime

from airflow.decorators import dag
from edp_dbt import dbt, redshift_auth_vars


@dag(
    dag_id="e2e_redshift_dbname_binding",
    schedule=None,
    start_date=datetime(2026, 9, 16),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False,
    tags=["platform", "e2e", "redshift"],
    description=(
        "redshift_auth_vars(db=...) against three databases: edp, "
        "edp_raw_dev, and edp_raw_{{ var.value.environment }}. Three "
        "independent `dbt debug` connections, all expected to pass."
    ),
)
def e2e_redshift_dbname_binding():
    dbt.cli(
        ["debug"],
        task_id="connect_edp",
        project="redshift_smoke_test",
        target="dev",
        env_vars=redshift_auth_vars(db="edp"),
    )
    dbt.cli(
        ["debug"],
        task_id="connect_raw",
        project="redshift_smoke_test",
        target="dev",
        env_vars=redshift_auth_vars(db="edp_raw_dev"),
    )
    dbt.cli(
        ["debug"],
        task_id="connect_raw_templated",
        project="redshift_smoke_test",
        target="dev",
        env_vars=redshift_auth_vars(db="edp_raw_{{ var.value.environment }}"),
    )


e2e_redshift_dbname_binding()
