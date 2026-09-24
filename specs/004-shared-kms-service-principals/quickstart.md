# Quickstart Validation Guide: Shared KMS Key for Multiple Similar Service Principals

**Feature**: `004-shared-kms-service-principals`
**Date**: 2026-06-30

This guide describes how to validate that the feature works end-to-end. Each scenario is independently runnable and maps to the acceptance criteria in [spec.md](spec.md).

---

## Prerequisites

- Terraform CLI installed and on `PATH`
- AWS credentials configured for the target account (dev workspace uses account `381491832813`)
- Active Terraform workspace:
  ```
  terraform -chdir=terraform workspace select dev
  ```
- `tflint` available (see `auto/tflint`)

---

## Scenario 1: Backward compatibility — existing entries plan with zero changes (SC-002)

Maps to: User Story 2, SC-002

**Setup**: Apply the module change (`variables.tf`, `main.tf`) and the `locals.tf` update (all 4 entries converted to `service_principals = [...]` form) to a dev workspace that already has the 4 KMS keys deployed.

**Steps**:
```
terraform -chdir=terraform plan -out=tfplan
```

**Expected outcome**:
- Plan output shows `No changes. Your infrastructure matches the configuration.` for all KMS resources (`module.kms["redshift"]`, `module.kms["sns"]`, `module.kms["cloudwatch_logs"]`, `module.kms["msk"]`)
- Zero resource additions, changes, or destructions

---

## Scenario 2: Multi-principal entry applies successfully (SC-001)

Maps to: User Story 1, SC-001

**Setup**: Add a temporary test entry to `local.kms_services` in `terraform/locals.tf`:
```hcl
test_shared = {
  service_principals = [
    "logs.eu-west-1.amazonaws.com",
    "logs.us-east-1.amazonaws.com",
  ]
}
```

**Steps**:
```
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform show -json tfplan | \
  jq '.resource_changes[] | select(.address == "module.kms[\"test_shared\"].aws_kms_key.this")'
```

**Expected outcome**:
- Plan shows 1 new `aws_kms_key` and 1 new `aws_kms_alias` for `test_shared`
- The planned key policy JSON contains both `logs.eu-west-1.amazonaws.com` and `logs.us-east-1.amazonaws.com` in the `AllowServiceAccess` statement's `Principal.Service` array
- Apply completes without errors

**Cleanup**: Remove the `test_shared` entry and run `terraform apply` to destroy the test key before merging.

---

## Scenario 3: Duplicate principals are silently deduplicated

Maps to: Edge Case (spec §Edge Cases), FR-001

**Setup**: Add a temporary test entry with a duplicate principal:
```hcl
test_dedup = {
  service_principals = [
    "sns.amazonaws.com",
    "sns.amazonaws.com",
  ]
}
```

**Steps**:
```
terraform -chdir=terraform plan -out=tfplan
terraform -chdir=terraform show -json tfplan | \
  jq '.resource_changes[] | select(.address == "module.kms[\"test_dedup\"].aws_kms_key.this") | .change.after.policy'
```

**Expected outcome**:
- Plan succeeds without any validation error
- The planned key policy contains `sns.amazonaws.com` exactly **once** in the `AllowServiceAccess` `Principal.Service` array (not twice)

**Cleanup**: Remove the `test_dedup` entry.

---

## Scenario 4: Empty `service_principals` is rejected at plan time (FR-005)

Maps to: Edge Case (spec §Edge Cases), FR-005

**Setup**: Add a temporary test entry with an empty set:
```hcl
test_empty = {
  service_principals = []
}
```

**Steps**:
```
terraform -chdir=terraform plan
```

**Expected outcome**:
- `terraform plan` exits with a non-zero exit code
- Error message contains text matching: `"At least one service principal must be provided"`
- No AWS API calls are made; no resources are created or changed

**Cleanup**: Remove the `test_empty` entry (no `terraform apply` needed — plan was rejected).

---

## Scenario 5: Linting and policy compliance pass (SC-003)

Maps to: SC-003

**Steps**:
```
# tflint
tflint --chdir=terraform

# Checkov
checkov -d terraform --compact
```

**Expected outcome**:
- `tflint`: 0 errors, 0 warnings related to this feature's changes
- Checkov: no new `FAILED` checks beyond the 3 pre-existing suppressed rules (`CKV_AWS_109`, `CKV_AWS_111`, `CKV_AWS_356`) in `terraform/modules/kms/main.tf`

---

## Reference

- Data model: [data-model.md](data-model.md)
- Module output contract: [contracts/outputs.md](contracts/outputs.md)
- Spec: [spec.md](spec.md)
