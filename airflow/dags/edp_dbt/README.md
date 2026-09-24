# `edp_dbt` — dbt Core operator

Runs dbt Core against a project, in its own isolated virtualenv. dbt cannot be installed into the Airflow interpreter itself (it and Airflow contend on Jinja2 - confirmed via a real pip dependency conflict between `apache-airflow` and `dbt-core`), so `DbtOperator` subclasses `ExternalPythonOperator` and invokes dbt's supported programmatic API, `dbtRunner`, inside that venv via its `bin/python` directly - never `bin/dbt` itself, see below. Most DAG authors want `edp_dbt.dbt`'s friendlier factories below, not `DbtOperator` directly.

```python
from edp_dbt import dbt

# "recon" here resolves to this task's own dags/<namespace>/recon prefix in
# the MWAA S3 bucket (namespace from aws_conn_id) - fetched once per content
# version and cached on the worker.
build = dbt.build(task_id="dbt_build", project="recon", target="dev")

# Selectors, and Airflow context passed through to --vars.
test = dbt.test(
    task_id="dbt_test",
    project="recon",
    select="marts",
    dbt_vars={"run_date": "{{ dag_run.run_after | ds }}"},
)

build >> test
```

Notes for DAG authors:

- **`dbt.build`/`dbt.run`/`dbt.test`/`dbt.seed`/`dbt.snapshot`/`dbt.compile`/
  `dbt.deps`/`dbt.parse`/`dbt.ls`** are thin factories, one per dbt
  subcommand, that build `DbtOperator`'s `args` from friendlier
  `select`/`exclude`/`dbt_vars` kwargs and forward everything else
  (`project`, `target`, `env_vars`, ...) straight through. `task_id`
  defaults to the subcommand name. `extra_args` (a plain `list[str]`) is
  appended last for anything else dbt accepts - e.g.
  `dbt.build(project="recon", extra_args=["--threads", "4", "--fail-fast"])`
  - for anything bigger, or that needs to come before `--select`/`--vars`,
  use `dbt.cli` instead.
- **`dbt.cli(args)`** is the escape hatch for anything the named factories
  don't cover — pass the raw dbt CLI args yourself, subcommand first (e.g.
  `dbt.cli(["build", "--fail-fast", "--threads", "4"])`). By default this
  skips `project=` entirely, which switches `DbtOperator` to **raw mode**:
  nothing is resolved and nothing is appended to `args` — no
  `--project-dir`, `--profiles-dir`, `--target`, or `--no-use-colors`.
  `args` runs exactly as given, so include whatever dbt needs yourself. You
  can still pass `project=`/`target=` to `dbt.cli` if you want
  `DbtOperator`'s usual resolution — just don't also put those same flags in
  `args` in that case, since they'd get appended a second time.
- **`DbtOperator(args=[...], ...)`** is the primitive underneath all of the
  above — it takes the dbt CLI args verbatim and has no notion of which
  subcommands are "allowed."
- **`project`** (on `DbtOperator`, and any factory above except `dbt.cli` by
  default) resolves in order: a directory bundled platform-wide under
  `/usr/local/airflow/dags/dbt_projects` (for shared/demo projects); otherwise
  relative to this task's own `dags/<namespace>/` prefix in the MWAA S3
  bucket; or a full `s3://bucket/prefix` URI, for a project outside your own
  namespace. The S3 forms are downloaded once per content version and cached
  on the worker; a push of new models changes the fingerprint and the next
  run picks it up.
- **`env_vars`** takes a `def f(aws_conn_id: str | None) -> dict[str, str]`,
  called at execute() time with this task's own `aws_conn_id`; the result
  becomes real environment variables for the dbt subprocess, typically read
  back via `profiles.yml`'s `env_var(...)`. For Redshift:

  ```python
  from edp_dbt import dbt, redshift_auth_vars

  dbt.build(task_id="dbt_build", project="recon", env_vars=redshift_auth_vars(db="edp"))
  ```

  Must be a plain top-level function, not a lambda or closure - a bare
  callable doesn't survive DAG serialization, the same constraint dbt's own
  `python_callable` already has, so it's re-imported at execute() time
  instead. This works equally well whether the function lives in a real
  installed module (like `redshift_auth_vars` above) or directly in your
  own DAG file - e.g. to combine Redshift auth with other variables:

  ```python
  from edp_dbt import dbt, redshift_auth_vars

  def my_env_vars(aws_conn_id: str | None) -> dict[str, str]:
      creds = redshift_auth_vars(db="edp")(aws_conn_id)
      return {**creds, "SOME_OTHER_VAR": "value"}

  dbt.build(task_id="dbt_build", project="recon", env_vars=my_env_vars)
  ```
- **`db` is always explicit.** Redshift binds the credentials it issues to
  the database they were requested for: using them against a different one
  is refused at login with `FATAL 28000 IAM authentication failed`, which
  looks like an IAM problem but isn't. So `redshift_auth_vars` has no
  default - `db="edp"` says edp, and anything else must also be listed in
  your namespace's `spec.writable_databases`
  (`redshift/namespaces/<name>.yaml`) for the role to be allowed to ask for
  it:

  ```python
  from edp_dbt import dbt, redshift_auth_vars

  dbt.build(
      task_id="dbt_build",
      project="recon",
      env_vars=redshift_auth_vars(db="edp_raw_dev"),
  )
  ```

  `redshift_auth_vars(db=...)` returns a `functools.partial`, so no wrapper
  function is needed. Passing it uncalled (`env_vars=redshift_auth_vars`) is
  rejected when the DAG is parsed.

- **One DAG across every environment.** `db` is templated per run like every
  other template field, so write the environment in rather than hardcoding
  `dev`:

  ```python
  env_vars=redshift_auth_vars(db="edp_raw_{{ var.value.environment }}")
  ```

  `var.value.environment` holds `dev`/`test`/`uat`/`prod` (see
  `airflow/README.md`), and renders on the worker - prefer it to calling
  `Variable.get()` at the top of a DAG file, which hits the secrets backend
  on every parse. `{{ params.x }}`, XComs and the rest work the same way;
  values must be plain scalars.

  Each environment's database still has to be listed under that
  environment's `spec.writable_databases`, or the credential request is
  denied there - a DAG that works in dev fails in test if only `edp_raw_dev`
  is registered.
- **A failing dbt test fails the task.** The operator raises on
  `dbtRunnerResult.success == False`; nothing wraps or swallows the result.
- **Use `{{ dag_run.run_after | ds }}`, not `{{ ds }}`.** In Airflow 3
  `logical_date` is nullable, so `ds` fails to render on a manually-triggered
  run — which during development is every run.
- **Never name a module in `dags/` with a `dbt` prefix.** dbt's plugin manager
  imports every top-level `dbt*` module on `sys.path`, and the DAGs folder is
  on `sys.path`. Such a module gets imported inside the dbt venv, where
  `import airflow` fails, breaking the dbt run with an unrelated-looking
  traceback.

## Why this lives under `airflow/dags/`, not `airflow/plugins/`

`edp_dbt`'s own wrapper code (`operators.py`, `dbt.py`, `redshift.py`) is
plain Python with no third-party dependencies beyond Airflow itself - it
just constructs `DbtOperator`/`ExternalPythonOperator` instances. `dags/`
syncs to every scheduler/worker/webserver continuously (~1 minute);
`plugins.zip` (like `requirements.txt` and `startup.sh`) is only read when
the MWAA environment starts or is updated (~20-30 minutes). Confirmed live,
via a local `aws/amazon-mwaa-docker-images` run (the actual open-sourced
MWAA base image): a plain top-level `from edp_dbt.operators import
DbtOperator` import works identically whether `edp_dbt` ships via
`plugins.zip` or lives directly under `dags/` - the dags/ folder root is
always on `sys.path` regardless. No loader, no `importlib` tricks, no
change to how DAG authors import it - it's ordinary Python, just synced on
the fast path instead of the slow one. `.airflowignore` excludes
`edp_dbt/` (and `edp_dbt_wheels/`, below) from DAG discovery, so none of
this gets mistaken for a DAG file.

## The dbt venv

Wheels for dbt-core's entire dependency closure are pre-built at
`terraform apply` time (by `ensure_wheels()` in
`terraform/mwaa/scripts/mwaa_s3_bootstrap.sh`, from this directory's
`requirements.txt`) and synced continuously to `dags/edp_dbt_wheels/`.
`DbtOperator._resolve_local_venv()` builds an actual venv from them
**natively on the worker**, the first time it's needed there (or whenever
`requirements.txt` changes), cached in a worker-local directory so it's a
one-time cost per worker rather than per task. `airflow/startup.sh` no
longer builds anything itself - kept only because
`aws_mwaa_environment.airflow`'s `startup_script_s3_object_version`
always needs to point at something real.

This two-step design (wheels built centrally and shipped fast; the venv
itself built locally, on demand) is deliberate, not incidental - both
alternatives that skip one of the two steps were tried first and
confirmed dead live:

- **Shipping a fully pre-built venv** (built once on the CI runner, synced
  to `dags/`, used directly) fails on two independent fronts. First,
  `dags/` is read-only on a worker - confirmed live, a `chmod` attempt on
  anything under it raises `OSError: Read-only file system`, so even a
  correctly-permissioned venv couldn't be created there, and whatever
  permissions actually land after the sync can't be fixed up in place
  either way. Second, and more fundamentally: a venv built with `python3
  -m venv` bakes the *building* machine's own Python installation path
  into `pyvenv.cfg`, and a worker doesn't have whatever the CI runner
  happens to have there - confirmed live, copying a CI-built venv to a
  worker and invoking its `bin/python` directly fails immediately with
  `Fatal Python error: init_fs_encoding ... ModuleNotFoundError: No
  module named 'encodings'`, because the copied interpreter can't find a
  standard library that was never copied anywhere near it. Wheels don't
  have this problem: they carry a platform/ABI tag (`cp312-manylinux...`),
  not an absolute path, so a venv built *from* them is always native to
  whatever machine actually runs `pip install`.
- **Building the venv on each worker at boot** (`airflow/startup.sh`'s
  original design) sidesteps both of the above - the venv is native by
  construction - but only ever runs once, at environment start, so a
  `requirements.txt` change needs a full ~20-30 min MWAA environment
  update to take effect, which is the whole problem this move away from
  `airflow/plugins/` was meant to solve in the first place.

`_resolve_local_venv()` combines both halves' advantages: it runs
`python3 -m venv` and `pip install --no-index --find-links=<wheels
synced via dags/> -r requirements.txt` using `sys.executable` - the
Airflow interpreter's own, i.e. this worker's native Python - so the
result is always correctly native, and it runs lazily on first use rather
than unconditionally at boot, cached locally by a fingerprint of
`requirements.txt`'s content so a worker only ever pays this cost once
per version. Both the wheels and `requirements.txt` are read from `dags/`
(read-only, which is fine - pip only ever writes into the venv it's
creating, in the writable local cache); nothing is ever written back to
`dags/`.

**Workers have no path to PyPI at all** (confirmed against the live route
tables - the MWAA app subnets have no route to `0.0.0.0/0`), which is
exactly why `pip install` here is `--no-index --find-links` against
wheels pre-built somewhere that does have PyPI access (the CI runner, at
`terraform apply` time) - the same offline-install technique
`mwaa-plugin-wheels/` used for the old, since-removed approach that built
the venv on the worker only at boot.

`ensure_wheels()` only rebuilds and re-syncs when `requirements.txt` has
actually changed (a content-hash marker in `build-markers/`, outside
dags/ entirely - purely the script's own bookkeeping, never synced to
MWAA). `--quiet` on both the wheel-building `pip` calls and the sync
itself keeps a real rebuild's CI output reasonable.

**Generic, not dbt-specific.** `ensure_wheels()` takes a name, a
requirements file, and an S3 destination; dbt is the first consumer, not
the only possible one. A future plugin needing its own isolated
third-party dependencies (unrelated to, or in conflict with, Airflow's
own) can use the exact same pattern - its own `requirements.txt`, its own
`ensure_wheels()` call in `mwaa_s3_bootstrap.sh`, its own
`dags/<name>_wheels/` prefix, and its own worker-local lazy-build cache
mirroring `_resolve_local_venv()` - with the same "no PyPI on the worker"
constraint, and the same immunity to import-order collisions with
Airflow's own dependencies that process isolation gives dbt here
(confirmed the hard way in a different context: vendoring a package
directly onto `sys.path` instead of into its own venv is NOT reliably
overridable if that exact package already exists anywhere in Airflow's
own dependency tree - whichever copy some other import reaches first
wins, since Python checks `sys.modules` before `sys.path`; a separate
venv sidesteps this entirely because it's a different interpreter, not
just a different import path).

The dbt version is pinned in `requirements.txt` (in this directory) and is
**environment-wide** — every namespace gets the same one. Bumping it is a
`terraform apply` plus the dags/ sync window on whichever worker next
needs a fresh venv, not an environment update.

## Linting, typechecking, and running the tests

`tests/` (excluded from both `plugins.zip` - moot now, this directory
never ships there - and the `dags/` S3 sync, since it imports `pytest`,
which no real environment has) covers `DbtOperator` and `_run_dbt` against
a real Airflow install, with `dbt.cli.main` mocked rather than real
dbt-core - `_run_dbt` can't even be imported under a dbt-only venv, since
importing `edp_dbt.operators` at all requires Airflow. See
`tests/test_run_dbt.py`'s module docstring for what that does and doesn't
cover.

Dependencies and ruff config all live in the repo-root `pyproject.toml`,
pinned by `uv.lock`. From the repo root:

```bash
make setup   # uv sync - creates .venv with the pinned versions
make check   # lint + typecheck + test, exactly what CI runs
```

`make test` / `make lint` / `make typecheck` run the pieces individually.
