"""GetSecretOperator - namespace-scoped Secrets Manager read as a leaf task.

Owns the one piece of Airflow-specific convention secrets_manager_client.py
deliberately doesn't know about: expanding a caller's plain ``key`` into the
full namespaced Secrets Manager name. See that module for the boto3-shaped
get primitive this calls.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from airflow.sdk import BaseOperator

from edp_secrets import secrets_manager_client

if TYPE_CHECKING:
    from airflow.providers.common.compat.sdk import Context

# airflow/<env>/namespaces/<namespace>/<key> - deliberately not
# airflow/<env>/connections/<namespace>* or the (aspirational, never
# actually granted - see airflow/README.md) airflow/variables/<namespace>__*
# prefixes: those are Airflow's own Connections/Variables backing stores,
# with their own payload shape and __-suffix parsing. This is a plain,
# application-agnostic KV store, so <key> is a free path segment (may
# contain "/") rather than a __-joined suffix - nothing parses it the way
# Airflow's secrets backend parses __.
_SECRET_NAME_TEMPLATE = "airflow/{environment}/namespaces/{namespace}/{key}"  # noqa: S105 - a name template, not a credential


def _secret_name(aws_conn_id: str | None, key: str) -> str:
    from airflow.exceptions import AirflowException  # type: ignore[attr-defined]
    from airflow.models import Variable

    if aws_conn_id is None:
        raise AirflowException(
            "aws_conn_id is None - this task's namespace wasn't set. Confirm this "
            "DAG file lives under dags/<namespace>/ so the cluster policy can set it."
        )

    # Same Secrets Manager-backed Airflow secrets backend as
    # redshift_auth_vars' environment/redshift_host reads - see mwaa.tf.
    environment = Variable.get("environment")
    return _SECRET_NAME_TEMPLATE.format(
        environment=environment, namespace=aws_conn_id, key=key
    )


class GetSecretOperator(BaseOperator):
    """Reads this namespace's own secret at ``key``; pushes it to XCom."""

    template_fields = ("aws_conn_id", "key")

    def __init__(self, *, key: str, **kwargs: object) -> None:
        # Populated by the cluster policy (airflow_local_settings.py's
        # task_policy) at DAG-parse time from this file's own namespace
        # directory - same contract edp_dbt.DbtOperator uses. Template
        # field so it survives serialization to the worker's deserialized
        # copy, which is what actually calls execute().
        self.aws_conn_id: str | None = None
        self.key = key
        super().__init__(**kwargs)  # type: ignore[arg-type]

    def execute(self, context: Context) -> str:
        return secrets_manager_client.get_secret_value(
            aws_conn_id=self.aws_conn_id,  # type: ignore[arg-type]
            SecretId=_secret_name(self.aws_conn_id, self.key),
        )
