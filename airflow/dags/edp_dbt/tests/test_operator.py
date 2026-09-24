"""Tests for edp_dbt.operators.DbtOperator (everything except _run_dbt itself -
see test_run_dbt.py)."""

from __future__ import annotations

import functools
import importlib.machinery
import importlib.util
import sys
from datetime import datetime
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any, cast

import pytest

# See operators.py: airflow.exceptions doesn't self-alias this re-export, so
# mypy's --no-implicit-reexport (part of strict) sees it as an upstream gap.
from airflow.exceptions import AirflowException  # type: ignore[attr-defined]
from airflow.providers.common.compat.sdk import Context
from airflow.providers.standard.operators.python import ExternalPythonOperator
from airflow.sdk import DAG
from airflow.utils.file import get_unique_dag_module_name
from edp_dbt.operators import DEFAULT_PROJECTS_ROOT, DbtOperator, DbtRunResult

# execute() only ever reads task-instance context via **kwargs deep inside
# dbt_vars templating, which these tests bypass entirely - an empty stand-in
# is enough to satisfy the real Context type.
_FAKE_CONTEXT = cast(Context, SimpleNamespace())

# What a real DbtOperator.execute() returns via _run_dbt - see test_run_dbt.py
# for that shape's own tests. These execute() tests only care about the
# plumbing around it (op_kwargs, project_dir resolution), not this content.
_FAKE_RUN_RESULT: DbtRunResult = {
    "success": True,
    "command": "run",
    "status_counts": {},
    "nodes": [],
}


def test_empty_args_raises_value_error() -> None:
    with pytest.raises(ValueError, match="non-empty"):
        DbtOperator(task_id="t", args=[], project="demo")


def test_construction_stores_project_and_projects_root_unresolved() -> None:
    # project_dir depends on a real filesystem check and (in the fallback
    # case) aws_conn_id, neither available yet at construction - see
    # _resolve_project_dir(), called from execute() instead.
    op = DbtOperator(task_id="t", args=["run"], project="demo")
    assert op.project == "demo"
    assert op.projects_root == DEFAULT_PROJECTS_ROOT
    assert "project_dir" not in op.op_kwargs


def test_op_kwargs_carries_target_only_when_project_is_given() -> None:
    op = DbtOperator(task_id="t", args=["run"], project="demo", target="prod")
    assert op.op_kwargs == {"args": ["run"], "target": "prod"}


def test_raw_mode_op_kwargs_has_no_target_and_project_stays_none() -> None:
    # dbt.cli's default path - see operators.py's docstring. Nothing
    # platform-managed gets added to op_kwargs; args is the whole of it.
    op = DbtOperator(task_id="t", args=["build", "--project-dir", "/caller/own"])
    assert op.project is None
    assert op.op_kwargs == {"args": ["build", "--project-dir", "/caller/own"]}


def test_execute_skips_project_resolution_in_raw_mode(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    op = DbtOperator(task_id="t", args=["build", "--project-dir", "/caller/own"])
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )

    op.execute(context=_FAKE_CONTEXT)

    assert "project_dir" not in op.op_kwargs


class _FakePaginator:
    def __init__(self, pages: list[dict[str, Any]]) -> None:
        self._pages = pages

    def paginate(self, **_kwargs: Any) -> list[dict[str, Any]]:
        return self._pages


class _FakeS3Client:
    """Stands in for the boto3 S3 client get_conn() returns."""

    def __init__(self, pages: list[dict[str, Any]]) -> None:
        self._pages = pages
        self.downloaded: list[tuple[str, str, str]] = []

    def get_paginator(self, name: str) -> _FakePaginator:
        assert name == "list_objects_v2"
        return _FakePaginator(self._pages)

    def download_file(self, bucket: str, key: str, dest: str) -> None:
        self.downloaded.append((bucket, key, dest))
        Path(dest).write_text("stub content")


@pytest.fixture
def fake_s3_client(monkeypatch: pytest.MonkeyPatch) -> _FakeS3Client:
    client = _FakeS3Client(
        pages=[
            {
                "Contents": [
                    {"Key": "ns/proj/model.sql", "ETag": '"abc123"'},
                    {"Key": "ns/proj/seeds/seed.csv", "ETag": '"def456"'},
                    # A trailing-slash "directory" key - must be filtered out,
                    # not downloaded as a file.
                    {"Key": "ns/proj/seeds/", "ETag": '"dirmarker"'},
                ]
            }
        ]
    )
    monkeypatch.setattr(
        "airflow.providers.amazon.aws.hooks.s3.S3Hook",
        lambda aws_conn_id=None: SimpleNamespace(get_conn=lambda: client),
    )
    return client


def test_sync_from_s3_downloads_every_non_directory_object(
    fake_s3_client: _FakeS3Client, tmp_path: Path
) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="demo", cache_root=str(tmp_path))

    cache_dir = op._sync_from_s3("s3://bucket/ns/proj")

    downloaded_keys = {key for _bucket, key, _dest in fake_s3_client.downloaded}
    assert downloaded_keys == {"ns/proj/model.sql", "ns/proj/seeds/seed.csv"}
    assert (Path(cache_dir) / ".complete").is_file()


def test_sync_from_s3_is_cached_on_second_call(
    fake_s3_client: _FakeS3Client, tmp_path: Path
) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="demo", cache_root=str(tmp_path))

    first = op._sync_from_s3("s3://bucket/ns/proj")
    downloads_after_first = len(fake_s3_client.downloaded)
    second = op._sync_from_s3("s3://bucket/ns/proj")

    assert second == first
    assert len(fake_s3_client.downloaded) == downloads_after_first


def test_sync_from_s3_raises_when_bucket_prefix_is_empty(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    empty_client = _FakeS3Client(pages=[{"Contents": []}])
    monkeypatch.setattr(
        "airflow.providers.amazon.aws.hooks.s3.S3Hook",
        lambda aws_conn_id=None: SimpleNamespace(get_conn=lambda: empty_client),
    )
    op = DbtOperator(task_id="t", args=["run"], project="demo", cache_root=str(tmp_path))

    with pytest.raises(AirflowException):
        op._sync_from_s3("s3://bucket/ns/proj")


def test_execute_resolves_s3_project_dir_by_replacing_op_kwargs(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="s3://bucket/ns/proj")
    original_op_kwargs = op.op_kwargs
    monkeypatch.setattr(op, "_sync_from_s3", lambda uri: "/local/cached/proj")
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )

    result = op.execute(context=_FAKE_CONTEXT)

    assert result == _FAKE_RUN_RESULT
    assert op.op_kwargs["project_dir"] == "/local/cached/proj"
    # Replaced wholesale, not mutated in place - see operators.py's execute().
    assert op.op_kwargs is not original_op_kwargs


def test_execute_uses_local_project_dir_without_touching_s3(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    (tmp_path / "demo").mkdir()
    op = DbtOperator(task_id="t", args=["run"], project="demo", projects_root=str(tmp_path))
    calls: list[str] = []

    def fake_sync_from_s3(uri: str) -> str:
        calls.append(uri)
        return uri

    monkeypatch.setattr(op, "_sync_from_s3", fake_sync_from_s3)
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )

    op.execute(context=_FAKE_CONTEXT)

    assert calls == []
    assert op.op_kwargs["project_dir"] == str(tmp_path / "demo")


# --- _resolve_project_dir -------------------------------------------------


def test_resolve_project_dir_uses_local_dir_when_present(tmp_path: Path) -> None:
    (tmp_path / "demo").mkdir()
    op = DbtOperator(task_id="t", args=["run"], project="demo", projects_root=str(tmp_path))

    assert op._resolve_project_dir() == str(tmp_path / "demo")


def test_resolve_project_dir_uses_explicit_s3_uri_regardless_of_local_dir(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="s3://bucket/ns/proj")
    monkeypatch.setattr(op, "_sync_from_s3", lambda uri: f"/cached/{uri}")

    assert op._resolve_project_dir() == "/cached/s3://bucket/ns/proj"


def test_resolve_project_dir_falls_back_to_own_namespace_s3_prefix(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    # No "recon" dir under projects_root, so this isn't the local-bundled
    # case - falls back to this task's own dags/<namespace>/ prefix.
    op = DbtOperator(task_id="t", args=["run"], project="recon", projects_root=str(tmp_path))
    op.aws_conn_id = "cdc"
    monkeypatch.setattr(
        "airflow.models.Variable.get", lambda key: "chedaws-edp-mwaa-dev-bucket"
    )
    seen_uris: list[str] = []

    def fake_sync_from_s3(uri: str) -> str:
        seen_uris.append(uri)
        return "/cached/recon"

    monkeypatch.setattr(op, "_sync_from_s3", fake_sync_from_s3)

    result = op._resolve_project_dir()

    assert result == "/cached/recon"
    assert seen_uris == ["s3://chedaws-edp-mwaa-dev-bucket/dags/cdc/recon"]


def test_resolve_project_dir_raises_without_aws_conn_id_for_a_non_local_project(
    tmp_path: Path,
) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="recon", projects_root=str(tmp_path))

    with pytest.raises(AirflowException, match="aws_conn_id"):
        op._resolve_project_dir()


# --- _resolve_local_venv ----------------------------------------------------


def test_resolve_local_venv_returns_an_override_verbatim_without_building(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="demo", dbt_venv="/already/local")
    monkeypatch.setattr(
        "subprocess.run", lambda *a, **k: pytest.fail("override must not build anything")
    )

    assert op._resolve_local_venv() == "/already/local"


def test_resolve_local_venv_is_cached_on_second_call(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    requirements = tmp_path / "requirements.txt"
    requirements.write_text("some==1.0\n")
    monkeypatch.setattr("edp_dbt.operators.DEFAULT_DBT_REQUIREMENTS", str(requirements))
    monkeypatch.setattr("edp_dbt.operators._LOCAL_VENV_CACHE_ROOT", str(tmp_path / "cache"))
    build_calls: list[list[str]] = []

    def fake_run(args: list[str], **kwargs: object) -> None:
        build_calls.append(args)
        if args[1:3] == ["-m", "venv"]:
            (Path(args[-1]) / "bin").mkdir(parents=True)

    monkeypatch.setattr("subprocess.run", fake_run)
    op = DbtOperator(task_id="t", args=["run"], project="demo")

    first = op._resolve_local_venv()
    calls_after_first = len(build_calls)
    second = op._resolve_local_venv()

    assert second == first
    assert (Path(first) / ".complete").is_file()
    # venv + pip install on the first (real) build; nothing more on the hit.
    assert calls_after_first == 2
    assert len(build_calls) == calls_after_first


def test_resolve_local_venv_installs_offline_from_dags_synced_wheels(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    requirements = tmp_path / "requirements.txt"
    requirements.write_text("some==1.0\n")
    monkeypatch.setattr("edp_dbt.operators.DEFAULT_DBT_REQUIREMENTS", str(requirements))
    monkeypatch.setattr("edp_dbt.operators._LOCAL_VENV_CACHE_ROOT", str(tmp_path / "cache"))
    pip_calls: list[list[str]] = []

    def fake_run(args: list[str], **kwargs: object) -> None:
        if args[1:3] == ["-m", "venv"]:
            (Path(args[-1]) / "bin").mkdir(parents=True)
        else:
            pip_calls.append(args)

    monkeypatch.setattr("subprocess.run", fake_run)
    op = DbtOperator(task_id="t", args=["run"], project="demo")

    op._resolve_local_venv()

    (pip_args,) = pip_calls
    assert "--no-index" in pip_args
    assert "--find-links" in pip_args
    from edp_dbt.operators import DEFAULT_DBT_WHEELS

    assert pip_args[pip_args.index("--find-links") + 1] == DEFAULT_DBT_WHEELS
    assert pip_args[-2:] == ["-r", str(requirements)]


# --- aws_conn_id ----------------------------------------------------------
#
# aws_conn_id has no constructor parameter - the cluster policy
# (airflow/plugins/airflow_local_settings.py) sets it from the DAG's
# namespace directory before execute() ever runs. These tests set it
# directly on the operator, standing in for that policy.


def test_template_fields_include_the_cluster_policy_attributes() -> None:
    # aws_conn_id/cache_root/project/projects_root/_env_vars_ref must stay
    # template_fields, not plain self.x assignments, or they're silently
    # dropped by DAG serialization - see test_serialization.py.
    assert {
        "aws_conn_id",
        "cache_root",
        "project",
        "projects_root",
        "_env_vars_ref",
    } <= set(DbtOperator.template_fields)


def test_sync_from_s3_uses_the_operators_aws_conn_id(monkeypatch: pytest.MonkeyPatch) -> None:
    seen_conn_ids: list[str | None] = []

    def fake_s3_hook(aws_conn_id: str | None = None) -> SimpleNamespace:
        seen_conn_ids.append(aws_conn_id)
        return SimpleNamespace(get_conn=lambda: _FakeS3Client(pages=[{"Contents": []}]))

    monkeypatch.setattr("airflow.providers.amazon.aws.hooks.s3.S3Hook", fake_s3_hook)
    op = DbtOperator(task_id="t", args=["run"], project="demo")
    op.aws_conn_id = "finance"

    with pytest.raises(AirflowException):  # empty bucket - see test above
        op._sync_from_s3("s3://bucket/ns/proj")

    assert seen_conn_ids == ["finance"]


# --- env_vars ---------------------------------------------------------------
#
# _fake_env_vars must be a real module-level function, not defined inside a
# test - env_vars is stored by dotted path (module + qualname) and
# re-imported at execute() time, so a closure/lambda can't work; see
# operators.py's docstring and test_env_vars_rejects_a_lambda_or_closure.

_seen_aws_conn_ids: list[str | None] = []


def _fake_env_vars(aws_conn_id: str | None) -> dict[str, str]:
    _seen_aws_conn_ids.append(aws_conn_id)
    return {"SOME_VAR": "some-value"}


def test_env_vars_rejects_a_lambda() -> None:
    with pytest.raises(ValueError, match="top-level function"):
        DbtOperator(task_id="t", args=["run"], project="demo", env_vars=lambda conn_id: {})


def test_env_vars_rejects_a_closure() -> None:
    def local_fn(aws_conn_id: str | None) -> dict[str, str]:
        return {}

    with pytest.raises(ValueError, match="top-level function"):
        DbtOperator(task_id="t", args=["run"], project="demo", env_vars=local_fn)


def test_execute_sets_env_vars_from_the_resolved_callable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _seen_aws_conn_ids.clear()
    op = DbtOperator(task_id="t", args=["run"], project="demo", env_vars=_fake_env_vars)
    op.aws_conn_id = "finance"
    monkeypatch.setattr(op, "_resolve_project_dir", lambda: "/local/project")
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )

    op.execute(context=_FAKE_CONTEXT)

    # Sets ExternalPythonOperator's own env_vars (real subprocess env), not
    # op_kwargs - see operators.py's execute().
    assert op.env_vars == {"SOME_VAR": "some-value"}
    assert _seen_aws_conn_ids == ["finance"]


def test_execute_leaves_env_vars_unset_by_default(monkeypatch: pytest.MonkeyPatch) -> None:
    op = DbtOperator(task_id="t", args=["run"], project="demo")
    op.aws_conn_id = "finance"
    monkeypatch.setattr(op, "_resolve_project_dir", lambda: "/local/project")
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )

    op.execute(context=_FAKE_CONTEXT)

    assert op.env_vars is None


def test_env_vars_from_a_real_module_is_encoded_by_dotted_path() -> None:
    op = DbtOperator(task_id="t", args=["run"], project="demo", env_vars=_fake_env_vars)
    assert op._env_vars_ref == ["module", __name__, "_fake_env_vars"]


# --- env_vars partials ------------------------------------------------------


def _fake_env_vars_with_db(aws_conn_id: str | None, db: str = "edp") -> dict[str, str]:
    return {"SOME_VAR": f"{aws_conn_id}/{db}"}


def test_env_vars_partial_is_encoded_with_its_keywords() -> None:
    op = DbtOperator(
        task_id="t",
        args=["run"],
        project="demo",
        env_vars=functools.partial(_fake_env_vars_with_db, db="edp_raw_dev"),
    )

    assert op._env_vars_ref == [
        "module",
        __name__,
        "_fake_env_vars_with_db",
        {"db": "edp_raw_dev"},
    ]


def test_env_vars_partial_defined_in_a_dag_file_is_encoded_by_file_path(
    tmp_path: Path,
) -> None:
    dag_file = tmp_path / "my_dag.py"
    module = _load_as_dag_file(
        "def my_env_vars(aws_conn_id, db='edp'):\n    return {}\n", dag_file
    )

    op = DbtOperator(
        task_id="t",
        args=["run"],
        project="demo",
        env_vars=functools.partial(module.my_env_vars, db="edp_raw_dev"),
    )

    assert op._env_vars_ref == ["file", str(dag_file), "my_env_vars", {"db": "edp_raw_dev"}]


def test_env_vars_partial_rejects_positional_arguments() -> None:
    with pytest.raises(ValueError, match="keyword arguments only"):
        DbtOperator(
            task_id="t",
            args=["run"],
            project="demo",
            env_vars=functools.partial(_fake_env_vars_with_db, "edp_raw_dev"),
        )


def test_env_vars_partial_rejects_keywords_that_cannot_be_templated() -> None:
    with pytest.raises(ValueError, match="strings, numbers"):
        DbtOperator(
            task_id="t",
            args=["run"],
            project="demo",
            env_vars=functools.partial(_fake_env_vars_with_db, db=cast(str, object())),
        )


def test_env_vars_rejects_a_factory_passed_uncalled() -> None:
    # mypy rejects this too; the runtime guard is for DAG files that aren't
    # type-checked, which is most of them.
    from edp_dbt.redshift import redshift_auth_vars

    with pytest.raises(ValueError, match="has to be called"):
        DbtOperator(
            task_id="t",
            args=["run"],
            project="demo",
            env_vars=redshift_auth_vars,  # type: ignore[arg-type]
        )


def test_env_vars_partial_of_a_lambda_is_still_rejected() -> None:
    with pytest.raises(ValueError, match="top-level function"):
        DbtOperator(
            task_id="t",
            args=["run"],
            project="demo",
            env_vars=functools.partial(lambda aws_conn_id, db: {}, db="edp_raw_dev"),
        )


def test_execute_passes_partial_keywords_back_to_the_resolved_callable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    op = DbtOperator(
        task_id="t",
        args=["run"],
        project="demo",
        env_vars=functools.partial(_fake_env_vars_with_db, db="edp_raw_dev"),
    )
    op.aws_conn_id = "finance"
    monkeypatch.setattr(op, "_resolve_project_dir", lambda: "/local/project")
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )

    op.execute(context=_FAKE_CONTEXT)

    assert op.env_vars == {"SOME_VAR": "finance/edp_raw_dev"}


def test_partial_keywords_are_templated_like_any_other_template_field() -> None:
    with DAG(dag_id="test_dag", schedule=None, start_date=datetime(2026, 1, 1)) as dag:
        op = DbtOperator(
            task_id="t",
            args=["run"],
            project="demo",
            env_vars=functools.partial(_fake_env_vars_with_db, db="{{ params.raw_db }}"),
        )

    op.render_template_fields({"params": {"raw_db": "edp_raw_dev"}, "dag": dag})

    assert op._env_vars_ref == [
        "module",
        __name__,
        "_fake_env_vars_with_db",
        {"db": "edp_raw_dev"},
    ]


def _load_as_dag_file(source: str, filepath: Path) -> ModuleType:
    """Loads `source` under Airflow's real DAG-file module-naming scheme,
    exactly as airflow.dag_processing.importers.python_importer does for an
    actual DAG file - see _DAG_FILE_MODULE_PREFIX in operators.py.
    """
    filepath.write_text(source)
    mod_name = get_unique_dag_module_name(str(filepath))
    loader = importlib.machinery.SourceFileLoader(mod_name, str(filepath))
    spec = importlib.util.spec_from_loader(mod_name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    loader.exec_module(module)
    return module


def test_env_vars_defined_in_a_dag_file_is_encoded_by_file_path(tmp_path: Path) -> None:
    dag_file = tmp_path / "my_dag.py"
    module = _load_as_dag_file("def my_env_vars(aws_conn_id):\n    return {}\n", dag_file)

    op = DbtOperator(task_id="t", args=["run"], project="demo", env_vars=module.my_env_vars)

    assert op._env_vars_ref == ["file", str(dag_file), "my_env_vars"]


def test_execute_resolves_env_vars_defined_in_a_dag_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    dag_file = tmp_path / "my_dag.py"
    module = _load_as_dag_file(
        "def my_env_vars(aws_conn_id):\n    return {'FROM_DAG_FILE': str(aws_conn_id)}\n",
        dag_file,
    )
    mod_name = module.__name__
    op = DbtOperator(task_id="t", args=["run"], project="demo", env_vars=module.my_env_vars)
    op.aws_conn_id = "finance"
    monkeypatch.setattr(op, "_resolve_project_dir", lambda: "/local/project")
    monkeypatch.setattr(op, "_resolve_local_venv", lambda: "/fake/venv")
    monkeypatch.setattr(
        ExternalPythonOperator, "execute", lambda self, context: _FAKE_RUN_RESULT
    )
    # A real worker task execution never has this module pre-loaded - it's a
    # fresh process. Removing it here is what makes this test meaningful:
    # without _resolve_env_vars's file-path fallback, this would only pass
    # by accident (still cached from the line above).
    del sys.modules[mod_name]

    op.execute(context=_FAKE_CONTEXT)

    assert op.env_vars == {"FROM_DAG_FILE": "finance"}
