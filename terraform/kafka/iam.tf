# ─── IAM Roles Anywhere Profile ───────────────────────────────────────────────
#
# A single profile per environment for all on-prem workloads.
# Only created in environments where a Trust Anchor has been provisioned.
# On-prem servers reference both the Trust Anchor ARN (local.trust_anchor_arn)
# and this profile ARN when calling `aws_signing_helper credential-process`.

resource "aws_rolesanywhere_profile" "onprem" {
  name    = "chedaws-edp-onprem-${local.environment}"
  enabled = true

  role_arns = concat(
    [for k, v in aws_iam_role.kafka_onprem_producer : v.arn],
    [for k, v in aws_iam_role.kafka_onprem_consumer : v.arn],
    [for k, v in aws_iam_role.kafka_onprem_connect : v.arn],
    [for k, v in aws_iam_role.kafka_consumer_connect_onprem : v.arn],
    # S3's on-prem producer roles are owned by the s3 state (terraform/s3/);
    # read them from its output. s3 applies before this stack, so a new S3
    # on-prem role joins this profile on the kafka apply that follows it.
    values(data.terraform_remote_state.s3.outputs.s3_onprem_producer_role_arns),
  )
}

