"""Foundation Readiness: IAM assume-role test.

Verifies that the post-deploy test role can be assumed and that the resulting
session identity matches the expected account and role name.  This is the most
fundamental prerequisite for the entire test suite: every subsequent test
consumes the aws_session fixture, so if this test fails, all others would fail
for the same reason.

Test ID: FR-IAM-001
Confluence: EDP Test Plan > 1. Foundation Readiness > IAM role test matrix
"""

from __future__ import annotations

import boto3


def test_post_deploy_test_role_can_be_assumed(
    aws_session: boto3.Session,
    aws_account_id: str,
    environment: str,
) -> None:
    """The chedaws-edp-post-deploy-tests-{env} role must be assumable and must
    resolve to the correct account and role name.

    What this proves:
    - The Terraform-provisioned role exists (would 404 / AccessDenied if not).
    - The trust policy correctly allows chedaws-edp-ci-runner to assume it.
    - The resulting session is scoped to the expected AWS account (rules out
      cross-account credential misconfiguration).
    - The ARN contains the expected role name (rules out landing in an
      unintended role through a trust policy mistake).
    """
    # Given: a boto3 session pre-assumed by the workflow under the post-deploy test role
    sts = aws_session.client("sts")
    expected_role = f"chedaws-edp-post-deploy-tests-{environment}"

    # When: we interrogate the caller identity of that session
    identity = sts.get_caller_identity()

    # Then: the session is in the correct account and carries the expected role name
    assert identity["Account"] == aws_account_id, (
        f"Session is in account {identity['Account']!r}, "
        f"expected {aws_account_id!r} for environment {environment!r}"
    )

    assumed_role_arn: str = identity["Arn"]
    assert expected_role in assumed_role_arn, (
        f"Caller ARN {assumed_role_arn!r} does not contain expected role name "
        f"{expected_role!r}. The session may have landed in the wrong role."
    )
