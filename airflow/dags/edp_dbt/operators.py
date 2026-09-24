"""DbtOperator - runs dbt Core in the platform-managed virtualenv.

Most DAG authors want edp_dbt.dbt's per-command factories
(``dbt.build(project="demo")``) or its ``dbt.cli(...)`` escape hatch, not
this class directly - see that module. DbtOperator itself is the primitive
underneath both: it takes the dbt CLI args verbatim (``args=["build", ...]``)
and has no notion of which subcommands are "allowed" - the venv path, the
interpreter, the callable, the project root and the temp-directory handling
are the platform concerns that stay here.
"""

from __future__ import annotations

import functools
import hashlib
import importlib
import importlib.util
import inspect
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable, Sequence
from pathlib import Path
from types import ModuleType
from typing import Any, Protocol, TypedDict, cast

# airflow.exceptions imports AirflowException from airflow.sdk.exceptions without
# the `as AirflowException` self-alias its sibling exports use, so mypy's
# --no-implicit-reexport (part of --strict) sees it as a re-export gap upstream
# rather than one of ours.
from airflow.exceptions import AirflowException  # type: ignore[attr-defined]
from airflow.providers.common.compat.sdk import Context
from airflow.providers.standard.operators.python import ExternalPythonOperator

# Sentinel meaning "build me a venv locally" (see _resolve_local_venv) -
# not a real path read directly. A caller passing anything else here gets
# that path used verbatim instead, with no caching/building at all - an
# escape hatch for an already-built, already-local venv.
DEFAULT_DBT_VENV = "/usr/local/airflow/dags/edp_dbt_venv"

# dbt-core's entire dependency closure, pre-built as wheels at `terraform
# apply` time (real PyPI access there; workers have none - confirmed
# against the live route tables) and synced continuously via the dags/
# prefix - see terraform/mwaa/scripts/mwaa_s3_bootstrap.sh's
# ensure_wheels(). requirements.txt lives alongside edp_dbt's own source,
# already synced via dags/ regardless of anything wheel-related.
DEFAULT_DBT_WHEELS = "/usr/local/airflow/dags/edp_dbt_wheels"
DEFAULT_DBT_REQUIREMENTS = "/usr/local/airflow/dags/edp_dbt/requirements.txt"

# Worker-local, writable cache for a venv built from the wheels above - not
# exposed as a constructor parameter (unlike cache_root/projects_root):
# this is an implementation detail, not something a DAG author has a
# reason to point elsewhere.
#
# Named "..._wheels", not "..._venv": an earlier, abandoned design (ship a
# pre-built venv, copy it here) used "_venv" for this same root and keyed
# its cache dirs by the identical md5(requirements.txt) fingerprint this
# design uses. Confirmed live: a worker that had already built that stale,
# non-relocatable cache entry during earlier testing kept serving it
# straight back out here too - same fingerprint, same ".complete" marker,
# no way for a cache-hit check to tell "valid wheels-built venv" apart from
# "stale copied venv from the dead design." A distinct root sidesteps this
# permanently, rather than patching the fingerprint to dodge one specific
# collision.
_LOCAL_VENV_CACHE_ROOT = "/usr/local/airflow/tmp/edp_dbt_wheels_venv"

# Where a bare project name resolves. Projects placed here ride along in the
# DAGs folder, which MWAA syncs to every worker.
DEFAULT_PROJECTS_ROOT = "/usr/local/airflow/dags/dbt_projects"

# Worker-local cache for projects fetched from S3. Per-worker and disposable:
# a miss costs a download, never correctness.
DEFAULT_CACHE_ROOT = "/usr/local/airflow/tmp/dbt-projects"


class DbtNodeResult(TypedDict):
    """One node's outcome, read defensively off dbt's per-command result shape.

    dbt's own result types vary by command (``List[str]`` for ``ls``,
    ``RunExecutionResult`` for ``build``/``run``/etc, a bare ``Manifest`` for
    ``parse``, ...), which is why every field below is read with
    ``getattr(..., default)`` rather than assumed present.
    """

    unique_id: str | None
    status: str
    execution_time: float | None
    message: str | None


class DbtRunResult(TypedDict):
    """Return shape of :func:`_run_dbt`, passed back through XCom."""

    success: bool
    command: str
    status_counts: dict[str, int]
    nodes: list[DbtNodeResult]


class _DbtEventInfo(Protocol):
    """The slice of dbt_common.events.base_types.EventMsg.info we read.

    The real object is a protobuf-generated CoreEventInfo with several more
    fields; dbt isn't installed in this (Airflow) venv - see module
    docstring - so this is a hand-written structural stand-in rather than an
    import of dbt's real type. Verified against a real fired event in
    dbt-core 1.12.3 / dbt-common (the pinned versions - see
    requirements.txt in this directory).
    """

    level: str
    msg: str


class _DbtEvent(Protocol):
    """The slice of dbt_common.events.base_types.EventMsg we read. See _DbtEventInfo."""

    info: _DbtEventInfo


class _DbtRunnerResult(Protocol):
    """The slice of dbt.cli.main.dbtRunnerResult we read. See _DbtEventInfo."""

    success: bool
    exception: BaseException | None
    # Varies by command - List[str] for ls, RunExecutionResult for
    # build/run/etc, a bare Manifest for parse, ... - which is why callers
    # only ever attempt iteration defensively (see DbtNodeResult).
    result: object


class _S3Object(TypedDict):
    """The slice of an S3 ListObjectsV2 entry we read."""

    Key: str
    ETag: str


class _S3Page(TypedDict, total=False):
    """The slice of an S3 ListObjectsV2 page we read.

    total=False: Contents is absent, not just empty, on a prefix with no
    objects - boto3 omits the key entirely rather than returning [].
    """

    Contents: list[_S3Object]


class _S3Paginator(Protocol):
    """The slice of a boto3 S3 list_objects_v2 paginator we use.

    Hand-written rather than importing boto3-stubs' real type: unlike dbt
    (see _DbtEventInfo), boto3 itself is available at runtime here - it's
    the *stubs* package (mypy-boto3-s3) that isn't, deliberately. It's a
    dev/type-checking-only dependency (pyproject.toml/uv.lock); making it
    an unconditional runtime import would drag it into the MWAA
    interpreter's own requirements.txt for zero runtime benefit. See
    EDP-597 for what happened when it briefly was one.
    """

    def paginate(self, *, Bucket: str, Prefix: str) -> Iterable[_S3Page]: ...


class _S3Client(Protocol):
    """The slice of a boto3 S3 client we use. See _S3Paginator."""

    def get_paginator(self, operation_name: str) -> _S3Paginator: ...
    def download_file(self, bucket: str, key: str, filename: str) -> None: ...


# Airflow's own DAG loader (airflow.dag_processing.importers.python_importer)
# imports every DAG file under a module name in this exact format
# (airflow.utils.file.get_unique_dag_module_name), registered ad hoc into
# that one process's sys.modules - never as a real importable package. A
# function defined directly in a DAG file therefore has a __module__ that
# no fresh importlib.import_module() call (on a different, later process -
# exactly what execute() is) can ever find; confirmed empirically, not just
# from reading the source. _encode_env_vars/_resolve_env_vars below handle
# that case by file path instead - see _encode_env_vars's docstring.
_DAG_FILE_MODULE_PREFIX = "unusual_prefix_"


def _encode_env_vars(func: Callable[..., dict[str, str]]) -> list[Any]:
    """Encodes an env_vars callable as ``[kind, location, qualname]`` (plus
    ``keywords`` for a partial - see below) for storage in a template_field
    (see DbtOperator's docstring) - JSON-safe, so it survives DAG
    serialization; :meth:`DbtOperator._resolve_env_vars` reverses this at
    execute() time. Two kinds:

    - ``["module", "<dotted module>", "<qualname>"]``: the common case - a
      function from a real installed module (e.g.
      ``edp_dbt.redshift.redshift_auth_vars``), re-imported the ordinary
      way.
    - ``["file", "<absolute path>", "<qualname>"]``: a function defined
      directly inside a DAG file - see ``_DAG_FILE_MODULE_PREFIX`` above.
      Recovered by loading that exact file directly from its absolute path
      instead, which (unlike its synthesized module name) is stable across
      processes - MWAA syncs dags/ identically to every scheduler and
      worker. This mirrors the fallback Airflow's own
      ``PythonVirtualenvOperator`` uses for a ``python_callable`` defined
      the same way (see ``get_python_source()`` /
      ``modified_dag_module_name`` in
      ``airflow/providers/standard/operators/python.py``).

    A :class:`functools.partial` of either kind gets a fourth element, its
    keywords dict, re-applied at execute() time. Kept as a real nested dict
    rather than a JSON string so Airflow templates it like any other
    template_field value.
    """
    keywords: dict[str, Any] = {}
    if isinstance(func, functools.partial):
        if func.args:
            raise ValueError(
                "env_vars partials must bind keyword arguments only - a "
                "positional one would take aws_conn_id's place."
            )
        keywords = dict(func.keywords)
        bad = {
            k: type(v).__name__
            for k, v in keywords.items()
            if not isinstance(v, str | int | float | bool | type(None))
        }
        if bad:
            raise ValueError(
                f"env_vars partial keywords must be strings, numbers, booleans "
                f"or None - these are not: {bad}"
            )
        func = func.func
    if func.__name__ == "<lambda>" or "<locals>" in func.__qualname__:
        raise ValueError(
            "env_vars must be a plain top-level function (optionally as a "
            "functools.partial of one), not a lambda or closure - see "
            "DbtOperator's docstring for why."
        )
    try:
        inspect.signature(func).bind(None, **keywords)
    except TypeError as exc:
        raise ValueError(
            f"env_vars must be callable as f(aws_conn_id) once its keywords "
            f"are applied, but {func.__qualname__} is not: {exc}. A factory "
            f"like redshift_auth_vars(db=...) has to be called, not passed "
            f"uncalled."
        ) from exc
    if func.__module__.startswith(_DAG_FILE_MODULE_PREFIX):
        ref: list[Any] = ["file", inspect.getfile(func), func.__qualname__]
    else:
        ref = ["module", func.__module__, func.__qualname__]
    return [*ref, keywords] if keywords else ref


def _run_dbt(
    args: list[str],
    project_dir: str | None = None,
    target: str | None = None,
) -> DbtRunResult:
    """Runs INSIDE the dbt virtualenv. Self-contained by necessity - see module docstring.

    project_dir/target are only given for the DbtOperator(project=...) path
    (dbt.build/test/etc, via DbtOperator.execute()) - that's where the
    platform-managed --project-dir/--profiles-dir/--target/--no-use-colors
    flags get spliced in, right after args[0]. dbt.cli's raw path (no
    project=) leaves both None: args is run exactly as given, with nothing
    added - see DbtOperator's docstring.
    """
    import shutil
    import tempfile
    from collections import Counter
    from collections.abc import Iterable
    from pathlib import Path
    from typing import cast

    # dbt only exists in this venv, not the Airflow one this file is otherwise
    # checked against - see module docstring - so mypy can't resolve it here.
    from dbt.cli.main import dbtRunner  # type: ignore[import-not-found]

    # env_vars (DbtOperator's own param) is injected by ExternalPythonOperator
    # itself, into this subprocess's real environment, before this function
    # ever runs - see DbtOperator's docstring. A profiles.yml target
    # typically reads them back via env_var(...).

    command = args[0]
    workdir: Path | None = None

    if project_dir is not None:
        # dbt writes target/ and logs/ into the project directory, and the
        # DAGs folder is managed by MWAA's S3 sync, so work on a copy.
        workdir = Path(tempfile.mkdtemp(prefix="dbt-"))
        run_dir = workdir / "project"
        shutil.copytree(project_dir, run_dir)
        # command first, then platform-managed flags, then whatever the
        # caller's own args (args[1:] - e.g. --select/--vars/anything else)
        # asked for - matches dbt's own CLI, where global options are valid
        # either side of the subcommand.
        full_args = [
            command,
            "--project-dir",
            str(run_dir),
            "--profiles-dir",
            str(run_dir),
            "--target",
            str(target),
            "--no-use-colors",
            *args[1:],
        ]
    else:
        # Raw mode (dbt.cli without project=): args is already complete -
        # nothing is inserted, nothing to collide with.
        full_args = args

    try:
        print(f"Running dbt [{' '.join(full_args)}]...", flush=True)

        def on_event(event: _DbtEvent) -> None:
            # Stream dbt's own structured events into the Airflow task log.
            try:
                info = event.info
                if info.level not in ("debug", "test"):
                    print(f"{info.level.upper():<7} {info.msg}", flush=True)
            except Exception:  # noqa: BLE001, S110
                # Deliberately unconditional: a malformed or unexpected event
                # shape must never take down the whole dbt run over a log
                # line. See test_on_event_swallows_malformed_events.
                pass

        # A string forward-ref, not the real name: _DbtRunnerResult is defined
        # in this module's Airflow-interpreter scope, which _run_dbt cannot
        # see - it runs in an isolated subprocess in the dbt venv, extracted
        # to run standalone (see docstring). cast() never evaluates its type
        # argument at runtime regardless, so mypy resolves the string
        # statically and this never triggers a NameError. See EDP-597: the
        # unquoted version passed every test here (all in-process) but broke
        # on the first real Airflow run, which is the actual runtime shape.
        res = cast("_DbtRunnerResult", dbtRunner(callbacks=[on_event]).invoke(full_args))

        try:
            # res.result is `object` (see _DbtRunnerResult): the cast only
            # asserts an iteration attempt to mypy, it changes nothing at
            # runtime - the comprehension's implicit iter() still raises
            # TypeError below for the non-iterable shapes (bool, Manifest,
            # ...), same as an untyped access would.
            nodes: list[DbtNodeResult] = [
                {
                    "unique_id": getattr(getattr(r, "node", None), "unique_id", None),
                    "status": str(getattr(r, "status", "")),
                    "execution_time": getattr(r, "execution_time", None),
                    "message": getattr(r, "message", None),
                }
                for r in cast(Iterable[object], res.result)
            ]
        except TypeError:
            nodes = []  # commands like parse return a non-iterable result

        counts = Counter(n["status"] for n in nodes)

        if not res.success:
            failed = [str(n["unique_id"]) for n in nodes if n["status"] in ("error", "fail")]
            detail = f" Failing nodes: {', '.join(failed)}" if failed else ""
            print(f"dbt [{command}] failed.", flush=True)
            # Raising is what turns the Airflow task red. dbt reports a failed
            # test through res.success, so a red test cannot show as green.
            raise RuntimeError(f"dbt {command} failed.{detail} {res.exception or ''}".strip())

        print(f"dbt [{command}] finished successfully.", flush=True)
        return {
            "success": True,
            "command": command,
            "status_counts": counts,
            "nodes": nodes,
        }
    finally:
        if workdir is not None:
            shutil.rmtree(workdir, ignore_errors=True)


class DbtOperator(ExternalPythonOperator):
    """Run dbt against a project, resolved locally or from S3.

    A thin primitive, deliberately without dbt-command-specific parameters
    (``select``/``exclude``/``--vars``/etc.) or any notion of which
    subcommands are valid - see edp_dbt.dbt for the friendlier, extensible
    layer built on top (``dbt.build(...)``, ``dbt.test(...)``, and the
    ``dbt.cli(...)`` escape hatch for anything that layer doesn't cover).

    :param args: the dbt CLI args, subcommand first - e.g.
        ``["build", "--select", "marts"]``. Templated (a Jinja placeholder
        inside any element, even one embedded in a JSON-encoded ``--vars``
        string, still renders - see edp_dbt.dbt's :func:`_command` for how
        the factories build these from friendlier kwargs). When ``project``
        is given, platform-managed flags (``--project-dir``/
        ``--profiles-dir``/``--target``/``--no-use-colors``) are appended
        automatically - see :func:`_run_dbt` - and must not be included
        here too. When ``project`` is omitted, nothing is appended: ``args``
        runs exactly as given, so it must be fully self-sufficient (its own
        ``--project-dir`` etc. if dbt needs them) - see edp_dbt.dbt's
        ``cli()``, the only caller expected to omit ``project``.
    :param project: one of, tried in this order:

        1. A directory name under ``projects_root`` (``"demo"``) - a
           project bundled platform-wide via the DAGs folder.
        2. Otherwise, that same name is treated as relative to this task's
           own ``dags/<namespace>/`` prefix in the MWAA S3 bucket
           (``"recon"`` -> ``s3://<mwaa bucket>/dags/<namespace>/recon``,
           namespace from ``aws_conn_id``) and fetched from there.
        3. A full ``s3://bucket/prefix`` URI, for a project outside your
           own namespace's prefix.

        Forms 2 and 3 are fetched once per content version and cached on
        the worker - see :meth:`_sync_from_s3`. Optional: omitting it (as
        edp_dbt.dbt's ``cli()`` does by default) switches this operator to
        raw mode - see ``args`` above - with no project resolution and no
        flag injection of any kind.
    :param target: dbt target (default ``dev``). Only meaningful, and only
        passed to dbt, when ``project`` is given.
    :param env_vars: a ``def f(aws_conn_id: str | None) -> dict[str, str]``
        called at execute() time with this task's own ``aws_conn_id``; the
        result is set as this (inherited) operator's own ``env_vars``,
        ExternalPythonOperator's native mechanism for injecting real
        environment variables into the dbt subprocess - typically read back
        via ``profiles.yml``'s ``env_var(...)``. Must be a plain top-level
        function, not a lambda or closure - a bare callable doesn't survive
        DAG serialization (confirmed - see test_serialization.py), so this
        operator never holds a live reference to it except within a single
        execute() call; instead it's stored (see :func:`_encode_env_vars`)
        and re-imported at execute() time (the same constraint
        ``python_callable`` already has, and for the same reason). This
        works whether the function lives in a real installed module or
        directly in your own DAG file, right next to the
        ``dbt.build(...)``/etc. call that uses it - both are re-imported
        correctly at execute() time. A :func:`functools.partial` of such a
        function is also accepted, so a parameterised helper can be passed
        inline (``env_vars=redshift_auth_vars(db="edp_raw_dev")``); its
        keywords are templated per run like any other template_field. For
        Redshift, use :func:`edp_dbt.redshift.redshift_auth_vars`, which is
        itself such a factory and so must be called, never passed uncalled.
    """

    # aws_conn_id/cache_root/project/projects_root/_env_vars_ref must be
    # template_fields, not just self.x assignments - it's the only mechanism
    # (besides op_kwargs) that survives DAG serialization, and the worker
    # executes the deserialized copy. Without it the cluster policy's
    # aws_conn_id, and project/projects_root/_env_vars_ref (all read in
    # execute(), not __init__ - see there for why), never reach execute().
    # Confirmed by round-tripping through DagSerialization.
    template_fields: Sequence[str] = tuple(
        set(ExternalPythonOperator.template_fields)
        | {
            "aws_conn_id",
            "cache_root",
            "project",
            "projects_root",
            "_env_vars_ref",
            "_dbt_venv_source",
        }
    )

    ui_color = "#ff6849"  # dbt orange

    def __init__(
        self,
        *,
        args: list[str],
        project: str | None = None,
        target: str = "dev",
        dbt_venv: str = DEFAULT_DBT_VENV,
        projects_root: str = DEFAULT_PROJECTS_ROOT,
        env_vars: Callable[[str | None], dict[str, str]] | None = None,
        cache_root: str = DEFAULT_CACHE_ROOT,
        **kwargs: Any,
    ) -> None:
        if not args:
            raise ValueError("args must be non-empty - args[0] is the dbt subcommand")

        # aws_conn_id set by the platform's cluster policy
        # (airflow_local_settings.py) from this file's namespace directory.
        self.aws_conn_id: str | None = None
        self.cache_root = cache_root
        # Resolved to a worker-local, freshly-built venv in execute() unless
        # this is an explicit override - self.python is set below from
        # `dbt_venv` directly, since ExternalPythonOperator.__init__ needs a
        # value now, but execute() overwrites it before ever invoking
        # anything - see _resolve_local_venv().
        self._dbt_venv_source = dbt_venv
        self.project = project
        self.projects_root = projects_root
        # Stored encoded (see _encode_env_vars), not the callable itself -
        # see docstring. Not named env_vars: that's ExternalPythonOperator's
        # own dict-typed attribute (its real subprocess env vars), which
        # execute() sets from this once resolved.
        self._env_vars_ref = _encode_env_vars(env_vars) if env_vars is not None else None

        # project_dir is resolved in execute(), not here - the local vs
        # own-namespace-S3 choice needs a real filesystem check on the
        # worker, and the latter needs aws_conn_id, which the cluster policy
        # only sets after construction. target is only meaningful alongside
        # project (see docstring), so it's omitted from op_kwargs entirely
        # in raw mode rather than passed through unused.
        op_kwargs: dict[str, Any] = {"args": args}
        if project is not None:
            op_kwargs["target"] = target

        super().__init__(
            python=f"{dbt_venv}/bin/python",
            python_callable=_run_dbt,
            op_kwargs=op_kwargs,
            # The dbt venv deliberately has no Airflow in it; without this the
            # operator warns (or errors) about the missing install.
            expect_airflow=False,
            **kwargs,
        )

    # --- project resolution ------------------------------------------------

    def _resolve_project_dir(self) -> str:
        # Only called from execute() when self.project is not None (raw mode
        # - project=None - never resolves a project_dir at all).
        if self.project is None:
            raise AirflowException("_resolve_project_dir called without project set")
        project = self.project

        if project.startswith("s3://"):
            return self._sync_from_s3(project)

        local_dir = f"{self.projects_root}/{project}"
        if os.path.isdir(local_dir):
            return local_dir

        from airflow.models import Variable

        namespace = self.aws_conn_id
        if namespace is None:
            raise AirflowException(
                f"project {project!r} isn't under projects_root and isn't an "
                "s3:// URI, so it's treated as relative to this task's own "
                "namespace prefix - that requires aws_conn_id, which the cluster "
                "policy didn't set."
            )
        mwaa_bucket = Variable.get("mwaa_s3_bucket")
        return self._sync_from_s3(f"s3://{mwaa_bucket}/dags/{namespace}/{project}")

    def _sync_from_s3(self, uri: str) -> str:
        """Fetch an s3:// project to a worker-local directory, cached by content.

        The cache key is a fingerprint of every object's key and ETag, so a
        push of new models produces a new directory and the next run picks it
        up. A TTL would be cheaper still but can silently run stale models;
        one LIST call per task is a fair price for not doing that.

        Note this runs in the Airflow interpreter, not the dbt venv - which is
        the only reason it can use S3Hook at all. The venv has no boto3.
        """
        from airflow.providers.amazon.aws.hooks.s3 import S3Hook

        bucket, _, prefix = uri[len("s3://") :].partition("/")
        prefix = prefix.rstrip("/")
        # get_conn() is declared to return the union of every AWS service's
        # client/resource type; S3Hook always constructs it with
        # client_type="s3" (see its __init__), so this client really is one.
        client = cast(_S3Client, S3Hook(aws_conn_id=self.aws_conn_id).get_conn())

        paginator = client.get_paginator("list_objects_v2")
        objects = sorted(
            (obj["Key"], obj["ETag"].strip('"'))
            for page in paginator.paginate(Bucket=bucket, Prefix=f"{prefix}/")
            for obj in page.get("Contents", [])
            if not obj["Key"].endswith("/")
        )
        if not objects:
            raise AirflowException(f"No objects found under {uri}")

        fingerprint = hashlib.sha256(
            "\n".join(f"{k}:{e}" for k, e in objects).encode()
        ).hexdigest()[:16]
        cache_dir = Path(self.cache_root) / f"{prefix.replace('/', '_')}-{fingerprint}"

        # The marker file distinguishes "fully populated" from "a download died
        # halfway"; without it a partial directory would be served as a hit.
        if (cache_dir / ".complete").is_file():
            self.log.info(f"Project cache hit: [{cache_dir}] ({len(objects)} objects).")
            return str(cache_dir)

        self.log.info(
            f"Project cache miss: downloading [{len(objects)}] objects from [{uri}]..."
        )
        cache_dir.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(dir=str(cache_dir.parent), prefix=".staging-"))
        try:
            for key, _etag in objects:
                dest = staging / key[len(prefix) :].lstrip("/")
                dest.parent.mkdir(parents=True, exist_ok=True)
                client.download_file(bucket, key, str(dest))
            (staging / ".complete").touch()
            try:
                # Atomic promotion. Two tasks on one worker can race here; the
                # loser's rename fails because the target is non-empty, which
                # is fine - the winner's copy is byte-identical by construction.
                os.rename(staging, cache_dir)
                self.log.info(f"Project [{uri}] downloaded to [{cache_dir}].")
            except OSError:
                self.log.info(
                    f"Another task populated the cache first for [{uri}]; using theirs."
                )
                shutil.rmtree(staging, ignore_errors=True)
        except Exception as exc:
            self.log.error(f"Failed to download project [{uri}]: [{exc}].")
            shutil.rmtree(staging, ignore_errors=True)
            raise

        return str(cache_dir)

    # --- env_vars ------------------------------------------------------------

    def _resolve_env_vars(self) -> dict[str, str]:
        """Re-imports the env_vars function per its stored encoding and calls it.

        Runs in the Airflow interpreter, not the dbt venv - same reason as
        _sync_from_s3 (this venv has no boto3). See _encode_env_vars for the
        two encodings this reverses.
        """
        if self._env_vars_ref is None:
            raise AirflowException("_resolve_env_vars called without env_vars set")
        kind, location, name, *rest = self._env_vars_ref
        keywords: dict[str, Any] = rest[0] if rest else {}
        module = self._load_env_vars_module(kind, location)
        func = cast("Callable[..., dict[str, str]]", getattr(module, name))
        return func(self.aws_conn_id, **keywords)

    @staticmethod
    def _load_env_vars_module(kind: str, location: str) -> ModuleType:
        if kind == "module":
            return importlib.import_module(location)
        # kind == "file": location is an absolute path to the DAG file the
        # function was defined in - see _encode_env_vars. Loaded directly
        # under Airflow's own DAG-file module-naming scheme (not
        # importlib.import_module - that's exactly what doesn't work here).
        from airflow.utils.file import get_unique_dag_module_name

        mod_name = get_unique_dag_module_name(location)
        spec = importlib.util.spec_from_file_location(mod_name, location)
        if spec is None or spec.loader is None:
            raise AirflowException(f"Could not load env_vars from DAG file [{location}]")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _resolve_local_venv(self) -> str:
        """Builds a venv natively on this worker, from wheels synced via
        dags/, the first time it's needed here, or whenever
        requirements.txt changes; reused as-is otherwise.

        Built here, not on the CI runner and shipped pre-built - tried
        that first, and confirmed dead live: a venv built with `python3
        -m venv` bakes the *building* machine's own Python installation
        path into pyvenv.cfg, and a worker doesn't have whatever the CI
        runner happens to have there ("No module named 'encodings'"
        trying to even start the copied interpreter, since dags/ has no
        symlink concept either - see DEFAULT_DBT_WHEELS's docstring for
        why wheels don't have this problem). Building right here means
        the venv is always native to whatever Python is actually on this
        machine.

        Workers have no path to PyPI at all (confirmed against the live
        route tables), so this installs `--no-index --find-links` against
        wheels pre-built at `terraform apply` time instead. Both the
        wheels and requirements.txt are read-only from dags/, which is
        fine - pip only ever writes into the venv it's creating, which
        lives in the (writable) local cache below, never back into dags/.

        Same fingerprint-then-cache-by-directory-name pattern as
        _sync_from_s3 - a fresh fingerprint gets a brand new directory
        rather than overwriting one in place, so a concurrent task on this
        worker never sees a half-built venv, and a ".complete" marker
        distinguishes a real hit from a build that died halfway.
        """
        if self._dbt_venv_source != DEFAULT_DBT_VENV:
            # An explicit override - some already-built, already-local
            # venv the caller is pointing at directly. Nothing to build
            # or cache.
            return self._dbt_venv_source

        requirements = Path(DEFAULT_DBT_REQUIREMENTS)
        fingerprint = hashlib.md5(requirements.read_bytes()).hexdigest()  # noqa: S324
        cache_dir = Path(_LOCAL_VENV_CACHE_ROOT) / fingerprint
        if (cache_dir / ".complete").is_file():
            return str(cache_dir)

        self.log.info(f"Venv cache miss: building [{cache_dir}] from wheels...")
        cache_dir.parent.mkdir(parents=True, exist_ok=True)
        staging = Path(tempfile.mkdtemp(dir=str(cache_dir.parent), prefix=".staging-"))
        try:
            # sys.executable, not a dbt-venv python - execute() runs in the
            # Airflow interpreter, which is this worker's own native Python.
            subprocess.run(  # noqa: S603
                [sys.executable, "-m", "venv", str(staging)], check=True
            )
            subprocess.run(  # noqa: S603
                [
                    str(staging / "bin" / "pip"),
                    "install",
                    "--quiet",
                    "--no-cache-dir",
                    "--no-index",
                    "--find-links",
                    DEFAULT_DBT_WHEELS,
                    "-r",
                    str(requirements),
                ],
                check=True,
            )
            (staging / ".complete").touch()
            try:
                # Atomic promotion. Two tasks on one worker can race here;
                # the loser's rename fails because the target is
                # non-empty, which is fine - the winner's build is
                # byte-identical by construction.
                os.rename(staging, cache_dir)
                self.log.info(f"Venv built at [{cache_dir}].")
            except OSError:
                self.log.info(
                    f"Another task built the venv cache first for [{fingerprint}]; "
                    "using theirs."
                )
                shutil.rmtree(staging, ignore_errors=True)
        except Exception as exc:
            self.log.error(f"Failed to build venv from wheels: [{exc}].")
            shutil.rmtree(staging, ignore_errors=True)
            raise

        return str(cache_dir)

    def execute(self, context: Context) -> DbtRunResult:
        self.python = f"{self._resolve_local_venv()}/bin/python"
        # op_kwargs has already been templated by this point; add the
        # worker-local project_dir the venv actually sees before the parent
        # hands op_kwargs to it. Raw mode (project=None) skips this
        # entirely - _run_dbt then runs op_kwargs["args"] verbatim.
        if self.project is not None:
            self.op_kwargs = {
                **self.op_kwargs,
                "project_dir": self._resolve_project_dir(),
            }
        if self._env_vars_ref is not None:
            # Sets ExternalPythonOperator's own env_vars (its real subprocess
            # environment), not op_kwargs - see docstring.
            self.env_vars = self._resolve_env_vars()
        # super().execute() is declared -> Any since ExternalPythonOperator
        # accepts any python_callable; ours is always _run_dbt.
        return cast(DbtRunResult, super().execute(context))
