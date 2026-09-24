# KMS CMK Module

Reusable module that provisions a single KMS Customer Managed Key (CMK) with a lean key policy: one root IAM statement (required for key management) and one service-principal statement granting the minimum permissions needed to the declared AWS service principals.

## Usage

```hcl
module "kms" {
  for_each = local.kms_services

  source             = "./modules/kms"
  service_name       = each.key
  service_principals = each.value.service_principals
  environment        = local.environment
}
```

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `service_name` | `string` | Service name used in alias and description (e.g. `redshift`) |
| `service_principals` | `set(string)` | One or more AWS service principals granted KMS actions (e.g. `["redshift.amazonaws.com"]`); must contain at least one element |
| `publisher_principals` | `set(string)` | Optional. Service principals that publish to resources encrypted with this key (e.g. `cloudwatch.amazonaws.com` for alarms sent to an encrypted SNS topic). Adds a statement granting only `kms:GenerateDataKey*` and `kms:Decrypt`, conditioned on `aws:SourceAccount`. Default `[]` |
| `environment` | `string` | Terraform workspace name, embedded in alias suffix (e.g. `dev`) |

## Outputs

| Name | Description |
|------|-------------|
| `key_arn` | ARN of the KMS CMK |
| `key_id` | ID of the KMS CMK |
| `alias_arn` | ARN of the KMS alias |

## Consumers

All six call sites are invoked from `terraform/kms.tf` via `for_each = local.kms_services`:

| Key | Alias | Consumers |
|-----|-------|-----------|
| `module.kms["redshift"]` | `alias/chedaws-edp-redshift-<env>` | `aws_redshift_cluster.this` (encryption at rest), `aws_secretsmanager_secret.redshift_password` (secret encryption) |
| `module.kms["sns"]` | `alias/chedaws-edp-sns-<env>` | `aws_sns_topic.alerts` (topic encryption at rest) |
| `module.kms["cloudwatch_logs"]` | `alias/chedaws-edp-cloudwatch_logs-<env>` | `aws_cloudwatch_log_group.redshift` (log group encryption at rest) |
| `module.kms["msk"]` | `alias/chedaws-edp-msk-<env>` | `aws_msk_cluster.this` (broker encryption at rest) |
| `module.kms["s3tables"]` | `alias/chedaws-edp-s3tables-<env>` | `aws_s3tables_table_bucket.this` (S3 Tables bucket encryption at rest); uses two principals: `s3tables.amazonaws.com` and `maintenance.s3tables.amazonaws.com` |
| `module.kms["s3"]` | `alias/chedaws-edp-s3-<env>` | `module.platform_s3` (platform S3 bucket encryption at rest) |

## Key Policy

Each CMK gets a two-statement lean policy:

1. **EnableIAMUserPermissions** — grants `kms:*` to the AWS account root (required by AWS for key management recovery).
2. **AllowServiceAccess** — grants `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey`, `kms:CreateGrant` to all declared service principals.
