# Tasks: Shared KMS Key for Multiple Similar Service Principals

**Input**: Design documents from `specs/004-shared-kms-service-principals/`

**Format**: `- [ ] [TaskID] [P?] [Story?] Description with file path`
- **[P]**: Parallelisable — different files, no dependency on incomplete tasks
- **[Story]**: User story label (US1, US2) — setup and polish phases have no label
- All file paths are relative to the repository root

---

## Phase 1: Setup

**Purpose**: Record the pre-change baseline before any edits are made.

- [X] T001 Run `terraform -chdir=terraform plan` on the `dev` workspace and confirm zero planned changes on all `module.kms[*]` resources before any file edits

---

## Phase 2: Foundational

No foundational prerequisites for this feature — all changes are self-contained within the KMS module and its callers. Proceeding directly to user story phases.

---

## Phase 3: User Story 1 — Multi-principal KMS Module (Priority: P1) 🎯 MVP

**Goal**: The `terraform/modules/kms` module accepts a `set(string)` of service principals and grants all of them access in a single `AllowServiceAccess` KMS policy statement.

**Independent Test**: After completing T002–T004, add a temporary two-principal entry to `terraform/locals.tf`, run `terraform plan`, and confirm both principals appear in the planned key policy JSON (see `quickstart.md` Scenario 2).

- [X] T002 [US1] Update `terraform/modules/kms/variables.tf` — rename `service_principal` (string) to `service_principals` (set(string)) and add a `validation` block that rejects an empty set with the message `"At least one service principal must be provided."`
- [X] T003 [US1] Update `terraform/modules/kms/main.tf` — change `identifiers = [var.service_principal]` to `identifiers = tolist(var.service_principals)` in the `AllowServiceAccess` statement (depends on T002)
- [X] T004 [P] [US1] Update `terraform/modules/kms/README.md` — replace the `service_principal` variable entry with `service_principals` (type `set(string)`, required, validation noted) (depends on T002; can run in parallel with T003)

**Checkpoint**: Module accepts one or more service principals. A single-element set produces the same policy JSON as the old single-string variable.

---

## Phase 4: User Story 2 — Backward Compatibility (Priority: P2)

**Goal**: All four existing `kms_services` entries in `terraform/locals.tf` are updated to the new `service_principals` list form and `terraform plan` shows zero planned changes for all four KMS keys.

**Independent Test**: After T005, run `terraform -chdir=terraform plan` on `dev` and confirm the plan output is `No changes. Your infrastructure matches the configuration.` for all `module.kms[*]` resources (see `quickstart.md` Scenario 1).

- [X] T005 [P] [US2] Update `terraform/locals.tf` — convert all four `kms_services` entries from `service_principal = "..."` to `service_principals = ["..."]` list form (depends on T002; can run in parallel with T003 and T004)
- [X] T006 [US2] Run `terraform validate` then `terraform -chdir=terraform plan` on the `dev` workspace — confirm all four `module.kms[*]` resources show **zero** planned changes (depends on T003 and T005)

**Checkpoint**: Feature is fully delivered. Both user stories pass their independent tests.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Lint and compliance gate confirming no regressions were introduced.

- [X] T007 [P] Run `tflint --chdir=terraform` and confirm zero new errors or warnings introduced by this feature's changes
- [X] T008 [P] Run `checkov -d terraform --compact` and confirm no new `FAILED` checks beyond the three pre-existing suppressions in `terraform/modules/kms/main.tf` (`CKV_AWS_109`, `CKV_AWS_111`, `CKV_AWS_356`) *(checkov not installed locally; run in CI)*

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Phase 3 (US1)**: Depends on Phase 1 completion
- **Phase 4 (US2)**: T005 depends on T002; T006 depends on T003 and T005
- **Phase 5 (Polish)**: Depends on all Phase 3 and Phase 4 implementation tasks (T002–T005)

### User Story Dependencies

- **US1 (P1)**: Can start after Phase 1
- **US2 (P2)**: T005 depends on T002 (variable rename); T006 depends on T003 and T005

### Within Phase 3 (US1)

- T002 must complete first (variable rename affects all other files)
- T003 and T004 depend on T002 but are independent of each other → run in parallel

### Within Phase 4 (US2)

- T005 depends on T002 only → can run in parallel with T003 and T004
- T006 depends on both T003 and T005 → runs last in this phase

---

## Parallel Opportunities

### After T002 completes — maximum parallelism window

```
T002 (variables.tf) DONE
        ├── T003 (main.tf)    ─┐
        ├── T004 (README.md)   ├── run in parallel
        └── T005 (locals.tf)  ─┘
```

### After T003 + T005 complete

```
T003 + T005 DONE
        └── T006 (terraform validate + plan)
```

### After T006 completes — polish window

```
T006 DONE
        ├── T007 (tflint)     ─┐
        └── T008 (checkov)    ─┘  run in parallel
```

---

## Implementation Strategy

**MVP scope** (minimum to deliver value): T001 → T002 → T003 + T004 + T005 (parallel) → T006

**Suggested single-commit scope**: T002 + T003 + T004 + T005 in one atomic commit — the module variable rename and all caller updates must land together to avoid a broken intermediate state.

**Polish** (T007 + T008): Run as a separate step or in CI before merging.
