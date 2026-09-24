locals {
  environment    = terraform.workspace
  aws_account_id = data.aws_caller_identity.current.account_id
}
