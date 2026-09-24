# Quickstart Validation Guide: IAM Identity Centre Redshift Integration

**Feature**: `specs/002-iam-ic-redshift-ci` | **Date**: 2026-06-30

This guide covers the runnable validation scenarios that prove the feature works end-to-end. Run these checks after `terraform apply` completes for the target workspace.

For resource schema details, see [data-model.md](../data-model.md). For output contracts, see [contracts/outputs.md](../contracts/outputs.md).

---

## Prerequisites

- Terraform >= 1.5.0 installed
- AWS CLI v2 installed and configured
- The `non-prod` AWS CLI profile configured (for `dev` workspace) with permission to assume `chedaws-edp-ci-runner`
- You have applied the Terraform changes in the target workspace:
  ```powershell
  cd terraform
  terraform workspace select dev   # or test, uat, prod
  terraform init
  terraform apply -var="idc_instance_arn=arn:aws:sso:::instance/ssoins-82599788fabf9a65"
  ```

---

## ~~Scenario 1 — IdC-Provisioned Roles Associated with Cluster~~ (Superseded)

> **Superseded by Q8 clarification**: `aws_redshift_cluster_iam_roles` and `cluster_iam_role_arns` are removed from scope. Cluster IAM role association is a data-plane mechanism (COPY/UNLOAD/Spectrum) and is NOT required for federated user authentication via `GetClusterCredentialsWithIAM` or Trusted Identity Propagation. This scenario is no longer applicable.

---

## Scenario 2 — IdC Application Registered (Trusted Identity Propagation)

**Validates**: FR-006, FR-007

### Step 1: Confirm application ARN from Terraform

```bash
terraform output redshift_idc_application_arn
```

**Expected**: A non-empty string in the format `arn:aws:redshift:ap-southeast-2:<account_id>:idc-application/...`

### Step 2: Confirm via AWS CLI

```bash
aws redshift describe-redshift-idc-applications \
  --profile non-prod \
  --query "RedshiftIdcApplications[?RedshiftIdcApplicationName=='chedaws-edp-dev'].{Name:RedshiftIdcApplicationName,ARN:RedshiftIdcApplicationArn,Status:ServiceIntegrations}" \
  --output json
```

**Expected**: One entry returned with `RedshiftIdcApplicationName = "chedaws-edp-dev"` and `ServiceIntegrations` showing `Authorization: Enabled` under the Redshift connect block.

### Step 3: Confirm IdC service role

```bash
aws iam get-role \
  --role-name chedaws-edp-redshift-idc-svc-dev \
  --profile non-prod \
  --query "Role.{ARN:Arn,Description:Description}" \
  --output table
```

**Expected**: Role ARN printed, description mentions "Trusted Identity Propagation".

---

## Scenario 3 — GetClusterCredentialsWithIAM (SQL Client Connection via IdC Permission Set Role)

**Validates**: SC-001

> **Pre-condition**: Requires the identity team to have provisioned IdC permission sets with `redshift:GetClusterCredentialsWithIAM`, `redshift:DescribeClusters`, and `redshift:JoinGroup` permissions, assigned to a test user. This project does NOT create these permission sets (FR-001, FR-009). No `cluster_iam_role_arns` variable or `aws_redshift_cluster_iam_roles` resource is involved (Q8).

### Step 1: Sign in via IdC portal

Using your IdC portal, sign in and choose the permission set for the `dev` account (e.g., "Redshift Read-Only" or "Redshift Read-Write").

### Step 2: Exchange credentials for cluster credentials (AWS CLI)

```bash
aws redshift get-cluster-credentials-with-iam \
  --cluster-identifier chedaws-edp-dev \
  --db-name dev \
  --region ap-southeast-2 \
  --profile non-prod
```

**Expected**: Response includes `DbUser`, `DbPassword`, and `Expiration`. The `Expiration` should be ≤ 3600 seconds from the current time (confirming the max session duration ceiling from SC-003).

### Step 3: Connect with SQL client

Configure DBeaver, SQL Workbench/J, or the Redshift Query Editor with:
- **Authentication**: IAM
- **IAM profile**: The permission set federated profile (or use `--plugin-name com.amazon.redshift.plugin.BrowserSamlCredentialsProvider`)
- **Host**: Value from `terraform output redshift_cluster_endpoint`
- **Port**: Value from `terraform output redshift_cluster_port`
- **Database**: `dev`

**Expected**: Connection established; `SELECT current_user;` returns the user mapped to the assumed IAM role.

---

## Scenario 4 — Access Revocation (SC-003)

**Validates**: SC-003 (revocation effective within 60 minutes)

> This is an operational test performed by the identity team after provisioning.

### Procedure

1. Confirm a test user has an active session (Scenario 3 completed).
2. In the IdC console, remove the user from the group associated with the read-only or read-write permission set.
3. Wait up to 60 minutes (the `max_session_duration = 3600` ceiling).
4. Attempt a new `GetClusterCredentialsWithIAM` call or a new SQL client connection.

**Expected**: The credential exchange call fails with `AccessDenied` (the user no longer has the IdC group membership that maps to the role). Any existing session tokens expire after at most 3600 seconds from issuance.

---

## Scenario 5 — Audit Log Verification (SC-004)

**Validates**: SC-004 (IAM principal captured in connection logs)

### Step 1: Confirm CloudWatch log group exists (from spec 001)

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/redshift/cluster/chedaws-edp-dev \
  --profile non-prod \
  --query "logGroups[*].logGroupName" \
  --output table
```

**Expected**: Log groups for `connectionlog`, `userlog`, `useractivitylog` listed.

### Step 2: Query recent connection events

After completing Scenario 3:

```bash
aws logs filter-log-events \
  --log-group-name /aws/redshift/cluster/chedaws-edp-dev/connectionlog \
  --start-time $(date -d '-5 minutes' +%s000 2>/dev/null || date -v-5M +%s000) \
  --profile non-prod \
  --query "events[*].message" \
  --output text
```

**Expected**: Log entry contains the `AWSReservedSSO_*` role ARN (e.g., `arn:aws:iam::<account_id>:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_RedshiftReadOnly_<hash>`) as the authenticated principal, confirming SC-004.

---

## Validation Checklist

| Scenario | Success Criterion | Pass/Fail |
|----------|-------------------|-----------|
| ~~S1~~ | ~~IAM roles created, cluster shows 2 IAM role ARNs~~ *(Superseded — Q8)* | N/A |
| S2 | IdC application ARN non-empty, `Authorization: Enabled` | |
| S3 | SQL client connects using IdC-federated credentials | |
| S4 | Credential exchange fails within 3600s of group removal | |
| S5 | `AWSReservedSSO_*` ARN appears in Redshift connection log | |
