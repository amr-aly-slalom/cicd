data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# module.kms["glue"] stays in the core state (terraform/kms.tf creates every
# service's CMK from one for_each), which has no output for it. Looked up by
# the terraform/modules/kms alias convention, same as terraform/rds and
# terraform/kafka do for their keys.
data "aws_kms_alias" "glue" {
  name = "alias/chedaws-edp-glue-${local.environment}"
}
