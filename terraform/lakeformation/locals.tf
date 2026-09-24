locals {
  environment  = terraform.workspace
  is_prod_like = contains(["uat", "prod"], local.environment)

  # Environments in their own AWS account (dev shares test's). Same list as
  # the core state's local of the same name, which glue.tf still uses.
  distinct_account_envs = ["test", "uat", "prod"]
}
