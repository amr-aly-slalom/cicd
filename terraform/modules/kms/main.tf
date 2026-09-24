terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "this" {
  #checkov:skip=CKV_AWS_109: Root admin statement is required by AWS for KMS key management; resource * is scoped to this key by policy attachment
  #checkov:skip=CKV_AWS_111: Root admin statement is required by AWS for KMS key management; resource * is scoped to this key by policy attachment
  #checkov:skip=CKV_AWS_356: Root admin statement is required by AWS for KMS key management; resource * is scoped to this key by policy attachment

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowServiceAccess"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = tolist(var.service_principals)
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(var.publisher_principals) > 0 ? [1] : []
    content {
      sid    = "AllowServicePublishers"
      effect = "Allow"
      principals {
        type        = "Service"
        identifiers = tolist(var.publisher_principals)
      }
      actions = [
        "kms:GenerateDataKey*",
        "kms:Decrypt",
      ]
      resources = ["*"]
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  description             = "KMS CMK for chedaws-edp-${var.service_name}-${var.environment}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.this.json

  tags = {
    Name = "chedaws-edp-${var.service_name}-kms-${var.environment}"
  }
}

resource "aws_kms_alias" "this" {
  name          = "alias/chedaws-edp-${var.service_name}-${var.environment}"
  target_key_id = aws_kms_key.this.key_id
}
