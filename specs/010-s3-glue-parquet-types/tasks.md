# Tasks: S3 Glue Parquet and Full Column Type Support

**Input**: Design documents from `specs/010-s3-glue-parquet-types/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: User story this task belongs to (US1-US4)
- Exact file paths are included in each description

---

## Phase 1: Setup

**Purpose**: Baseline existing state before making any changes

- [X] T001 Read specs/008-s3-producer-onboarding/contracts/table-schema.json, specs/008-s3-producer-onboarding/contracts/producer-schema.json, terraform/s3.tf, lambda/s3-e2e-verifier/handler.py, lambda/s3-e2e-verifier/requirements.txt, and list s3/platform/ to confirm current state

---

## Phase 2: Foundational (JSON Schema Contracts)

**Purpose**: Update the canonical contract files — the format enum (US1) and the column type regex pattern (US2, US3) both live in these two files. Deploying them to specs/008 unblocks all subsequent user story validation.

**⚠️ CRITICAL**: All user story validation depends on this phase completing first

- [X] T002 [P] Update specs/010-s3-glue-parquet-types/contracts/table-schema.json: add "parquet" to spec.format enum, replace spec.schema.columns[].type enum with the full Glue type regex pattern, and update the type field description to list all 14 primitives and 4 complex families per plan.md Changes 2 and 3
- [X] T003 [P] Update specs/010-s3-glue-parquet-types/contracts/producer-schema.json: add "parquet" to spec.format enum, replace spec.schema.columns[].type enum with the full Glue type regex pattern, and update the type field description to list all 14 primitives and 4 complex families per plan.md Changes 2 and 3
- [X] T004 Copy updated specs/010-s3-glue-parquet-types/contracts/table-schema.json over specs/008-s3-producer-onboarding/contracts/table-schema.json (depends on T002)
- [X] T005 Copy updated specs/010-s3-glue-parquet-types/contracts/producer-schema.json over specs/008-s3-producer-onboarding/contracts/producer-schema.json (depends on T003)

**Checkpoint**: Contracts updated and deployed — all four user stories may now be implemented and validated independently

---

## Phase 3: User Story 1 - Register a Parquet-Format Table (Priority: P1) 🎯 MVP

**Goal**: A producer can declare `spec.format: parquet` and receive a Glue catalog table with the correct Parquet SerDe on the first `terraform apply`.

**Independent Test**: Add the parquet SerDe entry to s3.tf, run `terraform plan -var="env=dev"`, and verify the plan includes `aws_glue_catalog_table.producer_dataset` with `ParquetHiveSerDe`, `MapredParquetInputFormat`, and `MapredParquetOutputFormat` — zero errors and zero unexpected changes to existing resources.

### Implementation for User Story 1

- [X] T006 [US1] Add `parquet` entry to the `_s3_serde_map` local in terraform/s3.tf with input_format "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat", output_format "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat", and serde_library "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe" (no serde_parameters key) per plan.md Change 1
- [ ] T007 [US1] Run `terraform plan -var="env=dev"` from the terraform/ directory and verify zero errors and no unexpected changes to existing resources (quickstart.md Scenario 4)

**Checkpoint**: User Story 1 complete — a Table YAML with `spec.format: parquet` will produce a valid Glue table on apply

---

## Phase 4: User Story 2 - Declare Columns Using Any Valid Glue Primitive Type (Priority: P2)

**Goal**: All 14 Glue primitive types (including parameterized forms like `decimal(10,2)`) are accepted by JSON schema validation; invalid types are rejected.

**Independent Test**: Run Python `jsonschema.validate` against the updated specs/008-s3-producer-onboarding/contracts/table-schema.json with columns typed as `float`, `tinyint`, `varchar(255)`, and `decimal(10,2)` — all must pass. Validate that `foobar` fails with a pattern mismatch error.

### Implementation for User Story 2

> **Note**: The schema change implementing this story (column type regex pattern) is in Phase 2 tasks T002/T003. This phase validates the deployed change.

- [X] T008 [P] [US2] Validate all 14 bare primitive types (boolean, tinyint, smallint, int, bigint, float, double, decimal, string, varchar, char, binary, date, timestamp) pass against specs/008-s3-producer-onboarding/contracts/table-schema.json per quickstart.md Scenario 2
- [X] T009 [P] [US2] Validate parameterized types decimal(10,2), varchar(255), and char(3) pass against specs/008-s3-producer-onboarding/contracts/table-schema.json per quickstart.md Scenario 1
- [X] T010 [US2] Validate that column type value "foobar" fails pattern validation against specs/008-s3-producer-onboarding/contracts/table-schema.json per quickstart.md Scenario 3

**Checkpoint**: User Story 2 complete — all 14 Glue primitive types and their parameterized forms are accepted; invalid values are rejected

---

## Phase 5: User Story 3 - Declare Columns Using Glue Complex Types (Priority: P3)

> **Note on phase ordering**: US4 (P2) follows this phase (Phase 6) rather than preceding it because US4 has a hard dependency on US1 (Phase 3) completing first. If working with multiple developers, US3 and US4 can proceed concurrently once Phase 2 and Phase 3 are complete.

**Goal**: Complex type expressions (`array<...>`, `map<...>`, `struct<...>`, `uniontype<...>`) pass JSON schema validation; malformed expressions are rejected.

**Independent Test**: Validate `array<string>` and `struct<id:bigint,name:string>` pass against the updated table-schema.json; validate `array<>` and `decimal(abc)` fail.

### Implementation for User Story 3

> **Note**: The schema change implementing this story (the complex-type portion of the same regex as US2) is in Phase 2 tasks T002/T003. This phase validates the complex-type portion of the deployed change.

- [X] T011 [P] [US3] Validate complex types array<string>, map<string,bigint>, struct<id:bigint,name:string>, and uniontype<int,string> pass against specs/008-s3-producer-onboarding/contracts/table-schema.json per quickstart.md Scenario 1
- [X] T012 [P] [US3] Validate malformed complex types array<> and decimal(abc) fail pattern validation against specs/008-s3-producer-onboarding/contracts/table-schema.json per quickstart.md Scenario 3

**Checkpoint**: User Story 3 complete — Glue complex types are accepted; malformed expressions are rejected

---

## Phase 6: User Story 4 - E2E Verification of Parquet Upload and Query (Priority: P2)

**Goal**: The E2E verifier Lambda automatically tests Parquet write, Athena query, and S3 cleanup for the `e2e_parquet` canary table, reporting `"outcome": "PASS"` with zero manual intervention.

**Independent Test**: Apply Terraform in dev (creating the e2e_parquet Glue table), redeploy the Lambda with pyarrow changes, invoke the Lambda manually, and verify the CloudWatch log shows `"outcome": "PASS"` for `e2e_parquet` and that no test objects remain in S3.

### Implementation for User Story 4

- [X] T013 [P] [US4] Create s3/platform/e2e_parquet.yaml with apiVersion s3.chedaws.io/v1, kind Table, namespace platform, name e2e_parquet, owner platform-team, spec.format parquet, and 4-column schema (id: int, name: string, value: double, active: boolean) per plan.md Change 4
- [X] T014 [P] [US4] Add `pyarrow>=15.0,<20.0` to lambda/s3-e2e-verifier/requirements.txt below the fastavro line, using the same direct-ZIP-bundling approach per data-model.md
- [X] T015 [US4] Extend lambda/s3-e2e-verifier/handler.py: add `import pyarrow as pa` and `import pyarrow.parquet as pq`, add `"e2e_parquet": "parquet"` to `_TABLE_EXT`, add `"e2e_parquet"` to the `tables` list, add `serialize_parquet()` function using `pa.Table.from_pylist(SAMPLE_ROWS)` and `pq.write_table` into `io.BytesIO`, extend `write_table()` with `elif ext == "parquet": buf = serialize_parquet()`, and add `"e2e_parquet"` to the assume-role failure path per plan.md Change 5 (depends on T014)
- [X] T016 [US4] Verify Lambda deployment package size — run `pip install -r lambda/s3-e2e-verifier/requirements.txt -t /tmp/lambda-pkg` and confirm total unzipped size is under 250 MB (depends on T014)
- [ ] T017 [US4] Run `terraform plan -var="env=dev"` and verify aws_glue_catalog_table.producer_dataset["platform/e2e_parquet"] will be created with correct Parquet SerDe settings (depends on T013)
- [ ] T023 [US4] Invoke the Lambda manually in dev per quickstart.md Scenario 7 and verify CloudWatch shows `"outcome": "PASS"` for `e2e_parquet` with all 3 expected rows returned; confirm no test objects remain under `platform/e2e_parquet/` in the landing bucket (SC-006; depends on Terraform apply in dev and Lambda redeployment with pyarrow changes)

**Checkpoint**: User Story 4 complete — e2e_parquet canary table and Lambda Parquet path fully implemented

---

## Phase 7: Polish and Cross-Cutting Concerns

**Purpose**: Full backward-compatibility check, multi-environment Terraform plan, tflint, README update, and clean commit

- [X] T018 [P] Validate backward compatibility — run Python jsonschema against all existing s3/*.yaml files using updated specs/008-s3-producer-onboarding/contracts/table-schema.json and confirm zero validation failures (SC-004, quickstart.md Scenario 2)
- [ ] T019 [P] Run `terraform plan -var="env=<env>"` for test, uat, and prod environments and verify exit code 0 or 2 with no errors (SC-005, quickstart.md Scenario 5)
- [X] T021 Run `auto/tflint` from the repository root and resolve or suppress with justification all warnings before raising a PR (constitution §Development Workflow §2; depends on T006)
- [X] T022 [P] Update root README.md to document `parquet` as a supported `spec.format` value alongside `csv`, `json`, and `avro`
- [X] T020 Commit all changes grouped as: (1) JSON schema contracts (specs/010 and specs/008), (2) terraform/s3.tf, (3) s3/platform/e2e_parquet.yaml plus Lambda changes, (4) root README.md — remove any scratch test YAMLs (e.g., s3/platform/e2e_types.yaml) before committing per quickstart.md Post-Validation Cleanup (depends on T018, T019, T021, T022)

---

## Dependencies and Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — BLOCKS all user story validation
- **User Story 1 (Phase 3)**: Depends on Phase 2 completion (contracts deployed)
- **User Story 2 (Phase 4)**: Depends on Phase 2 completion — independent of US1
- **User Story 3 (Phase 5)**: Depends on Phase 2 completion — independent of US1 and US2
- **User Story 4 (Phase 6)**: Depends on Phase 2 (parquet in schema) and logically on Phase 3 (parquet SerDe in Terraform) — T013 and T017 require parquet to be in the schema and SerDe map
- **Polish (Phase 7)**: Depends on all prior phases

### User Story Dependencies

- **US1 (P1)**: Start after Phase 2 — no dependency on other user stories
- **US2 (P2)**: Start after Phase 2 — no dependency on US1 (schema regex is independent of Terraform SerDe)
- **US3 (P3)**: Start after Phase 2 — shares the same regex change as US2; validates the complex-type portion
- **US4 (P2)**: Start after Phase 2 and US1 — T013 (e2e_parquet.yaml) depends on parquet being in the format enum and SerDe map; T015 (Lambda) depends on T014 (requirements)

### Within Each User Story

- Phase 3 (US1): T006 (implement) before T007 (validate)
- Phase 4 (US2): T008 and T009 can run in parallel; T010 is independent
- Phase 5 (US3): T011 and T012 can run in parallel
- Phase 6 (US4): T013 and T014 can run in parallel; T015 depends on T014; T016 depends on T014; T017 depends on T013; T023 depends on T017 and Lambda redeployment in dev

---

## Parallel Execution Examples

### Phase 2 (Foundational)

```
Parallel:  T002 (table-schema.json) | T003 (producer-schema.json)
Sequential: T004 (copy table-schema) → wait for T002
            T005 (copy producer-schema) → wait for T003
```

### Phase 4 (US2)

```
Parallel:  T008 (validate 14 primitives) | T009 (validate parameterized types)
Sequential: T010 (validate invalid type rejected)
```

### Phase 5 (US3)

```
Parallel:  T011 (validate complex types pass) | T012 (validate malformed types fail)
```

### Phase 6 (US4)

```
Parallel:  T013 (create e2e_parquet.yaml) | T014 (add pyarrow to requirements.txt)
Sequential: T015 (extend handler.py) → wait for T014
            T016 (verify ZIP size) → wait for T014
            T017 (terraform plan for e2e_parquet) → wait for T013
            T023 (Lambda invocation + PASS verification) → after T017 and Lambda redeployed in dev
```

### Phase 7 (Polish)

```
Parallel:  T018 (backward compat check) | T019 (multi-env terraform plan) | T022 (README update)
Sequential: T021 (tflint) → after T006
            T020 (commit) → after T018 + T019 + T021 + T022
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL — deploy updated contracts)
3. Complete Phase 3: User Story 1 (Terraform SerDe entry + plan validation)
4. **STOP and VALIDATE**: Run `terraform plan -var="env=dev"`, confirm Parquet Glue table in plan
5. Ship US1 if needed — producers can register Parquet tables immediately

### Incremental Delivery

1. Phase 1 + Phase 2 → Contracts deployed (foundation ready)
2. Phase 3 (US1) → Parquet format + Terraform SerDe (MVP)
3. Phase 4+5 (US2+US3) → Full column type coverage (column flexibility)
4. Phase 6 (US4) → E2E Lambda verification (continuous assurance)
5. Phase 7 → Final validation and clean commit

### Single-Developer Strategy

Work sequentially in priority order:
1. Phase 1 → Phase 2 (foundation)
2. Phase 3 (US1, P1) — highest value, unblocks producers
3. Phase 6 (US4, P2) — E2E assurance, depends on US1
4. Phase 4 (US2, P2) — column type expansion
5. Phase 5 (US3, P3) — complex types (validation only)
6. Phase 7 (Polish)

---

## Notes

- [P] tasks operate on different files and have no in-flight dependencies — safe to parallelize
- US2 and US3 share the same JSON schema change (a single regex covers both primitives and complex types); their phases are distinct only for validation traceability
- US4 has a hard dependency on US1 (parquet must be in the schema enum and SerDe map before e2e_parquet.yaml can be registered)
- Lambda ZIP size guard (T016) is a mandatory verification — do not skip it
- `s3/platform/e2e_parquet.yaml` is a permanent file; do not confuse it with scratch test YAMLs
- No changes to `terraform-legacy/` — that directory is frozen per constitution §VI
- Commit after Phase 3 and again after Phase 6 to keep history clean; final commit after Phase 7
