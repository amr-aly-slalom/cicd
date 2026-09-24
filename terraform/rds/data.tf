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

data "aws_subnets" "db" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Tier = "Db"
  }
}

data "aws_subnet" "db" {
  for_each = toset(data.aws_subnets.db.ids)
  id       = each.value
}

# module.kms["rds"] stays in the core state (terraform/kms.tf creates every
# service's CMK from one for_each). Looked up by the alias convention from
# terraform/modules/kms rather than via terraform_remote_state, same as
# terraform/mwaa/data.tf does for the ECR key: core never exposed an rds KMS
# output, so there is nothing to read from its state.
data "aws_kms_alias" "rds" {
  name = "alias/chedaws-edp-rds-${local.environment}"
}
