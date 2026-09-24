# Tasks: Multi-Environment S3 Bucket Provisioning

**Input**: Design documents from `/specs/005-multi-env-s3-buckets/`

**Prerequisites**: plan.md (required), spec.md (required for user stories), research.md, data-model.md

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Prepare the Terraform structure for the reusable S3 bucket implementation.

- [ ] T001 Create the reusable S3 module scaffold under terraform/modules/s3/ with main.tf, variables.tf, outputs.tf, and README.md
- [ ] T002 Add environment-aware Terraform locals and naming conventions in terraform/locals.tf for dev, test, uat, and prod
- [ ] T003 [P] Add the root S3 bucket instantiation entry points in terraform/s3.tf for the four environments

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Implement the shared bucket module and baseline controls that all environments depend on.

- [ ] T004 Implement bucket resource configuration in terraform/modules/s3/main.tf with encryption, versioning, lifecycle, ownership controls, and public access blocking
- [ ] T005 Implement module inputs in terraform/modules/s3/variables.tf for environment-specific naming, tags, and optional access policy settings
- [ ] T006 Implement module outputs in terraform/modules/s3/outputs.tf for bucket name, ARN, and relevant identifiers
- [ ] T007 Add module documentation in terraform/modules/s3/README.md covering usage, assumptions, and validation expectations
- [ ] T008 Configure baseline bucket policy and private access alignment for approved CI/CD and internal workloads in the S3 module

**Checkpoint**: Foundation ready - environment-specific bucket provisioning can now proceed.

---

## Phase 3: User Story 1 - Secure bucket provisioning for each environment (Priority: P1) 🎯 MVP

**Goal**: Provision a secure S3 bucket for each environment with consistent baseline controls.

**Independent Test**: Each environment can be validated by checking that the bucket exists and includes encryption, versioning, tags, and public-access blocking.

### Implementation for User Story 1

- [ ] T009 [P] [US1] Create the dev bucket configuration wiring in terraform/s3.tf using the shared S3 module
- [ ] T010 [P] [US1] Create the test bucket configuration wiring in terraform/s3.tf using the shared S3 module
- [ ] T011 [P] [US1] Create the uat bucket configuration wiring in terraform/s3.tf using the shared S3 module
- [ ] T012 [P] [US1] Create the prod bucket configuration wiring in terraform/s3.tf using the shared S3 module
- [ ] T013 [US1] Apply the required common tags and environment-specific values to the bucket module inputs

**Checkpoint**: User Story 1 should now be deployable independently for any environment.

---

## Phase 4: User Story 2 - Controlled access for CI/CD and internal workloads (Priority: P1)

**Goal**: Restrict bucket access to approved private paths while supporting CI/CD and internal automation.

**Independent Test**: An approved principal can access the bucket through the intended private path, while public access is denied.

### Implementation for User Story 2

- [ ] T014 [P] [US2] Add CI/CD and internal principal policy variables to terraform/modules/s3/variables.tf
- [ ] T015 [US2] Implement the baseline bucket policy in terraform/modules/s3/main.tf to allow only approved principals and deny public access
- [ ] T016 [US2] Wire the environment-specific principals and access policy inputs from terraform/s3.tf into the S3 module

**Checkpoint**: User Story 2 should be independently testable through policy enforcement and access validation.

---

## Phase 5: User Story 3 - Validation before release (Priority: P2)

**Goal**: Provide a repeatable smoke-test path to confirm bucket compliance before environments are accepted.

**Independent Test**: A smoke test can confirm encryption, policy enforcement, tags, and public access blocking for a deployed bucket.

### Implementation for User Story 3

- [ ] T017 [P] [US3] Add a smoke-test script or Terraform validation workflow under terraform/ or scripts/ to verify bucket encryption, tags, and public access blocking
- [ ] T018 [US3] Add output values in terraform/modules/s3/outputs.tf to support smoke-test validation and operational verification
- [ ] T019 [US3] Document the smoke-test procedure in specs/001-multi-env-s3-buckets/quickstart.md and terraform/modules/s3/README.md

**Checkpoint**: User Story 3 should provide a clear release validation path for each environment.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Finalize the deployment experience and verify the implementation across all environments.

- [ ] T020 [P] Run terraform fmt across terraform/ and ensure Terraform files are consistently formatted
- [ ] T021 Run terraform validate and review any provider or syntax issues
- [ ] T022 Review the configuration for tag completeness, naming consistency, and documentation accuracy
- [ ] T023 Run the smoke-test workflow for dev, test, uat, and prod environments as applicable

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies
- **Foundational (Phase 2)**: Depends on Setup completion
- **User Story 1 (Phase 3)**: Depends on Foundational completion
- **User Story 2 (Phase 4)**: Depends on Foundational completion and may build on User Story 1 outputs
- **User Story 3 (Phase 5)**: Depends on User Story 1 and User Story 2 completion
- **Polish (Phase 6)**: Depends on all user stories being complete

### Parallel Opportunities

- T003 can run in parallel with T001 and T002 once the structure is clear
- T009 through T012 can be implemented in parallel because they target different environment-specific instantiations
- T014 and T017 are parallelizable because they target separate module and validation concerns
