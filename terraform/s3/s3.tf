# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  # Namespace registrations: s3/<namespace>.yaml
  _s3_namespace_files = {
    for f in fileset("${path.root}/../../s3", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../s3/${f}"))
  }

  s3_namespaces_this_env = {
    for k, v in local._s3_namespace_files :
    k => v
    if contains(keys(v.spec.producer.environments), local.environment)
  }

  s3_aws_namespaces_this_env = {
    for k, v in local.s3_namespaces_this_env :
    k => v.spec.producer.environments[local.environment].iamRoles
    if can(v.spec.producer.environments[local.environment].iamRoles)
  }

  s3_onprem_namespaces_this_env = {
    for k, v in local.s3_namespaces_this_env :
    k => { certificate_subjects = v.spec.producer.environments[local.environment].certificateSubject }
    if can(v.spec.producer.environments[local.environment].certificateSubject)
  }

  # Table registrations: s3/<namespace>/<name>.yaml
  _s3_table_files = {
    for f in fileset("${path.root}/../../s3", "*/*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../s3/${f}"))
  }

  s3_tables_active = {
    for k, v in local._s3_table_files :
    k => v
    if !try(v.spec.decommission, false)
  }

  # Tables whose namespace is registered for this environment (used for Glue)
  s3_tables_this_env = {
    for k, v in local.s3_tables_active :
    k => v
    if contains(keys(local.s3_namespaces_this_env), v.metadata.namespace)
  }

  s3_tables_with_schema_this_env = {
    for k, v in local.s3_tables_this_env :
    k => v
    if can(v.spec.schema.columns)
  }

  # Optional table-level roles (table YAMLs declaring spec.producer)
  s3_table_aws_producers_this_env = {
    for k, v in local.s3_tables_active :
    k => v.spec.producer.environments[local.environment].iamRoles
    if can(v.spec.producer.environments[local.environment].iamRoles)
  }

  s3_table_onprem_producers_this_env = {
    for k, v in local.s3_tables_active :
    k => { certificate_subjects = v.spec.producer.environments[local.environment].certificateSubject }
    if can(v.spec.producer.environments[local.environment].certificateSubject)
  }

  # Distinct (env, namespace) keys for Glue database provisioning.
  _s3_glue_database_keys = toset([
    for k, v in local.s3_tables_with_schema_this_env :
    "${local.environment}_${replace(v.metadata.namespace, "-", "_")}"
  ])

  _s3_namespace_slug_list   = [for k, v in local.s3_namespaces_this_env : v.metadata.name]
  _s3_namespace_slug_unique = distinct(local._s3_namespace_slug_list)
  _s3_table_slug_list       = [for k, v in local.s3_tables_active : "${v.metadata.namespace}-${v.metadata.name}"]
  _s3_table_slug_unique     = distinct(local._s3_table_slug_list)

  _s3_serde_map = {
    csv = {
      input_format  = "org.apache.hadoop.mapred.TextInputFormat"
      output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
      serde_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      serde_parameters = {
        "skip.header.line.count" = "1"
        "field.delim"            = ","
      }
    }
    json = {
      input_format  = "org.apache.hadoop.mapred.TextInputFormat"
      output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
      serde_library = "org.openx.data.jsonserde.JsonSerDe"
    }
    avro = {
      input_format  = "org.apache.avro.mapred.AvroInputFormat"
      output_format = "org.apache.avro.mapred.AvroOutputFormat"
      serde_library = "org.apache.hadoop.hive.serde2.avro.AvroSerDe"
    }
    parquet = {
      input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
      output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
      serde_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }
  }
}

# ─── Validations ──────────────────────────────────────────────────────────────

resource "terraform_data" "s3_namespace_unique_check" {
  lifecycle {
    precondition {
      condition     = length(local._s3_namespace_slug_list) == length(local._s3_namespace_slug_unique)
      error_message = "Duplicate namespace values detected in s3/*.yaml: ${join(", ", setsubtract(toset(local._s3_namespace_slug_list), toset(local._s3_namespace_slug_unique)))}"
    }
  }
}

resource "terraform_data" "s3_table_unique_check" {
  lifecycle {
    precondition {
      condition     = length(local._s3_table_slug_list) == length(local._s3_table_slug_unique)
      error_message = "Duplicate active (namespace, name) pairs detected in s3/*/*.yaml: ${join(", ", setsubtract(toset(local._s3_table_slug_list), toset(local._s3_table_slug_unique)))}"
    }
  }
}

resource "terraform_data" "s3_namespace_name_length_check" {
  for_each = local.s3_namespaces_this_env

  lifecycle {
    precondition {
      condition     = length("edp-${local.environment}-s3-producer-${each.value.metadata.name}") <= 64
      error_message = "IAM role name 'edp-${local.environment}-s3-producer-${each.value.metadata.name}' exceeds 64 characters."
    }
  }
}

resource "terraform_data" "s3_table_name_length_check" {
  for_each = merge(local.s3_table_aws_producers_this_env, local.s3_table_onprem_producers_this_env)

  lifecycle {
    precondition {
      condition     = length("edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}") <= 64
      error_message = "IAM role name 'edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}' exceeds 64 characters."
    }
  }
}

# ─── S3 Buckets ───────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "s3_policy" {
  statement {
    sid     = "DenyNonPlatformKeyUploads"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["_S3_BUCKET_ARN_/*"]

    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn]
    }
  }

  statement {
    sid     = "DenyNonKMSAlgorithm"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["_S3_BUCKET_ARN_/*"]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "DenyNonTLSRequests"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      "_S3_BUCKET_ARN_",
      "_S3_BUCKET_ARN_/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

module "landing_s3" {
  #checkov:skip=CKV_AWS_18: "Ensure the S3 bucket has access logging enabled"
  #checkov:skip=CKV_AWS_145: "Ensure that S3 buckets are encrypted with KMS by default"
  #checkov:skip=CKV_AWS_144: "Ensure that S3 bucket has cross-region replication enabled"
  #checkov:skip=CKV_AWS_21: "Ensure all data stored in the S3 bucket have versioning enabled"
  #checkov:skip=CKV_AWS_300: "Ensure S3 lifecycle configuration sets period for aborting failed uploads"
  #checkov:skip=CKV_TF_1: registry source with pinned version is the correct alternative to a git commit hash
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.3"

  bucket = "chedaws-edp-landing-bucket-${local.environment}"

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
      id      = "intelligent-tiering"
      enabled = true

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
      id      = "athena-query-results-e2e-expiry"
      enabled = true
      prefix  = "athena-query-results/"

      expiration = {
        days = 7
      }
    }
  ]

  attach_policy = true
  policy        = data.aws_iam_policy_document.s3_policy.json

  tags = {
    Name = "chedaws-edp-landing-bucket-${local.environment}"
  }
}

# ─── Namespace IAM ────────────────────────────────────────────────────────────

resource "aws_iam_policy" "s3_namespace_producer" {
  for_each = local.s3_namespaces_this_env

  name        = "edp-${local.environment}-s3-producer-${each.value.metadata.name}"
  description = "S3 write and Athena query access for namespace ${each.value.metadata.name} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketAccess"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = module.landing_s3.s3_bucket_arn
      },
      {
        Sid    = "S3PutObject"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:PutObjectTagging", "s3:DeleteObject"]
        Resource = [
          "${module.landing_s3.s3_bucket_arn}/${each.value.metadata.name}/*"
        ]
      },
      {
        Sid      = "S3ReadNamespace"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${module.landing_s3.s3_bucket_arn}/${each.value.metadata.name}/*"
      },
      {
        Sid    = "AthenaResultsAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${module.landing_s3.s3_bucket_arn}/athena-query-results/${each.value.metadata.name}/*",
        ]
      },
      {
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [
          data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn,
          data.aws_kms_alias.glue.target_key_arn,
        ]
      },
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
        ]
        Resource = "arn:aws:athena:${data.aws_region.current.region}:${local.aws_account_id}:workgroup/edp-${local.environment}-${each.value.metadata.name}"
      },
      {
        Sid    = "GlueReadNamespace"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:database/edp_${local.environment}_${replace(each.value.metadata.name, "-", "_")}",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:table/edp_${local.environment}_${replace(each.value.metadata.name, "-", "_")}/*",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "s3_namespace_aws_producer" {
  for_each = local.s3_aws_namespaces_this_env

  name        = "edp-${local.environment}-s3-producer-${local.s3_namespaces_this_env[each.key].metadata.name}"
  description = "S3 namespace producer role for ${local.s3_namespaces_this_env[each.key].metadata.name} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = each.value }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  depends_on = [aws_iam_role.s3_e2e_verifier_lambda_execution]
}

resource "aws_iam_role_policy_attachment" "s3_namespace_aws_producer" {
  for_each = local.s3_aws_namespaces_this_env

  role       = aws_iam_role.s3_namespace_aws_producer[each.key].name
  policy_arn = aws_iam_policy.s3_namespace_producer[each.key].arn
}

resource "aws_iam_role" "s3_namespace_onprem_producer" {
  for_each = local.s3_onprem_namespaces_this_env

  name        = "edp-${local.environment}-s3-producer-${local.s3_namespaces_this_env[each.key].metadata.name}"
  description = "S3 namespace producer role for ${local.s3_namespaces_this_env[each.key].metadata.name} in ${local.environment} (on-premises)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "rolesanywhere.amazonaws.com" }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
          "sts:SetSourceIdentity"
        ]
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:PrincipalTag/x509Subject/CN" = [for cn in each.value.certificate_subjects : split("CN=", cn)[1]]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_namespace_onprem_producer" {
  for_each = local.s3_onprem_namespaces_this_env

  role       = aws_iam_role.s3_namespace_onprem_producer[each.key].name
  policy_arn = aws_iam_policy.s3_namespace_producer[each.key].arn
}

# ─── Table IAM ────────────────────────────────────────────────────────────────

resource "aws_iam_policy" "s3_table_producer" {
  for_each = toset(concat(
    keys(local.s3_table_aws_producers_this_env),
    keys(local.s3_table_onprem_producers_this_env)
  ))

  name        = "edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}"
  description = "S3 write and Athena query access for table ${each.key} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3BucketAccess"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = module.landing_s3.s3_bucket_arn
      },
      {
        Sid    = "S3PutObject"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:PutObjectTagging", "s3:DeleteObject"]
        Resource = [
          "${module.landing_s3.s3_bucket_arn}/${split("/", each.key)[0]}/${split("/", each.key)[1]}/*"
        ]
      },
      {
        Sid      = "S3ReadTable"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${module.landing_s3.s3_bucket_arn}/${split("/", each.key)[0]}/${split("/", each.key)[1]}/*"
      },
      {
        Sid    = "AthenaResultsAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = [
          "${module.landing_s3.s3_bucket_arn}/athena-query-results/${split("/", each.key)[0]}/${split("/", each.key)[1]}/*",
        ]
      },
      {
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [
          data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn,
          data.aws_kms_alias.glue.target_key_arn,
        ]
      },
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
        ]
        Resource = "arn:aws:athena:${data.aws_region.current.region}:${local.aws_account_id}:workgroup/edp-${local.environment}-${split("/", each.key)[0]}"
      },
      {
        Sid    = "GlueReadTable"
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:database/edp_${local.environment}_${replace(split("/", each.key)[0], "-", "_")}",
          "arn:aws:glue:${data.aws_region.current.region}:${local.aws_account_id}:table/edp_${local.environment}_${replace(split("/", each.key)[0], "-", "_")}/${split("/", each.key)[1]}",
        ]
      },
    ]
  })
}

resource "aws_iam_role" "s3_table_aws_producer" {
  for_each = local.s3_table_aws_producers_this_env

  name        = "edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}"
  description = "S3 table producer role for ${split("/", each.key)[0]}/${split("/", each.key)[1]} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = each.value }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_table_aws_producer" {
  for_each = local.s3_table_aws_producers_this_env

  role       = aws_iam_role.s3_table_aws_producer[each.key].name
  policy_arn = aws_iam_policy.s3_table_producer[each.key].arn
}

resource "aws_iam_role" "s3_table_onprem_producer" {
  for_each = local.s3_table_onprem_producers_this_env

  name        = "edp-${local.environment}-s3-producer-${split("/", each.key)[0]}-${split("/", each.key)[1]}"
  description = "S3 table producer role for ${split("/", each.key)[0]}/${split("/", each.key)[1]} in ${local.environment} (on-premises)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "rolesanywhere.amazonaws.com" }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession",
          "sts:SetSourceIdentity"
        ]
        Condition = {
          "ForAnyValue:StringEquals" = {
            "aws:PrincipalTag/x509Subject/CN" = [for cn in each.value.certificate_subjects : split("CN=", cn)[1]]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_table_onprem_producer" {
  for_each = local.s3_table_onprem_producers_this_env

  role       = aws_iam_role.s3_table_onprem_producer[each.key].name
  policy_arn = aws_iam_policy.s3_table_producer[each.key].arn
}

# ─── Athena Workgroups ────────────────────────────────────────────────────────

resource "aws_athena_workgroup" "s3_namespace_producer" {
  for_each = local.s3_namespaces_this_env

  name = "edp-${local.environment}-${each.value.metadata.name}"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://chedaws-edp-landing-bucket-${local.environment}/athena-query-results/${each.value.metadata.name}/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      }
    }
  }

  tags = {
    Name = "edp-${local.environment}-${each.value.metadata.name}"
  }
}

# ─── Glue Catalog ─────────────────────────────────────────────────────────────
#
# The account-wide catalog encryption setting these rely on stays in the core
# state (terraform/glue.tf).

resource "aws_glue_catalog_database" "producer_domain" {
  for_each = local._s3_glue_database_keys

  # each.key is "${env}_${replace(namespace, "-", "_")}" e.g. "dev_finance"
  name        = "edp_${each.key}"
  description = "EDP landing datasets for ${trimprefix(each.key, "${local.environment}_")} namespace in ${local.environment}"

  location_uri = "s3://${module.landing_s3.s3_bucket_id}/${replace(trimprefix(each.key, "${local.environment}_"), "_", "-")}/"
}

resource "aws_glue_catalog_table" "producer_dataset" {
  for_each = local.s3_tables_with_schema_this_env

  database_name = "edp_${local.environment}_${replace(each.value.metadata.namespace, "-", "_")}"
  name          = each.value.metadata.name

  table_type = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${module.landing_s3.s3_bucket_id}/${each.value.metadata.namespace}/${each.value.metadata.name}/"
    input_format  = local._s3_serde_map[each.value.spec.format].input_format
    output_format = local._s3_serde_map[each.value.spec.format].output_format

    ser_de_info {
      serialization_library = local._s3_serde_map[each.value.spec.format].serde_library
      parameters            = try(local._s3_serde_map[each.value.spec.format].serde_parameters, {})
    }

    dynamic "columns" {
      for_each = [
        for col in each.value.spec.schema.columns :
        col if !contains(try(each.value.spec.schema.partitionKeys, []), col.name)
      ]
      content {
        name    = columns.value.name
        type    = columns.value.type
        comment = try(columns.value.comment, null)
      }
    }
  }

  dynamic "partition_keys" {
    for_each = [
      for col in each.value.spec.schema.columns :
      col if contains(try(each.value.spec.schema.partitionKeys, []), col.name)
    ]
    content {
      name    = partition_keys.value.name
      type    = partition_keys.value.type
      comment = try(partition_keys.value.comment, null)
    }
  }

  depends_on = [aws_glue_catalog_database.producer_domain]
}

# ─── E2E Verifier ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "s3_e2e_verifier_lambda_execution" {
  name        = "chedaws-edp-s3-e2e-verifier-${local.environment}"
  description = "Lambda execution role for the S3 E2E verifier - assumes platform namespace IAM role and manages test data lifecycle"

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

resource "aws_iam_role_policy" "s3_e2e_verifier_lambda_execution" {
  name = "s3-e2e-verifier-lambda-execution-policy"
  role = aws_iam_role.s3_e2e_verifier_lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeNamespaceRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-s3-producer-platform"
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
        Resource = "arn:aws:logs:*:*:log-group:/chedaws-edp/s3-e2e-verifier/${local.environment}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "s3_e2e_verifier" {
  name              = "/chedaws-edp/s3-e2e-verifier/${local.environment}"
  retention_in_days = local.log_retention_days
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "chedaws-edp-s3-e2e-verifier-logs-${local.environment}"
  }
}

resource "terraform_data" "build_s3_verifier_zip" {
  triggers_replace = [
    filemd5("${path.root}/../../lambda/s3-e2e-verifier/handler.py"),
    filemd5("${path.root}/../../lambda/s3-e2e-verifier/requirements.txt"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      python3 -m pip install -r ${path.root}/../../lambda/s3-e2e-verifier/requirements.txt \
          -t ${path.root}/../../lambda/s3-e2e-verifier/package/
      cp ${path.root}/../../lambda/s3-e2e-verifier/handler.py \
          ${path.root}/../../lambda/s3-e2e-verifier/package/
      (cd ${path.root}/../../lambda/s3-e2e-verifier/package && zip -r ../function.zip .)
    EOT
  }
}

resource "aws_s3_object" "s3_e2e_verifier_lambda" {
  depends_on             = [terraform_data.build_s3_verifier_zip]
  bucket                 = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  key                    = "e2e/s3-e2e-verifier/function.zip"
  source                 = "${path.root}/../../lambda/s3-e2e-verifier/function.zip"
  source_hash            = md5(join("", [filemd5("${path.root}/../../lambda/s3-e2e-verifier/handler.py"), filemd5("${path.root}/../../lambda/s3-e2e-verifier/requirements.txt")]))
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

#trivy:ignore:AWS-0066 X-Ray tracing not required for scheduled synthetic verifier
resource "aws_lambda_function" "s3_e2e_verifier" {
  #checkov:skip=CKV_AWS_117: S3 and Athena APIs are public; VPC not required for this scheduled synthetic verifier
  #checkov:skip=CKV_AWS_173: Lambda env vars contain non-secret config; KMS envelope encryption not required
  #checkov:skip=CKV_AWS_50: X-Ray tracing not required for scheduled synthetic verifier
  #checkov:skip=CKV_AWS_272: Code-signing not used in this project
  #checkov:skip=CKV_AWS_116: Scheduled synthetic verifier; DLQ not applicable
  function_name                  = "chedaws-edp-s3-e2e-verifier-${local.environment}"
  role                           = aws_iam_role.s3_e2e_verifier_lambda_execution.arn
  handler                        = "handler.lambda_handler"
  runtime                        = "python3.14"
  timeout                        = local.is_prod_like ? 300 : 120
  memory_size                    = local.is_prod_like ? 512 : 256
  reserved_concurrent_executions = 1

  s3_bucket         = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  s3_key            = aws_s3_object.s3_e2e_verifier_lambda.key
  s3_object_version = aws_s3_object.s3_e2e_verifier_lambda.version_id

  environment {
    variables = {
      ENVIRONMENT                  = local.environment
      NAMESPACE_ROLE_ARN           = "arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-s3-producer-platform"
      LANDING_BUCKET               = "chedaws-edp-landing-bucket-${local.environment}"
      KMS_KEY_ARN                  = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      ATHENA_WORKGROUP             = "edp-${local.environment}-platform"
      GLUE_DATABASE                = "edp_${local.environment}_platform"
      ATHENA_QUERY_TIMEOUT_SECONDS = tostring(local.is_prod_like ? 90 : 30)
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.s3_e2e_verifier.name
    log_format = "Text"
  }

  depends_on = [aws_cloudwatch_log_group.s3_e2e_verifier]

  tags = {
    Name = "chedaws-edp-s3-e2e-verifier-${local.environment}"
  }
}

resource "aws_cloudwatch_event_rule" "s3_e2e_verifier_schedule" {
  name                = "chedaws-edp-s3-e2e-verifier-schedule-${local.environment}"
  description         = "Triggers S3 E2E verifier Lambda daily at 06:00 UTC in ${local.environment}"
  schedule_expression = "cron(0 6 * * ? *)"
  state               = "ENABLED"

  tags = {
    Name = "chedaws-edp-s3-e2e-verifier-schedule-${local.environment}"
  }
}

resource "aws_cloudwatch_event_target" "s3_e2e_verifier" {
  rule      = aws_cloudwatch_event_rule.s3_e2e_verifier_schedule.name
  target_id = "S3E2EVerifierLambda"
  arn       = aws_lambda_function.s3_e2e_verifier.arn
}

resource "aws_lambda_permission" "s3_e2e_verifier_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_e2e_verifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_e2e_verifier_schedule.arn
}

resource "aws_cloudwatch_metric_alarm" "s3_e2e_validation_failure" {
  alarm_name        = "chedaws-edp-s3-e2e-validation-failure-${local.environment}"
  alarm_description = "S3 E2E verifier test has failed or not run in the last 24 hours in ${local.environment}. Check CloudWatch Logs at /chedaws-edp/s3-e2e-verifier/${local.environment} for run_id, status, and table outcome details."

  namespace   = "ChedawsEDP/S3E2EVerifier"
  metric_name = "S3E2ETestSuccess"

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
    Name = "chedaws-edp-s3-e2e-validation-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3_e2e_cleanup_failure" {
  alarm_name        = "chedaws-edp-s3-e2e-cleanup-failure-${local.environment}"
  alarm_description = "S3 E2E verifier cleanup has failed in the last 24 hours in ${local.environment}. Test data objects may remain under platform/ prefix. Check CloudWatch Logs at /chedaws-edp/s3-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/S3E2EVerifier"
  metric_name = "S3E2ECleanupSuccess"

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
    Name = "chedaws-edp-s3-e2e-cleanup-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "s3_e2e_lambda_errors" {
  alarm_name        = "chedaws-edp-s3-e2e-lambda-errors-${local.environment}"
  alarm_description = "S3 E2E verifier Lambda invocation errors in ${local.environment}. Check /chedaws-edp/s3-e2e-verifier/${local.environment} for details."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"

  dimensions = {
    FunctionName = aws_lambda_function.s3_e2e_verifier.function_name
  }

  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-s3-e2e-lambda-errors-${local.environment}"
  }
}
