"""Tests for edp_dbt.operators._run_dbt.

_run_dbt only ever really executes inside the separate dbt venv (see the
module docstring on operators.py) - and even there, only as a value
cloudpickled across from the Airflow interpreter, never imported by name.
Merely importing edp_dbt.operators - which every test here has to do to
reach _run_dbt at all - already requires Airflow, which the dbt venv doesn't
have (confirmed by a real pip dependency conflict between apache-airflow and
dbt-core). So these tests run under the Airflow venv, with dbt.cli.main
injected into sys.modules as a fake rather than the real package.

This means dbt's real invoke()/dbtRunnerResult behaviour is never exercised
here - only _run_dbt's own logic (arg building, result-shape handling,
success/failure, cleanup). Nothing in this suite catches a real dbt-core API
change.
"""

from __future__ import annotations

import inspect
import json
import sys
import tempfile
import types
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from edp_dbt.operators import _run_dbt


class _FakeResult:
    def __init__(
        self,
        success: bool,
        result: Any = None,
        exception: BaseException | None = None,
    ) -> None:
        self.success = success
        self.result = result
        self.exception = exception


@pytest.fixture
def project_dir(tmp_path: Path) -> Path:
    project = tmp_path / "project"
    project.mkdir()
    (project / "dbt_project.yml").write_text("name: test_proj\n")
    return project


class _FakeDbtRunnerController:
    """Set `.result` to the dbtRunnerResult-alike `invoke()` should return, and
    `.fired_events` to the sequence of event-like objects the runner should
    hand to every registered callback. `.calls` accumulates each `invoke()`
    call's args list.
    """

    def __init__(self) -> None:
        self.result: _FakeResult = _FakeResult(success=True, result=[])
        self.fired_events: list[Any] = []
        self.calls: list[list[str]] = []


@pytest.fixture
def fake_dbt_runner(monkeypatch: pytest.MonkeyPatch) -> _FakeDbtRunnerController:
    """Injects a fake dbt.cli.main.dbtRunner and returns a controller for it."""
    controller = _FakeDbtRunnerController()

    class FakeDbtRunner:
        def __init__(self, callbacks: list[Any] | None = None) -> None:
            self.callbacks = callbacks or []

        def invoke(self, args: list[str]) -> _FakeResult:
            controller.calls.append(args)
            for callback in self.callbacks:
                for event in controller.fired_events:
                    callback(event)
            return controller.result

    fake_main = types.ModuleType("dbt.cli.main")
    fake_main.dbtRunner = FakeDbtRunner  # type: ignore[attr-defined]
    fake_cli = types.ModuleType("dbt.cli")
    fake_cli.main = fake_main  # type: ignore[attr-defined]
    fake_dbt = types.ModuleType("dbt")
    fake_dbt.cli = fake_cli  # type: ignore[attr-defined]

    monkeypatch.setitem(sys.modules, "dbt", fake_dbt)
    monkeypatch.setitem(sys.modules, "dbt.cli", fake_cli)
    monkeypatch.setitem(sys.modules, "dbt.cli.main", fake_main)

    return controller


def test_platform_flags_are_inserted_after_the_subcommand(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    # select/exclude/--vars building is edp_dbt.dbt._command's job now, not
    # _run_dbt's - see test_dbt.py. _run_dbt just inserts the
    # platform-managed flags right after args[0] and passes the rest of the
    # caller's own args through untouched, in order.
    _run_dbt(
        args=["run", "--select", "marts", "--vars", json.dumps({"run_date": "2026-08-31"})],
        project_dir=str(project_dir),
        target="dev",
    )
    (invoked,) = fake_dbt_runner.calls
    assert invoked[0] == "run"
    assert "--project-dir" in invoked
    assert "--target" in invoked and invoked[invoked.index("--target") + 1] == "dev"
    # The caller's own args come after the platform-managed flags, in the
    # order given - not reordered or deduplicated.
    assert invoked[-4:] == [
        "--select",
        "marts",
        "--vars",
        json.dumps({"run_date": "2026-08-31"}),
    ]


def test_args_with_only_a_subcommand_still_gets_platform_flags(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")
    (invoked,) = fake_dbt_runner.calls
    assert invoked[0] == "run"
    assert "--project-dir" in invoked
    assert "--profiles-dir" in invoked
    assert "--no-use-colors" in invoked


def test_raw_mode_runs_args_verbatim_with_no_platform_flags(
    fake_dbt_runner: _FakeDbtRunnerController,
) -> None:
    # dbt.cli's default path: project_dir/target both None - see
    # DbtOperator's docstring. No workdir copy either, since there's no
    # project_dir to copy from.
    _run_dbt(args=["build", "--project-dir", "/caller/own/project", "--target", "prod"])
    (invoked,) = fake_dbt_runner.calls
    assert invoked == ["build", "--project-dir", "/caller/own/project", "--target", "prod"]


def test_raw_mode_does_not_create_a_workdir(
    fake_dbt_runner: _FakeDbtRunnerController, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def fail_mkdtemp(*args: Any, **kwargs: Any) -> str:
        raise AssertionError("raw mode must not create a workdir")

    monkeypatch.setattr(tempfile, "mkdtemp", fail_mkdtemp)

    result = _run_dbt(args=["run"])

    assert result["success"] is True


def test_success_extracts_nodes_and_status_counts(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    fake_dbt_runner.result = _FakeResult(
        success=True,
        result=[
            SimpleNamespace(
                node=SimpleNamespace(unique_id="model.a"),
                status="success",
                execution_time=1.5,
                message=None,
            ),
            SimpleNamespace(
                node=SimpleNamespace(unique_id="model.b"),
                status="success",
                execution_time=0.2,
                message=None,
            ),
            SimpleNamespace(
                node=SimpleNamespace(unique_id="model.c"),
                status="error",
                execution_time=0.1,
                message="boom",
            ),
        ],
    )

    result = _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")

    assert result["success"] is True
    assert result["command"] == "run"
    assert result["status_counts"] == {"success": 2, "error": 1}
    assert [n["unique_id"] for n in result["nodes"]] == ["model.a", "model.b", "model.c"]
    assert result["nodes"][2]["message"] == "boom"


def test_non_iterable_result_yields_no_nodes(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    # Mirrors what dbt actually returns for e.g. `parse`: a bare Manifest,
    # not a list of node results.
    fake_dbt_runner.result = _FakeResult(success=True, result=SimpleNamespace())

    result = _run_dbt(args=["parse"], project_dir=str(project_dir), target="dev")

    assert result["nodes"] == []
    assert result["status_counts"] == {}


def test_failure_raises_with_failed_node_ids(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    fake_dbt_runner.result = _FakeResult(
        success=False,
        result=[
            SimpleNamespace(
                node=SimpleNamespace(unique_id="model.c"),
                status="error",
                execution_time=0.1,
                message="boom",
            ),
        ],
        exception=None,
    )

    with pytest.raises(RuntimeError, match=r"model\.c"):
        _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")


def test_a_passing_test_command_cannot_look_like_success(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    # A failed dbt test reports success=False even though nothing raised
    # inside dbt itself - the guard this asserts is exactly what stops a red
    # test from showing green (see the comment in operators.py).
    fake_dbt_runner.result = _FakeResult(success=False, result=[])
    with pytest.raises(RuntimeError):
        _run_dbt(args=["test"], project_dir=str(project_dir), target="dev")


def test_workdir_is_cleaned_up_on_success(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path, tmp_path: Path
) -> None:
    workdir = tmp_path / "captured-workdir"

    def fake_mkdtemp(prefix: str = "") -> str:
        workdir.mkdir()
        return str(workdir)

    orig_mkdtemp = tempfile.mkdtemp
    tempfile.mkdtemp = fake_mkdtemp  # type: ignore[assignment]
    try:
        _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")
    finally:
        tempfile.mkdtemp = orig_mkdtemp

    assert not workdir.exists()


def test_workdir_is_cleaned_up_on_failure(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path, tmp_path: Path
) -> None:
    fake_dbt_runner.result = _FakeResult(success=False, result=[])
    workdir = tmp_path / "captured-workdir"

    def fake_mkdtemp(prefix: str = "") -> str:
        workdir.mkdir()
        return str(workdir)

    orig_mkdtemp = tempfile.mkdtemp
    tempfile.mkdtemp = fake_mkdtemp  # type: ignore[assignment]
    try:
        with pytest.raises(RuntimeError):
            _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")
    finally:
        tempfile.mkdtemp = orig_mkdtemp

    assert not workdir.exists()


def test_on_event_prints_non_debug_levels_only(
    fake_dbt_runner: _FakeDbtRunnerController,
    project_dir: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    fake_dbt_runner.fired_events = [
        SimpleNamespace(info=SimpleNamespace(level="debug", msg="hidden")),
        SimpleNamespace(info=SimpleNamespace(level="info", msg="shown")),
    ]

    _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")

    out = capsys.readouterr().out
    assert "hidden" not in out
    assert "shown" in out


def test_on_event_swallows_malformed_events(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    # An event missing .info shouldn't blow up the whole dbt invocation.
    fake_dbt_runner.fired_events = [SimpleNamespace()]

    result = _run_dbt(args=["run"], project_dir=str(project_dir), target="dev")

    assert result["success"] is True


def test_run_dbt_is_self_contained_when_run_in_isolation(
    fake_dbt_runner: _FakeDbtRunnerController, project_dir: Path
) -> None:
    """_run_dbt must not use any name from operators.py's enclosing module
    scope that it doesn't also import inside its own body - see the module
    docstring on operators.py.

    Every other test in this file calls _run_dbt normally, imported the
    ordinary way - which always has that module's globals available via
    the function's own __globals__, regardless of what's imported locally
    inside the function body. That's not what actually happens at runtime:
    Airflow's ExternalPythonOperator hands the callable across to the dbt
    venv subprocess in a way that preserves its original compiled
    behaviour (annotations stay lazy under PEP 563 - a real name isn't
    needed just to satisfy one), but does NOT give it access to the rest
    of operators.py's globals. A real runtime reference to a sibling name
    (a Protocol class, a module-level import) raises NameError there.

    Confirmed the hard way: EDP-597. Four separate names (cast,
    _DbtRunnerResult, Iterable, Counter) all passed every other test in
    this file and broke on the first real Airflow run.

    This re-execs _run_dbt's own extracted source in a bare namespace - the
    closest a same-process test can get to the real isolation boundary -
    so a future edit reintroducing this bug fails here instead of in
    production.
    """
    source = "from __future__ import annotations\n\n" + inspect.getsource(_run_dbt)
    namespace: dict[str, Any] = {}
    exec(  # noqa: S102 - the whole point: simulate the real out-of-module isolation boundary
        compile(source, "<isolated _run_dbt>", "exec"), namespace
    )
    isolated_run_dbt = namespace["_run_dbt"]

    result = isolated_run_dbt(args=["run"], project_dir=str(project_dir), target="dev")

    assert result["success"] is True
