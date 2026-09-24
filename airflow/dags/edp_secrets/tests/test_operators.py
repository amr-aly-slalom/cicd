"""Tests for GetSecretOperator's namespace-path expansion and delegation to
secrets_manager_client - the one piece of convention that module itself
deliberately doesn't know about.
"""

from __future__ import annotations

from typing import Any

import pytest

# See edp_dbt/operators.py: airflow.exceptions doesn't self-alias this
# re-export, so mypy's --no-implicit-reexport (part of strict) sees it as
# an upstream gap.
from airflow.exceptions import AirflowException  # type: ignore[attr-defined]
from edp_secrets.operators import GetSecretOperator


def test_get_secret_operator_expands_the_namespaced_secret_name(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr("airflow.models.Variable.get", lambda key: "dev")
    seen: dict[str, Any] = {}

    def fake_get_secret_value(*, aws_conn_id: str, SecretId: str) -> str:
        seen["aws_conn_id"] = aws_conn_id
        seen["SecretId"] = SecretId
        return "sekrit"

    monkeypatch.setattr(
        "edp_secrets.operators.secrets_manager_client.get_secret_value", fake_get_secret_value
    )

    op = GetSecretOperator(task_id="get", key="api/token")
    op.aws_conn_id = "finance"  # what the cluster policy sets before execute()

    result = op.execute(context={})

    assert result == "sekrit"
    assert seen["aws_conn_id"] == "finance"
    assert seen["SecretId"] == "airflow/dev/namespaces/finance/api/token"


def test_get_secret_operator_raises_without_aws_conn_id() -> None:
    op = GetSecretOperator(task_id="get", key="api/token")

    with pytest.raises(AirflowException, match="aws_conn_id"):
        op.execute(context={})
