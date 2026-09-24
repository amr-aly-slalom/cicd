# MWAA Namespace Onboarding

Apache Airflow is hosted on AWS MWAA as a shared, multi-tenant platform. Each team operates within a **namespace** — a logical boundary that provides its own IAM role, AWS connection, S3 DAG prefix, and (optionally) Fargate compute infrastructure. All namespaces share a single Airflow scheduler and web server.

- Airflow version: **3.2.1**
- Provider: `apache-airflow-providers-amazon` (bundled with MWAA)
- Web server access: **private only** — reachable via VPN or Direct Connect

---

## Quick Reference

Everything provisioned for a namespace follows a deterministic naming pattern. Replace `<namespace>` with your `metadata.name` value and `<env>` with the target environment (`dev`, `test`, `uat`, `prod`).

| Resource | Name / URI |
|---|---|
| Airflow web UI | Obtain from `terraform output mwaa_webserver_url` after apply (VPN/Direct Connect required) |
| MWAA environment | `chedaws-edp-mwaa-<env>` |
| Namespace IAM role | `edp-<env>-mwaa-ns-<namespace>` |
| CI deploy IAM role | `edp-<env>-mwaa-ns-<namespace>-ci` (only if `ci_roles` declared) |
| Airflow connection ID | `<namespace>` |
| Secrets Manager connection path | `airflow/<env>/connections/<namespace>` |
| Namespace secrets prefix | `airflow/<env>/namespaces/<namespace>/<key>` |
| S3 DAG prefix | `s3://chedaws-edp-mwaa-<env>-<account_id>-ap-southeast-2/dags/<namespace>/` |
| ECR repository URI | `<account_id>.dkr.ecr.ap-southeast-2.amazonaws.com/chedaws-edp-mwaa-<namespace>-<env>` (Fargate only) |
| Fargate execution role | `edp-<env>-fargate-exec-<namespace>` (Fargate only) |
| Fargate log group | `/chedaws-edp/fargate/<namespace>/<env>` (Fargate only) |
| ECS cluster | `chedaws-edp-mwaa-fargate-<env>` (shared across all Fargate namespaces) |

Look up live values after apply:

```bash
cd terraform
terraform workspace select <env>

terraform output mwaa_webserver_url          # Airflow web UI URL
terraform output mwaa_s3_bucket_name         # DAGs/plugins bucket name
terraform output mwaa_namespace_role_arns    # All namespace IAM role ARNs
terraform output mwaa_namespace_ci_role_arns # All CI role ARNs
terraform output mwaa_ecr_repository_urls    # ECR repo URLs (Fargate namespaces)
terraform output mwaa_fargate_cluster_arn    # Shared ECS cluster ARN
```

---

## Requesting a Namespace

Create a file at `airflow/mwaa/<namespace>.yaml` and open a pull request. No Terraform edits are required — the platform reads all `*.yaml` files in that directory automatically.

```yaml
apiVersion: mwaa.chedaws.io/v1
kind: Namespace
metadata:
  name: <namespace>          # snake_case; must be unique across all namespaces
  owner: <team-name>
  description: <one-line description>

spec:
  fargate_enabled: <true|false>   # set to true to get Fargate compute + ECR repository

  sso_roles:                      # optional; grants Airflow UI access via IAM Identity Center
    dev:  <permission-set-name>
    test: <permission-set-name>
    uat:  <permission-set-name>
    prod: <permission-set-name>

  ci_roles:                       # optional; IAM role ARNs allowed to deploy DAGs from CI
    dev:
      - arn:aws:iam::<account_id>:role/<role_name>
    prod:
      - arn:aws:iam::<account_id>:role/<role_name>
```

See [airflow/mwaa/platform.yaml](mwaa/platform.yaml) for a complete working example.

**Decommissioning**: set `spec.decommission: true` in the manifest, merge and apply, then delete the file in a follow-up PR once resources are destroyed - a convention for a clean, reviewable destroy plan; deleting the file directly destroys the same resources on the next apply either way.

---

## What Gets Provisioned

Terraform creates the following resources for every namespace on `terraform apply`.

### Always provisioned

| Resource | Name | Purpose |
|---|---|---|
| IAM role | `edp-<env>-mwaa-ns-<namespace>` | Namespace identity; assumed by the MWAA execution role for all tasks in the namespace |
| IAM role policy | `edp-<env>-mwaa-ns-<namespace>-s3` | Read/write access to `dags/<namespace>/*` in the MWAA S3 bucket; read access to own Secrets Manager connection prefix |
| IAM role policy | `edp-<env>-mwaa-ns-<namespace>-secrets` | Get/put/create access to own `airflow/<env>/namespaces/<namespace>/*` Secrets Manager prefix - see `edp_secrets`'s README |
| IAM role policy | `edp-<env>-mwaa-ns-<namespace>-api` | `airflow:CreateWebLoginToken` for the Op FAB role - lets DAG code call the Airflow REST API/UI directly; see "Calling the Airflow REST API" below |
| Secrets Manager secret | `airflow/<env>/connections/<namespace>` | Connection URI that assumes the namespace IAM role; surfaced to DAGs as the `<namespace>` connection |

If `ci_roles` are declared for an environment, an additional role is created:

| Resource | Name | Purpose |
|---|---|---|
| IAM role | `edp-<env>-mwaa-ns-<namespace>-ci` | Assumed by CI pipelines; write-only access to `dags/<namespace>/*` in S3 |

### Provisioned when `fargate_enabled: true`

| Resource | Name | Purpose |
|---|---|---|
| IAM role policy | `edp-<env>-mwaa-ns-<namespace>-fargate` | Allows `ecs:RunTask/DescribeTasks/StopTask` on ECS tasks tagged `MwaaNamespace=<namespace>` |
| ECR repository | `chedaws-edp-mwaa-<namespace>-<env>` | Private container registry for Fargate task images; namespace role + CI roles can push, Fargate exec role can pull |
| Fargate execution role | `edp-<env>-fargate-exec-<namespace>` | Assumed by ECS at task launch; grants ECR pull and CloudWatch Logs write |
| CloudWatch log group | `/chedaws-edp/fargate/<namespace>/<env>` | Fargate task logs |

---

## Information Available to Consumers

After provisioning, the following are ready for use in DAGs.

### AWS connection

The connection `<namespace>` is auto-provisioned in Secrets Manager. Using it in a DAG gives the task credentials scoped to the namespace IAM role — no hardcoded keys, no cross-namespace access.

```python
from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

hook = AwsBaseHook(aws_conn_id="<namespace>", client_type="s3")
client = hook.get_client_type()
```

All AWS SDK calls through this hook assume `arn:aws:iam::<account>:role/edp-<env>-mwaa-ns-<namespace>`.

### Platform Airflow Variables

These variables are provisioned by Terraform and available to all namespaces via Jinja templating (`{{ var.value.<name> }}`):

| Variable | Value | Example use |
|---|---|---|
| `environment` | `dev`, `test`, `uat`, or `prod` | Construct resource names dynamically |
| `app_subnet_a` | First App-tier subnet ID | Fargate `networkConfiguration` |
| `app_subnet_b` | Second App-tier subnet ID | Fargate `networkConfiguration` |
| `mwaa_security_group_id` | MWAA security group ID | Fargate `networkConfiguration` |
| `mwaa_s3_bucket` | MWAA S3 bucket name | Reading/writing DAG artefacts |

### Namespace-scoped Variables and Connections

Namespace teams can add their own additional Connections by creating Secrets Manager
secrets under this path (surfaced to DAGs via Airflow's own secrets backend, as
`Connection` objects):

| Type | Secret path | Airflow key |
|---|---|---|
| Connection | `airflow/<env>/connections/<namespace>__<conn_id>` | `<namespace>__<conn_id>` |

The namespace IAM role has `secretsmanager:GetSecretValue`/`DescribeSecret` on
`airflow/<env>/connections/<namespace>-*` and `<namespace>__*`. There is currently no
equivalent grant for a namespace-Variable-shaped path - if you need to hand a DAG an
arbitrary application secret rather than a full Airflow Connection, use `edp_secrets`
below instead.

### Namespace-scoped application secrets (`edp_secrets`)

For an arbitrary key/value secret that isn't shaped like an Airflow Connection - an
API token, a partner credential, anything your own DAG code just needs to read back -
declare it in your namespace manifest instead of creating a Secrets Manager secret by
hand:

```yaml
spec:
  secrets:
    - api_partner_token
```

Terraform creates `airflow/<env>/namespaces/<namespace>/api_partner_token` on the next
apply; a platform admin sets its value by hand. Read it back with the `edp_secrets`
plugin (`airflow/dags/edp_secrets/`, see its README):

```python
from edp_secrets import GetSecretOperator

fetch = GetSecretOperator(task_id="fetch_token", key="api_partner_token")
```

The namespace IAM role can only `GetSecretValue`/`DescribeSecret` under its own
prefix - it cannot put, create, or delete a secret. See
`airflow/dags/edp_secrets/README.md` for the full API and
`airflow/dags/README.md` for the generic namespace-scoped-plugin pattern this and
`edp_dbt` both follow.

### Calling the Airflow REST API

Your namespace role can call `airflow:CreateWebLoginToken`, exchange it for a
session, and hit Airflow's own REST API - e.g. to trigger another DAG or check a
run's status from inside your own:

```python
import boto3
import requests
from airflow.models import Variable

def _airflow_session() -> requests.Session:
    client = boto3.client("airflow")
    token = client.create_web_login_token(
        Name=f"chedaws-edp-mwaa-{Variable.get('environment')}",
    )
    login = requests.post(
        f"https://{token['WebServerHostname']}/pluginsv2/aws_mwaa/login",
        data={"token": token["WebToken"]},
    )
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {login.cookies['_token']}"
    return session

session = _airflow_session()
session.get(f"https://{hostname}/api/v2/dags/{namespace}.{dag_id}/dagRuns")
```

This authenticates as the **Op** FAB role - there's no per-namespace Airflow RBAC
today, so it can see and manage every namespace's DAGs, not just your own; treat
it accordingly. `boto3` already ships in the base MWAA image, no extra dependency.

### S3 DAG prefix

DAG files must be placed under `dags/<namespace>/` in the MWAA S3 bucket:

```
chedaws-edp-mwaa-<env>-<account_id>-<region>/
└── dags/
    └── <namespace>/       ← your DAGs live here
```

The bucket enforces KMS encryption (`alias/chedaws-edp-s3-<env>`) and TLS-only access on all operations.

### ECR repository (Fargate namespaces only)

Repository URI: `<account_id>.dkr.ecr.ap-southeast-2.amazonaws.com/chedaws-edp-mwaa-<namespace>-<env>`

Images tagged `latest` or with a semantic version are retained. Untagged images are expired after 14 days.

---

## Creating and Deploying DAGs

### Directory layout

Create a subdirectory matching your namespace name under `airflow/dags/`:

```
airflow/dags/
└── <namespace>/
    ├── <dag_name>.py
    └── <other_dag>.py
```

A cluster policy (`airflow/plugins/airflow_local_settings.py`) prefixes every `dag_id` with its namespace automatically at parse time (`<namespace>.<dag_id>`), derived from the directory the file lives in. Write plain `dag_id`s; don't prefix them yourself.

```python
# airflow/dags/finance/load_transactions.py

from airflow.decorators import dag, task
from datetime import datetime

@dag(
    dag_id="load_transactions",
    schedule="@daily",
    start_date=datetime(2026, 1, 1),
    catchup=False,
)
def load_transactions():
    @task
    def extract():
        ...
```

### Deploying DAGs

DAG files are deployed to S3 via the platform's Terraform pipeline — there is no separate DAG upload step. To deploy:

1. Add or update `.py` files in `airflow/dags/<namespace>/`.
2. Open a pull request and merge to `main`.
3. `terraform apply` runs and `aws s3 sync` uploads all DAGs in `airflow/dags/` to the `dags/` prefix in the MWAA S3 bucket.

MWAA polls the S3 bucket and picks up new and changed DAGs within a few minutes of upload.

---

## Available Operators

All operators in `apache-airflow-providers-amazon` are available without any additional installation.

### Standard Python and Bash

```python
from airflow.operators.bash import BashOperator
from airflow.decorators import task

@task
def my_python_task():
    ...
```

### AWS API calls via AwsBaseHook

Use `AwsBaseHook` inside a `@task`-decorated function for any AWS SDK call. Credentials are injected from the namespace connection — no keys in code.

```python
from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

@task
def list_objects():
    hook = AwsBaseHook(aws_conn_id="<namespace>", client_type="s3")
    client = hook.get_client_type()
    return client.list_objects_v2(Bucket="{{ var.value.mwaa_s3_bucket }}")
```

### EcsRunTaskOperator (Fargate)

Requires `fargate_enabled: true` in the namespace manifest. Both App-tier subnets must be specified for multi-AZ fault tolerance.

```python
from airflow.providers.amazon.aws.operators.ecs import EcsRunTaskOperator

run_task = EcsRunTaskOperator(
    task_id="run_my_task",
    cluster="chedaws-edp-mwaa-fargate-{{ var.value.environment }}",
    task_definition="chedaws-edp-mwaa-<namespace>-<task>-{{ var.value.environment }}",
    launch_type="FARGATE",
    overrides={},
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
    awslogs_group="/chedaws-edp/fargate/<namespace>/{{ var.value.environment }}",
    awslogs_stream_prefix="ecs/<container-name>",
    awslogs_region="ap-southeast-2",
    deferrable=False,
)
```

Fargate task definitions have a governance ceiling of **4 vCPU / 8 GB memory** enforced by CI.

### Shared plugins

Shared plugins are distributed via `plugins/plugins.zip` in the MWAA S3 bucket. Import them directly:

```python
from my_shared_plugin import MyOperator
```

To request a new shared plugin, open a PR adding the plugin source to `airflow/plugins/` and updating [airflow/plugins/README.md](plugins/README.md).

---

## CI Validations

Every pull request touching `airflow/` runs the following checks:

| Check | What it does |
|---|---|
| **Credential scanning** | `checkov` + `gitleaks` reject hardcoded AWS credentials in any DAG file |
| **Terraform lint/plan** | `tflint` and `trivy` validate any Terraform changes; `terraform plan` runs for each environment |

---

## Further Reading

- [airflow/dags/README.md](dags/README.md) — detailed DAG conventions, operator examples, and variable reference
- [airflow/plugins/README.md](plugins/README.md) — plugin lifecycle and contribution guide
- [specs/009-mwaa-airflow-platform/plan.md](../specs/009-mwaa-airflow-platform/plan.md) — platform architecture and infrastructure design
