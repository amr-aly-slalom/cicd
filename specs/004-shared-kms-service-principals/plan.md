# Implementation Plan: Shared KMS Key for Multiple Similar Service Principals

**Branch**: `004-shared-kms-service-principals` | **Date**: 2026-06-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/004-shared-kms-service-principals/spec.md`

## Summary

Widen the `terraform/modules/kms` module's `service_principal` input from a single string to a `set(string)` so that one KMS customer-managed key can grant encrypt/decrypt access to multiple AWS service principals via a single policy statement. All four existing KMS entries (redshift, sns, cloudwatch_logs, msk) are updated atomically from the old single-string form to the new set form; `terraform plan` must show zero changes for those entries after the update. No new shared entries are created as part of this delivery.

## Technical Context

**Language/Version**: Terraform HCL; HashiCorp AWS provider ~5.x

**Primary Dependencies**: `terraform/modules/kms` (the module being modified); `hashicorp/aws` Terraform provider

**Storage**: N/A — no application data; Terraform workspace state stored in `terraform/terraform.tfstate.d/`

**Testing**: `tflint` (`auto/tflint`), Checkov (policy compliance scan), `terraform validate`, `terraform plan`

**Target Platform**: AWS (multi-account: dev/test `381491832813`, uat `339712719726`, prod `637423180765`)

**Project Type**: Terraform IaC — module enhancement + root-module configuration update

**Performance Goals**: N/A

**Constraints**: AWS KMS key policy max 32 KB; `terraform plan` must show zero changes for existing 4 entries after the module update

**Scale/Scope**: 1 module modified (`terraform/modules/kms`); 1 configuration file modified (`terraform/locals.tf`); 4 existing entries updated in-place

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Verified against [Chedaws EDP Infrastructure Constitution](../../.specify/memory/constitution.md):

- [x] **Security**: The module change only widens `identifiers` in the `AllowServiceAccess` policy statement. Each service principal receives the same 6 named KMS actions (`Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant`) — never `kms:*`. No secrets hardcoded; no Security Groups involved. Least-privilege is preserved.
- [x] **Observability**: N/A — KMS keys are not compute/pipeline resources; no CloudWatch Log Groups or Alarms are required for KMS key changes. Existing observability setup is unaffected.
- [x] **Durability**: N/A — no S3, Redshift, or DMS resources changed.
- [x] **Fault-Tolerance**: N/A — no ECS, MWAA, or Glue changes.
- [x] **Cost Optimisation**: Feature enables future KMS key count reduction ($1/key/month). No new keys created by this delivery.
- [x] **DRY & Modularity**: Existing `terraform/modules/kms` module enhanced in-place. No new module created. The module already has 4 established call sites in `kms_services`. No single-use wrapper introduced. No edits to `terraform-legacy/`.

## Project Structure

### Documentation (this feature)

```text
specs/004-shared-kms-service-principals/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── outputs.md       # Phase 1 output — module output contract
└── tasks.md             # Phase 2 output (/speckit.tasks — NOT created here)
```

### Source Code (repository root)

```text
terraform/
├── locals.tf            # kms_services map: service_principal → service_principals
└── modules/
    └── kms/
        ├── variables.tf # service_principal (string) → service_principals (set(string))
        └── main.tf      # identifiers = [var.service_principal] → tolist(var.service_principals)
```

**Structure Decision**: Single-module enhancement. No new files, no new directories. Two existing files modified: `terraform/modules/kms/variables.tf` and `terraform/modules/kms/main.tf`. One configuration file updated: `terraform/locals.tf` (all 4 `kms_services` entries). `terraform/modules/kms/README.md` updated to document the new variable.
