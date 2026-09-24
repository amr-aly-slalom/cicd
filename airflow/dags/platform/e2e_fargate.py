from datetime import datetime

from airflow.decorators import dag
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator


@dag(
    dag_id="e2e_fargate",
    schedule="*/15 * * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=True,
    tags=["platform", "e2e"],
    description="Validates the Fargate data path by running a public Alpine smoke task via EcsRunTaskOperator",
)
def e2e_fargate():
    EcsRunTaskOperator(
        task_id="run_fargate_smoke",
        cluster="chedaws-edp-mwaa-fargate-{{ var.value.environment }}",
        task_definition="chedaws-edp-mwaa-platform-smoke-{{ var.value.environment }}",
        launch_type="FARGATE",
        overrides={},
        propagate_tags="TASK_DEFINITION",
        network_configuration={
            "awsvpcConfiguration": {
                "subnets": [
                    "{{ var.value.app_subnet_a }}",
                    "{{ var.value.app_subnet_b }}",
                ],
                "securityGroups": ["{{ var.value.mwaa_security_group_id }}"],
                "assignPublicIp": "DISABLED",
            }
        },
        awslogs_group="/chedaws-edp/fargate/platform/{{ var.value.environment }}",
        awslogs_stream_prefix="smoke",
        awslogs_region="ap-southeast-2",
        # Wait for the task to reach STOPPED before marking success/failure.
        deferrable=False,
    )


e2e_fargate()
