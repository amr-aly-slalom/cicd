# Module Output Contract: `terraform/modules/kms`

**Feature**: `004-shared-kms-service-principals`
**Date**: 2026-06-30

The output contract of `terraform/modules/kms` is **unchanged** by this feature. All existing callers (`module.kms["redshift"]`, `module.kms["sns"]`, `module.kms["cloudwatch_logs"]`, `module.kms["msk"]`) continue to reference the same outputs without modification.

---

## Outputs

| Output | Type | Description | Changed? |
|--------|------|-------------|---------|
| `key_arn` | `string` | ARN of the KMS CMK, e.g. `arn:aws:kms:eu-west-1:381491832813:key/…` | No |
| `key_id` | `string` | ID of the KMS CMK (UUID), e.g. `mrk-abc123…` | No |
| `alias_arn` | `string` | ARN of the KMS alias, e.g. `arn:aws:kms:eu-west-1:381491832813:alias/chedaws-edp-redshift-dev` | No |

---

## Input Contract (changed fields only)

| Variable | Old type | New type | Breaking? |
|----------|----------|----------|-----------|
| `service_principal` | `string` | *(removed)* | Yes — callers must update to `service_principals` |
| `service_principals` | *(new)* | `set(string)` | — |

> All 4 callers in `terraform/locals.tf` are updated atomically in the same commit. No external callers exist outside this repository.

---

## Caller Reference (existing `terraform/outputs.tf`)

These root-module outputs reference the KMS module by `for_each` key and are **unaffected**:

```hcl
module.kms["redshift"].key_arn
module.kms["sns"].key_arn
module.kms["cloudwatch_logs"].key_arn
```

The `for_each` key is `service_name` (the `kms_services` map key), which does not change.

---

## Alias Naming Convention (unchanged)

```
alias/chedaws-edp-{service_name}-{environment}
```

Examples:
- `alias/chedaws-edp-redshift-dev`
- `alias/chedaws-edp-cloudwatch_logs-prod`
- `alias/chedaws-edp-msk-uat`
