# Output Contracts: IAM Identity Centre Redshift Integration

**Feature**: `specs/002-iam-ic-redshift-ci` | **Date**: 2026-06-30

This document defines the Terraform output contracts introduced by this feature. All outputs are defined in `terraform/outputs.tf` and appended to the existing outputs from `specs/001-redshift-cluster`.

---

## New Outputs

> **Note (R-008)**: `redshift_readonly_role_arn` and `redshift_readwrite_role_arn` are removed from this project's outputs. User-facing IAM roles are created and managed by the identity team via IdC permission sets; their ARNs are retrieved directly from IAM or the IdC console by the identity team.

### `redshift_idc_svc_role_arn`

| Property | Value |
|----------|-------|
| **Source** | `aws_iam_role.redshift_idc_svc.arn` |
| **Type** | `string` |
| **Sensitive** | No |
| **Format** | `arn:aws:iam::<account_id>:role/chedaws-edp-redshift-idc-svc-<env>` |
| **Description** | ARN of the service role assumed by `redshift.amazonaws.com` for Trusted Identity Propagation. This role is referenced internally by the `aws_redshift_idc_application` resource and surfaced here for audit and troubleshooting purposes. |

**Example (dev)**:
```
arn:aws:iam::381491832813:role/chedaws-edp-redshift-idc-svc-dev
```

---

### `redshift_idc_application_arn`

| Property | Value |
|----------|-------|
| **Source** | `aws_redshift_idc_application.this.redshift_idc_application_arn` |
| **Type** | `string` |
| **Sensitive** | No |
| **Format** | `arn:aws:redshift:ap-southeast-2:<account_id>:idc-application:<application_id>` |
| **Description** | ARN of the registered Redshift IdC application for Trusted Identity Propagation. Used to confirm the application was registered successfully and to identify it in IAM Access Analyser findings or IdC audit logs. |

**Example (dev)**:
```
arn:aws:redshift:ap-southeast-2:381491832813:idc-application/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

---

## Existing Outputs (Unchanged)

The following outputs from `specs/001-redshift-cluster` are unchanged and documented here for reference:

| Output | Description |
|--------|-------------|
| `aws_account_id` | AWS account ID of the current workspace |
| `redshift_cluster_identifier` | Identifier of the Redshift cluster |
| `redshift_cluster_endpoint` | DNS endpoint of the Redshift cluster |
| `redshift_cluster_port` | Port of the Redshift cluster |

---

## Consumer Responsibilities

Consumers of these outputs must:

1. **`redshift_idc_svc_role_arn`**: Surfaced for audit and troubleshooting purposes. This role is already referenced internally by `aws_redshift_idc_application`; no action required by consumers unless diagnosing Trusted Identity Propagation failures.

2. **`redshift_idc_application_arn`**: Use this ARN to verify successful application registration in the AWS Console under IAM Identity Centre → Applications. Required for SC-002 acceptance test.
