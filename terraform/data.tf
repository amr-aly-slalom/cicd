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

data "aws_subnets" "tgw" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = {
    Tier = "TGW"
  }
}

# tflint-ignore: terraform_unused_declarations
data "aws_subnet" "tgw" {
  for_each = toset(data.aws_subnets.tgw.ids)
  id       = each.value
}
