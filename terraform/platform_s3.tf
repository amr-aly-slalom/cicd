# ─── Platform S3 Bucket ───────────────────────────────────────────────────────

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
      values   = [module.kms["s3"].key_arn]
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

module "platform_s3" {
  #checkov:skip=CKV_AWS_145: KMS encryption configured via server_side_encryption_configuration sub-resource
  #checkov:skip=CKV_AWS_21: Versioning enabled via versioning sub-resource
  #checkov:skip=CKV_AWS_18: Access logging not required for this platform artefact bucket
  #checkov:skip=CKV_AWS_144: Cross-region replication not required for single-region deployment
  #checkov:skip=CKV_AWS_300: abort_incomplete_multipart_upload is set via lifecycle_rule input (days_after_initiation = 7)
  #checkov:skip=CKV_TF_1: registry source with pinned version is the correct alternative to a git commit hash
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.15.3"

  bucket = "chedaws-edp-platform-${local.environment}-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = module.kms["s3"].key_arn
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
    }
  ]

  attach_policy = true
  policy        = data.aws_iam_policy_document.s3_policy.json

  tags = {
    Name = "chedaws-edp-platform-${local.environment}-${data.aws_region.current.region}"
  }
}
