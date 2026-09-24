from datetime import datetime

from airflow.decorators import dag
from airflow.operators.bash import BashOperator


@dag(
    dag_id="e2e_scheduler",
    schedule="*/5 * * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False,
    tags=["platform", "e2e"],
    description="Validates that the MWAA scheduler and worker are functional",
)
def e2e_scheduler():
    BashOperator(
        task_id="echo_timestamp",
        bash_command='echo "{{ ts }}"',
    )


e2e_scheduler()
