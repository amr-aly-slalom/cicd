# Tasks: MWAA Airflow Platform

**Input**: Design documents from `specs/009-mwaa-airflow-platform/`

**Prerequisites**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/namespace-manifest.md](contracts/namespace-manifest.md), [quickstart.md](quickstart.md)

**Tests**: Not explicitly requested in the specification — test DAGs are part of feature scope (US5), not a separate TDD test suite.

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US5 per spec.md)
- All file paths are relative to the repository root

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: KMS key extensions, namespace manifest directory, and DAG directory skeleton — prerequisites for all subsequent phases.

- [X] T001 Add `mwaa` (service_principal: `airflow.amazonaws.com`) and `ecr` (service_principal: `ecr.amazonaws.com`) entries to `local.kms_services` in `terraform/locals.tf`
- [X] T002 Create `airflow/mwaa/platform.yaml` namespace manifest with `fargate_enabled: true`, per-environment `sso_roles` (mwaa-platform-dev/test/uat/prod), and per-environment `ci_roles` (InfraBuildRole ARNs) per plan.md §2c and contracts/namespace-manifest.md schema
- [X] T003 [P] Create `airflow/dags/README.md` documenting: namespace DAG directory layout (`airflow/dags/<namespace>/`), ECS operator invocation requirements (MUST specify both App-tier subnet IDs for multi-AZ), Fargate CPU/memory ceiling (4 vCPU / 8 GB max per task), and plugin consumption pattern

**Checkpoint**: KMS entries allow `module.kms["mwaa"]` and `module.kms["ecr"]` to be referenced; manifest directory populated; DAG conventions documented.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core Terraform locals, S3 bucket, security group, and ECS cluster that MUST exist before any user story infrastructure can be built.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T004 Add MWAA sizing locals (`mwaa_environment_class`, `mwaa_max_workers`, `mwaa_min_workers`, `mwaa_schedulers`, `mwaa_log_retention`) with `is_prod_like` gate to `terraform/locals.tf` per plan.md §2a
- [X] T005 Create `terraform/mwaa_namespaces.tf` (new file) with `_mwaa_namespace_files`, `mwaa_namespaces`, and `mwaa_fargate_namespaces` locals using `fileset`/`yamldecode` pattern over `airflow/mwaa/*.yaml` per plan.md §2b
- [X] T006 [P] Add `module.mwaa_s3` (versioning, SSE-KMS via `module.kms["mwaa"]`, lifecycle rules, block public access) and `data.aws_iam_policy_document.mwaa_s3_policy` to `terraform/s3.tf`; the policy document MUST include two `Deny` statements: (1) deny non-KMS uploads (`s3:x-amz-server-side-encryption != aws:kms`), (2) deny all `s3:*` when `aws:SecureTransport = false` (TLS enforcement per constitution §I and spec FR-016) per plan.md §3
- [X] T007 [P] Create `aws_security_group.mwaa` in `terraform/mwaa.tf` (inbound HTTPS/443 from `data.aws_vpc.current.cidr_block`, unrestricted egress with checkov skip annotation) per plan.md §4a
- [X] T008 [P] Create `aws_ecs_cluster.mwaa_fargate` with `containerInsights = "enabled"` in `terraform/ecs_fargate.tf` per plan.md §9a
- [X] T009 [P] Create `.github/scripts/bootstrap-mwaa-s3.sh` that uploads an empty `requirements/requirements.txt` and minimal valid `airflow/plugins/plugins.zip` (empty zip bytes) to the MWAA S3 bucket for a given `$env` parameter; referenced from quickstart.md §Pre-Flight; MUST be run before first `terraform apply` or MWAA will error on missing S3 keys

**Checkpoint**: Foundation ready — all user story phases can now begin.

---

## Phase 3: User Story 1 - Platform Team Provisions MWAA Environment (Priority: P1) 🎯 MVP

**Goal**: A running, correctly configured MWAA environment with observability in all four environments.

**Independent Test**: `aws mwaa get-environment --name "chedaws-edp-mwaa-dev" --query "Environment.Status"` returns `AVAILABLE`; all five CloudWatch alarms in `OK` state per quickstart.md Scenario 1 and Scenario 3.

### Implementation for User Story 1

- [X] T010 [P] [US1] Create `aws_iam_role.mwaa_execution`, `aws_iam_role_policy.mwaa_execution`, and `data.aws_iam_policy_document.mwaa_execution` in `terraform/mwaa.tf` (grants: S3 DAG read, CW Logs write, SQS, KMS decrypt/generate on mwaa+cloudwatch_logs keys, Secrets Manager read on `airflow/*`, SNS publish, `sts:AssumeRole` on `edp-${local.environment}-mwaa-ns-*`) per plan.md §4b
- [X] T011 [P] [US1] Create `terraform/cloudwatch.tf` (new file) with `_mwaa_log_types` local and `aws_cloudwatch_log_group.mwaa` (for_each, names `/chedaws-edp/mwaa/<env>/<type>`, KMS-encrypted with `module.kms["cloudwatch_logs"]`, `mwaa_log_retention`) per plan.md §6a
- [X] T012 [US1] Create `aws_mwaa_environment.airflow` in `terraform/mwaa.tf` (Airflow 3.2.1, `PRIVATE_ONLY`, env-sizing locals, `module.mwaa_s3`, `aws_security_group.mwaa`, `aws_iam_role.mwaa_execution`, Secrets Manager secrets backend config with `__` separator, logging config for all 5 log types, `module.kms["mwaa"]`, `plugins_s3_object_version = null`) per plan.md §5
- [X] T013 [US1] Add `aws_cloudwatch_metric_alarm.mwaa_scheduler_heartbeat` and `aws_cloudwatch_metric_alarm.mwaa_failed_tasks` (both with `alarm_actions` and `ok_actions` to `aws_sns_topic.alerts`) to `terraform/cloudwatch.tf` per plan.md §6b

**Checkpoint**: MWAA environment reaches `AVAILABLE`; scheduler heartbeat and failed task alarms active in all four environments.

---

## Phase 4: User Story 2 - Use-Case Team Onboards a Namespace (Priority: P1)

**Goal**: Self-serve namespace onboarding via manifest YAML with isolated IAM, ECR, Fargate, and SSO bindings.

**Independent Test**: Add `airflow/mwaa/finance.yaml`, run `terraform apply`, verify: `aws_iam_role.mwaa_namespace["finance"]` exists with correct trust; `aws_ecr_repository.mwaa_namespace["finance"]` exists with scan_on_push; namespace S3 prefix isolated by IAM policy per quickstart.md Scenarios 4 and 9.

### Implementation for User Story 2

- [X] T014 [P] [US2] Add `aws_iam_role.mwaa_namespace` (for_each `mwaa_namespaces`, trusts `mwaa_execution` role) and `aws_iam_role_policy.mwaa_namespace_s3` (S3 prefix read/write scoped to `dags/<namespace>/*`, KMS, Secrets Manager `airflow/connections/<namespace>__*`) to `terraform/mwaa_namespaces.tf` per plan.md §7
- [X] T015 [P] [US2] Create `aws_iam_role.fargate_task_execution` (for_each `mwaa_fargate_namespaces`), `aws_iam_role_policy.fargate_task_execution_ecr_logs` (custom least-privilege policy: `ecr:GetAuthorizationToken` on `*`, ECR pull actions scoped to `aws_ecr_repository.mwaa_namespace[each.key].arn` only, CW Logs write scoped to namespace log group ARN — replaces `AmazonECSTaskExecutionRolePolicy` per constitution §I), and `aws_iam_role_policy.fargate_task_execution_kms` (KMS decrypt on cloudwatch_logs + ecr keys) in `terraform/ecs_fargate.tf` per plan.md §9b
- [X] T016 [P] [US2] Create `aws_ecr_repository.mwaa_namespace` (`scan_on_push = true`, KMS via `module.kms["ecr"]`, `MUTABLE`) and `aws_ecr_repository_policy.mwaa_namespace` (pull-only for `fargate_task_execution` role) (for_each `mwaa_fargate_namespaces`) in `terraform/ecr.tf` per plan.md §8
- [X] T017 [P] [US2] Add SSO binding locals (`_mwaa_sso_bindings`) and wire them into the `IDCPermissionSet` trust statement on `aws_iam_role.mwaa_namespace` (resource-based policy — no `aws_ssoadmin_permission_set_inline_policy`); CI pipeline cannot access the IDC org account so SSO access is granted via the role trust policy only per plan.md §7a
- [X] T018 [P] [US2] Add `aws_cloudwatch_log_group.fargate_namespace` (for_each `mwaa_fargate_namespaces`, name `/chedaws-edp/fargate/<namespace>/<env>`, KMS-encrypted, `mwaa_log_retention`) to `terraform/cloudwatch.tf` per plan.md §6c
- [X] T019 [US2] Add `aws_iam_role_policy.mwaa_namespace_fargate` (for_each `mwaa_fargate_namespaces`, `ecs:RunTask/DescribeTasks/StopTask` with `StringEquals aws:ResourceTag/MwaaNamespace` condition, `iam:PassRole` for fargate exec role) and `aws_iam_role_policy.mwaa_namespace_ci_deploy` (for_each where `ci_roles[env]` non-empty, `s3:PutObject/GetObject/DeleteObject` on namespace DAG prefix) to `terraform/mwaa_namespaces.tf` per plan.md §7, §7b
- [X] T020 [US2] Add ECS Fargate CloudWatch alarms (`aws_cloudwatch_metric_alarm.ecs_cpu_utilization`, `aws_cloudwatch_metric_alarm.ecs_memory_utilization`, `aws_cloudwatch_metric_alarm.ecs_running_task_count_anomaly` with `ANOMALY_DETECTION_BAND` metric math) to `terraform/cloudwatch.tf` per plan.md §6d
- [X] T021 [US2] Create `.github/scripts/check-mwaa-decommission.sh` using the corrected three-dot diff range (`"${BASE:-origin/main}...HEAD"`), `python3 -c "yaml.safe_load"` to check `spec.decommission` specifically (avoids false matches on other nesting levels), and merge-base resolution per plan.md §7c and spec FR-026
- [X] T022 [US2] Register `.github/scripts/check-mwaa-decommission.sh` in the CI pipeline configuration file (identify correct file — `.github/workflows/`, `buildspec.yml`, or equivalent): add a step that runs the guard with `BASE=origin/<base-ref>` on any PR touching `airflow/mwaa/*.yaml` files; ensure the step is a **required status check** per plan.md §7d and spec FR-026

**Checkpoint**: Adding a new `airflow/mwaa/<namespace>.yaml` and running `terraform apply` provisions all namespace resources; decommission guard script created and registered as a required CI check.

---

## Phase 5: User Story 3 - Use-Case Team DAG Authenticates to AWS Services (Priority: P2)

**Goal**: Credential-free DAG-to-AWS authentication via namespace IAM role assumption through Secrets Manager-backed Airflow connections.

**Independent Test**: Trigger `platform_e2e_aws_auth` DAG after creating `airflow/connections/platform__aws_default` secret; task succeeds, CloudTrail shows assumed role = `edp-dev-mwaa-ns-platform`, no credentials in task log per quickstart.md Scenario 6.

### Implementation for User Story 3

- [X] T023 [P] [US3] Verify `data.aws_iam_policy_document.mwaa_execution` in `terraform/mwaa.tf` includes `sts:AssumeRole` statement scoped to `arn:aws:iam::${local.aws_account_id}:role/edp-${local.environment}-mwaa-ns-*` (wildcard on namespace suffix); add if missing from T010 (enables Airflow workers to assume namespace roles via `aws_default` connection `role_arn`)
- [X] T024 [US3] Update `airflow/dags/README.md` with namespace AWS connection setup: Secrets Manager secret format (`{"conn_type":"aws","extra":"{\"role_arn\":\"...\"}"}`) at path `airflow/connections/<namespace>__aws_default`, connection ID usage in DAGs (`<namespace>__aws_default`), AwsBaseHook pattern, and note that DAGs MUST NOT contain hardcoded AWS credentials (verified by SC-005 credential scanning in CI)

**Checkpoint**: Platform namespace DAG can call AWS APIs using `platform__aws_default` connection without hardcoded credentials.

---

## Phase 6: User Story 4 - Platform Team Provides Shared Plugins (Priority: P2)

**Goal**: Versioned shared plugins package centrally managed at `airflow/plugins/plugins.zip` and automatically available to all namespaces.

**Independent Test**: Upload `airflow/plugins/plugins.zip` to S3; wait for MWAA to reload; DAG in `platform` namespace successfully imports and uses the plugin without additional setup per spec US4 acceptance criteria.

### Implementation for User Story 4

- [X] T025 [P] [US4] Create `plugins/README.md` documenting shared plugins management: how to build and upload `plugins.zip` to S3 (`airflow/plugins/plugins.zip`), versioning via S3 object versioning, pinning via `plugins_s3_object_version` in `aws_mwaa_environment`, and backwards-compatibility policy per research.md §10

**Checkpoint**: Plugins management process documented; plugin version pinning supported via `plugins_s3_object_version = null` in T012 (updated when pinning a specific version).

---

## Phase 7: User Story 5 - End-to-End Test Using `platform` Namespace (Priority: P1)

**Goal**: Three `platform` namespace DAGs that validate scheduler, AWS authentication, and namespace isolation after every deployment.

**Independent Test**: Trigger all three DAGs in `airflow/dags/platform/` after uploading to S3; all tasks reach `success` within 15 minutes per quickstart.md Scenarios 5–7 and SC-003.

### Implementation for User Story 5

- [X] T026 [P] [US5] Upload canary bootstrap object `dags/canary_namespace_for_isolation_test/.keep` (empty file) to the MWAA S3 bucket as part of `.github/scripts/bootstrap-mwaa-s3.sh` (extend T009 script); this ensures the isolation test gets `AccessDenied` (not `NoSuchKey`) when the `platform` role attempts access to another namespace's prefix
- [X] T027 [P] [US5] Create `dags/platform/e2e_scheduler.py` (BashOperator `echo $(date)`, `schedule=None`, `catchup=False`, `max_active_runs=1`, `tags=["platform","e2e"]`) per plan.md §10
- [X] T028 [P] [US5] Create `dags/platform/e2e_aws_auth.py` (PythonOperator using `AwsBaseHook` with `aws_conn_id="platform__aws_default"`, calls `s3:ListObjectsV2` on `airflow/dags/platform/` prefix, no hardcoded credentials, `schedule=None`, `catchup=False`, `tags=["platform","e2e"]`) per plan.md §10
- [X] T029 [P] [US5] Create `dags/platform/e2e_isolation.py` (PythonOperator using `platform__aws_default` connection, attempts `s3:GetObject` on `dags/canary_namespace_for_isolation_test/.keep`; MUST catch `ClientError` and distinguish `AccessDenied` → log `"Isolation check PASSED: AccessDenied as expected"` + succeed vs `NoSuchKey` or any other exception → fail with message; `schedule=None`, `catchup=False`, `tags=["platform","e2e"]`) per plan.md §10 and quickstart.md Scenario 7
- [X] T030 [US5] Create `aws_ecs_task_definition.platform_e2e` in `terraform/ecs_fargate.tf` (FARGATE, awsvpc, 256 CPU/512 MiB, `e2e-runner` container from `ecr_repository.mwaa_namespace["platform"]`, awslogs driver to `cloudwatch_log_group.fargate_namespace["platform"]`, tag `MwaaNamespace=platform`) per plan.md §9c

**Checkpoint**: All three platform e2e DAGs deployable and executable; canary isolation object bootstrapped; Fargate task definition available for Scenario 8 validation per quickstart.md.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Lint validation, plan review, security scanning, tagging audit, and documentation compliance per constitution requirements.

- [X] T031 [P] Run `tflint` (via `auto/tflint`) against all new/modified Terraform files (`terraform/mwaa.tf`, `terraform/mwaa_namespaces.tf`, `terraform/ecs_fargate.tf`, `terraform/ecr.tf`, `terraform/cloudwatch.tf`, `terraform/s3.tf`, `terraform/locals.tf`) and resolve all warnings per constitution §DW §2
- [X] T032 [P] Run `terraform plan -var="env=dev"` (and `test`, `uat`, `prod`) after all infrastructure phases complete; review and confirm plan output shows no unexpected destroys per constitution §DW §3
- [X] T033 [P] Verify all IAM role resources include non-empty `description` fields, all resource local names are descriptive (no `"this"`, `"main"`, `"default"`), all `aws_cloudwatch_metric_alarm` resources have `alarm_actions` wired to `aws_sns_topic.alerts`, and `aws_sns_topic.alerts` has a `kms_master_key_id` set (constitution §II SNS KMS requirement) per constitution §I and §DW §5
- [X] T034 [P] Verify `providers.tf` `default_tags` block contains all four required cost allocation tags: `Environment`, `Project`, `Owner`, `CostCentre` (spec FR-014, SC-008, constitution §V); add any missing tags
- [X] T035 [P] Add CI credential scanning step: run `checkov --directory terraform/` to scan for hardcoded secrets in Terraform resources, and run `gitleaks detect --source airflow/dags/` (or `truffleHog filesystem dags/`) on `dags/` Python files in the CI pipeline; document the scan step in the CI config file per spec SC-005
- [X] T036 [P] Add a CI DAG ID prefix validation step: a script (Python or bash) that scans all `.py` files in `airflow/dags/<namespace>/` and asserts each file's `dag_id` starts with `<namespace>__`; add to CI pipeline and document in `airflow/dags/README.md`; prevents scheduler-level ID collisions across namespaces (spec Assumptions, research.md §14). Later removed - it only ever covered DAGs committed to this repo, and most namespaces deploy straight to S3 from their own CI via `publish-mwaa-artefact`, which this check never saw.
- [X] T037 Update root `README.md` with MWAA Airflow Platform component entry (brief description, environments, link to `specs/009-mwaa-airflow-platform/`) per constitution §DW §8
- [X] T038 Post-apply: validate all five CloudWatch alarms reach `OK` state using scripts in `specs/009-mwaa-airflow-platform/quickstart.md` Scenario 3; confirm MWAA environment status `AVAILABLE` per quickstart.md Scenario 1

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately; T002, T003 are parallel
- **Foundational (Phase 2)**: Depends on T001 (KMS entries) for T006; T004, T005, T006, T007, T008, T009 have no cross-dependencies and can run in parallel once Phase 1 is complete
- **US1 (Phase 3)**: Depends on Foundational; T010 and T011 are parallel; T012 depends on T010 + T006 + T007; T013 depends on T012
- **US2 (Phase 4)**: Depends on Foundational; T014–T018 are parallel; T019 depends on T014 + T015; T020 depends on T008; T021 and T022 are independent
- **US3 (Phase 5)**: Depends on US1 (T010 execution role policy); T023 verifies/updates T010; T024 extends T003's README
- **US4 (Phase 6)**: Depends on US1 S3 bucket (T006); T025 is independent documentation
- **US5 (Phase 7)**: T026 extends T009 script; T027–T029 are parallel Python DAGs; T030 depends on T015 + T016 + T018; requires Phase 4 (US2) completion for platform namespace
- **Polish (Phase 8)**: Depends on all infrastructure and DAG phases complete

### User Story Dependencies

- **US1 (P1)**: No dependency on other stories — implements standalone MWAA environment
- **US2 (P1)**: Can start in parallel with US1 after Foundational; T019/T020 need T008 (ECS cluster)
- **US3 (P2)**: Depends on US1 (MWAA environment with secrets backend) and US2 (namespace IAM roles)
- **US4 (P2)**: Depends on US1 (S3 bucket) only
- **US5 (P1)**: Depends on US2 (platform namespace IAM/ECR/Fargate) and US3 (authentication mechanism)

### Parallel Opportunities Within US2

```
# Launch simultaneously after Phase 2 completes:
T014: terraform/mwaa_namespaces.tf   → namespace IAM roles
T015: terraform/ecs_fargate.tf       → Fargate task execution roles (custom ECR policy)
T016: terraform/ecr.tf               → ECR repositories
T017: terraform/mwaa_namespaces.tf   → SSO bindings  (same file as T014; sequence after T014)
T018: terraform/cloudwatch.tf        → Fargate log groups
T021: .github/scripts/               → decommission guard script

# After T014 + T015 complete:
T019: mwaa_namespace_fargate policy + ci_deploy policy (depends on T014, T015)

# After T008 (ECS cluster):
T020: ECS Fargate alarms (depends on T008)

# Independent:
T022: CI pipeline registration for decommission guard
```

### Parallel Opportunities Within US5

```
# Launch simultaneously after US2 + T009 bootstrap script complete:
T026: extend bootstrap script (.github/scripts/bootstrap-mwaa-s3.sh)
T027: airflow/dags/platform/e2e_scheduler.py
T028: airflow/dags/platform/e2e_aws_auth.py
T029: airflow/dags/platform/e2e_isolation.py

# After T015 + T016 + T018 complete:
T030: terraform/ecs_fargate.tf → platform_e2e task definition
```

---

## Implementation Strategy

### MVP First (US1 Only — 13 tasks)

1. Complete Phase 1: Setup (T001–T003)
2. Complete Phase 2: Foundational (T004–T009) — **CRITICAL: blocks all stories**
3. Complete Phase 3: US1 (T010–T013)
4. **STOP and VALIDATE**: MWAA environment `AVAILABLE`, alarms in `OK` state per quickstart.md Scenarios 1–3
5. Deploy to `dev` and confirm before proceeding to US2

### Incremental Delivery

1. Complete Setup + Foundational → Foundation ready
2. Add US1 (T010–T013) → Test independently → Deploy to `dev` (MVP)
3. Add US2 (T014–T022) → Verify namespace onboarding + decommission guard → Deploy
4. Add US3 (T023–T024) → Verify credential-free auth → Deploy
5. Add US4 (T025) → Verify plugins → Deploy
6. Add US5 (T026–T030) → Trigger e2e test suite → Deploy to all envs

### Parallel Team Strategy

With two engineers after Foundational completes:
- **Engineer A**: US1 (T010–T013) → US5 (T026–T030)
- **Engineer B**: US2 (T014–T022) → US3 (T023–T024) → US4 (T025)

---

## Notes

- **Rollout order**: Phase 1 (KMS) must be applied before Phase 3 (S3 bucket references `module.kms["mwaa"]`). Phase 2 S3 bucket must be applied before Phase 3 MWAA environment. Phase 2 ECS cluster must exist before Phase 4 Fargate IAM policies.
- **Pre-apply bootstrap**: Run `.github/scripts/bootstrap-mwaa-s3.sh` (T009) before the first `terraform apply` — uploads empty `plugins.zip`, `requirements.txt`, and the canary isolation object. MWAA will error on startup if the S3 keys are missing.
- **SSO prerequisite**: Permission sets referenced in `spec.sso_roles` must exist in IAM Identity Center before users can assume namespace roles. Terraform no longer reads or modifies them — no `data.aws_ssoadmin_permission_set` lookup — so a missing permission set won't block `terraform apply`.
- **MWAA provisioning time**: 20–30 minutes per environment. Plan pipeline timeouts accordingly.
- **[P] tasks** = different files, no blocking dependencies between them
- **[Story] label** maps each task to its user story for traceability
- Commit after each phase or logical task group per CLAUDE.md guidance
- Run `tflint` (T031) before raising the PR, not after
- **Task numbering**: T009 (bootstrap script) was added to Phase 2; all subsequent IDs shifted up by one from the original draft
