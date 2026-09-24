# Tasks: IAM Identity Centre Redshift Integration

**Input**: Design documents from `specs/002-iam-ic-redshift-ci/`

**Branch**: `feat/iam-ic-redshift-ci` | **Date**: 2026-06-30

**Format**: `[ID] [P?] [Story?] Description with file path`
- **[P]**: Can run in parallel (no dependencies on incomplete tasks)
- **[US1]** / **[US2]**: User story from spec.md

---

## Phase 1: Setup

**Purpose**: Declare the new Terraform variable required by all downstream resources.

- [X] T001 Add `idc_instance_arn` (type: `string`, default: `"arn:aws:sso:::instance/ssoins-82599788fabf9a65"`, description: "ARN of the central IAM Identity Centre instance") variable declaration to `terraform/variables.tf`

**Checkpoint**: Variable declared — Phase 2 can begin.

---

## Phase 2: User Story 1 — Federated Login via Corporate SSO (Priority: P1) 🎯 MVP

**Goal**: Register the Redshift cluster with IAM Identity Centre for Trusted Identity Propagation, enabling Query Editor v2 and native IdC clients to authenticate directly via corporate SSO without database passwords.

**Independent Test**: After `terraform apply -var="idc_instance_arn=arn:aws:sso:::instance/ssoins-82599788fabf9a65"` in the `dev` workspace, run `terraform output redshift_idc_application_arn` and confirm a non-empty ARN. Confirm via `aws redshift describe-redshift-idc-applications` that an entry with `RedshiftIdcApplicationName = "chedaws-edp-dev"` exists and has `Authorization: Enabled`.

### Implementation for User Story 1

- [X] T002 [US1] Add `aws_iam_role.redshift_idc_svc` with `name = "chedaws-edp-redshift-idc-svc-${local.environment}"`, `description = "Service role for the chedaws-edp-${local.environment} Redshift IdC application; assumed by redshift.amazonaws.com for Trusted Identity Propagation"`, and `assume_role_policy` trusting `{"Service": "redshift.amazonaws.com"}` with action `sts:AssumeRole` in `terraform/redshift.tf`
- [X] T003 [US1] Add `aws_iam_role_policy.redshift_idc_svc` inline policy on `aws_iam_role.redshift_idc_svc`: Sid `SSODescribe` → `sso:DescribeRegisteredRegions`, `sso:GetApplicationAuthenticationMethod`, `sso:GetApplicationGrant` on `"*"` (checkov skip CKV_AWS_355: SSO actions require wildcard); Sid `RedshiftDescribe` → `redshift:DescribeClusters` scoped to `arn:aws:redshift:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster:chedaws-edp-${local.environment}` in `terraform/redshift.tf`
- [X] T004 [US1] Add `aws_redshift_idc_application.this` with `idc_instance_arn = var.idc_instance_arn`, `idc_display_name = "chedaws-edp-${local.environment}"`, `redshift_idc_application_name = "chedaws-edp-${local.environment}"`, `iam_role_arn = aws_iam_role.redshift_idc_svc.arn`, and `service_integration { redshift { connect { authorization = "Enabled" } } }` in `terraform/redshift.tf` (no `identity_namespace` — AWS default used)

**Checkpoint**: User Story 1 fully implemented. `terraform plan` with `idc_instance_arn` supplied shows exactly 3 resources to add (idc_svc role, idc_svc policy, idc_application), 0 to replace.

---

## Phase 3: User Story 2 — Access Revocation & Audit Trail (Priority: P2)

**Goal**: Confirm all Redshift connection attempts are captured in CloudWatch Logs (SC-004). Access revocation TTL (SC-003) is enforced by the IdC permission set session duration — configured by the identity team, outside this project's scope.

**Independent Test**: Confirm `aws_redshift_logging.this` in `terraform/redshift.tf` exports `connectionlog`, `userlog`, and `useractivitylog`. After a test connection using IdC credentials, query `/aws/redshift/cluster/chedaws-edp-dev/connectionlog` in CloudWatch and confirm the `AWSReservedSSO_*` role ARN appears as the authenticated principal.

### Implementation for User Story 2

- [X] T005 [US2] Confirm `aws_redshift_logging.this` in `terraform/redshift.tf` has `log_exports` containing `connectionlog`, `userlog`, and `useractivitylog` (SC-004 audit trail — already provisioned in spec 001 via separate `aws_redshift_logging` resource; no Terraform changes required for this feature)

**Checkpoint**: User Story 2 complete. Audit logging active via `aws_redshift_logging.this`.

---

## Phase 4: Polish & Cross-Cutting

**Purpose**: Expose IdC integration state as Terraform outputs per `contracts/outputs.md`; validate the complete plan.

- [X] T006 [P] Add two new outputs to `terraform/outputs.tf`: `redshift_idc_svc_role_arn` (value: `aws_iam_role.redshift_idc_svc.arn`, description: "ARN of the Redshift IdC application service role") and `redshift_idc_application_arn` (value: `aws_redshift_idc_application.this.redshift_idc_application_arn`, description: "ARN of the registered Redshift IdC application")
- [X] T007 Run `terraform validate` in `terraform/`; then run `terraform plan -var="idc_instance_arn=arn:aws:sso:::instance/ssoins-82599788fabf9a65"` in the `dev` workspace; confirm plan shows exactly 3 resources to add, 0 to replace, 0 errors; also confirm checkov reports 0 failed checks (validates SC-002 — no static credentials in source files)

**Checkpoint**: All resources provisioned and validated. Feature complete.

---

## Dependencies

```
T001 (variable: idc_instance_arn)
  └── T002 [US1] aws_iam_role.redshift_idc_svc
        └── T003 [US1] aws_iam_role_policy.redshift_idc_svc
              └── T004 [US1] aws_redshift_idc_application.this
                    └── T006 (outputs)
                          └── T007 (validate + plan)

T005 [US2] — fully independent; can run at any point after T001
```

---

## Parallel Execution Opportunities

### User Story 1

T002 (service role) unblocks T003 (policy) which unblocks T004 (IdC application). Write all three in a single file edit to `terraform/redshift.tf`:

```
T001 → T002 → T003 → T004
```

### Outputs (T006)

Both output declarations target `terraform/outputs.tf`; write both in a single edit.

### User Story 2 (T005)

T005 is fully independent and can be confirmed at any point after T001.

---

## Implementation Strategy

**MVP scope (T001–T004, T006–T007)**: Delivers Trusted Identity Propagation (Query Editor v2) in a single `terraform apply`. Only `idc_instance_arn` is required. Users assigned to IdC groups can authenticate immediately via Query Editor v2.

**Delivery order**:
1. T001 — variable (unblocks all US1 work)
2. T002 → T003 → T004 — service role, inline policy, IdC application (single file edit, sequential)
3. T005 — audit logging verification (any time, independent)
4. T006 — outputs (after T004)
5. T007 — validate and plan smoke test


```
T001 (variable: idc_instance_arn)
  └── T002 [US1] aws_iam_role.redshift_idc_svc
        └── T003 [US1] aws_iam_role_policy.redshift_idc_svc
              └── T004 [US1] aws_redshift_idc_application.this
                    └── T006 (outputs)
                          └── T007 (validate + plan)

T005 [US2] — fully independent; can run at any point after T001
```

---

## Parallel Execution Opportunities

### User Story 1

T002 (service role) unblocks T003 (policy) which unblocks T004 (IdC application). Write all three in a single file edit to `terraform/redshift.tf`:

```
T001 → T002 → T003 → T004
```

### Outputs (T006)

Both output declarations target `terraform/outputs.tf`; write both in a single edit.

### User Story 2 (T005)

T005 is fully independent and can be confirmed at any point after T001.

---

## Implementation Strategy

**MVP scope (T001–T004, T006–T007)**: Delivers Trusted Identity Propagation (Query Editor v2) in a single `terraform apply`. Only `idc_instance_arn` is required. Users assigned to IdC groups can authenticate immediately via Query Editor v2.

**Delivery order**:
1. T001 — variable (unblocks all US1 work)
2. T002 → T003 → T004 — service role, inline policy, IdC application (single file edit, sequential)
3. T005 — audit logging verification (any time, independent)
4. T006 — outputs (after T004)
5. T007 — validate and plan smoke test
