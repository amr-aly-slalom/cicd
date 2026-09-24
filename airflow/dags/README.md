# MWAA DAG Directory

## Namespace Directory Layout

Each use-case namespace has its own subdirectory under `airflow/dags/`:

```
airflow/dags/
├── platform/              ← platform team e2e tests
│   ├── e2e_scheduler.py
│   ├── e2e_aws_auth.py
│   ├── e2e_isolation.py
│   └── e2e_fargate.py
├── <namespace>/           ← one directory per registered namespace
│   └── <dag_id>.py
└── README.md              ← this file
```

A cluster policy (`airflow/plugins/airflow_local_settings.py`) prefixes every `dag_id` with its namespace automatically (`<namespace>.<dag_id>`), derived from the directory. Write plain `dag_id`s.

## Deploying Your DAGs via CI

Namespace teams deploy by syncing their own `dags/<namespace>/` directory to
S3 from their own CI - the platform does not merge namespace DAGs into this
repo. A reusable composite action,
[`publish-mwaa-artefact`](../../.github/actions/publish-mwaa-artefact/action.yaml),
wraps this so you don't need to know the platform's account IDs, IAM
role-naming convention, or S3 bucket name:

```yaml
steps:
  # ... whatever credential-setup step(s) give you (or let you assume) a
  # principal listed under spec.ci_roles[environment] for your namespace -
  # a self-hosted runner's instance profile, your own OIDC step, static
  # keys, anything. This action does not establish your initial AWS
  # identity itself; see the comment in action.yaml for why.
  - uses: <org>/chedaws-tf-edp-infra/.github/actions/publish-mwaa-artefact@main
    with:
      environment: dev
      namespace: finance
      source_dir: dags
```

The principal you hold when this step runs must already be listed under
`spec.ci_roles[environment]` in your `airflow/mwaa/<namespace>.yaml`
manifest - see
[`namespace-manifest.md`](../../specs/009-mwaa-airflow-platform/contracts/namespace-manifest.md).
The action chains from it into a namespace-scoped CI role that can only
write to `s3://<mwaa bucket>/dags/<namespace>/` - it has no access to
Secrets Manager or any other namespace-scoped resource.

## ECS Operator Invocation Requirements

When triggering Fargate tasks from a DAG using the `EcsRunTaskOperator` (or `EcsOperator`):

- **MUST specify both App-tier subnet IDs** for multi-AZ fault tolerance. Specifying only one subnet pins all Fargate tasks to a single Availability Zone.
- Retrieve subnet IDs from SSM Parameter Store or pass them in as Airflow Variables — do not hardcode them.

The following Airflow Variables are provisioned by Terraform and available to all DAGs via Jinja templating (`{{ var.value.<name> }}`):

| Variable | Description |
|---|---|
| `environment` | Deployment environment name (`dev`, `test`, `uat`, `prod`) |
| `app_subnet_a` | First App-tier subnet ID for Fargate task placement |
| `app_subnet_b` | Second App-tier subnet ID for Fargate task placement |
| `mwaa_security_group_id` | MWAA security group ID for Fargate task network configuration |
| `mwaa_s3_bucket` | MWAA DAG/plugins S3 bucket name |

Example:

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
            "subnets": ["{{ var.value.app_subnet_a }}", "{{ var.value.app_subnet_b }}"],
            "securityGroups": ["{{ var.value.mwaa_security_group_id }}"],
            "assignPublicIp": "DISABLED",
        }
    },
)
```

## Fargate CPU/Memory Ceiling

Fargate task definitions for MWAA namespaces have a governance ceiling of:
- **CPU**: 4 vCPU (4096 CPU units) maximum
- **Memory**: 8 GB (8192 MiB) maximum

CI tflint rules will reject any `aws_ecs_task_definition` resource that exceeds these limits.

## Authoring a namespace-scoped plugin

`edp_dbt` and `edp_secrets` (both under this directory) are the platform's
namespace-scoped plugins so far - dbt's own README (`edp_dbt/README.md`) and
Secrets Manager's (`edp_secrets/README.md`) stay tool-specific; this section
is the pattern both of them follow, for whoever builds the third one. This
is distinct from the platform-team-managed shared `plugins.zip` plugins
(`airflow/plugins/README.md`) - a namespace-scoped plugin is code any
namespace's DAG can use, behaving differently per calling namespace via the
mechanism below, not a single shared behavior identical for everyone.

### Why plugins live here, not in `airflow/plugins/`

`dags/` syncs to every scheduler/worker/webserver continuously (~1 minute).
`airflow/plugins/plugins.zip` (like `requirements.txt` and `startup.sh`) is
only read when the MWAA environment starts or is updated (~20-30 minutes,
every namespace's workers restart) - see `airflow/plugins/README.md`.

This applies regardless of whether your plugin needs process isolation.
`edp_dbt` needs it (dbt-core conflicts with Airflow's own Jinja2 pin) and
still lives under `dags/`; `edp_secrets` needs no isolation at all (boto3
already ships in the base MWAA image) and lives under `dags/` too, purely
because the fast sync is a strictly better deal with no downside - there's no
reason to accept a 20-30 minute update cycle when a 1 minute one is free.

A plain top-level `from <plugin> import ...` works identically whether a
package ships via `plugins.zip` or lives directly under `dags/` - confirmed
live via a local `aws/amazon-mwaa-docker-images` run (the actual
open-sourced MWAA base image): the `dags/` folder root is always on
`sys.path` regardless. No loader, no `importlib` tricks needed on your part.

### The namespace-discovery contract

This is the one thing every namespace-scoped plugin must do, and it's
already fully generic and free - no registration, no new code needed in
`airflow_local_settings.py` for your plugin specifically.

`airflow_local_settings.py`'s cluster policy sets a task's namespace at
DAG-parse time:

```python
def task_policy(task: BaseOperator) -> None:
    namespace = _namespace_from_fileloc(task.dag.fileloc or "")
    if namespace and hasattr(task, "aws_conn_id"):
        task.aws_conn_id = namespace
```

Any `BaseOperator` subclass that declares an `aws_conn_id` attribute gets it
populated automatically, purely via `hasattr()` duck-typing - derived from
the DAG file's own path (`dags/<namespace>/...`). To participate:

1. Declare `self.aws_conn_id: str | None = None` in `__init__` (before the
   cluster policy has run - it fires after construction, at DAG-parse time).
2. If you read it inside `execute()` (you always will - it isn't set yet at
   `__init__` time), add `"aws_conn_id"` to `template_fields` so it survives
   DAG serialization to the worker's deserialized copy, which is what
   actually calls `execute()`. Forgetting this is a real, easy-to-hit bug:
   the attribute exists and works fine in-process, then comes back `None`
   (or raises `AttributeError` on a `SerializedBaseOperator`) the moment a
   real worker runs it from the metadata DB. Write a `test_serialization.py`
   (see Testing below) to catch this before it ships.

**Hooks don't get this for free.** A bare hook constructed inside a
`PythonOperator`/`@task` callable has no `.dag`/`.fileloc` for the cluster
policy to derive a namespace from - it only ever fires on real operators
discovered during DAG parsing. Two ways to bridge this, both used today:

- `edp_dbt.redshift.redshift_auth_vars(db=...)` returns a plain function,
  called by `DbtOperator.execute()` with `self.aws_conn_id` passed in
  explicitly.
- `edp_secrets.GetSecretOperator` builds the namespaced secret name itself and
  calls `secrets_manager_client.get_secret_value` with
  `aws_conn_id=self.aws_conn_id` passed straight through, for the same
  reason. A DAG author using the
  module-shaped API directly inside a bare `@task` callable has no such
  operator attribute to read at all - confirmed live,
  `context["task"].aws_conn_id` raises `AttributeError` on a plain `@task`'s
  underlying operator - so recover the namespace from `context["dag"].dag_id`
  instead: `dag_policy` always prefixes it `<namespace>.<dag_id>`, so
  `context["dag"].dag_id.split(".", 1)[0]` is the namespace. See
  `edp_secrets/README.md` for a worked example.

### Package layout

```
airflow/dags/<name>/
├── __init__.py       # re-exports the public API
├── operators.py       # and/or hook.py, or a plain module - see below
├── requirements.txt   # only if you need process isolation - see next section
├── README.md          # <name>-specific usage docs
└── tests/
    ├── conftest.py
    └── test_*.py
```

Add `<name>/` to `airflow/dags/.airflowignore` so it's never mistaken for a
DAG file during discovery. If your plugin's own name (or anything it
re-exports) could collide with a top-level module name some other package on
`sys.path` scans for - `edp_dbt`'s own gotcha: never name a module with a
`dbt` prefix, since dbt's plugin manager imports every top-level `dbt*`
module it finds - check for an equivalent landmine with whatever tool you're
wrapping.

There's no single mandated shape for the code itself - `edp_dbt` is a class
(`DbtOperator`) plus friendlier factory functions over it; `edp_secrets` is a
plain module of boto3-shaped functions (`secrets_manager_client.py`) plus two
thin operators over it. Pick whichever is closest to the tool you're
wrapping's own idiom - a plain module mirroring the underlying SDK's own
function names/shapes is often the better default over a class, unless the
tool itself is naturally stateful.

### Do you need process isolation?

Check whether the tool's dependencies actually conflict with Airflow's own
pins - a real `pip install` dependency resolution, not an assumption. `boto3`
(what `edp_secrets` needs) already ships in the base MWAA image with no
conflict risk; `dbt-core` (what `edp_dbt` needs) conflicts with Airflow's own
Jinja2 pin, confirmed via a real pip resolution failure.

**If yes** - follow `edp_dbt`'s pattern: wheels for the dependency closure
built centrally, at `terraform apply` time, where real PyPI access exists
(`ensure_wheels()` in `terraform/mwaa/scripts/mwaa_s3_bootstrap.sh` - already
generic, `name`/`requirements`/`dest` arguments, add one call for your
plugin), synced fast via `dags/<name>_wheels/`; the actual venv built
natively on each worker, on first use there, from those wheels
(`--no-index --find-links` - workers have no PyPI route), cached by a
fingerprint of `requirements.txt`'s content with a `.complete` marker and
atomic `os.rename` so a concurrent task never sees a half-built venv. See
`edp_dbt/operators.py`'s `_resolve_local_venv` for the reference
implementation to copy the *shape* of - there's no shared helper for this
yet (see "Why no shared venv/cache module yet" below), so copy it, don't try
to import from `edp_dbt`.

**If no** - run directly in the Airflow interpreter, an ordinary
hook/operator/module, no `ExternalPythonOperator`. This is `edp_secrets`'s
whole design.

#### The S3 content-fingerprint cache pattern

If your plugin needs to sync its own content from S3 with cache invalidation
(a project directory, a config bundle - not code, which just ships via
`dags/` directly) - `edp_dbt.operators._sync_from_s3` is the reference
implementation: fingerprint is a sha256 of the sorted `(key, ETag)` pairs
from listing the S3 prefix (not a TTL - a push of new content produces a new
fingerprint and the next run picks it up immediately), same
`.complete`-marker/atomic-rename cache pattern as the venv build above.
Same "copy the shape" note applies.

#### Why no shared venv/cache module yet

Both patterns above are genuinely reusable in shape, but extracting them into
a shared `airflow/dags/edp_common/`-style module now, with exactly one real
caller (`edp_dbt`) and `edp_secrets` never touching either, would be
guessing at the right abstraction from a single example. `edp_dbt` already
has two different fingerprint strategies for its two different cache types
(a file hash for the venv, a listing-based hash for S3 content) - a hint
that a single shared shape covering both isn't obviously right yet either.
Extract when a real second consumer needs process isolation, with that
consumer's own requirements informing the actual interface, not before.

### IAM / registration pattern for a new AWS-resource plugin

Namespaces are registered at `airflow/mwaa/<name>.yaml`, driving
`local.mwaa_namespaces` in `terraform/mwaa/mwaa.tf`. When your plugin needs
its own AWS permissions, the decision is:

- **No extra per-namespace metadata, no side-effectful provisioning beyond
  IAM** - add a same-file boolean flag (like `spec.fargate_enabled`, gating
  `aws_iam_role_policy.mwaa_namespace_fargate`) or grant unconditionally via
  `for_each = local.mwaa_namespaces` straight from the existing manifest
  (like `aws_iam_role_policy.mwaa_namespace_secrets` - `edp_secrets`'s own
  grant). Attach a new `aws_iam_role_policy` resource to
  `aws_iam_role.mwaa_namespace[each.key]` - its own resource, not folded into
  an existing one, for a clean diff/blast-radius boundary per capability
  even though several policies attach to the same role.
- **Genuine extra metadata, or a real side effect Terraform must
  orchestrate beyond IAM** - a separate `<service>/namespaces/<name>.yaml`
  registry, its own JSON Schema, and a CI validator script.
  `redshift/namespaces/<name>.yaml` is the worked example: it declares
  `spec.additional_schemas` (real per-namespace metadata) and gates a
  Terraform-orchestrated Redshift schema/group bootstrap
  (`terraform/scripts/redshift_namespace_bootstrap.sh`) - genuine extra
  machinery neither `fargate_enabled` nor a plain Secrets Manager IAM grant
  needs.

Never attach a new namespace capability to `aws_iam_role.mwaa_namespace_ci`
(the CI-only role, see "Deploying Your DAGs via CI" above) - it's
deliberately excluded from Secrets Manager and every other namespace-scoped
runtime capability by design, so CI credentials can never reach what only
running tasks should.

### Testing conventions

- Real Airflow install in every test, always - never a mocked Airflow.
  `conftest.py` inserts `dags/`'s root onto `sys.path`, mirroring how MWAA
  actually imports a `dags/`-rooted top-level package in production.
- Fake only the literal external boundary your plugin crosses - the
  third-party library itself via `sys.modules` injection (`edp_dbt`'s
  `dbt.cli.main`), or AWS itself via `botocore.stub.Stubber` against a real
  `boto3.client(...)` (`edp_secrets`'s Secrets Manager calls) - not moto,
  not a hand-rolled fake AWS. `botocore` ships with the pinned `boto3`
  dependency already, so `Stubber` costs nothing new; it stubs at the
  wire-protocol level against the real client, a closer match to production
  than a full in-memory service emulation.
- A `test_serialization.py` doing a real DAG serialize/deserialize round
  trip for any new `template_fields` - see the namespace-discovery section
  above for why this specific bug class is easy to miss otherwise.
- A `test_run_dbt.py`-style regression test - `inspect.getsource()`ing a
  callable that crosses a process boundary and `exec()`ing it in a bare
  namespace, to catch hidden reliance on enclosing-module globals that don't
  exist on the other side - is needed **only** for code that actually
  crosses a process boundary (like `edp_dbt._run_dbt`, cloudpickled into the
  dbt venv subprocess). Nothing in `edp_secrets` crosses one, so it has no
  equivalent test - don't add one out of habit.
- `make check` (ruff, ty, pytest, terraform fmt/validate/tflint, trivy) is
  the existing gate; add your plugin's paths to `PY_LINT_PATHS`/
  `PY_TEST_PATHS` in the `Makefile`.

### Backwards compatibility

- **Additive changes** (new operators, hooks, functions): safe to release
  immediately - the fast `dags/` sync means this reaches every worker within
  a minute, no coordinated rollout needed.
- **Breaking changes** (removed or renamed APIs): coordinate with every
  namespace team using the plugin before release; give at least one
  sprint's notice.

## AWS Connection Setup

See the **AWS Connection Setup** section below for credential-free DAG-to-AWS authentication using namespace IAM roles via Airflow Connections backed by AWS Secrets Manager.

### Secrets Manager secret format

Create a secret at path `airflow/connections/<namespace>` with the following JSON value:

```json
{
  "conn_type": "aws",
  "extra": "{\"role_arn\": \"arn:aws:iam::<account_id>:role/edp-<env>-mwaa-ns-<namespace>\"}"
}
```

### Connection ID usage in DAGs

Reference the connection by its ID, `<namespace>`:

```python
from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

hook = AwsBaseHook(aws_conn_id="platform", client_type="s3")
client = hook.get_client_type()
```

**IMPORTANT**: DAGs MUST NOT contain hardcoded AWS credentials (access key IDs, secret access keys, session tokens). CI runs credential scanning (`checkov` + `gitleaks`) on all DAG files and will reject any commit containing hardcoded credentials (SC-005).
