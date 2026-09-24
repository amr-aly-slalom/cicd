# Phase 0 Research: IAM Identity Centre Redshift Integration

**Date**: 2026-06-30 | **Feature**: `specs/002-iam-ic-redshift-ci`

All NEEDS CLARIFICATION items from the Technical Context in `plan.md` are resolved below.

---

## R-001: Federation Mechanism — OIDC vs SAML

**Decision**: SAML (not OIDC) is the correct federation mechanism for IAM Identity Centre → IAM role assumption.

**Rationale**: AWS IAM Identity Centre automatically creates a SAML identity provider (`AWSSSO_<id>_DO_NOT_DELETE`) in every AWS account enrolled in the organisation. This provider is what IAM role trust policies must reference for federated role assumption. An `aws_iam_openid_connect_provider` Terraform resource is NOT needed and would be architecturally incorrect for this integration path.

**Verified in dev/test account (`381491832813`)**: SAML provider already exists:
`arn:aws:iam::381491832813:saml-provider/AWSSSO_6fc196b1318fdeb5_DO_NOT_DELETE`
Created: 2024-02-12. The provider is auto-managed by IdC and must NOT be created, modified, or deleted by this Terraform project.

**Impact on spec**: *(Superseded by R-008 and Q8 clarification.)* FR-001 is corrected — instead of creating `aws_iam_openid_connect_provider`, the finding confirmed that SAML trust is used. However, this project does NOT consume the SAML provider ARN at all (`saml_provider_arn` variable was removed); user-facing role trust policies are managed by IdC internally. The SAML provider information here is background context only.

**Alternatives considered**:
- `aws_iam_openid_connect_provider` (OIDC): Incorrect for IdC SAML-based IAM role federation. OIDC applies only when using IdC as an application OIDC provider (e.g., for custom web apps), not for IAM role assumption from the console or CLI.

---

## R-002: `aws_redshift_idc_application` Resource Schema

**Decision**: Use `aws_redshift_idc_application` with `service_integration.redshift.connect.authorization = "Enabled"`. No cluster identifier argument exists — the resource operates at the account/region level and enables Trusted Identity Propagation for all Redshift clusters in the account.

**Required arguments** (from Terraform AWS Provider v6.x docs):
| Argument | Type | Notes |
|----------|------|-------|
| `iam_role_arn` | Required | The IdC integration service role (`aws_iam_role.redshift_idc_svc`) |
| `idc_display_name` | Required | Human-readable name shown in IdC console |
| `idc_instance_arn` | Required | The organisation's central IdC instance ARN (variable input) |
| `redshift_idc_application_name` | Required | Name of the Redshift application in IdC |

**Optional but needed**:
```hcl
service_integration {
  redshift {
    connect {
      authorization = "Enabled"
    }
  }
}
```
Enables the Redshift connect integration scope for Trusted Identity Propagation.

**Optional `identity_namespace`**: A namespace string that namespaces the IdC application. Omitted — the AWS default value is used. Per-environment uniqueness is already enforced by `redshift_idc_application_name = "chedaws-edp-${local.environment}"`, making an explicit namespace unnecessary.

**Exported attributes**: `idc_managed_application_arn`, `redshift_idc_application_arn`

**Key architectural insight**: Because `aws_redshift_idc_application` has no `cluster_identifier`, it is NOT cluster-specific. It registers the Redshift service in the account with IdC. All clusters in the account benefit from Trusted Identity Propagation once registered. One resource per workspace apply is correct and sufficient.

**Alternatives considered**:
- Creating one application per cluster: Not how the resource works; the resource is account/region-scoped.

---

## R-003: IAM Role Association — Separate Resource vs Inline

> **Superseded by Q8 clarification**: `aws_redshift_cluster_iam_roles` and `cluster_iam_role_arns` are out of scope. `GetClusterCredentialsWithIAM` does NOT require cluster IAM role association — the IAM principal needs only the correct permission in their IdC permission set policy (identity team responsibility). The research below is retained for reference only.

**Decision**: Use `aws_redshift_cluster_iam_roles` (dedicated resource) rather than inline `iam_roles` on `aws_redshift_cluster`, to avoid state conflicts and enable in-place role updates without cluster downtime or recreation.

**Rationale**: The Terraform AWS provider documentation explicitly recommends this pattern when managing IAM role associations separately from the cluster lifecycle. The provider's note warns against configuring `default_iam_role_arn` in both resources simultaneously.

**Verified**: The dev cluster `chedaws-edp-dev` currently has `"IamRoles": []` (confirmed via `aws redshift describe-clusters` with `non-prod` profile on 2026-06-30). No import is needed. Adding roles via `aws_redshift_cluster_iam_roles` is an in-place update with no cluster recreation.

**Max IAM roles**: Up to 10 per cluster. This feature adds 2; 8 slots remain for future integrations.

**Alternatives considered**:
- Inline `iam_roles` on `aws_redshift_cluster.this`: Would work but creates a conflict surface if the cluster's IAM associations ever need independent lifecycle management. The dedicated resource also supports `default_iam_role_arn`.

---

## R-004: IAM Role Trust Policy for `GetClusterCredentialsWithIAM` Path

> **Superseded by R-008 and Q8 clarification**: User-facing IAM roles and their trust policies are managed by the identity team via IdC permission sets. This project does not create trust policies for user-facing roles. Retained for reference only.

**Decision**: `sts:AssumeRoleWithSAML` + `sts:TagSession` with the IdC-managed SAML provider as the federated principal.

**Trust policy structure**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "<var.saml_provider_arn>"
      },
      "Action": [
        "sts:AssumeRoleWithSAML",
        "sts:TagSession"
      ],
      "Condition": {
        "StringEquals": {
          "SAML:aud": "https://signin.aws.amazon.com/saml"
        }
      }
    }
  ]
}
```

**Why `sts:TagSession`**: Enables session-level identity propagation, including the `sqlworkbench-team` tag used by Redshift Query Editor v2 for team-based sharing. Also required for Trusted Identity Propagation's token propagation mechanisms.

**Why `SAML:aud` condition**: Restricts role assumption to the AWS sign-in endpoint only, preventing misuse from other SAML service providers that may reference the same IdC SAML provider.

**Max session duration**: Set to `3600` (1 hour) on both user-facing roles to enforce the SC-003 revocation TTL ceiling.

**Alternatives considered**:
- `sts:AssumeRoleWithWebIdentity` (OIDC): Incorrect. IdC uses SAML for IAM role assumption from the portal, CLI (`aws sso login`), and SDK credential provider.

---

## R-005: IAM Service Role Permissions for `aws_redshift_idc_application`

**Decision**: Custom inline policy with minimum SSO describe actions and scoped Redshift describe. Trust: `redshift.amazonaws.com`.

**Trust policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "redshift.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

**Inline permission policy**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSODescribe",
      "Effect": "Allow",
      "Action": [
        "sso:DescribeRegisteredRegions",
        "sso:GetApplicationAuthenticationMethod",
        "sso:GetApplicationGrant"
      ],
      "Resource": "*"
    },
    {
      "Sid": "RedshiftDescribe",
      "Effect": "Allow",
      "Action": "redshift:DescribeClusters",
      "Resource": "arn:aws:redshift:<region>:<account>:cluster:chedaws-edp-<env>"
    }
  ]
}
```

**Alternatives considered**:
- AWS managed policy `AmazonRedshiftFullAccess`: Far too permissive; violates constitution principle I.
- `AmazonRedshiftServiceLinkedRolePolicy`: This policy is for the Redshift service-linked role, not for the IdC application service role; different use case.

---

## R-006: Existing Account Resources Inventory

| Resource | dev/test (`381491832813`) | uat (`339712719726`) | prod (`637423180765`) |
|----------|--------------------------|---------------------|----------------------|
| IdC SAML provider | `arn:aws:iam::381491832813:saml-provider/AWSSSO_6fc196b1318fdeb5_DO_NOT_DELETE` (verified) | Assumed to exist; ARN provided via `saml_provider_arn` variable | Assumed to exist; ARN provided via `saml_provider_arn` variable |
| Redshift cluster | `chedaws-edp-dev` — available, `rg.xlarge`, `IamRoles: []` (verified) | Not queried (profile not available) | Not queried (profile not available) |
| Existing Redshift IAM roles | `chedaws-ndp-dev-redshift-dms-endpoint-role`, `chedaws-ndp-test-redshift-dms-endpoint-role`, `redshift-glue-lf-access` | Not queried | Not queried |
| OIDC providers | None (verified) | Not queried | Not queried |

**IdC instance** (verified across all environments):
- ARN: `arn:aws:sso:::instance/ssoins-82599788fabf9a65`
- Owner account: `211125762431` (dedicated IdC/management account)
- Status: `ACTIVE`
- Identity Store ID: `d-976740cf30`
- Created: 2024-02-12

**Note**: Only the dev/test account was actively queried using the `non-prod` AWS profile per planning instructions. UAT and prod assumptions are based on standard AWS Organizations IdC enrollment behaviour (SAML provider auto-created in all enrolled accounts).

---

## R-007: User-Facing IAM Role Permission Policies

> **Superseded by R-008**: User-facing IAM roles are managed by the identity team via IdC permission sets; this project does not create or manage permission policies on those roles. Retained for reference only.

**Decision**: Scope `redshift:GetClusterCredentialsWithIAM` and `redshift:DescribeClusters` to the specific cluster ARN. Include `redshift:JoinGroup` scoped to the role's corresponding database group.

**Read-only role policy**:
```json
{
  "Statement": [
    {
      "Sid": "GetCredentials",
      "Effect": "Allow",
      "Action": ["redshift:GetClusterCredentialsWithIAM", "redshift:DescribeClusters"],
      "Resource": "arn:aws:redshift:ap-southeast-2:<account_id>:cluster:chedaws-edp-<env>"
    },
    {
      "Sid": "JoinGroup",
      "Effect": "Allow",
      "Action": "redshift:JoinGroup",
      "Resource": "arn:aws:redshift:ap-southeast-2:<account_id>:dbgroup:chedaws-edp-<env>/readonly_group"
    }
  ]
}
```

**Read-write role policy**: Identical structure, with `dbgroup` scoped to `readwrite_group`.

**Implementation note**: `<account_id>` is sourced from `data.aws_caller_identity.current.account_id` (already declared in `data.tf`). `<env>` is `local.environment`.

---

---

## R-008: User-Facing IAM Role Ownership — IdC Permission Sets vs Terraform-Managed

**Decision**: User-facing IAM roles for Redshift authentication MUST be created and managed by IAM Identity Centre via **permission sets** and **account assignments** — NOT by this Terraform project. R-004 and R-007 are superseded for the purposes of this project's scope.

**Rationale**: When an IdC permission set is assigned to an account, AWS creates an IAM role in that account named `AWSReservedSSO_<PermissionSetName>_<hash>`. This role inherits the permission set's inline and managed policies and has a SAML trust policy automatically configured by IdC. Creating a parallel set of custom IAM roles (with manually managed SAML trust) is redundant, creates an extra layer of role assumption, and diverges from the AWS-recommended pattern for IdC-integrated applications. The identity team owns permission sets and account assignments; they are responsible for configuring the correct Redshift permissions in those sets.

**Impact on scope** *(updated to reflect Q8 clarification)*:
- This Terraform project MUST NOT create `aws_iam_role.redshift_readonly`, `aws_iam_role.redshift_readwrite`, their inline policies, or reference `saml_provider_arn`.
- The `saml_provider_arn` variable is REMOVED from this project.
- The `cluster_iam_role_arns` variable and `aws_redshift_cluster_iam_roles` resource are also REMOVED (Q8): cluster IAM role association is a data-plane mechanism unrelated to federated user authentication; `GetClusterCredentialsWithIAM` requires only `redshift:GetClusterCredentialsWithIAM` in the IAM principal's permission set policy.
- The project retains only the Trusted Identity Propagation path: `aws_iam_role.redshift_idc_svc` + `aws_redshift_idc_application.this`.

**Alternatives considered**:
- Continue creating custom SAML-trust roles (original R-004 approach): Rejected — diverges from IdC best practice; creates role-within-role complexity; identity team must manage both permission sets AND custom role mappings.
- Manage permission sets via `aws_ssoadmin_permission_set` Terraform resources: Rejected — FR-009 explicitly prohibits this project from managing IdC permission sets; permission set ownership belongs to the centralised identity team.

---

## Summary: Resolved Unknowns

| Item | Status | Decision |
|------|--------|----------|
| OIDC vs SAML for IdC federation | Resolved | SAML; existing provider; no Terraform resource needed |
| `aws_redshift_idc_application` schema | Resolved | 4 required args + `service_integration` block; no cluster linkage |
| IAM role association method | Superseded (Q8) | `aws_redshift_cluster_iam_roles` not needed; `GetClusterCredentialsWithIAM` requires only permission set policy |
| Trust policy for user roles | Superseded by R-008 | IdC permission sets manage this |
| Service role permissions | Resolved | 3 SSO describe + scoped `redshift:DescribeClusters` |
| User-facing role ownership | Resolved (R-008 + Q8) | IdC permission sets; no `cluster_iam_role_arns` variable |
| Dev cluster current state | Resolved | Available, `rg.xlarge`, no existing IAM roles |
| IdC instance ARN | Resolved | `arn:aws:sso:::instance/ssoins-82599788fabf9a65` |
| SAML provider ARN (dev/test) | Resolved (background context) | `arn:aws:iam::381491832813:saml-provider/AWSSSO_6fc196b1318fdeb5_DO_NOT_DELETE` |
