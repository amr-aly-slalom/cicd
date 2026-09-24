locals {
  environment           = terraform.workspace
  distinct_account_envs = ["test", "uat", "prod"]

  aws_account_id = data.aws_caller_identity.current.account_id

  kms_services = {
    redshift = {
      service_principals = ["redshift.amazonaws.com"]
    }
    sns = {
      service_principals = ["sns.amazonaws.com"]
      # Services that publish to the encrypted alerts topic must be able to
      # use its key, or their notifications are silently dropped.
      publisher_principals = ["cloudwatch.amazonaws.com", "redshift.amazonaws.com"]
    }
    cloudwatch_logs = {
      service_principals = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    msk = {
      service_principals = ["kafka.amazonaws.com"]
    }
    s3 = {
      service_principals = ["s3.amazonaws.com", "airflow.amazonaws.com", "airflow-env.amazonaws.com", "logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    s3tables = {
      service_principals = [
        "s3tables.amazonaws.com",
        "maintenance.s3tables.amazonaws.com"
      ]
    }
    rds = {
      service_principals = ["rds.amazonaws.com"]
    }
    glue = {
      service_principals = ["glue.amazonaws.com"]
    }
    ecr = {
      service_principals = ["ecr.amazonaws.com"]
    }
    secretsmanager = {
      service_principals = ["secretsmanager.amazonaws.com"]
    }
    dms = {
      service_principals = ["dms.amazonaws.com"]
    }
  }

}
