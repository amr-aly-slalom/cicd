# Feature Specification: IAM Identity Centre Redshift Integration

**Feature Branch**: `feat/iam-ic-redshift-ci`

**Created**: 2026-06-30

**Status**: Complete

**Input**: User description: "integrate IAM identity centre with the redshift cluster. Prepare terraform configuration for CI to deploy in each environment."

## Clarifications

### Session 2026-06-30

- Q: Should `identity_namespace` be explicitly set on `aws_redshift_idc_application`? → A: No — the default AWS value is used; `identity_namespace` is omitted from the resource. The collision risk across workspaces sharing account `381491832813` is acceptable because `redshift_idc_application_name` already includes the environment suffix, making each application uniquely named within the account.
- Q: Are CI and engineer IAM roles (including `chedaws-edp-ci-runner`) in scope for this feature? → A: No — these roles are pre-existing infrastructure and must not be created or modified by this feature.
- Q: Which IAM Identity Centre → Redshift integration pattern should this feature implement? → A: Both — `GetClusterCredentialsWithIAM` (for SQL client compatibility via IAM roles) and Trusted Identity Propagation (for Query Editor v2 and native IdC clients via `aws_redshift_idc_application`) must both be enabled and configured. *(Note: Q9 subsequently determined that `GetClusterCredentialsWithIAM` does not require any Terraform infrastructure from this project — no cluster IAM role association is needed. This project delivers only Trusted Identity Propagation via `aws_redshift_idc_application`.)*
- Q: What is the IdC deployment model across the three AWS accounts? → A: A single IdC instance exists in a dedicated AWS Organizations account; the same `idc_instance_arn` value is used for all environments. This feature integrates the existing Redshift clusters with that pre-existing IdC instance.
- Q: Are CI pipeline and PR-related requirements in scope for this feature? → A: No — CI pipeline, GitHub Actions workflows, and PR gate configuration are entirely out of scope. This feature covers only the IAM Identity Centre integration with the existing Redshift cluster.
- Q: Should IAM, OIDC, and IdC application resources be defined inline in `redshift.tf` or in a new file; and should `for_each` iterate over environments? → A: Inline in `redshift.tf`, consistent with spec 001 co-location convention. No `for_each` over environments — per-environment deployment is managed by Terraform workspaces, so each resource is defined once and the active workspace drives the environment.
- Q: Is OIDC or SAML the correct federation mechanism for IAM Identity Centre in this topology? → A: *(Superseded by Q8 and R-008.)* SAML is the correct mechanism — IdC auto-creates a SAML provider in each enrolled account. However, Q8 subsequently determined that this project does not need to consume the SAML provider ARN at all, because user-facing IAM roles are owned entirely by IdC permission sets. The `saml_provider_arn` variable was removed from this project's scope.
- Q: Should user-facing IAM roles for Redshift authentication be created by this Terraform project, or by IAM Identity Centre permission sets and account assignments? → A: User-facing IAM roles MUST be created and managed by IAM Identity Centre via permission sets and account assignments, NOT by this Terraform project. IdC creates `AWSReservedSSO_*` roles in each enrolled account when a permission set is assigned. The `saml_provider_arn` and `cluster_iam_role_arns` variables are removed from this project’s scope (see also Q9). Research finding R-008 documents the full rationale.- Q: Is `aws_redshift_cluster_iam_roles` required to support `GetClusterCredentialsWithIAM` or native IdP federation? → A: No. Neither integration path (Trusted Identity Propagation nor `GetClusterCredentialsWithIAM`) requires associating IAM roles with the cluster via `aws_redshift_cluster_iam_roles`. Cluster IAM role association is a data-plane mechanism for COPY/UNLOAD/Spectrum operations, not for user authentication. For `GetClusterCredentialsWithIAM`, the IAM principal only needs `redshift:GetClusterCredentialsWithIAM` permission in their policy — this is granted by the identity team via the IdC permission set, entirely outside this project's scope. The `cluster_iam_role_arns` variable and `aws_redshift_cluster_iam_roles` resource are removed from this feature. This project's Terraform delivers only Trusted Identity Propagation via `aws_redshift_idc_application` and its service role.
## User Scenarios & Testing *(mandatory)*

### User Story 1 - Federated Login to Redshift via Corporate SSO (Priority: P1)

A data analyst or data engineer authenticates to the Redshift cluster using their corporate identity (managed in AWS IAM Identity Centre) instead of a shared database password. They are granted access by being assigned to an IAM Identity Centre group, and their Redshift permissions are determined by the group they belong to.

**Why this priority**: This is the primary security improvement. Without this, users rely on shared credentials, which cannot be individually revoked and create audit gaps.

**Independent Test**: Assign a test user to the "Redshift Read-Only" IdC group in the `dev` environment. Verify the user can connect to `chedaws-edp-dev` using temporary IAM credentials obtained via IdC, without a database password, and can execute `SELECT` queries. Verify they cannot execute `INSERT` or `DROP` statements.

**Acceptance Scenarios**:

> **Note**: Group names below ("Redshift Read-Only", "Redshift Read-Write") are illustrative. Actual IdC group names and permission sets are configured and provisioned by the identity team (FR-009 — out of scope for this project).

1. **Given** a user is assigned to the "Redshift Read-Only" IdC group, **When** the user requests temporary credentials via IdC and connects to the Redshift cluster, **Then** the connection is accepted and the user has read-only access to the assigned schemas.
2. **Given** a user is assigned to the "Redshift Read-Write" IdC group, **When** the user connects using IdC credentials, **Then** the user can execute both `SELECT` and `INSERT`/`UPDATE`/`DELETE` statements on permitted schemas.
3. **Given** a user is removed from all Redshift IdC groups, **When** the user attempts to connect to the cluster, **Then** the connection is denied and no active sessions persist beyond the credential TTL.
4. **Given** the same IdC group exists across all environments, **When** a user is assigned to the `dev` group, **Then** they can only access the `dev` cluster and not the `uat` or `prod` clusters.
5. **Given** a user is assigned to the "Redshift Read-Only" IdC group, **When** the user opens Redshift Query Editor v2 and authenticates via IdC native SSO, **Then** the connection succeeds using Trusted Identity Propagation without requiring JDBC configuration or credential plugin setup.

---

### User Story 2 - Access Revocation and Audit Trail (Priority: P2)

A security administrator revokes a user's Redshift access by removing them from the relevant IdC group. The revocation takes effect within a defined time window. All Redshift connection attempts — successful and failed — are recorded in CloudWatch Logs.

**Why this priority**: Timely access revocation and auditability are requirements for data platform security and regulatory compliance.

**Independent Test**: Remove a test user from the Redshift IdC group. Wait for the maximum credential TTL. Attempt to connect with previously valid credentials. Verify the connection is denied. Verify the denied attempt appears in the Redshift connection log in CloudWatch.

**Acceptance Scenarios**:

1. **Given** a user's IdC group assignment is revoked, **When** their existing temporary credentials expire (at most 1 hour after the TTL), **Then** any new connection attempt is denied.
2. **Given** a Redshift connection is attempted (success or failure), **When** the CloudWatch Logs for the cluster are queried, **Then** a log entry for the connection attempt exists, including the IAM principal used.

---

### Edge Cases

- What happens when a user belongs to both "Read-Only" and "Read-Write" IdC groups? The most permissive role applies; effective permissions are the union of both roles.
- What happens if the IdC instance is in a different AWS account than the Redshift cluster? The IdC instance IS in a separate dedicated AWS Organizations account — this is the confirmed topology. Cross-account federation is handled internally by IAM Identity Centre; no SAML provider ARN or OIDC provider resource is created by this project. This project uses only `idc_instance_arn` (for the `aws_redshift_idc_application`). No cluster IAM role association is needed for either Trusted Identity Propagation or `GetClusterCredentialsWithIAM`.

## Requirements *(mandatory)*

### Functional Requirements

**IAM Identity Centre Integration**

- **FR-001**: This Terraform project MUST NOT create IAM roles that federated users assume directly. User-facing IAM roles for Redshift access are created and managed by IAM Identity Centre via permission sets and account assignments; the resulting `AWSReservedSSO_*` roles are owned by the identity team and are out of scope for this project.
- **FR-002**: *(Removed — `aws_redshift_cluster_iam_roles` is a data-plane mechanism for COPY/UNLOAD/Spectrum operations and is NOT required for either Trusted Identity Propagation or `GetClusterCredentialsWithIAM`. The `cluster_iam_role_arns` variable and `aws_redshift_cluster_iam_roles` resource are out of scope. `GetClusterCredentialsWithIAM` requires only `redshift:GetClusterCredentialsWithIAM` permission in the IAM principal's policy, which is granted by the identity team via IdC permission sets. See Q8 clarification.)*
- **FR-003**: *(Removed — SAML trust policies on user-facing roles are managed by IAM Identity Centre internally; this project does not create or modify them. See R-008.)*
- **FR-004**: *(Removed — `GetClusterCredentialsWithIAM` permission policies on user-facing roles are configured in IdC permission sets by the identity team; this project does not create or modify them. See R-008.)*
- **FR-005**: *(Merged into FR-002.)*
- **FR-006**: A dedicated IAM service role per environment MUST be created (`chedaws-edp-redshift-idc-svc-<env>`) to authorise the IdC application to interact with the Redshift cluster, carrying the minimum permissions required for the integration (`redshift:DescribeClusters` and related IdC token exchange actions).
- **FR-007**: An IAM Identity Centre application (`aws_redshift_idc_application`) MUST be provisioned per environment, registering the Redshift cluster with the IdC instance to enable Trusted Identity Propagation for Query Editor v2 and native IdC-aware clients. The IdC instance ARN MUST be provided as a Terraform variable input (`idc_instance_arn`).
- **FR-008**: *(Removed — Redshift database group provisioning (`readonly_group`, `readwrite_group`) and SQL grants are managed outside Terraform by the database administration team and are out of scope. See Assumptions.)*
- **FR-009**: Terraform MUST NOT provision IAM Identity Centre permission sets, account assignments, or group assignments directly; IdC group and permission management is the responsibility of the identity team and is out of scope.
- **FR-010**: All IAM roles created by this feature MUST include a `Description` field explaining their purpose, per constitution principle I.

### Key Entities

- **IAM Identity Centre Instance**: The centrally managed IdC instance; expected to pre-exist, shared across all environments, and provided as a Terraform variable input (`idc_instance_arn`) rather than created by this feature.
- **IdC Permission Set Role** (`AWSReservedSSO_*`): An IAM role automatically created in each enrolled AWS account by IAM Identity Centre when a permission set is assigned to that account. Owned and managed by the identity team; NOT created by this project. The role must carry `redshift:GetClusterCredentialsWithIAM` permission in the IdC permission set policy (identity team's responsibility); no cluster association via this project is required.
- **IdC Integration Service Role** (`chedaws-edp-redshift-idc-svc-<env>`): An IAM role created by this project, used exclusively by the `aws_redshift_idc_application` resource to interact with the Redshift cluster. This is a machine role, not a user-facing role.
- **IdC Application** (`aws_redshift_idc_application`): Registers the Redshift cluster with IAM Identity Centre per environment, enabling Trusted Identity Propagation for Query Editor v2 and native IdC-aware clients.
- **Terraform Workspace**: The per-environment workspace (`dev`, `test`, `uat`, `prod`) that isolates state and drives environment-specific variable resolution.
- **Redshift Database Group**: A Redshift-side user group (`readonly_group`, `readwrite_group`) that enforces schema-level permissions. Provisioned by the database administration team outside Terraform; out of scope for this project.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user federated via IAM Identity Centre can establish a connection to the Redshift cluster within 60 seconds of being granted group membership, with no manual database user provisioning required. *(Enforcement: this depends on IdC group assignment propagation latency and the identity team's provisioning process; not directly enforced or measurable by this project's Terraform.)*
- **SC-002**: Zero static AWS credentials exist in the Terraform source files or repository at any time.
- **SC-003**: After a user's IdC group membership is revoked, all subsequent Redshift connection attempts using that identity are denied within 60 minutes. *(Enforcement: this is governed by the `session_duration` setting on the IdC permission set, configured by the identity team. This project does not create or enforce this setting; it is an operational outcome, not a Terraform-enforceable criterion for this project.)*
- **SC-004**: Every Redshift connection attempt (successful and failed) is recorded in CloudWatch Logs and retrievable within 5 minutes of the event.

## Assumptions

- The AWS IAM Identity Centre instance is pre-existing, managed centrally in a dedicated AWS Organizations account, and shared across all environments. Its ARN is provided as a single Terraform variable input (`idc_instance_arn`) with the same value for all four workspaces; this feature consumes it and does not create or manage it.
- The IdC instance account and the three environment accounts (dev/test `381491832813`, uat `339712719726`, prod `637423180765`) are all members of the same AWS Organization, enabling cross-account federation via the SAML provider automatically created by IdC in each enrolled account.
- IAM Identity Centre permission sets and account/user/group assignments are created and managed by the identity team outside this Terraform project. The `AWSReservedSSO_*` roles produced by those assignments are NOT created by this project and are not referenced in this project's Terraform. The identity team is responsible for granting `redshift:GetClusterCredentialsWithIAM` in the permission-set policy.
- The CI platform is GitHub Actions; however, CI pipeline configuration and workflows are out of scope for this feature.
- The Terraform S3 backend (`chedaws-prod-terraform-state-file`) and state locking are already configured in `providers.tf`; no new backend infrastructure is created within this feature.
- The four environments span **three AWS accounts**: `dev` and `test` share account `381491832813`; `uat` uses account `339712719726`; `prod` uses account `637423180765`.
- The existing Redshift cluster (from `specs/001-redshift-cluster`) is in place in each environment; this feature extends it with the IdC application and its service role rather than re-provisioning it.
- All IAM and IdC application resources introduced by this feature are defined inline in `redshift.tf`, co-located with the existing Redshift resources per the spec 001 convention. No separate `iam.tf` file is created.
- Per-environment resource creation is achieved by selecting the appropriate Terraform workspace (`dev`, `test`, `uat`, `prod`) before running `terraform apply`. No `for_each` over environments is used; each resource is defined once and `local.environment` (derived from `terraform.workspace`) drives naming and environment-specific values.
- Cost allocation tags consistent with the existing provider `default_tags` block will be applied to all new resources provisioned by this feature.
- The IdC permission set roles created by the identity team (`AWSReservedSSO_*`) are mapped to Redshift database groups by the database administration team via SQL grants. Schema-level grants (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) are managed as Redshift SQL outside Terraform and are outside the scope of this project.
