"""Shared fixtures for post-deploy infrastructure tests.

Auth flow
---------
All three credential hops happen in the post-deploy-tests
composite action (.github/actions/post-deploy-tests) before pytest starts:

  1. Self-hosted runner instance profile (InfraBuildRole in the runner account).
  2. Assume chedaws-edp-ci-runner in the target account.
  3. Assume chedaws-edp-post-deploy-tests-{env} from that ci-runner session.

By the time pytest runs, AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
AWS_SESSION_TOKEN in the environment already represent the constrained read-only
post-deploy-tests role (defined in terraform/post_deploy_tests.tf).  The
aws_session fixture simply wraps those ambient credentials -- no STS calls in
the test layer.

Every test that needs AWS access should accept the aws_session fixture rather
than constructing its own boto3 session, so all tests run under the same
constrained identity.
"""

from __future__ import annotations

import os

import boto3
import pytest

_VALID_ENVIRONMENTS = ("dev", "test", "uat", "prod")

_REGION = "ap-southeast-2"


@pytest.fixture(scope="session")
def environment() -> str:
    """The target environment, sourced from the ENVIRONMENT env var.

    Set by the post-deploy-tests action; must also be set manually for local runs:
        ENVIRONMENT=dev pytest tests/post_deploy/
    """
    env = os.environ.get("ENVIRONMENT", "").strip()
    if env not in _VALID_ENVIRONMENTS:
        pytest.fail(
            f"ENVIRONMENT env var must be one of {list(_VALID_ENVIRONMENTS)}; got {env!r}"
        )
    return env


@pytest.fixture(scope="session")
def aws_account_id() -> str:
    """Expected AWS account ID for the target environment.

    Sourced from the AWS_ACCOUNT_ID env var, which is set by
    the post-deploy-tests action from the same account map used in the
    'Assume ci-runner' step.  For local runs set it manually:
        AWS_ACCOUNT_ID=381491832813 ENVIRONMENT=dev pytest tests/post_deploy/
    """
    account_id = os.environ.get("AWS_ACCOUNT_ID", "").strip()
    if not account_id:
        pytest.fail(
            "AWS_ACCOUNT_ID env var is not set. "
            "It is exported by the post-deploy-tests action; for local runs set it manually."
        )
    return account_id


@pytest.fixture(scope="session")
def aws_session() -> boto3.Session:
    """A boto3 Session inheriting the ambient post-deploy-tests role credentials.

    The role assumption happens in the post-deploy-tests action before pytest starts.
    This fixture simply wraps the resulting AWS_* env vars -- no STS call here.
    The role has only Describe/List/Get permissions and cannot modify any
    infrastructure.
    """
    return boto3.Session(region_name=_REGION)

