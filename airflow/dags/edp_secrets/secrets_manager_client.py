"""Thin, boto3-shaped wrapper for namespace-scoped Secrets Manager reads.

Deliberately not a class: import and call this exactly like boto3's own
secretsmanager client methods (same `SecretId` parameter name), with one
Airflow-specific addition - `aws_conn_id`, the namespace whose credentials
resolve the actual boto3 client - since there's no other way to pick the
right identity in a stateless module-function shape.

Read-only on purpose: the secret object itself is created by Terraform from
a namespace's own `spec.secrets` declaration (see
`terraform/mwaa/mwaa.tf`'s `aws_secretsmanager_secret.mwaa_namespace`), and
its value is set by a platform admin, not by DAG code - see
`airflow/dags/edp_secrets/README.md`.

This module does no secret-name/path expansion - callers pass the full
Secrets Manager name straight through. operators.py owns building
`airflow/<env>/namespaces/<namespace>/<key>` from a caller's plain key; this
module doesn't know that convention exists.
"""

from __future__ import annotations

import logging
from typing import Protocol, TypedDict, cast

log = logging.getLogger(__name__)


class _SecretValueResponse(TypedDict):
    """The slice of a boto3 GetSecretValue response we read."""

    SecretString: str


class _SecretsManagerClient(Protocol):
    """The slice of a boto3 Secrets Manager client we use.

    Hand-written rather than importing boto3-stubs' real type - see
    edp_dbt.operators._S3Client for why (same reasoning, same stubs
    package: a type-check-only dev dependency, never a runtime one).
    """

    def get_secret_value(self, *, SecretId: str) -> _SecretValueResponse: ...


def _client(aws_conn_id: str) -> _SecretsManagerClient:
    from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

    return cast(
        _SecretsManagerClient,
        AwsBaseHook(aws_conn_id=aws_conn_id, client_type="secretsmanager").get_conn(),
    )


def get_secret_value(*, aws_conn_id: str, SecretId: str) -> str:
    """Fetches a secret's current value.

    Raises botocore's ClientError (ResourceNotFoundException) if the secret
    has no value yet - not swallowed, since a namespace's own Terraform-
    declared secret only has a value once a platform admin sets one, and
    reading it before then is a real, loud failure rather than a silent
    None.
    """
    client = _client(aws_conn_id)
    log.info(f"Fetching secret [{SecretId}]...")
    value = client.get_secret_value(SecretId=SecretId)["SecretString"]
    log.info(f"Secret [{SecretId}] fetched.")
    return value
