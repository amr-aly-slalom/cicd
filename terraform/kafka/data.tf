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

data "aws_subnet" "app" {
  for_each = toset(data.aws_subnets.app.ids)
  id       = each.value
}

# module.kms["msk"] stays in the core state (terraform/kms.tf creates every
# service's CMK from one for_each). Looked up by the terraform/modules/kms
# alias convention, same as terraform/rds does for its key - core never
# exposed an msk KMS output.
data "aws_kms_alias" "msk" {
  name = "alias/chedaws-edp-msk-${local.environment}"
}
