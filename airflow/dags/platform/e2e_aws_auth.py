from datetime import datetime

from airflow.decorators import dag, task


@dag(
    dag_id="e2e_aws_auth",
    schedule="*/5 * * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False,
    tags=["platform", "e2e"],
    description="Validates credential-free AWS authentication via platform namespace IAM role",
)
def e2e_aws_auth():
    @task
    def verify_aws_auth() -> None:
        from airflow.models import Variable
        from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

        hook = AwsBaseHook(aws_conn_id="platform", client_type="s3")
        client = hook.get_client_type()

        mwaa_bucket = Variable.get("mwaa_s3_bucket")
        print(f"Verifying AWS auth against bucket [{mwaa_bucket}]...")
        response = client.list_objects_v2(
            Bucket=mwaa_bucket,
            Prefix="dags/platform/",
            MaxKeys=10,
        )
        status = response["ResponseMetadata"]["HTTPStatusCode"]
        print(f"AWS auth succeeded. S3 response HTTP status: [{status}].")

    verify_aws_auth()


e2e_aws_auth()
