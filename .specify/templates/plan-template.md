# Implementation Plan: [FEATURE]

**Branch**: `[###-feature-name]` | **Date**: [DATE] | **Spec**: [link]

**Input**: Feature specification from `/specs/[###-feature-name]/spec.md`

**Note**: This template is filled in by the `/speckit.plan` command. See `.specify/templates/plan-template.md` for the execution workflow.

## Summary

[Extract from feature spec: primary requirement + technical approach from research]

## Technical Context

<!--
  ACTION REQUIRED: Replace the content in this section with the technical details
  for the project. The structure here is presented in advisory capacity to guide
  the iteration process.
-->

**Language/Version**: [e.g., Python 3.11, Swift 5.9, Rust 1.75 or NEEDS CLARIFICATION]

**Primary Dependencies**: [e.g., FastAPI, UIKit, LLVM or NEEDS CLARIFICATION]

**Storage**: [if applicable, e.g., PostgreSQL, CoreData, files or N/A]

**Testing**: [e.g., pytest, XCTest, cargo test or NEEDS CLARIFICATION]

**Target Platform**: [e.g., Linux server, iOS 15+, WASM or NEEDS CLARIFICATION]

**Project Type**: [e.g., library/cli/web-service/mobile-app/compiler/desktop-app or NEEDS CLARIFICATION]

**Performance Goals**: [domain-specific, e.g., 1000 req/s, 10k lines/sec, 60 fps or NEEDS CLARIFICATION]

**Constraints**: [domain-specific, e.g., <200ms p95, <100MB memory, offline-capable or NEEDS CLARIFICATION]

**Scale/Scope**: [domain-specific, e.g., 10k users, 1M LOC, 50 screens or NEEDS CLARIFICATION]

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Verify the following against the [Chedaws EDP Infrastructure Constitution](.specify/memory/constitution.md) before proceeding:

- [ ] **Security**: All new resources use KMS CMKs for encryption at rest; IAM policies are least-privilege; no secrets hardcoded; Security Groups restrict traffic to minimum required.
- [ ] **Observability**: CloudWatch Log Groups (KMS-encrypted, retention defined) and CloudWatch Alarms (routed to an SNS topic) are included for every compute/pipeline resource; names follow `/chedaws-edp/<component>/<env>` convention; MSK clusters set `enhanced_monitoring` ≥ `PER_BROKER`; alarms MUST be active in all four environments (no `count` gate to suppress in dev/test); no observability resources created manually.
- [ ] **Durability**: S3 versioning enabled on all data/artefact buckets; a lifecycle/retention policy is defined for every stateful resource (S3, Redshift, DMS, Log Groups) and the chosen strategy is documented in the spec — no specific storage class or threshold is mandated, but the rationale MUST be recorded; Terraform state uses S3 + DynamoDB locking.
- [ ] **Fault-Tolerance**: Production ECS services span ≥ 2 AZs with ≥ 2 tasks; MWAA HA mode enabled in prod; Glue jobs have retry counts and timeouts.
- [ ] **Cost Optimisation**: Dev/test use smaller instance types; cost allocation tags (`Environment`, `Project`, `Owner`, `CostCentre`) applied to all resources; a lifecycle/retention policy with a documented cost rationale is defined for every S3 bucket and other stateful resource — the storage class transition strategy (e.g., `INTELLIGENT_TIERING`, `STANDARD_IA` + Glacier tiers, expiration) MUST match the resource's access pattern and be recorded in the feature spec.
- [ ] **DRY & Modularity**: Repeated resource patterns are extracted to a module under `terraform/modules/`; any new module has a documented reusability plan (≥ 2 distinct call sites identified in the module's `README.md` "Consumers" section); single-use resources are defined inline, not wrapped in a module; Terraform files are named meaningfully; Terraform resource local names (the second label in each `resource` block) reflect the resource's purpose and are unique within their resource type — generic names (`"this"`, `"main"`, `"default"`) MUST NOT be used when multiple resources of the same type exist; no edits to `terraform-legacy/`.

## Project Structure

### Documentation (this feature)

```text
specs/[###-feature]/
├── plan.md              # This file (/speckit.plan command output)
├── research.md          # Phase 0 output (/speckit.plan command)
├── data-model.md        # Phase 1 output (/speckit.plan command)
├── quickstart.md        # Phase 1 output (/speckit.plan command)
├── contracts/           # Phase 1 output (/speckit.plan command)
└── tasks.md             # Phase 2 output (/speckit.tasks command - NOT created by /speckit.plan)
```

### Source Code (repository root)
<!--
  ACTION REQUIRED: Replace the placeholder tree below with the concrete layout
  for this feature. Delete unused options and expand the chosen structure with
  real paths (e.g., apps/admin, packages/something). The delivered plan must
  not include Option labels.
-->

```text
# [REMOVE IF UNUSED] Option 1: Single project (DEFAULT)
src/
├── models/
├── services/
├── cli/
└── lib/

tests/
├── contract/
├── integration/
└── unit/

# [REMOVE IF UNUSED] Option 2: Web application (when "frontend" + "backend" detected)
backend/
├── src/
│   ├── models/
│   ├── services/
│   └── api/
└── tests/

frontend/
├── src/
│   ├── components/
│   ├── pages/
│   └── services/
└── tests/

# [REMOVE IF UNUSED] Option 3: Mobile + API (when "iOS/Android" detected)
api/
└── [same as backend above]

ios/ or android/
└── [platform-specific structure: feature modules, UI flows, platform tests]
```

**Structure Decision**: [Document the selected structure and reference the real
directories captured above]

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| [e.g., 4th project] | [current need] | [why 3 projects insufficient] |
| [e.g., Repository pattern] | [specific problem] | [why direct DB access insufficient] |
