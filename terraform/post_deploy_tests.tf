# ─── Post-Deploy Test Role ────────────────────────────────────────────────────
#
# Read-only role assumed by the post-deploy test suite (tests/post_deploy/).
# Deliberately separate from chedaws-edp-ci-runner:
#   - ci-runner has full write access to all EDP infrastructure; a bug in test
#     code operating under that role could destroy live resources.
#   - This role is restricted to the Describe/List/Get API surface the test
#     suite needs to verify infrastructure state. It cannot modify anything.
#
# Trust model (chained assumption):
#   EC2 instance profile (self-hosted runner)
#     -> chedaws-edp-ci-runner  (assumed by Terraform, as today)
#     -> chedaws-edp-post-deploy-tests-{env}  (assumed by test suite step)
#
# This mirrors the publish-mwaa-artefact action pattern: the runner's ambient
# identity first assumes ci-runner, then does a second sts:AssumeRole into
# this narrower role. Trusting ci-runner rather than the raw instance profile
# ensures the test role is only reachable through the approved CI pipeline.

resource "aws_iam_role" "post_deploy_tests" {
  name        = "chedaws-edp-post-deploy-tests-${local.environment}"
  description = "Read-only role for post-deploy infrastructure test suite in ${local.environment}. Assumed from chedaws-edp-ci-runner; no write permissions."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCiRunnerToAssume"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.aws_account_id}:role/chedaws-edp-ci-runner"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })

  tags = {
    Name = "chedaws-edp-post-deploy-tests-${local.environment}"
  }
}

resource "aws_iam_role_policy" "post_deploy_tests" {
  name = "post-deploy-tests-read-only"
  role = aws_iam_role.post_deploy_tests.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StsIdentity"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
      # For future use
      # {
      #   Sid    = "KmsInspect"
      #   Effect = "Allow"
      #   Action = [
      #     "kms:DescribeKey",
      #     "kms:ListAliases",
      #     "kms:GetKeyPolicy",
      #     "kms:GetKeyRotationStatus",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "Ec2Inspect"
      #   Effect = "Allow"
      #   Action = [
      #     "ec2:DescribeVpcs",
      #     "ec2:DescribeSubnets",
      #     "ec2:DescribeSecurityGroups",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "MskInspect"
      #   Effect = "Allow"
      #   Action = [
      #     "kafka:DescribeCluster",
      #     "kafka:ListClusters",
      #     "kafka:GetBootstrapBrokers",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "RedshiftInspect"
      #   Effect = "Allow"
      #   Action = [
      #     "redshift:DescribeClusters",
      #     "redshift:DescribeClusterParameterGroups",
      #     "redshift:DescribeClusterParameters",
      #     "redshift:DescribeLoggingStatus",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "CloudWatchInspect"
      #   Effect = "Allow"
      #   Action = [
      #     "cloudwatch:DescribeAlarms",
      #     "logs:DescribeLogGroups",
      #     "logs:ListTagsLogGroup",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "S3Inspect"
      #   Effect = "Allow"
      #   Action = [
      #     "s3:GetBucketEncryption",
      #     "s3:GetBucketVersioning",
      #     "s3:GetBucketLocation",
      #     "s3:GetBucketTagging",
      #     "s3:ListAllMyBuckets",
      #     "s3:GetBucketPublicAccessBlock",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "SecretsManagerInspect"
      #   Effect = "Allow"
      #   Action = [
      #     "secretsmanager:DescribeSecret",
      #     "secretsmanager:ListSecrets",
      #   ]
      #   Resource = "*"
      # },
      # {
      #   Sid    = "IamInspect"
      #   Effect = "Allow"
      #   Action = [
      #     "iam:GetRole",
      #     "iam:ListRoles",
      #     "iam:ListRoleTags",
      #     "iam:ListAttachedRolePolicies",
      #     "iam:ListRolePolicies",
      #   ]
      #   Resource = "*"
      # },
    ]
  })
}

output "post_deploy_tests_role_arn" {
  value       = aws_iam_role.post_deploy_tests.arn
  description = "ARN of the read-only post-deploy test role. Assumed by the test suite from within a chedaws-edp-ci-runner session."
}
