data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# module.kms["s3tables"] and module.kms["glue"] stay in the core state
# (terraform/kms.tf creates every service's CMK from one for_each), which has
# no outputs for either. Looked up by the terraform/modules/kms alias
# convention, same as terraform/rds and terraform/kafka do for their keys.
data "aws_kms_alias" "s3tables" {
  name = "alias/chedaws-edp-s3tables-${local.environment}"
}

data "aws_kms_alias" "glue" {
  name = "alias/chedaws-edp-glue-${local.environment}"
}
