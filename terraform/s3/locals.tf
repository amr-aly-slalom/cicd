locals {
  environment  = terraform.workspace
  is_prod_like = contains(["uat", "prod"], local.environment)

  aws_account_id = data.aws_caller_identity.current.account_id

  log_retention_days = local.is_prod_like ? 30 : 7
}
