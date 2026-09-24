locals {
  environment  = terraform.workspace
  is_prod_like = contains(["uat", "prod"], local.environment)

  rds_environments = ["dev", "test", "uat", "prod"]
}
