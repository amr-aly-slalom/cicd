# ─── Glue Data Catalog Encryption ─────────────────────────────────────────────
#
# An account-wide setting (one per account and region) that every Glue
# catalog in the account relies on - S3 producer databases, S3 Tables and
# Lake Formation alike - so it stays in core rather than with any one of them.

resource "aws_glue_data_catalog_encryption_settings" "edp_catalog" {
  #checkov:skip=CKV_AWS_94 : Ensure Glue Data Catalog Encryption is enabled
  count = contains(local.distinct_account_envs, local.environment) ? 1 : 0
  data_catalog_encryption_settings {
    encryption_at_rest {
      catalog_encryption_mode         = "SSE-KMS-WITH-SERVICE-ROLE"
      sse_aws_kms_key_id              = module.kms["glue"].key_arn
      catalog_encryption_service_role = aws_iam_role.glue_catalog_encryption[count.index].arn
    }
    connection_password_encryption {
      aws_kms_key_id                       = module.kms["glue"].key_arn
      return_connection_password_encrypted = true
    }
  }
}

resource "aws_iam_role" "glue_catalog_encryption" {
  count = contains(local.distinct_account_envs, local.environment) ? 1 : 0
  name  = "glue-catalog-encryption-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "glue_catalog_encryption_kms" {
  #checkov:skip=CKV_AWS_355: Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions
  #checkov:skip=CKV_AWS_290: Ensure IAM policies does not allow write access without constraints
  count = contains(local.distinct_account_envs, local.environment) ? 1 : 0
  name  = "glue-catalog-encryption-policy"
  role  = aws_iam_role.glue_catalog_encryption[count.index].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      Resource = "*"
    }]
  })
}
