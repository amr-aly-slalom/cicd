"""Tests for edp_dbt.redshift's credential helpers."""

from __future__ import annotations

import functools
from types import SimpleNamespace
from typing import Any

import pytest

# See operators.py: airflow.exceptions doesn't self-alias this re-export, so
# mypy's --no-implicit-reexport (part of strict) sees it as an upstream gap.
from airflow.exceptions import AirflowException  # type: ignore[attr-defined]
from edp_dbt.redshift import _auth_vars, redshift_auth_vars


def test_redshift_auth_vars_uses_aws_conn_id_as_the_namespace(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    seen: dict[str, Any] = {}

    def fake_get_cluster_credentials(**kwargs: Any) -> dict[str, str]:
        seen.update(kwargs)
        return {"DbUser": "finance_mwaa", "DbPassword": "secret"}

    monkeypatch.setattr(
        "airflow.providers.amazon.aws.hooks.base_aws.AwsBaseHook",
        lambda aws_conn_id, client_type: SimpleNamespace(
            get_conn=lambda: SimpleNamespace(
                get_cluster_credentials=fake_get_cluster_credentials
            )
        ),
    )
    monkeypatch.setattr(
        "airflow.models.Variable.get",
        lambda key: {"environment": "dev", "redshift_host": "redshift.example"}[key],
    )

    creds = redshift_auth_vars(db="edp")("finance")

    assert seen["DbUser"] == "finance_mwaa"
    assert seen["DbGroups"] == ["finance_group"]
    assert creds["DBT_REDSHIFT_USER"] == "finance_mwaa"
    assert creds["DBT_REDSHIFT_PASSWORD"] == "secret"  # noqa: S105 - fake test value


def test_db_uses_that_database_for_both_halves(monkeypatch: pytest.MonkeyPatch) -> None:
    """Redshift binds credentials to the database they were requested for, so
    the credential request and the connection must name the same one."""
    seen = _patch_redshift(monkeypatch)

    creds = redshift_auth_vars(db="edp_raw_dev")("finance")

    assert seen["DbName"] == "edp_raw_dev"
    assert creds["DBT_REDSHIFT_DBNAME"] == "edp_raw_dev"
    # still the namespace's own user and group, whatever the database
    assert seen["DbUser"] == "finance_mwaa"
    assert seen["DbGroups"] == ["finance_group"]


def test_it_returns_a_re_importable_partial() -> None:
    partial = redshift_auth_vars(db="edp_raw_dev")

    assert isinstance(partial, functools.partial)
    assert partial.func is _auth_vars
    assert partial.keywords == {"db": "edp_raw_dev"}
    assert not partial.args


def test_db_has_no_default() -> None:
    with pytest.raises(TypeError, match="db"):
        redshift_auth_vars()  # type: ignore[call-arg]


def test_db_raises_without_aws_conn_id() -> None:
    with pytest.raises(AirflowException, match="aws_conn_id"):
        redshift_auth_vars(db="edp_raw_dev")(None)


def _patch_redshift(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Fakes the Redshift client and Airflow Variables; returns the kwargs the
    GetClusterCredentials call was made with."""
    seen: dict[str, Any] = {}

    def fake_get_cluster_credentials(**kwargs: Any) -> dict[str, str]:
        seen.update(kwargs)
        return {"DbUser": "finance_mwaa", "DbPassword": "secret"}

    monkeypatch.setattr(
        "airflow.providers.amazon.aws.hooks.base_aws.AwsBaseHook",
        lambda aws_conn_id, client_type: SimpleNamespace(
            get_conn=lambda: SimpleNamespace(
                get_cluster_credentials=fake_get_cluster_credentials
            )
        ),
    )
    monkeypatch.setattr(
        "airflow.models.Variable.get",
        lambda key: {"environment": "dev", "redshift_host": "redshift.example"}[key],
    )
    return seen
