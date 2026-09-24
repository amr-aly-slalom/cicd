"""Tests for edp_dbt.dbt - the friendlier factories and the cli() escape
hatch built on top of DbtOperator (see test_operator.py for that primitive).
"""

from __future__ import annotations

import json

from edp_dbt import dbt


def test_command_builds_args_from_select_exclude_and_vars() -> None:
    op = dbt._command(
        "test",
        project="demo",
        select="marts",
        exclude="staging",
        dbt_vars={"run_date": "2026-08-31"},
    )
    assert op.op_kwargs["args"] == [
        "test",
        "--select",
        "marts",
        "--exclude",
        "staging",
        "--vars",
        json.dumps({"run_date": "2026-08-31"}),
    ]


def test_command_omits_flags_that_are_not_given() -> None:
    op = dbt._command("run", project="demo")
    assert op.op_kwargs["args"] == ["run"]


def test_command_appends_extra_args_last() -> None:
    op = dbt._command(
        "build",
        project="demo",
        select="marts",
        extra_args=["--threads", "4", "--fail-fast"],
    )
    assert op.op_kwargs["args"] == [
        "build",
        "--select",
        "marts",
        "--threads",
        "4",
        "--fail-fast",
    ]


def test_named_factory_forwards_extra_args() -> None:
    op = dbt.build(project="demo", extra_args=["--fail-fast"])
    assert op.op_kwargs["args"] == ["build", "--fail-fast"]


def test_command_defaults_task_id_to_the_subcommand_name() -> None:
    op = dbt._command("run", project="demo")
    assert op.task_id == "run"


def test_command_forwards_an_explicit_task_id() -> None:
    op = dbt._command("run", task_id="my_task", project="demo")
    assert op.task_id == "my_task"


def test_named_factories_delegate_to_the_matching_subcommand() -> None:
    factories = {
        "build": dbt.build,
        "run": dbt.run,
        "test": dbt.test,
        "seed": dbt.seed,
        "snapshot": dbt.snapshot,
        "compile": dbt.compile,
        "deps": dbt.deps,
        "parse": dbt.parse,
        "ls": dbt.ls,
    }
    for name, factory in factories.items():
        op = factory(project="demo")
        assert op.op_kwargs["args"] == [name]
        assert op.task_id == name
        assert op.project == "demo"


def test_cli_passes_args_through_verbatim() -> None:
    op = dbt.cli(["build", "--fail-fast", "--threads", "4"])
    assert op.op_kwargs["args"] == ["build", "--fail-fast", "--threads", "4"]


def test_cli_defaults_task_id_to_args_zero() -> None:
    op = dbt.cli(["build", "--fail-fast"])
    assert op.task_id == "build"


def test_cli_defaults_to_raw_mode_with_no_project() -> None:
    op = dbt.cli(["build", "--project-dir", "/caller/own", "--target", "prod"])
    assert op.project is None
    assert op.op_kwargs == {
        "args": ["build", "--project-dir", "/caller/own", "--target", "prod"]
    }


def test_cli_still_accepts_project_and_target_via_kwargs() -> None:
    op = dbt.cli(["build", "--fail-fast"], project="demo", target="prod")
    assert op.project == "demo"
    assert op.op_kwargs == {"args": ["build", "--fail-fast"], "target": "prod"}
