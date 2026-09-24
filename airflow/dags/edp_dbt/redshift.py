"""Redshift authentication for DbtOperator's env_vars - see its docstring.

Kept out of operators.py so DbtOperator stays a generic "run dbt with these
env vars" primitive with no built-in notion of Redshift; this is just the
platform's own implementation of the common case, exported for DAG authors
to pass in explicitly.
"""

from __future__ import annotations

import functools
import logging
from collections.abc import Callable
from typing import Protocol, TypedDict, cast

log = logging.getLogger(__name__)

# Static across every environment - see port in terraform/redshift.tf.
DEFAULT_REDSHIFT_PORT = "5439"


class _RedshiftCredentials(TypedDict):
    """The slice of a boto3 Redshift GetClusterCredentials response we read."""

    DbUser: str
    DbPassword: str


class _RedshiftClient(Protocol):
    """The slice of a boto3 Redshift client we use.

    Hand-written rather than importing boto3-stubs' real type - see
    edp_dbt.operators._S3Paginator for why (same reasoning, same stubs
    package).
    """

    def get_cluster_credentials(
        self,
        *,
        DbUser: str,
        DbName: str,
        ClusterIdentifier: str,
        DbGroups: list[str],
        AutoCreate: bool,
        DurationSeconds: int,
    ) -> _RedshiftCredentials: ...


def redshift_auth_vars(*, db: str) -> Callable[[str | None], dict[str, str]]:
    """Short-lived Redshift DB credentials for a namespace, for ``db``.

    Pass the result to :class:`~edp_dbt.DbtOperator`'s ``env_vars``, e.g.
    ``DbtOperator(..., env_vars=redshift_auth_vars(db="edp"))``. It returns a
    :func:`functools.partial`, not credentials: DbtOperator calls it with its
    own ``aws_conn_id`` at execute() time and injects the result as env vars
    for a ``profiles.yml`` target using ``env_var(...)`` with plain
    ``method: database`` auth (DB user ``<namespace>_mwaa``, group
    ``<namespace>_group`` - see terraform/redshift_namespaces.tf).

    ``db`` is templated per run, so one DAG can serve every environment with
    ``db="edp_raw_{{ var.value.environment }}"``.

    It is used for both halves - the credential request and the connection
    dbt then makes - because Redshift binds the credentials it issues to the
    database they were requested for; connecting to a different one is
    refused with ``FATAL 28000 IAM authentication failed``, which reads like
    an IAM problem but isn't (confirmed in dev on 2026-09-16). Anything other
    than ``edp`` must also be listed in ``spec.writable_databases``
    (redshift/namespaces/<name>.yaml), which is what scopes the role's
    GetClusterCredentials policy.

    Runs in the Airflow interpreter, not the dbt venv - the venv has no
    boto3. Uses GetClusterCredentials, not GetClusterCredentialsWithIAM: the
    namespace role's IAM policy (terraform/redshift_namespaces.tf) is
    Resource-scoped to this one DbUser/DbGroup pair specifically, which only
    the classic API supports - see that file's comment for why.
    """
    return functools.partial(_auth_vars, db=db)


def _auth_vars(aws_conn_id: str | None, *, db: str) -> dict[str, str]:
    from airflow.exceptions import AirflowException  # type: ignore[attr-defined]
    from airflow.models import Variable
    from airflow.providers.amazon.aws.hooks.base_aws import AwsBaseHook

    namespace = aws_conn_id
    if namespace is None:
        raise AirflowException("redshift_auth_vars requires aws_conn_id")

    # Both variables are exposed via the Secrets Manager-backed Airflow
    # secrets backend, same as environment/app_subnet_a/b - see mwaa.tf.
    environment = Variable.get("environment")
    host = Variable.get("redshift_host")
    cluster_id = f"chedaws-edp-{environment}"

    client = cast(
        _RedshiftClient,
        AwsBaseHook(aws_conn_id=aws_conn_id, client_type="redshift").get_conn(),
    )
    log.info(
        f"Fetching Redshift credentials for namespace [{namespace}], database [{db}]..."
    )
    creds = client.get_cluster_credentials(
        DbUser=f"{namespace}_mwaa",
        DbName=db,
        ClusterIdentifier=cluster_id,
        DbGroups=[f"{namespace}_group"],
        AutoCreate=True,
        DurationSeconds=3600,
    )
    log.info(
        f"Redshift credentials for namespace [{namespace}], database [{db}] fetched."
    )

    return {
        "DBT_REDSHIFT_HOST": host,
        "DBT_REDSHIFT_PORT": DEFAULT_REDSHIFT_PORT,
        "DBT_REDSHIFT_DBNAME": db,
        "DBT_REDSHIFT_USER": creds["DbUser"],
        "DBT_REDSHIFT_PASSWORD": creds["DbPassword"],
    }
