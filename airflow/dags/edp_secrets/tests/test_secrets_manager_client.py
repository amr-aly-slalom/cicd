"""Tests for edp_secrets.secrets_manager_client.

Stubs botocore's own event system against a real boto3 secretsmanager
client (botocore.stub.Stubber), not a hand-rolled fake and not moto - see
airflow/dags/README.md for why: this repo already ships boto3 (so
botocore, and Stubber with it, cost nothing new), and stubbing at the
wire-protocol level against the real client is a closer match to
production than a full in-memory service emulation would be.
"""

from __future__ import annotations

import boto3
import pytest
from botocore.stub import Stubber
from edp_secrets import secrets_manager_client


def _stubbed_client(monkeypatch: pytest.MonkeyPatch) -> Stubber:
    client = boto3.client(
        "secretsmanager",
        region_name="ap-southeast-2",
        aws_access_key_id="fake",
        aws_secret_access_key="fake",  # noqa: S106
    )
    monkeypatch.setattr(
        "edp_secrets.secrets_manager_client._client", lambda aws_conn_id: client
    )
    return Stubber(client)


def test_get_secret_value_fetches_the_value(monkeypatch: pytest.MonkeyPatch) -> None:
    stubber = _stubbed_client(monkeypatch)
    stubber.add_response(
        "get_secret_value",
        {"SecretString": "sekrit"},
        {"SecretId": "airflow/dev/namespaces/finance/api/token"},
    )
    stubber.activate()

    value = secrets_manager_client.get_secret_value(
        aws_conn_id="finance", SecretId="airflow/dev/namespaces/finance/api/token"
    )

    assert value == "sekrit"
    stubber.assert_no_pending_responses()


def test_get_secret_value_reraises_when_no_value_is_set_yet(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from botocore.exceptions import ClientError

    stubber = _stubbed_client(monkeypatch)
    stubber.add_client_error(
        "get_secret_value", service_error_code="ResourceNotFoundException"
    )
    stubber.activate()

    with pytest.raises(ClientError, match="ResourceNotFoundException"):
        secrets_manager_client.get_secret_value(
            aws_conn_id="finance", SecretId="airflow/dev/namespaces/finance/api/token"
        )
