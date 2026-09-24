# _S3_BUCKET_ARN_ is a terraform-aws-modules/s3-bucket (v5.15.3) convention:
# it substitutes the bucket's own ARN internally, avoiding a circular
# reference to an output of the same module call this policy is passed into.
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
