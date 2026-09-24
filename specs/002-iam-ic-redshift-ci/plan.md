# Implementation Plan: IAM Identity Centre Redshift Integration

**Branch**: `feat/iam-ic-redshift-ci` | **Date**: 2026-06-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/002-iam-ic-redshift-ci/spec.md`

## Summary

Extend the existing Redshift clusters (provisioned in `specs/001-redshift-cluster`) to support IAM Identity Centre federated authentication via two paths, all defined inline in `terraform/redshift.tf` using workspace-driven per-environment deployment:

1. **Trusted Identity Propagation** — A regional `aws_redshift_idc_application` registers Redshift with the organisation’s IdC instance (`arn:aws:sso:::instance/ssoins-82599788fabf9a65`), enabling Query Editor v2 and native IdC clients to authenticate directly via IdC SSO.

2. **`GetClusterCredentialsWithIAM`** — *(Out of scope for this project.)* The IAM principal needs only `redshift:GetClusterCredentialsWithIAM` in their permission set policy, which is configured by the identity team via IdC. No cluster IAM role association (`aws_redshift_cluster_iam_roles`) is required or created by this project. See Q8 clarification and R-008.

This project creates **only** the machine-facing IdC service role and the IdC application resource. User-facing IAM roles are owned by the identity team (R-008).

## Technical Context

**Language/Version**: Terraform >= 1.5.0, HCL

**Primary Dependencies**: AWS Provider `~> 6.0` (`hashicorp/aws`); Random Provider `~> 3.0` — both already in `providers.tf`

**Storage**: S3 backend `chedaws-prod-terraform-state-file` (ap-southeast-2) + DynamoDB state lock — existing, unchanged

**Testing**: Manual `terraform plan` / `terraform apply` per workspace; AWS CLI and console validation (IAM role listing, Redshift IAM role association check, credential exchange test)

**Target Platform**: AWS ap-southeast-2 (Australia Sydney); three accounts — dev/test `381491832813`, uat `339712719726`, prod `637423180765`

**Project Type**: IaC extension — adds an IAM service role and an IdC application resource to the existing Redshift configuration

**Performance Goals**: User connection within 60 seconds of IdC group assignment (SC-001); access revocation effective within 60 minutes (SC-003)

**Constraints**:
- All new resources inline in `redshift.tf` (spec 001 co-location convention, Q5 clarification)
- No `for_each` over environments; Terraform workspace selection drives per-environment deployment (Q5 clarification)
- No new Terraform module — single call site; constitution VI prohibits single-use modules
- Existing `aws_redshift_cluster.this` must NOT be replaced (Q8: cluster IAM role association is out of scope — `aws_redshift_cluster_iam_roles` is NOT created by this project)
- User-facing IAM roles MUST NOT be created by this project; they are managed by the identity team via IdC permission sets (R-008)
- No `saml_provider_arn` variable — SAML trust is handled internally by IdC for permission set roles (R-008)

**Scale/Scope**: 2 new IAM resources (1 service role + 1 inline policy) + 1 `aws_redshift_idc_application`; 1 new variable (`idc_instance_arn`); 2 new outputs

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

### Pre-Design Check

- [x] **Security**: The service role carries only the minimum SSO describe + `redshift:DescribeClusters` permissions scoped to the cluster ARN. Trusted by `redshift.amazonaws.com` only. All roles include `Description` (constitution I). No credentials, account IDs, or secrets hardcoded; `idc_instance_arn` is the sole variable input. User-facing roles are owned by the identity team via IdC permission sets — no SAML trust policy is created or managed by this project (R-008).
- [x] **Observability**: No new compute resources introduced. The existing CloudWatch audit log configuration from spec 001 (`connectionlog`, `userlog`, `useractivitylog`) already captures IAM principal information on every connection attempt, satisfying SC-004. No new log groups or alarms are needed for this feature.
- [x] **Durability**: Not applicable — IAM roles and IdC applications are global/regional AWS-managed services with built-in durability. No data store introduced.
- [x] **Fault-Tolerance**: Not applicable — IAM is a global AWS service with built-in high availability.
- [x] **Cost Optimisation**: IAM roles and IdC applications have no direct AWS cost. The provider's `default_tags` block applies automatically to all new taggable resources (constitution V).
- [x] **DRY & Modularity**: All resources inline in `redshift.tf`. No new module created — only one call site exists; constitution VI prohibits single-use modules. No edits to `terraform-legacy/`. Total distinct resource types added: IAM Role, IAM Role Policy, Redshift IDC Application — 3 types, well within the 5-type inline threshold.

### Post-Design Check (re-evaluated after Phase 1)

- [x] All constitution gates confirmed. No violations. No complexity tracking required.

## Project Structure

### Documentation (this feature)

```text
specs/002-iam-ic-redshift-ci/
├── plan.md           ← This file
├── research.md       ← Phase 0 output (all unknowns resolved)
├── data-model.md     ← Phase 1 output (Terraform resource schema)
├── quickstart.md     ← Phase 1 output (validation guide)
├── contracts/
│   └── outputs.md    ← Phase 1 output (new Terraform output contracts)
└── tasks.md          ← Phase 2 output (created by /speckit.tasks — NOT this command)
```

### Source Code (repository root)

```text
terraform/
├── redshift.tf     ← 3 new resources appended here (inline, co-located)
│                      aws_iam_role.redshift_idc_svc
│                      aws_iam_role_policy.redshift_idc_svc
│                      aws_redshift_idc_application.this
├── variables.tf    ← One new variable appended: idc_instance_arn
└── outputs.tf      ← Two new outputs appended: redshift_idc_svc_role_arn,
                       redshift_idc_application_arn
```

**Structure Decision**: Single-root Terraform project (existing pattern). New resources appended to `redshift.tf` per the spec 001 co-location convention for all resources exclusively serving the Redshift cluster. No new files created beyond documentation artifacts.

## Implementation Details

### New Variables (`variables.tf`)

| Variable | Type | Sensitive | Description |
|----------|------|-----------|-------------|
| `idc_instance_arn` | `string` | No | ARN of the central IdC instance; same value across all workspaces: `arn:aws:sso:::instance/ssoins-82599788fabf9a65` |

### IAM Role Trust Policy — IdC Service Role

```json
{
  "Principal": { "Service": "redshift.amazonaws.com" },
  "Action": "sts:AssumeRole"
}
```

### IAM Permission Policy — IdC Service Role

```hcl
{
  Sid: "SSODescribe"    → sso:DescribeRegisteredRegions,
                          sso:GetApplicationAuthenticationMethod,
                          sso:GetApplicationGrant
    Resource: *
  Sid: "RedshiftDescribe" → redshift:DescribeClusters
    Resource: arn:aws:redshift:${region}:${account_id}:cluster:chedaws-edp-${env}
}
```

### `aws_redshift_idc_application.this`

```hcl
resource "aws_redshift_idc_application" "this" {
  idc_instance_arn              = var.idc_instance_arn
  idc_display_name              = "chedaws-edp-${local.environment}"
  redshift_idc_application_name = "chedaws-edp-${local.environment}"
  iam_role_arn                  = aws_iam_role.redshift_idc_svc.arn

  service_integration {
    redshift {
      connect {
        authorization = "Enabled"
      }
    }
  }
}
```

`identity_namespace` is omitted; the AWS default is used. Per-environment uniqueness is already ensured by `redshift_idc_application_name = "chedaws-edp-${local.environment}"`.

## Spec Corrections Applied

R-001: Original FR-001 stated `aws_iam_openid_connect_provider` — corrected to SAML in the clarifications round.
R-008: FR-001 through FR-005 revised; FR-008 removed. User-facing IAM role creation moved out of scope; `saml_provider_arn` variable removed. All changes applied to `spec.md`.
Q8/R-008: `aws_redshift_cluster_iam_roles` resource and `cluster_iam_role_arns` variable removed from scope. `GetClusterCredentialsWithIAM` does NOT require cluster IAM role association; the IAM principal needs only the correct permission in their IdC permission set policy (identity team responsibility). Removed from all plan artifacts.
