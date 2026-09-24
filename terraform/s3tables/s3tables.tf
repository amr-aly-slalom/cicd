locals {
  s3tables_config_dir         = "${path.root}/../../s3tables"
  s3tables_valid_environments = ["dev", "test", "uat", "prod"]
  s3tables_e2e_namespace      = "platform"
  s3tables_e2e_table          = "e2e_iceberg"
  s3tables_e2e_log_retention  = local.is_prod_like ? 30 : 7

  s3tables_athena_results_bucket = module.s3tables_athena_results_s3.s3_bucket_id
  _s3tables_namespace_files = sort(tolist(setunion(
    fileset(local.s3tables_config_dir, "namespaces/*.yaml"),
    fileset(local.s3tables_config_dir, "namespaces/*.yml"),
  )))

  _s3tables_raw_namespaces = [
    for f in local._s3tables_namespace_files : {
      source  = f
      content = yamldecode(file("${local.s3tables_config_dir}/${f}"))
    }
  ]
  _s3tables_namespaces_normalized = [
    for e in local._s3tables_raw_namespaces : {
      source = e.source
      name   = e.content.metadata.name
      environments = try(e.content.spec.environments, null) == null ? {
        for env in local.s3tables_valid_environments : env => {}
      } : e.content.spec.environments
    }
    if try(e.content.metadata.name, null) != null
  ]

  s3tables_namespaces_this_env = [
    for e in local._s3tables_namespaces_normalized : {
      source    = e.source
      name      = e.name
      iam_roles = try(e.environments[local.environment].iamRoles, [])
    }
    if contains(keys(e.environments), local.environment)
  ]
  s3tables_producers = {
    for e in local.s3tables_namespaces_this_env : e.name => {
      source         = e.source
      name           = e.name
      iam_roles      = e.iam_roles
      role_name      = "edp-${local.environment}-s3tables-producer-${e.name}"
      workgroup      = "edp-${local.environment}-tables-${e.name}"
      results_prefix = "athena-query-results/${e.name}"
    }
    if length(e.iam_roles) > 0
  }

  s3tables_producer_invalid_principals = sort(flatten([
    for name, p in local.s3tables_producers : [
      for arn in p.iam_roles : "${p.source}: ${arn}"
      if !can(regex("^arn:aws:iam::[0-9]{12}:role/", arn))
    ]
  ]))

  s3tables_producer_role_names_too_long = sort([
    for name, p in local.s3tables_producers : "${p.role_name} (${length(p.role_name)} chars)"
    if length(p.role_name) > 64
  ])

  s3tables_workgroup_names_too_long = sort([
    for name, p in local.s3tables_producers : "${p.workgroup} (${length(p.workgroup)} chars)"
    if length(p.workgroup) > 128
  ])
  s3tables_e2e_namespace_aws  = "edp_${local.environment}_${local.s3tables_e2e_namespace}"
  s3tables_e2e_results_prefix = "athena-query-results/e2e-verifier"
}
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#                                                                                          S3 Tables Resources
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Table Bucket
# ---------------------------------------------------------------------------

resource "aws_s3tables_table_bucket" "this" {
  name          = "chedaws-edp-table-bucket-${local.environment}"
  force_destroy = false

  encryption_configuration = {
    sse_algorithm = "aws:kms"
    kms_key_arn   = data.aws_kms_alias.s3tables.target_key_arn
  }
}

# ---------------------------------------------------------------------------
# Namespaces and Tables
# ---------------------------------------------------------------------------

module "table_bucket" {
  source = "../modules/s3tables"

  bucket_arn              = aws_s3tables_table_bucket.this.arn
  environment             = local.environment
  config_dir              = local.s3tables_config_dir
  enable_namespace_prefix = true
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
#                                                                                          E2E Validation Resrouces
# ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Athena Query Results Bucket 
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "s3tables_athena_results" {
  statement {
    sid     = "DenyWrongEncryptionAlgorithm"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["_S3_BUCKET_ARN_/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms", "AES256"]
    }
  }
}

module "s3tables_athena_results_s3" {
  #checkov:skip=CKV_AWS_18: "Ensure the S3 bucket has access logging enabled"
  #checkov:skip=CKV_AWS_144: "Ensure that S3 bucket has cross-region replication enabled"
  #checkov:skip=CKV_TF_1: registry source with pinned version is the correct alternative to a git commit hash
  #checkov:skip=CKV_AWS_145: "Ensure that S3 buckets are encrypted with KMS by default"
  #checkov:skip=CKV_AWS_21: "Ensure all data stored in the S3 bucket have versioning enabled"
  #checkov:skip=CKV_AWS_300: "Ensure S3 lifecycle configuration sets period for aborting failed uploads"
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.14.1"

  bucket = "chedaws-edp-s3tables-athena-result-${local.environment}"

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
      id      = "expire-query-results"
      enabled = true

      abort_incomplete_multipart_upload = {
        days_after_initiation = 7
      }

      expiration = {
        days = 7
      }

      noncurrent_version_expiration = {
        noncurrent_days = 7
      }
    }
  ]

  attach_policy = true
  policy        = data.aws_iam_policy_document.s3tables_athena_results.json

  tags = {
    Name = "chedaws-edp-s3tables-athena-results-${local.environment}"
  }
}

# ---------------------------------------------------------------------------
# Producer Preconditions 
# ---------------------------------------------------------------------------
resource "terraform_data" "s3tables_producer_validation" {
  lifecycle {
    precondition {
      condition     = length(local.s3tables_producer_invalid_principals) == 0
      error_message = "These producer principals are not IAM role ARNs: ${join("; ", local.s3tables_producer_invalid_principals)}. A bare account ID would widen the trust to every principal in that account."
    }

    precondition {
      condition     = length(local.s3tables_producer_role_names_too_long) == 0
      error_message = "These IAM role name(s) exceed the 64-character limit: ${join(", ", local.s3tables_producer_role_names_too_long)}. Shorten the namespace name in YAML."
    }

    precondition {
      condition     = length(local.s3tables_workgroup_names_too_long) == 0
      error_message = "These Athena workgroup name(s) exceed the 128-character limit: ${join(", ", local.s3tables_workgroup_names_too_long)}. Shorten the namespace name in YAML."
    }
  }
}
# ---------------------------------------------------------------------------
# Producer Roles
# ---------------------------------------------------------------------------
resource "aws_iam_role" "s3tables_namespace_producer" {
  for_each = local.s3tables_producers

  name        = each.value.role_name
  description = "S3 Tables producer role for namespace ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = each.value.iam_roles }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = each.value.role_name
  }
  depends_on = [
    aws_iam_role.s3tables_e2e_verifier_lambda_execution,
    terraform_data.s3tables_producer_validation,
  ]
}

resource "aws_iam_role_policy" "s3tables_namespace_producer" {
  for_each = local.s3tables_producers

  name = "s3tables-producer-${each.key}-policy"
  role = aws_iam_role.s3tables_namespace_producer[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:GetDataCatalog",
        ]
        Resource = [
          "arn:aws:athena:${data.aws_region.current.region}:${local.aws_account_id}:workgroup/${each.value.workgroup}",
          "arn:aws:athena:${data.aws_region.current.region}:${local.aws_account_id}:datacatalog/*",
        ]
      },
      {
        Sid      = "AthenaResultsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.s3tables_athena_results_bucket}"
      },
      {
        Sid    = "AthenaResultsObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "arn:aws:s3:::${local.s3tables_athena_results_bucket}/${each.value.results_prefix}/*"
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = [
          data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn,
          data.aws_kms_alias.s3tables.target_key_arn,
          data.aws_kms_alias.glue.target_key_arn,
        ]
      },
      {
        Sid    = "S3TablesAccess"
        Effect = "Allow"
        Action = [
          "s3tables:GetTableBucket",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:ListTables",
          "s3tables:GetTable",
          "s3tables:GetTableMetadataLocation",
          "s3tables:UpdateTableMetadataLocation",
          "s3tables:GetTableData",
          "s3tables:PutTableData",
        ]
        Resource = [
          aws_s3tables_table_bucket.this.arn,
          "${aws_s3tables_table_bucket.this.arn}/*",
        ]
      },
      {
        Sid    = "GlueCatalogAccess"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
          "glue:UpdateTable",
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog/s3tablescatalog",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog/s3tablescatalog/${aws_s3tables_table_bucket.this.name}",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:database/s3tablescatalog/${aws_s3tables_table_bucket.this.name}/${module.table_bucket.namespaces[each.key]}",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:table/s3tablescatalog/${aws_s3tables_table_bucket.this.name}/${module.table_bucket.namespaces[each.key]}/*",
        ]
      },
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = "lakeformation:GetDataAccess"
        Resource = "*"
      },
    ]
  })
}
# ---------------------------------------------------------------------------
# Athena Workgroup per Namespace
# ---------------------------------------------------------------------------
resource "aws_athena_workgroup" "s3tables_namespace" {
  #checkov:skip=CKV_AWS_159: "Ensure that Athena Workgroup is encrypted"
  for_each = local.s3tables_producers

  name          = each.value.workgroup
  description   = "Athena workgroup for S3 Tables namespace ${each.key} in ${local.environment}"
  state         = "ENABLED"
  force_destroy = false

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${local.s3tables_athena_results_bucket}/${each.value.results_prefix}/"
    }
  }

  tags = {
    Name = each.value.workgroup
  }

  depends_on = [terraform_data.s3tables_producer_validation]
}

# ---------------------------------------------------------------------------
# IAM: Lambda Execution Role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "s3tables_e2e_verifier_lambda_execution" {
  name        = "chedaws-edp-s3tables-e2e-verifier-${local.environment}"
  description = "Lambda execution role for the S3 Tables E2E verifier"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "s3tables_e2e_verifier_lambda_execution" {
  name = "s3tables-e2e-verifier-lambda-execution-policy"
  role = aws_iam_role.s3tables_e2e_verifier_lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeNamespaceRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.s3tables_e2e_verifier_producer.arn
      },
      {
        Sid      = "EmitMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
      },
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${local.aws_account_id}:log-group:/chedaws-edp/s3tables-e2e-verifier/${local.environment}:*"
      },
    ]
  })
}
# ---------------------------------------------------------------------------
# IAM: The Verifier's Own Producer Role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "s3tables_e2e_verifier_producer" {
  name        = "edp-${local.environment}-s3tables-e2e-verifier-producer"
  description = "Producer role the S3 Tables E2E verifier assumes to write to its canary table"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.s3tables_e2e_verifier_lambda_execution.arn }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "edp-${local.environment}-s3tables-e2e-verifier-producer"
  }
}

resource "aws_iam_role_policy" "s3tables_e2e_verifier_producer" {
  name = "s3tables-e2e-verifier-producer-policy"
  role = aws_iam_role.s3tables_e2e_verifier_producer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:GetDataCatalog",
        ]
        Resource = [
          aws_athena_workgroup.s3tables_e2e_verifier.arn,
          "arn:aws:athena:${data.aws_region.current.region}:${local.aws_account_id}:datacatalog/*",
        ]
      },
      {
        Sid      = "AthenaResultsBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.s3tables_athena_results_bucket}"
      },
      {
        Sid    = "AthenaResultsObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "arn:aws:s3:::${local.s3tables_athena_results_bucket}/${local.s3tables_e2e_results_prefix}/*"
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = [
          data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn,
          data.aws_kms_alias.s3tables.target_key_arn,
          data.aws_kms_alias.glue.target_key_arn,
        ]
      },
      {
        # CreateTable added: this verifier now creates its own table on
        # first run via CREATE TABLE IF NOT EXISTS.
        Sid    = "S3TablesAccess"
        Effect = "Allow"
        Action = [
          "s3tables:GetTableBucket",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:ListTables",
          "s3tables:GetTable",
          "s3tables:CreateTable",
          "s3tables:GetTableMetadataLocation",
          "s3tables:UpdateTableMetadataLocation",
          "s3tables:GetTableData",
          "s3tables:PutTableData",
        ]
        Resource = [
          aws_s3tables_table_bucket.this.arn,
          "${aws_s3tables_table_bucket.this.arn}/*",
        ]
      },
      {
        # CreateTable added: needed for the CREATE TABLE IF NOT EXISTS the
        # Lambda now runs against the federated Glue catalog.
        Sid    = "GlueCatalogAccess"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartitions",
          "glue:BatchGetPartition",
          "glue:CreateTable",
          "glue:UpdateTable",
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog/s3tablescatalog",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog/s3tablescatalog/${aws_s3tables_table_bucket.this.name}",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:database/s3tablescatalog/${aws_s3tables_table_bucket.this.name}/${local.s3tables_e2e_namespace_aws}",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:table/s3tablescatalog/${aws_s3tables_table_bucket.this.name}/${local.s3tables_e2e_namespace_aws}/*",
        ]
      },
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = "lakeformation:GetDataAccess"
        Resource = "*"
      },
    ]
  })
}
# ---------------------------------------------------------------------------
# The Verifier's Own Athena Workgroup
# ---------------------------------------------------------------------------

#trivy:ignore:AWS-0006 Ensure that Athena Workgroup is encrypted
resource "aws_athena_workgroup" "s3tables_e2e_verifier" {
  #checkov:skip=CKV_AWS_159: "Ensure that Athena Workgroup is encrypted"
  name        = "edp-${local.environment}-tables-e2e-verifier"
  description = "Athena workgroup for the S3 Tables E2E verifier in ${local.environment}"
  state       = "ENABLED"

  force_destroy = false

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${local.s3tables_athena_results_bucket}/${local.s3tables_e2e_results_prefix}/"
    }
  }

  tags = {
    Name = "edp-${local.environment}-tables-e2e-verifier"
  }
}
# ---------------------------------------------------------------------------
# CloudWatch Log Group
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "s3tables_e2e_verifier" {
  name              = "/chedaws-edp/s3tables-e2e-verifier/${local.environment}"
  retention_in_days = local.s3tables_e2e_log_retention
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "chedaws-edp-s3tables-e2e-verifier-logs-${local.environment}"
  }
}
# ---------------------------------------------------------------------------
# S3 Object: Lambda ZIP
# ---------------------------------------------------------------------------
resource "terraform_data" "build_s3tables_e2e_verifier_zip" {
  triggers_replace = [
    filemd5("${path.root}/../../lambda/s3tables-e2e-verifier/handler.py"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      (cd ${path.root}/../../lambda/s3tables-e2e-verifier && zip -j handler.zip handler.py)
    EOT
  }
}

resource "aws_s3_object" "s3tables_e2e_verifier_lambda" {
  depends_on             = [terraform_data.build_s3tables_e2e_verifier_zip]
  bucket                 = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  key                    = "e2e/s3tables-e2e-verifier/handler.zip"
  source                 = "${path.root}/../../lambda/s3tables-e2e-verifier/handler.zip"
  source_hash            = filemd5("${path.root}/../../lambda/s3tables-e2e-verifier/handler.py")
  server_side_encryption = "aws:kms"
  kms_key_id             = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  # source is only where the zip is built locally; the object's content is
  # tracked by source_hash, a hash of the files the zip is built from. Ignoring
  # source keeps a change to that local path (e.g. this module moving
  # directory) from re-uploading a zip this checkout never built.
  lifecycle {
    ignore_changes = [source]
  }
}
# ---------------------------------------------------------------------------
# Lambda Function 
# ---------------------------------------------------------------------------
#trivy:ignore:AWS-0066 X-Ray tracing not required for scheduled synthetic verifier
resource "aws_lambda_function" "s3tables_e2e_verifier" {
  #checkov:skip=CKV_AWS_117: Athena APIs are public; VPC not required for this scheduled synthetic verifier
  #checkov:skip=CKV_AWS_173: Lambda env vars contain non-secret config; KMS envelope encryption not required
  #checkov:skip=CKV_AWS_50: X-Ray tracing not required for scheduled synthetic verifier
  #checkov:skip=CKV_AWS_272: Code-signing not used in this project
  #checkov:skip=CKV_AWS_116: Scheduled synthetic verifier; DLQ not applicable
  function_name                  = "chedaws-edp-s3tables-e2e-verifier-${local.environment}"
  role                           = aws_iam_role.s3tables_e2e_verifier_lambda_execution.arn
  handler                        = "handler.lambda_handler"
  runtime                        = "python3.12"
  timeout                        = local.is_prod_like ? 300 : 120
  memory_size                    = local.is_prod_like ? 512 : 256
  reserved_concurrent_executions = 1

  s3_bucket         = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  s3_key            = aws_s3_object.s3tables_e2e_verifier_lambda.key
  s3_object_version = aws_s3_object.s3tables_e2e_verifier_lambda.version_id

  environment {
    variables = {
      ENVIRONMENT         = local.environment
      NAMESPACE_ROLE_ARN  = aws_iam_role.s3tables_e2e_verifier_producer.arn
      ATHENA_WORKGROUP    = aws_athena_workgroup.s3tables_e2e_verifier.name
      TABLE_BUCKET_NAME   = aws_s3tables_table_bucket.this.name
      TABLE_BUCKET_ARN    = aws_s3tables_table_bucket.this.arn
      TABLE_BUCKET_REGION = data.aws_region.current.region
      TABLE_NAMESPACE     = local.s3tables_e2e_namespace_aws
      TABLE_NAME          = local.s3tables_e2e_table

      ATHENA_QUERY_TIMEOUT_SECONDS = tostring(local.is_prod_like ? 90 : 30)
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.s3tables_e2e_verifier.name
    log_format = "Text"
  }

  depends_on = [aws_cloudwatch_log_group.s3tables_e2e_verifier]

  tags = {
    Name = "chedaws-edp-s3tables-e2e-verifier-${local.environment}"
  }
}
# ---------------------------------------------------------------------------
# EventBridge Schedule
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "s3tables_e2e_verifier_schedule" {
  name                = "chedaws-edp-s3tables-e2e-verifier-schedule-${local.environment}"
  description         = "Triggers S3 Tables E2E verifier Lambda daily at 06:00 UTC in ${local.environment}"
  schedule_expression = "cron(0 6 * * ? *)"
  state               = "ENABLED"

  tags = {
    Name = "chedaws-edp-s3tables-e2e-verifier-schedule-${local.environment}"
  }
}

resource "aws_cloudwatch_event_target" "s3tables_e2e_verifier" {
  rule      = aws_cloudwatch_event_rule.s3tables_e2e_verifier_schedule.name
  target_id = "S3TablesE2EVerifierLambda"
  arn       = aws_lambda_function.s3tables_e2e_verifier.arn
}

resource "aws_lambda_permission" "s3tables_e2e_verifier_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3tables_e2e_verifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3tables_e2e_verifier_schedule.arn
}
# ---------------------------------------------------------------------------
# CloudWatch Alarms
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "s3tables_e2e_validation_failure" {
  alarm_name        = "chedaws-edp-s3tables-e2e-validation-failure-${local.environment}"
  alarm_description = "S3 Tables E2E verifier test has failed or not run in the last 24 hours in ${local.environment}. Check CloudWatch Logs at /chedaws-edp/s3tables-e2e-verifier/${local.environment} for run_id, status, and details."

  namespace   = "ChedawsEDP/S3TablesE2EVerifier"
  metric_name = "S3TablesE2ETestSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-s3tables-e2e-validation-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3tables_e2e_cleanup_failure" {
  alarm_name        = "chedaws-edp-s3tables-e2e-cleanup-failure-${local.environment}"
  alarm_description = "S3 Tables E2E verifier cleanup has failed in the last 24 hours in ${local.environment}. Orphaned test rows may remain in the Iceberg table. Check CloudWatch Logs at /chedaws-edp/s3tables-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/S3TablesE2EVerifier"
  metric_name = "S3TablesE2ECleanupSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-s3tables-e2e-cleanup-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3tables_e2e_lambda_errors" {
  alarm_name        = "chedaws-edp-s3tables-e2e-lambda-errors-${local.environment}"
  alarm_description = "S3 Tables E2E verifier Lambda invocation errors in ${local.environment}. Check /chedaws-edp/s3tables-e2e-verifier/${local.environment} for details."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"

  dimensions = {
    FunctionName = aws_lambda_function.s3tables_e2e_verifier.function_name
  }

  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-s3tables-e2e-lambda-errors-${local.environment}"
  }
}
# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "s3tables_table_bucket_arn" {
  description = "ARN of the S3 Tables table bucket"
  value       = aws_s3tables_table_bucket.this.arn
}

output "s3tables_namespaces" {
  description = "Map of S3 Tables namespace name in YAML => namespace name in AWS"
  value       = module.table_bucket.namespaces
}

output "s3tables_producer_role_arns" {
  description = "Map of S3 Tables namespace => producer role ARN"
  value       = { for name, r in aws_iam_role.s3tables_namespace_producer : name => r.arn }
}

output "s3tables_athena_workgroups" {
  description = "Map of S3 Tables namespace => Athena workgroup name"
  value       = { for name, wg in aws_athena_workgroup.s3tables_namespace : name => wg.name }
}

output "s3tables_athena_result_locations" {
  description = "Map of S3 Tables namespace => enforced query result location"
  value = {
    for name, p in local.s3tables_producers :
    name => "s3://${local.s3tables_athena_results_bucket}/${p.results_prefix}/"
  }
}

output "s3tables_e2e_verifier_function_name" {
  description = "Name of the E2E verifier Lambda. Always present - the verifier is independent of the s3tables/ registry."
  value       = aws_lambda_function.s3tables_e2e_verifier.function_name
}

output "s3tables_e2e_verifier_target" {
  description = "The namespace and table the E2E verifier writes to, addressed by name. These are created from the s3tables/ registry; if either is removed, the verifier stays deployed and reports the miss at runtime."
  value = {
    namespace = local.s3tables_e2e_namespace_aws
    table     = local.s3tables_e2e_table
    workgroup = aws_athena_workgroup.s3tables_e2e_verifier.name
    role_arn  = aws_iam_role.s3tables_e2e_verifier_producer.arn
  }
}
