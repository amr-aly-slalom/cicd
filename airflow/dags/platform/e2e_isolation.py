from datetime import datetime

from airflow.decorators import dag, task


@dag(
    dag_id="e2e_isolation",
    schedule="*/5 * * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=False,
    tags=["platform", "e2e"],
    description="Validates namespace S3 prefix isolation — platform role must receive AccessDenied on canary prefix",
)
def e2e_isolation():
    @task
    def verify_namespace_isolation() -> None:
        from botocore.exceptions import ClientError

        from airflow.models import Variable
        from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

        hook = AwsBaseHook(aws_conn_id="platform", client_type="s3")
        client = hook.get_client_type()

        # The canary object is bootstrapped by scripts/bootstrap-mwaa-s3.sh.
        # The platform namespace IAM role must NOT have access to this prefix —
        # receiving AccessDenied is the expected success outcome.
        mwaa_bucket = Variable.get("mwaa_s3_bucket")

        print(f"Verifying namespace isolation against bucket [{mwaa_bucket}]...")
        try:
            client.get_object(
                Bucket=mwaa_bucket,
                Key="dags/canary_namespace_for_isolation_test/.keep",
            )
            raise RuntimeError(
                "Isolation check FAILED: platform role was able to read the canary object. "
                "Expected AccessDenied."
            )
        except ClientError as exc:
            error_code = exc.response["Error"]["Code"]
            if error_code == "AccessDenied":
                print("Isolation check PASSED: AccessDenied as expected.")
            elif error_code == "NoSuchBucket":
                raise RuntimeError(
                    f"Isolation check FAILED: bucket '{mwaa_bucket}' does not exist. "
                    f"Ensure the 'mwaa_s3_bucket' Airflow Variable is set to the correct bucket name."
                ) from exc
            else:
                raise RuntimeError(
                    f"Isolation check FAILED: unexpected error '{error_code}'. "
                    f"Expected AccessDenied."
                ) from exc

    verify_namespace_isolation()


e2e_isolation()
