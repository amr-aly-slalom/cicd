# Data Model: IAM Identity Centre Redshift Integration

**Feature**: `specs/002-iam-ic-redshift-ci` | **Date**: 2026-06-30

All resources are defined inline in `terraform/redshift.tf`. Per-environment values come from `local.environment` (Terraform workspace). References to `<env>` below mean `${local.environment}`.

---

## New Terraform Resources

> **Note (R-008)**: User-facing IAM roles (`redshift_readonly`, `redshift_readwrite`) are created and managed by IAM Identity Centre via permission sets and account assignments. The resulting `AWSReservedSSO_*` roles are NOT created by this project and are not referenced here. Cluster IAM role association (`aws_redshift_cluster_iam_roles`) is out of scope (Q8 clarification — it is a data-plane mechanism unrelated to federated authentication).

### 1. `aws_iam_role.redshift_idc_svc`

| Attribute | Value |
|-----------|-------|
| `name` | `"chedaws-edp-redshift-idc-svc-${local.environment}"` |
| `description` | `"Service role for the chedaws-edp-${local.environment} Redshift IdC application; assumed by redshift.amazonaws.com for Trusted Identity Propagation"` |
| Trust Principal | `{"Service": "redshift.amazonaws.com"}` |
| Trust Action | `sts:AssumeRole` |

### 2. `aws_iam_role_policy.redshift_idc_svc` (inline policy on `redshift_idc_svc`)

| Sid | Actions | Resource |
|-----|---------|----------|
| `SSODescribe` | `sso:DescribeRegisteredRegions`, `sso:GetApplicationAuthenticationMethod`, `sso:GetApplicationGrant` | `*` |
| `RedshiftDescribe` | `redshift:DescribeClusters` | `arn:aws:redshift:${region}:${account_id}:cluster:chedaws-edp-${env}` |

---

### 3. `aws_redshift_idc_application.this`

| Attribute | Value |
|-----------|-------|
| `idc_instance_arn` | `var.idc_instance_arn` |
| `idc_display_name` | `"chedaws-edp-${local.environment}"` |
| `redshift_idc_application_name` | `"chedaws-edp-${local.environment}"` |
| `iam_role_arn` | `aws_iam_role.redshift_idc_svc.arn` |
| `service_integration.redshift.connect.authorization` | `"Enabled"` |

**Scope**: Account/region-level. Enables Trusted Identity Propagation for all Redshift clusters in the account. One resource per workspace apply.

**Exported attributes used in outputs**: `redshift_idc_application_arn`

---

## New Variables

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `idc_instance_arn` | `string` | `"arn:aws:sso:::instance/ssoins-82599788fabf9a65"` | ARN of the organisation's central IdC instance. Same value for all workspaces: `arn:aws:sso:::instance/ssoins-82599788fabf9a65` |

---

## New Outputs

| Output Name | Source | Description |
|-------------|--------|-------------|
| `redshift_idc_svc_role_arn` | `aws_iam_role.redshift_idc_svc.arn` | ARN of the IdC application service role |
| `redshift_idc_application_arn` | `aws_redshift_idc_application.this.redshift_idc_application_arn` | ARN of the registered Redshift IdC application |

---

## Resource Dependency Graph

```
var.idc_instance_arn ───────────────────────────────────────────────┐
                                                                     ▼
                                       aws_redshift_idc_application.this
                                                  ▲
                                                  │ iam_role_arn
                                             aws_iam_role.redshift_idc_svc
                                                  ▲
                                                  │ inline policy
                                      aws_iam_role_policy.redshift_idc_svc

Identity team (out-of-scope):
  IdC permission sets → AWSReservedSSO_* roles → `redshift:GetClusterCredentialsWithIAM` in policy
```

---

## Existing Resources Referenced (No Changes)

| Resource | Address | Notes |
|----------|---------|-------|
| Redshift cluster | `aws_redshift_cluster.this` | Existing; not modified by this feature |
| AWS caller identity | `data.aws_caller_identity.current` | Already in `data.tf`; used for cluster ARN construction in inline policies |
| AWS region | `data.aws_region.current` | Already in `data.tf`; used for cluster ARN construction |
| KMS keys | `module.kms[*]` | Existing; not modified by this feature |
