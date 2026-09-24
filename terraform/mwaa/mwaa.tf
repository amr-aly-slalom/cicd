# MWAA Airflow platform — see specs/009-mwaa-airflow-platform/

# --- Locals ---

locals {
  _mwaa_namespace_files = {
    for f in fileset("${path.root}/../../airflow/mwaa", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../airflow/mwaa/${f}"))
  }

  # Exclude decommissioned namespaces so Terraform destroys their resources on apply.
  mwaa_namespaces = {
    for k, v in local._mwaa_namespace_files :
    k => v if !try(v.spec.decommission, false)
  }

  # Namespaces with Fargate compute enabled.
  mwaa_fargate_namespaces = {
    for k, v in local.mwaa_namespaces : k => v if v.spec.fargate_enabled
  }

  # Flat map of namespace → permission set name for the current environment only.
  _mwaa_sso_bindings = {
    for k, v in local.mwaa_namespaces :
    k => try(v.spec.sso_roles[local.environment], null)
    if try(v.spec.sso_roles[local.environment], null) != null
  }

  # First two App-tier subnet IDs, sorted for stable ordering. Used by MWAA
  # network_configuration and exposed as Airflow Variables for DAG operators.
  mwaa_app_subnets = slice(sort(tolist(data.aws_subnets.app.ids)), 0, 2)

  # Flattened (namespace, key) pairs from every namespace's spec.secrets -
  # one entry per Secrets Manager object to create.
  _mwaa_namespace_secret_keys = merge([
    for ns, v in local.mwaa_namespaces : {
      for key in try(v.spec.secrets, []) : "${ns}/${key}" => { namespace = ns, key = key }
    }
  ]...)

  # redshift/namespaces/*.yaml locals live in redshift_namespaces.tf, with the
  # bootstrap and IAM policy that use them.
}

# --- MWAA S3 Bucket ---

module "mwaa_s3" {
  #checkov:skip=CKV_AWS_18: Access logging not required for MWAA DAG/plugins bucket
  #checkov:skip=CKV_AWS_144: Cross-region replication not required for single-region deployment
  #checkov:skip=CKV_AWS_145: KMS encryption configured via server_side_encryption_configuration
  #checkov:skip=CKV_AWS_21: Versioning enabled via versioning sub-resource
  #checkov:skip=CKV_AWS_300: abort_incomplete_multipart_upload set via lifecycle_rule input
  #checkov:skip=CKV_TF_1: registry source with pinned version is the correct alternative to a git commit hash
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.3"

  bucket = "chedaws-edp-mwaa-${local.environment}-${local.aws_account_id}-${data.aws_region.current.region}"

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      }
      bucket_key_enabled = true
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle_rule = [
    {
      id      = "dags-intelligent-tiering"
      enabled = true
      prefix  = "dags/"
      abort_incomplete_multipart_upload = {
        days_after_initiation = 7
      }
      transition = [
        {
          days          = 30
          storage_class = "INTELLIGENT_TIERING"
        }
      ]
      noncurrent_version_expiration = {
        noncurrent_days = 30
      }
    },
    {
      id      = "plugins-intelligent-tiering"
      enabled = true
      prefix  = "plugins/"
      abort_incomplete_multipart_upload = {
        days_after_initiation = 7
      }
      transition = [
        {
          days          = 30
          storage_class = "INTELLIGENT_TIERING"
        }
      ]
      noncurrent_version_expiration = {
        noncurrent_days = 30
      }
    },
    {
      id      = "execution-artefacts-expiry"
      enabled = true
      prefix  = "tmp/"
      expiration = {
        days = 90
      }
    }
  ]

  attach_policy = true
  policy        = data.aws_iam_policy_document.s3_policy.json

  tags = {
    Name = "chedaws-edp-mwaa-${local.environment}"
  }
}

# --- MWAA S3 Bootstrap ---
# Deploys all MWAA S3 objects from the repo on every apply where content changes.
# Runs after the bucket is created (depends_on) and before MWAA provisions
# (aws_mwaa_environment.airflow depends_on this resource).
resource "terraform_data" "mwaa_s3_bootstrap" {
  depends_on = [module.mwaa_s3]

  # Re-run whenever the bucket changes or any source file is added/modified.
  # Includes the bootstrap script itself (mwaa_s3_bootstrap.sh) - it's a
  # separate file precisely so this can hash it directly, rather than
  # tying a re-run to edits anywhere in this whole .tf file (which would
  # force a ~30 min MWAA environment update for changes that have nothing
  # to do with the S3 bootstrap). See EDP-597.
  #
  # Keyed by relative path rather than a plain list of hashes so `terraform
  # plan` shows which file(s) changed, not just an opaque hash diff.
  triggers_replace = merge(
    { s3_bucket_id = module.mwaa_s3.s3_bucket_id },
    { "scripts/mwaa_s3_bootstrap.sh" = filemd5("${path.root}/scripts/mwaa_s3_bootstrap.sh") },
    { "airflow/startup.sh" = filemd5("${path.root}/../../airflow/startup.sh") },
    {
      for f in fileset("${path.root}/../../airflow/plugins", "**") :
      "airflow/plugins/${f}" => filemd5("${path.root}/../../airflow/plugins/${f}")
      if f != "README.md" && !strcontains(f, "__pycache__")
    },
    {
      for f in fileset("${path.root}/../../airflow/dags", "**") :
      "airflow/dags/${f}" => filemd5("${path.root}/../../airflow/dags/${f}")
      if f != "README.md" && !startswith(f, "edp_dbt/tests/") && !strcontains(f, "__pycache__")
    }
  )

  provisioner "local-exec" {
    environment = {
      BUCKET      = module.mwaa_s3.s3_bucket_id
      REGION      = data.aws_region.current.region
      ROLE_ARN    = "arn:aws:iam::${local.aws_account_id}:role/chedaws-edp-ci-runner"
      KMS_KEY     = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      DAGS_SRC    = "${path.root}/../../airflow/dags"
      PLUGINS_SRC = "${path.root}/../../airflow/plugins"
      STARTUP     = "${path.root}/../../airflow/startup.sh"
    }
    command = "bash \"${path.root}/scripts/mwaa_s3_bootstrap.sh\""
  }
}

# Reads back the version IDs of what mwaa_s3_bootstrap.sh just uploaded, so
# aws_mwaa_environment.airflow can pin to them explicitly. Omitting
# *_s3_object_version (as `null`) does NOT mean "always use latest": MWAA's
# UpdateEnvironment API treats an absent field as "leave whatever's
# currently configured" rather than "resolve to latest", so once these
# fields got set to a concrete version they stay there forever regardless of
# subsequent uploads. Confirmed live: this environment's PluginsS3Path
# version was still pinned to its original 2026-08-05 version weeks later,
# despite dozens of applies in between - every deploy since had silently
# been deploying stale, broken artifacts. See EDP-597.
data "aws_s3_object" "mwaa_plugins_zip" {
  bucket     = module.mwaa_s3.s3_bucket_id
  key        = "plugins/plugins.zip"
  depends_on = [terraform_data.mwaa_s3_bootstrap]
}

data "aws_s3_object" "mwaa_startup_script" {
  bucket     = module.mwaa_s3.s3_bucket_id
  key        = "startup/startup.sh"
  depends_on = [terraform_data.mwaa_s3_bootstrap]
}

# --- MWAA Security Group ---

resource "aws_security_group" "mwaa" {
  #checkov:skip=CKV2_AWS_5: Security group is attached to MWAA environment network_configuration
  name        = "chedaws-edp-mwaa-sg-${local.environment}"
  description = "Security group for MWAA environment chedaws-edp-mwaa-${local.environment}"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block, "172.16.0.0/12"]
    description = "HTTPS from VPC (Airflow web UI and API)"
  }

  # Required by MWAA: workers, schedulers, and webserver must be able to reach
  # each other. Without this rule the environment creation fails with INCORRECT_CONFIGURATION.
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
    description = "Allow all inbound from same SG (MWAA internal node communication)"
  }

  # checkov:skip=CKV_AWS_25: Unrestricted egress required by MWAA managed service for task execution
  #trivy:ignore:AWS-0104 Unrestricted egress required by MWAA managed service for task execution
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (MWAA managed service requires unrestricted egress)"
  }

  tags = {
    Name = "chedaws-edp-mwaa-sg-${local.environment}"
  }
}

# --- MWAA Execution Role ---

data "aws_iam_policy_document" "mwaa_execution" {
  statement {
    sid    = "S3DAGAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetEncryptionConfiguration",
    ]
    resources = [
      module.mwaa_s3.s3_bucket_arn,
      "${module.mwaa_s3.s3_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "S3AccountPublicAccessBlock"
    effect = "Allow"
    actions = [
      "s3:GetAccountPublicAccessBlock",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "AirflowPublishMetrics"
    effect    = "Allow"
    actions   = ["airflow:PublishMetrics"]
    resources = ["arn:aws:airflow:ap-southeast-2:${local.aws_account_id}:environment/chedaws-edp-mwaa-${local.environment}"]
  }

  statement {
    sid    = "CloudWatchLogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:CreateLogGroup",
      "logs:PutLogEvents",
      "logs:GetLogEvents",
      "logs:GetLogRecord",
      "logs:GetLogGroupFields",
      "logs:GetQueryResults",
      "logs:DescribeLogGroups",
    ]
    # MWAA creates log groups as airflow-<environment-name>-<LogType>, not under a custom prefix.
    resources = [
      "arn:aws:logs:*:${local.aws_account_id}:log-group:airflow-chedaws-edp-mwaa-${local.environment}*",
      "arn:aws:logs:*:${local.aws_account_id}:log-group:airflow-chedaws-edp-mwaa-${local.environment}*:*",
    ]
  }

  statement {
    sid       = "CloudWatchMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["AmazonMWAA"]
    }
  }

  statement {
    sid    = "SQSAccess"
    effect = "Allow"
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
      "sqs:SendMessage",
    ]
    resources = ["arn:aws:sqs:*:*:airflow-celery-*"]
  }

  statement {
    sid    = "KMSAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
      "kms:Encrypt",
      "kms:CreateGrant",
    ]
    resources = [
      data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn,
      data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn,
    ]
  }

  statement {
    sid    = "SecretsManagerReadAirflow"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = ["arn:aws:secretsmanager:*:${local.aws_account_id}:secret:airflow/${local.environment}/*"]
  }

  statement {
    sid       = "SNSPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  }

  statement {
    sid       = "AssumeNamespaceRoles"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-mwaa-ns-*"]
  }
}

resource "aws_iam_role" "mwaa_execution" {
  name        = "edp-${local.environment}-mwaa-execution"
  description = "Execution role for MWAA environment in ${local.environment}; grants S3 DAG read, CloudWatch Logs write, Secrets Manager read, and KMS access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["airflow.amazonaws.com", "airflow-env.amazonaws.com"] }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.aws_account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "mwaa_execution" {
  name   = "edp-${local.environment}-mwaa-execution-policy"
  role   = aws_iam_role.mwaa_execution.id
  policy = data.aws_iam_policy_document.mwaa_execution.json
}

# --- MWAA Environment ---

resource "aws_mwaa_environment" "airflow" {
  name              = "chedaws-edp-mwaa-${local.environment}"
  airflow_version   = "3.2.1"
  environment_class = local.mwaa_environment_class
  max_workers       = local.mwaa_max_workers
  min_workers       = local.mwaa_min_workers
  schedulers        = local.mwaa_schedulers

  execution_role_arn = aws_iam_role.mwaa_execution.arn

  source_bucket_arn         = module.mwaa_s3.s3_bucket_arn
  dag_s3_path               = "dags/"
  plugins_s3_path           = "plugins/plugins.zip"
  plugins_s3_object_version = data.aws_s3_object.mwaa_plugins_zip.version_id

  # startup.sh no longer builds anything (see airflow/startup.sh) -
  # DbtOperator's venv (airflow/dags/edp_dbt/) is pre-built at apply time
  # and synced continuously via the dags/ prefix instead. Kept as a real
  # object because startup_script_s3_object_version always points at
  # something.
  #
  # NOTE: changing startup.sh or plugins.zip requires an MWAA *environment
  # update* - roughly 20-30 minutes, restarting every namespace's workers.
  # Unlike the dags/ prefix, these are read only at environment start, not
  # synced continuously.
  startup_script_s3_path           = "startup/startup.sh"
  startup_script_s3_object_version = data.aws_s3_object.mwaa_startup_script.version_id

  webserver_access_mode = "PRIVATE_ONLY"

  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    # sort() ensures stable ordering across plan invocations; tolist() on a set is non-deterministic.
    subnet_ids = local.mwaa_app_subnets
  }

  logging_configuration {
    dag_processing_logs {
      enabled   = true
      log_level = "INFO"
    }
    scheduler_logs {
      enabled   = true
      log_level = "INFO"
    }
    task_logs {
      enabled   = true
      log_level = "INFO"
    }
    webserver_logs {
      enabled   = true
      log_level = "WARNING"
    }
    worker_logs {
      enabled   = true
      log_level = "INFO"
    }
  }

  airflow_configuration_options = {
    "secrets.backend" = "airflow.providers.amazon.aws.secrets.secrets_manager.SecretsManagerBackend"
    "secrets.backend_kwargs" = jsonencode({
      connections_prefix = "airflow/${local.environment}/connections"
      variables_prefix   = "airflow/${local.environment}/variables"
      sep                = "/"
    })
    "core.dags_are_paused_at_creation" = "True"
    "core.load_examples"               = "False"
  }

  kms_key = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  depends_on = [terraform_data.mwaa_s3_bootstrap]

  tags = {
    Name = "chedaws-edp-mwaa-${local.environment}"
  }
}

# --- Airflow Variables via Secrets Manager ---

# The mwaa_s3_bucket variable is consumed by the platform e2e DAGs via Variable.get("mwaa_s3_bucket").
# Provisioning it here ensures DAGs succeed without manual setup after first apply.
resource "aws_secretsmanager_secret" "airflow_var_mwaa_s3_bucket" {
  name        = "airflow/${local.environment}/variables/mwaa_s3_bucket"
  description = "Airflow variable: MWAA DAG/plugins S3 bucket name for environment ${local.environment}"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = {
    Name = "airflow/${local.environment}/variables/mwaa_s3_bucket"
  }
}

resource "aws_secretsmanager_secret_version" "airflow_var_mwaa_s3_bucket" {
  secret_id     = aws_secretsmanager_secret.airflow_var_mwaa_s3_bucket.id
  secret_string = module.mwaa_s3.s3_bucket_id
}

# Environment name — consumed by DAGs that build cluster/task-definition names.
resource "aws_secretsmanager_secret" "airflow_var_environment" {
  name        = "airflow/${local.environment}/variables/environment"
  description = "Airflow variable: current Terraform workspace / deployment environment"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/variables/environment" }
}

resource "aws_secretsmanager_secret_version" "airflow_var_environment" {
  secret_id     = aws_secretsmanager_secret.airflow_var_environment.id
  secret_string = local.environment
}

# App-tier subnet IDs — consumed by EcsRunTaskOperator for multi-AZ placement.
resource "aws_secretsmanager_secret" "airflow_var_app_subnet_a" {
  name        = "airflow/${local.environment}/variables/app_subnet_a"
  description = "Airflow variable: first App-tier subnet ID for Fargate task placement"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/variables/app_subnet_a" }
}

resource "aws_secretsmanager_secret_version" "airflow_var_app_subnet_a" {
  secret_id     = aws_secretsmanager_secret.airflow_var_app_subnet_a.id
  secret_string = local.mwaa_app_subnets[0]
}

resource "aws_secretsmanager_secret" "airflow_var_app_subnet_b" {
  name        = "airflow/${local.environment}/variables/app_subnet_b"
  description = "Airflow variable: second App-tier subnet ID for Fargate task placement"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/variables/app_subnet_b" }
}

resource "aws_secretsmanager_secret_version" "airflow_var_app_subnet_b" {
  secret_id     = aws_secretsmanager_secret.airflow_var_app_subnet_b.id
  secret_string = local.mwaa_app_subnets[1]
}

# MWAA security group ID — Fargate tasks share the MWAA SG so they can reach
# the Celery broker without an additional SG rule.
resource "aws_secretsmanager_secret" "airflow_var_mwaa_security_group_id" {
  name        = "airflow/${local.environment}/variables/mwaa_security_group_id"
  description = "Airflow variable: MWAA security group ID used for Fargate task network configuration"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/variables/mwaa_security_group_id" }
}

resource "aws_secretsmanager_secret_version" "airflow_var_mwaa_security_group_id" {
  secret_id     = aws_secretsmanager_secret.airflow_var_mwaa_security_group_id.id
  secret_string = aws_security_group.mwaa.id
}

# Redshift cluster endpoint — consumed by DbtOperator._get_redshift_credentials
# (edp_dbt/operators.py), which GetClusterCredentials doesn't itself return.
resource "aws_secretsmanager_secret" "airflow_var_redshift_host" {
  name        = "airflow/${local.environment}/variables/redshift_host"
  description = "Airflow variable: Redshift cluster endpoint hostname"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/variables/redshift_host" }
}

resource "aws_secretsmanager_secret_version" "airflow_var_redshift_host" {
  secret_id     = aws_secretsmanager_secret.airflow_var_redshift_host.id
  secret_string = data.terraform_remote_state.redshift.outputs.redshift_cluster_endpoint
}

# Platform CMK ARN — consumed by edp_secrets.secrets_manager_client.put_secret_value
# to explicitly encrypt a newly-created namespace secret with this key
# (same one every other Secrets Manager secret in this file already uses -
# see kms_key_id above) rather than Secrets Manager's own default
# aws/secretsmanager key.
resource "aws_secretsmanager_secret" "airflow_var_platform_kms_key_arn" {
  name        = "airflow/${local.environment}/variables/platform_kms_key_arn"
  description = "Airflow variable: platform CMK ARN for Secrets Manager encryption"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/variables/platform_kms_key_arn" }
}

resource "aws_secretsmanager_secret_version" "airflow_var_platform_kms_key_arn" {
  secret_id     = aws_secretsmanager_secret.airflow_var_platform_kms_key_arn.id
  secret_string = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
}

# --- Airflow Connections via Secrets Manager ---

# One connection secret per namespace, providing the Airflow connection used by
# DAGs to assume the namespace IAM role via AwsBaseHook. Connection ID is the
# bare namespace - the cluster policy (airflow/plugins/airflow_local_settings.py)
# sets aws_conn_id to this automatically, so DAG authors never name it.
# Secret path: airflow/<environment>/connections/<namespace>
resource "aws_secretsmanager_secret" "airflow_conn_namespace_aws_default" {
  for_each = local.mwaa_namespaces

  name        = "airflow/${local.environment}/connections/${each.key}"
  description = "Airflow connection: AWS credentials for namespace '${each.key}' in ${local.environment} - assumes namespace IAM role"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = {
    Name = "airflow/${local.environment}/connections/${each.key}"
  }
}

resource "aws_secretsmanager_secret_version" "airflow_conn_namespace_aws_default" {
  for_each = local.mwaa_namespaces

  secret_id     = aws_secretsmanager_secret.airflow_conn_namespace_aws_default[each.key].id
  secret_string = "aws://?role_arn=${replace(aws_iam_role.mwaa_namespace[each.key].arn, ":", "%3A")}&region_name=${data.aws_region.current.region}"
}

# --- MWAA CloudWatch Alarms (constitution §II mandated) ---

resource "aws_cloudwatch_metric_alarm" "mwaa_scheduler_heartbeat" {
  alarm_name          = "chedaws-edp-mwaa-scheduler-heartbeat-${local.environment}"
  alarm_description   = "MWAA scheduler heartbeat has stopped in ${local.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "SchedulerHeartbeat"
  namespace           = "AmazonMWAA"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    Function    = "Scheduler"
    Environment = aws_mwaa_environment.airflow.name
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}

# Platform-wide failure rate, not individual failures: customer tasks fail
# routinely, so this only fires when most tasks across every namespace fail
# at once. MWAA publishes TaskInstanceFailures/Successes environment-wide
# only with DAG=All and Task=All; a series with just Environment doesn't
# exist, so an alarm on it never receives data.
resource "aws_cloudwatch_metric_alarm" "mwaa_failed_tasks" {
  alarm_name          = "chedaws-edp-mwaa-failed-tasks-${local.environment}"
  alarm_description   = "Over ${local.mwaa_failure_ratio_threshold * 100}% of MWAA task runs failed across all namespaces for 30 minutes in ${local.environment} (only evaluated when at least ${local.mwaa_failure_ratio_min_tasks} tasks finished per 15 minutes)"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = local.mwaa_failure_ratio_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "IF((failures + successes) >= ${local.mwaa_failure_ratio_min_tasks}, failures / (failures + successes), 0)"
    label       = "Task failure ratio (all namespaces)"
    return_data = true
  }

  metric_query {
    id = "failures_raw"
    metric {
      metric_name = "TaskInstanceFailures"
      namespace   = "AmazonMWAA"
      period      = 900
      stat        = "Sum"
      dimensions  = local.mwaa_all_tasks_dimensions
    }
  }

  metric_query {
    id = "successes_raw"
    metric {
      metric_name = "TaskInstanceSuccesses"
      namespace   = "AmazonMWAA"
      period      = 900
      stat        = "Sum"
      dimensions  = local.mwaa_all_tasks_dimensions
    }
  }

  metric_query {
    id         = "failures"
    expression = "FILL(failures_raw, 0)"
  }

  metric_query {
    id         = "successes"
    expression = "FILL(successes_raw, 0)"
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "mwaa_triggerer_heartbeat" {
  alarm_name          = "chedaws-edp-mwaa-triggerer-heartbeat-${local.environment}"
  alarm_description   = "MWAA triggerer heartbeat has stopped in ${local.environment}; deferred tasks will not resume"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TriggererHeartbeat"
  namespace           = "AmazonMWAA"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    Function    = "Triggerer"
    Environment = aws_mwaa_environment.airflow.name
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}

# Isolated sync errors happen a few times a week; alarm only when they
# persist, which means DAG changes aren't reaching the environment.
resource "aws_cloudwatch_metric_alarm" "mwaa_s3_sync_errors" {
  alarm_name          = "chedaws-edp-mwaa-s3-sync-errors-${local.environment}"
  alarm_description   = "MWAA components are repeatedly failing to sync DAGs and plugins from S3 in ${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 3
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "total"
    expression  = "SUM(METRICS())"
    label       = "S3 sync errors (all components)"
    return_data = true
  }

  dynamic "metric_query" {
    for_each = toset(["Scheduler", "Worker", "Webserver"])
    content {
      id = "sync_${lower(metric_query.value)}"
      metric {
        metric_name = "S3SyncErrors"
        namespace   = "AmazonMWAA"
        period      = 900
        stat        = "Sum"
        dimensions = {
          Function         = "S3 Sync"
          AirflowComponent = metric_query.value
          Environment      = aws_mwaa_environment.airflow.name
        }
      }
    }
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}

# --- Namespace IAM Roles ---

resource "aws_iam_role" "mwaa_namespace" {
  for_each = local.mwaa_namespaces

  name        = "edp-${local.environment}-mwaa-ns-${each.key}"
  description = "Namespace IAM role for MWAA namespace '${each.key}' in ${local.environment}; grants least-privilege access to namespace-scoped resources"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "MWAAExecution"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.mwaa_execution.arn }
        Action    = "sts:AssumeRole"
      }],
      try(local._mwaa_sso_bindings[each.key], null) != null ? [{
        Sid       = "IDCPermissionSet"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.aws_account_id}:root" }
        Action    = "sts:AssumeRole"
        Condition = {
          ArnLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${local.aws_account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_${local._mwaa_sso_bindings[each.key]}_*"
          }
        }
      }] : [],
      # CI runners assume a dedicated CI role (mwaa_namespace_ci) with S3-only access,
      # not this role, so they cannot reach Secrets Manager via the namespace role.
      []
    )
  })
}

resource "aws_iam_role_policy" "mwaa_namespace_s3" {
  for_each = local.mwaa_namespaces

  name = "edp-${local.environment}-mwaa-ns-${each.key}-s3"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DAGPrefixReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "${module.mwaa_s3.s3_bucket_arn}/dags/${each.key}/*",
          module.mwaa_s3.s3_bucket_arn,
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:Encrypt",
          "kms:DescribeKey",
        ]
        Resource = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      },
      {
        Sid    = "SecretsManagerReadOwn"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        # First entry: the default connection, named exactly <namespace> (plus
        # Secrets Manager's own random suffix). The trailing "-*" (not "*")
        # keeps a namespace from matching another's secret by name prefix,
        # e.g. "finance" must not match "financelegacy-<suffix>".
        Resource = [
          "arn:aws:secretsmanager:*:${local.aws_account_id}:secret:airflow/${local.environment}/connections/${each.key}-*",
          "arn:aws:secretsmanager:*:${local.aws_account_id}:secret:airflow/${local.environment}/connections/${each.key}__*",
        ]
      },
    ]
  })
}

# One Secrets Manager object per namespace's declared spec.secrets entry -
# see airflow/dags/edp_secrets/README.md. No aws_secretsmanager_secret_version
# here: the value is set by hand by a platform admin, not by Terraform.
resource "aws_secretsmanager_secret" "mwaa_namespace" {
  for_each = local._mwaa_namespace_secret_keys

  name        = "airflow/${local.environment}/namespaces/${each.value.namespace}/${each.value.key}"
  description = "Namespace secret for ${each.value.namespace} - value set manually by a platform admin"
  kms_key_id  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  tags = { Name = "airflow/${local.environment}/namespaces/${each.value.namespace}/${each.value.key}" }
}

# Read-only access to a plain application-secret prefix - distinct from
# mwaa_namespace_s3's SecretsManagerReadOwn above, which is scoped to the
# platform's own Connection secret, not a general-purpose KV store. No write
# actions: the secret object is Terraform's (aws_secretsmanager_secret.mwaa_namespace
# above), not the namespace role's. See airflow/dags/edp_secrets/README.md.
resource "aws_iam_role_policy" "mwaa_namespace_secrets" {
  for_each = local.mwaa_namespaces

  name = "edp-${local.environment}-mwaa-ns-${each.key}-secrets"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "NamespaceSecretsGetDescribe"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = "arn:aws:secretsmanager:*:${local.aws_account_id}:secret:airflow/${local.environment}/namespaces/${each.key}/*-*"
      },
    ]
  })
}

# Lets a namespace's own task code mint itself a web login token and call
# the Airflow REST API/UI directly, as the Op FAB role - there's no
# per-namespace Airflow RBAC (confirmed dead end investigating it), so this
# is not scoped to that namespace's own DAGs: once logged in, a namespace's
# code can see/manage every namespace's DAGs, same as any other Op-role user.
resource "aws_iam_role_policy" "mwaa_namespace_api" {
  for_each = local.mwaa_namespaces

  name = "edp-${local.environment}-mwaa-ns-${each.key}-api"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CreateWebLoginToken"
        Effect   = "Allow"
        Action   = "airflow:CreateWebLoginToken"
        Resource = "arn:aws:airflow:${data.aws_region.current.region}:${local.aws_account_id}:role/${aws_mwaa_environment.airflow.name}/Op"
      },
    ]
  })
}

resource "aws_iam_role_policy" "mwaa_namespace_fargate" {
  for_each = local.mwaa_fargate_namespaces

  name = "edp-${local.environment}-mwaa-ns-${each.key}-fargate"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RunNamespaceTasksOnly"
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:DescribeTasks",
          "ecs:StopTask",
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "ecs:cluster" = aws_ecs_cluster.mwaa_fargate.arn
          }
          StringEquals = {
            "aws:ResourceTag/MwaaNamespace" = each.key
          }
        }
      },
      {
        Sid      = "PassTaskExecutionRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.fargate_task_execution[each.key].arn
      },
    ]
  })
}

# Dedicated CI-only role per namespace: S3 DAG prefix access only.
# CI runners assume this role, NOT the namespace role, so they cannot reach
# Secrets Manager or other namespace-scoped AWS resources.
resource "aws_iam_role" "mwaa_namespace_ci" {
  for_each = {
    for k, v in local.mwaa_namespaces :
    k => v if length(try(v.spec.ci_roles[local.environment], [])) > 0
  }

  name        = "edp-${local.environment}-mwaa-ns-${each.key}-ci"
  description = "CI-only role for namespace '${each.key}': S3 DAG prefix write access; no Secrets Manager access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CIDeploy"
      Effect    = "Allow"
      Principal = { AWS = each.value.spec.ci_roles[local.environment] }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "mwaa_namespace_ci_deploy" {
  for_each = aws_iam_role.mwaa_namespace_ci

  name = "edp-${local.environment}-mwaa-ns-${each.key}-ci-deploy"
  role = aws_iam_role.mwaa_namespace_ci[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CIDeployDAGs"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = "${module.mwaa_s3.s3_bucket_arn}/dags/${each.key}/*"
      },
      # s3:ListBucket (bucket-level - needs the bare bucket ARN, not a
      # /dags/<ns>/* key pattern) authorizes ListObjectsV2, which `aws s3
      # sync --delete` needs against the destination. Scoped to this
      # namespace's own prefix, unlike mwaa_namespace_s3's unconditional
      # grant below - this CI-only role is meant to stay narrower.
      {
        Sid      = "CIDeployList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = module.mwaa_s3.s3_bucket_arn
        Condition = {
          StringLike = {
            "s3:prefix" = "dags/${each.key}/*"
          }
        }
      },
      {
        Sid    = "KMSForDAGUpload"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      },
    ]
  })
}

# --- ECR Repositories for MWAA Fargate Namespaces ---

resource "aws_ecr_repository" "mwaa_namespace" {
  #checkov:skip=CKV_AWS_51: MUTABLE tags required; namespaces overwrite :latest on each deploy
  for_each = local.mwaa_fargate_namespaces

  name                 = "chedaws-edp-mwaa-${each.key}-${local.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = data.aws_kms_alias.ecr.target_key_arn
  }

  tags = {
    Name          = "chedaws-edp-mwaa-${each.key}-${local.environment}"
    MwaaNamespace = each.key
  }
}

resource "aws_ecr_repository_policy" "mwaa_namespace" {
  for_each = local.mwaa_fargate_namespaces

  repository = aws_ecr_repository.mwaa_namespace[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "FargateExecutionRolePull"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.fargate_task_execution[each.key].arn
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
      },
      {
        Sid    = "CIAndIDCPush"
        Effect = "Allow"
        Principal = {
          AWS = concat(
            [aws_iam_role.mwaa_namespace[each.key].arn],
            try(each.value.spec.ci_roles[local.environment], [])
          )
        }
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
      },
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "mwaa_namespace" {
  for_each = local.mwaa_fargate_namespaces

  repository = aws_ecr_repository.mwaa_namespace[each.key].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

# --- ECS Fargate Cluster ---

resource "aws_ecs_cluster" "mwaa_fargate" {
  name = "chedaws-edp-mwaa-fargate-${local.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "chedaws-edp-mwaa-fargate-${local.environment}"
  }
}

# --- Per-namespace Fargate task execution roles ---

resource "aws_iam_role" "fargate_task_execution" {
  for_each = local.mwaa_fargate_namespaces

  name        = "edp-${local.environment}-fargate-exec-${each.key}"
  description = "Fargate task execution role for namespace '${each.key}' in ${local.environment}; grants ECR pull from namespace repo and CloudWatch Logs write"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fargate_task_execution_ecr_logs" {
  for_each = local.mwaa_fargate_namespaces

  #checkov:skip=CKV_AWS_287: sts:GetServiceBearerToken is required for public ECR auth and does not expose credentials

  name = "edp-${local.environment}-fargate-exec-${each.key}-ecr-logs"
  role = aws_iam_role.fargate_task_execution[each.key].id

  # Custom least-privilege policy replacing AmazonECSTaskExecutionRolePolicy.
  # Scopes ECR pull to this namespace's repository only (constitution §I).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        # GetAuthorizationToken (private) and GetAuthorizationToken (public) do not
        # support resource-level permissions; sts:GetServiceBearerToken is required
        # by the public ECR auth flow.
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr-public:GetAuthorizationToken",
          "sts:GetServiceBearerToken",
        ]
        Resource = "*"
      },
      {
        Sid    = "ECRPullNamespaceRepo"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.mwaa_namespace[each.key].arn
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.fargate_namespace[each.key].arn}:*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "fargate_task_execution_kms" {
  for_each = local.mwaa_fargate_namespaces

  name = "edp-${local.environment}-fargate-exec-${each.key}-kms"
  role = aws_iam_role.fargate_task_execution[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "KMSDecryptForLogsAndECR"
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      Resource = [
        data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn,
        data.aws_kms_alias.ecr.target_key_arn,
      ]
    }]
  })
}

# --- Platform namespace e2e Fargate task definition ---

resource "aws_ecs_task_definition" "platform_e2e" {
  #checkov:skip=CKV_AWS_336: e2e runner writes test artifacts to the filesystem; read-only root would break test execution
  family                   = "chedaws-edp-mwaa-platform-e2e-${local.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.fargate_task_execution["platform"].arn

  container_definitions = jsonencode([{
    name      = "e2e-runner"
    image     = "${aws_ecr_repository.mwaa_namespace["platform"].repository_url}:latest"
    essential = true
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fargate_namespace["platform"].name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "e2e"
      }
    }
  }])

  tags = {
    Name          = "chedaws-edp-mwaa-platform-e2e-${local.environment}"
    MwaaNamespace = "platform"
  }
}

# Smoke-test task definition — uses public Alpine image so no custom build is
# needed. The container simply prints a timestamp and exits 0.
# The platform e2e DAG (platform.e2e_fargate) submits this task to verify that
# the ECS Fargate data path (IAM, networking, logging) is working end-to-end.
resource "aws_ecs_task_definition" "platform_e2e_smoke" {
  #checkov:skip=CKV_AWS_336: read-only root not compatible with Alpine's /tmp usage during echo
  family                   = "chedaws-edp-mwaa-platform-smoke-${local.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.fargate_task_execution["platform"].arn

  container_definitions = jsonencode([{
    name      = "smoke"
    image     = "public.ecr.aws/docker/library/alpine:latest"
    essential = true
    command   = ["sh", "-c", "echo Fargate smoke test passed at $(date -u +%Y-%m-%dT%H:%M:%SZ) && exit 0"]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fargate_namespace["platform"].name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "smoke"
      }
    }
  }])

  tags = {
    Name          = "chedaws-edp-mwaa-platform-smoke-${local.environment}"
    MwaaNamespace = "platform"
  }
}

# --- Fargate Namespace CloudWatch Log Groups ---

resource "aws_cloudwatch_log_group" "fargate_namespace" {
  for_each = local.mwaa_fargate_namespaces

  name              = "/chedaws-edp/fargate/${each.key}/${local.environment}"
  retention_in_days = local.mwaa_log_retention
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "/chedaws-edp/fargate/${each.key}/${local.environment}"
  }
}

# --- ECS Fargate CloudWatch Alarms (constitution §II mandated for ECS) ---

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_utilization" {
  alarm_name          = "chedaws-edp-ecs-mwaa-cpu-utilization-${local.environment}"
  alarm_description   = "ECS Fargate CPU utilisation exceeded 80% in ${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "ECS/ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.mwaa_fargate.name
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_utilization" {
  alarm_name          = "chedaws-edp-ecs-mwaa-memory-utilization-${local.environment}"
  alarm_description   = "ECS Fargate memory utilisation exceeded 80% in ${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "ECS/ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.mwaa_fargate.name
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_task_count_anomaly" {
  alarm_name          = "chedaws-edp-ecs-mwaa-running-task-anomaly-${local.environment}"
  alarm_description   = "Anomalous running ECS task count in MWAA Fargate cluster in ${local.environment}"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "ad1"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "RunningTaskCount"
      namespace   = "ECS/ContainerInsights"
      period      = 300
      stat        = "Average"
      dimensions = {
        ClusterName = aws_ecs_cluster.mwaa_fargate.name
      }
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    return_data = true
    label       = "RunningTaskCount (expected)"
  }

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions    = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
}
