data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["chedaws-ndp-*"]
  }
  filter {
    name   = "tag:ApplicationOwner"
    values = ["Platform"]
  }
}

data "aws_subnets" "app" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Tier = "App"
  }
}

# Looked up directly (alias convention from terraform/modules/kms) rather
# than via terraform_remote_state.core.outputs - unlike the KMS ARNs that
# module *does* expose, there was never an ecr_kms_key_arn output on core
# before this split, so it isn't live in any already-applied state yet;
# reading it via remote_state would fail plan until a core apply catches up.
# The alias itself already exists (module.kms["ecr"] predates this branch).
data "aws_kms_alias" "ecr" {
  name = "alias/chedaws-edp-ecr-${local.environment}"
}
