from datetime import datetime

from airflow.decorators import dag
from edp_dbt import dbt, redshift_auth_vars


@dag(
    dag_id="e2e_dbt_redshift",
    schedule=None,
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False,
    tags=["platform", "e2e", "dbt", "redshift"],
    description=(
        "Smoke-tests namespace-scoped Redshift access end-to-end: fetches "
        "short-lived credentials under the platform namespace role "
        "(redshift:GetClusterCredentials), creates a table and inserts data "
        "into the schema/GRANTs provisioned for it (see "
        "redshift/namespaces/platform.yaml), retrieves it back via a dbt "
        "test, then drops the table. Manually triggered."
    ),
)
def e2e_dbt_redshift():
    build = dbt.build(
        task_id="dbt_build",
        project="redshift_smoke_test",
        target="dev",
        env_vars=redshift_auth_vars(db="edp"),
    )

    # Same build, run through dbt.cli's escape hatch instead of the
    # dbt.build factory - demonstrates that it's a drop-in equivalent when
    # given project=/target=/env_vars= (DbtOperator's own resolution and
    # flag injection still applies; only args=["build"] is raw here).
    cli_build = dbt.cli(
        ["build"],
        task_id="dbt_cli_build",
        project="redshift_smoke_test",
        target="dev",
        env_vars=redshift_auth_vars(db="edp"),
    )

    build >> cli_build


e2e_dbt_redshift()
