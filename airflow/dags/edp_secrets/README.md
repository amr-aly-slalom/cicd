# `edp_secrets` — namespace-scoped Secrets Manager reads

Read-only access to your own namespace's arbitrary application secrets - an
API token, a partner credential, anything your DAG code needs to read back
that isn't shaped like an Airflow Connection (for that, see
`airflow/README.md`'s "Namespace-scoped Variables and Connections" section
instead).

The secret *object* isn't created by this plugin. Declare it in your
namespace's manifest instead:

```yaml
# airflow/mwaa/<namespace>.yaml
spec:
  secrets:
    - example_secret
```

and Terraform creates `airflow/<env>/namespaces/<namespace>/example_secret`
in Secrets Manager on the next apply - see
`terraform/mwaa/mwaa.tf`'s `aws_secretsmanager_secret.mwaa_namespace`. A
platform admin then sets its value by hand (console or CLI); a DAG can only
read it, never create, overwrite, or delete it. Until a value is set, a read
fails with `ResourceNotFoundException` - expected, not a bug.

## Reading a secret

```python
from edp_secrets import GetSecretOperator

fetch = GetSecretOperator(task_id="fetch_token", key="example_secret")
```

`GetSecretOperator` gets `aws_conn_id` (the namespace) for free from the
platform's cluster policy, the same mechanism `edp_dbt.DbtOperator` uses -
see `airflow/dags/README.md`. For the module directly (e.g. inside a
`@task` callable, which has no `aws_conn_id` for the cluster policy to
populate), recover the namespace from the DAG's own `dag_id` instead -
`dag_policy` always prefixes it `<namespace>.<dag_id>`:

```python
from airflow.decorators import task
from airflow.models import Variable
from edp_secrets import secrets_manager_client

@task
def use_a_secret(**context):
    aws_conn_id = context["dag"].dag_id.split(".", 1)[0]
    environment = Variable.get("environment")
    return secrets_manager_client.get_secret_value(
        aws_conn_id=aws_conn_id,
        SecretId=f"airflow/{environment}/namespaces/{aws_conn_id}/example_secret",
    )
```

Prefer `GetSecretOperator` over this where you can - it builds the full
Secrets Manager name for you from a plain `key`.

## Secret path

`airflow/<env>/namespaces/<namespace>/<key>` - `<key>` is a free-form path
segment (may contain `/`), not the `__`-joined suffix Airflow's own
Connections/Variables backend uses.

Your namespace's IAM role (`terraform/mwaa/mwaa.tf`'s
`aws_iam_role_policy.mwaa_namespace_secrets`) can `GetSecretValue`/
`DescribeSecret` on this prefix and nothing outside it - a different
namespace's role gets a real AWS `AccessDenied`, not just a naming
convention, if it tries your prefix. It cannot put, create, or delete a
secret at all; that's Terraform's and a platform admin's job respectively.

## Why this lives under `airflow/dags/`, and why there's no venv here

See `airflow/dags/README.md` for the full generic pattern. Short version:
`dags/` syncs to every scheduler/worker/webserver in ~1 minute vs.
`plugins.zip`'s 20-30 minute environment update. This plugin needs no
process isolation either: `boto3` already ships in the base MWAA image, so
`secrets_manager_client`/`GetSecretOperator` run directly in the Airflow
interpreter.

## Testing

`tests/` (excluded from the `dags/` S3 sync and DAG discovery, same as
`edp_dbt/tests/`) covers `secrets_manager_client` and `GetSecretOperator`
against a real Airflow install, stubbing only Secrets Manager itself via
`botocore.stub.Stubber` against a real `boto3.client`.

```bash
make check   # lint + typecheck + test, exactly what CI runs
```
