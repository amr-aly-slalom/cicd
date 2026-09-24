"""Friendlier dbt task factories, built on the DbtOperator primitive.

    from edp_dbt import dbt

    dbt.build(project="recon")
    dbt.test(project="recon", select="marts")

Adding a new dbt subcommand is a two-line addition next to the others
below - _command() holds the actual DbtOperator-construction logic, so
there's nothing else to keep in sync. There's no allowlist: DbtOperator
itself never validates args[0], so a subcommand this module hasn't grown a
named wrapper for yet just needs cli() instead.
"""

from __future__ import annotations

import json
from typing import Any

from edp_dbt.operators import DbtOperator


def _command(
    name: str,
    *,
    task_id: str | None = None,
    select: str | None = None,
    exclude: str | None = None,
    dbt_vars: dict[str, object] | None = None,
    extra_args: list[str] | None = None,
    **kwargs: Any,
) -> DbtOperator:
    """Builds `args` for one dbt subcommand from friendlier kwargs.

    select/exclude/dbt_vars aren't validated against `name` - e.g. `deps`
    has no --select. Passing one dbt doesn't support fails at dbt's own
    CLI parser, at task execution rather than DAG-parse time; narrower
    per-command signatures would catch that earlier but would also mean
    hand-maintaining which flags are valid per command, which is exactly
    the kind of allowlist this module is trying to avoid.

    extra_args is the release valve for anything not worth its own
    parameter (--threads, --fail-fast, ...) - appended last, after
    select/exclude/--vars. For anything bigger than a flag or two, or that
    needs to come before those, use cli() instead.
    """
    args = [
        name,
        *(["--select", select] if select else []),
        *(["--exclude", exclude] if exclude else []),
        *(["--vars", json.dumps(dbt_vars)] if dbt_vars else []),
        *(extra_args or []),
    ]
    return DbtOperator(task_id=task_id or name, args=args, **kwargs)


def build(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("build", task_id=task_id, **kwargs)


def run(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("run", task_id=task_id, **kwargs)


def test(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("test", task_id=task_id, **kwargs)


def seed(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("seed", task_id=task_id, **kwargs)


def snapshot(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("snapshot", task_id=task_id, **kwargs)


def compile(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("compile", task_id=task_id, **kwargs)


def deps(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("deps", task_id=task_id, **kwargs)


def parse(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("parse", task_id=task_id, **kwargs)


def ls(*, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    return _command("ls", task_id=task_id, **kwargs)


def cli(args: list[str], *, task_id: str | None = None, **kwargs: Any) -> DbtOperator:
    """Escape hatch: the raw dbt CLI args yourself, subcommand first - e.g.
    ``dbt.cli(["build", "--fail-fast", "--threads", "4"])``.

    Unlike build()/test()/etc., this skips DbtOperator's project= entirely
    by default, which switches it to raw mode: nothing is resolved and
    nothing is appended to `args` - no --project-dir, --profiles-dir,
    --target, or --no-use-colors. `args` runs exactly as given, so include
    whatever dbt needs (a project it can already see on the worker, its own
    --target, etc.) yourself. This is deliberate, not a gap: the friendlier
    commands' project=/target= convenience and this escape hatch's "run
    literally this" contract don't mix well - inserting flags a caller
    didn't write invites exactly the kind of silent surprise this hatch
    exists to avoid.

    You can still pass project=/target= yourself via kwargs if you want
    DbtOperator's usual resolution - it's DbtOperator's own parameter, not
    something this function forbids - just don't also put
    --project-dir/--profiles-dir/--target/--no-use-colors in `args` if you
    do, since those get appended for you in that mode (see DbtOperator's
    docstring).

    Unlike build()/test()/etc., this never runs run-operation-style
    arbitrary-SQL commands through any extra check - args[0] can be
    anything dbt itself accepts. It runs as this task's own namespace role
    either way, the same as every other command here.
    """
    return DbtOperator(task_id=task_id or (args[0] if args else "dbt"), args=args, **kwargs)
