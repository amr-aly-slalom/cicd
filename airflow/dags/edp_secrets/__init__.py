"""Namespace-scoped read access to AWS Secrets Manager."""

from edp_secrets import secrets_manager_client
from edp_secrets.operators import GetSecretOperator

__all__ = ["GetSecretOperator", "secrets_manager_client"]

__version__ = "0.2.0"
