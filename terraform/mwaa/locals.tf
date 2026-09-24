locals {
  environment  = terraform.workspace
  is_prod_like = contains(["uat", "prod"], local.environment)

  aws_account_id = data.aws_caller_identity.current.account_id

  log_retention_days = local.is_prod_like ? 30 : 7

  mwaa_environment_class = local.is_prod_like ? "mw1.medium" : "mw1.small"
  mwaa_max_workers       = local.is_prod_like ? 10 : 5
  mwaa_min_workers       = local.is_prod_like ? 2 : 1
  mwaa_schedulers        = local.is_prod_like ? 3 : 2
  mwaa_log_retention     = local.log_retention_days

  mwaa_all_tasks_dimensions = {
    Environment = aws_mwaa_environment.airflow.name
    DAG         = "All"
    Task        = "All"
  }
  mwaa_failure_ratio_threshold = 0.5
  mwaa_failure_ratio_min_tasks = 10
}
