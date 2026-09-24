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

data "aws_subnets" "db" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Tier = "Db"
  }
}

data "aws_iam_roles" "redshift_load" {
  name_regex = ".*-redshift-load.*${local.environment}"
}
