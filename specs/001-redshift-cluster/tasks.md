---
description: "Task list for Redshift Cluster Provisioning"
---

# Tasks: Redshift Cluster Provisioning

**Input**: Design documents from `specs/001-redshift-cluster/`

**Prerequisites**: [plan.md](plan.md) ✅ · [spec.md](spec.md) ✅ · [research.md](research.md) ✅ · [data-model.md](data-model.md) ✅ · [contracts/outputs.md](contracts/outputs.md) ✅

**Tests**: Not requested — no test tasks included.

**Note on cross-phase dependency**: The security group (T016, US3) is a hard prerequisite for the Redshift cluster resource (T009, US1). Code T016 before T009 within the same implementation session even though the phases appear later. All resources are applied together via a single `terraform apply`.

**Plan revision 2026-06-29 (KMS module)**: Three service-specific KMS CMKs (Redshift, SNS, CloudWatch Logs) are provisioned via a reusable `terraform/modules/kms/` module. `kms.tf` invokes it as a single `module "kms"` block with `for_each = local.kms_services`. Phase 7 (T021–T026) creates the module files, the kms.tf caller, and updates all consumer references. T025 updates outputs to use `module.kms[…].key_arn` (total 10 outputs).

**Plan revision 2026-06-29 (file co-location)**: All resources exclusively dedicated to Redshift (Secrets Manager, Security Group, CloudWatch log group and alarms, cluster resources) are co-located in `terraform/redshift.tf`. `terraform/sns.tf` remains separate. T018 completed the consolidation from earlier separate files.

**Plan revision 2026-06-28**: Node types updated from `ra3.xlplus`/`ra3.4xlarge` to `rg.xlarge`/`rg.4xlarge` (Graviton-based, confirmed valid per AWS documentation).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no shared dependencies)
- **[Story]**: User story label for story-phase tasks only
- All paths are relative to the repository root

---

## Phase 1: Setup

**Purpose**: Extend existing Terraform root configuration with the locals and data sources that every Redshift resource depends on.

- [X] T001 Add 5 locals maps to `terraform/locals.tf`: `redshift_node_type` (rg.xlarge for dev/test, rg.4xlarge for uat/prod), `redshift_snapshot_retention` (1/7 days), `redshift_skip_final_snapshot` (true for dev/test), `redshift_log_retention` (7/30/90 days), `redshift_connection_alarm_threshold` (450/900)
- [X] T002 [P] Add 4 subnet data sources to `terraform/data.tf`: `data "aws_subnets" "app"` (filter vpc-id + tag Tier=App), `data "aws_subnets" "db"` (filter vpc-id + tag Tier=Db), `data "aws_subnet" "app"` (for_each on app IDs), `data "aws_subnet" "db"` (for_each on db IDs)

**Checkpoint**: `terraform plan` resolves 4 data sources with no errors.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Resources that block ALL user stories. Must be complete before any story phase can produce a deployable increment.

**⚠️ CRITICAL**: No cluster, secret, or CloudWatch resource can be created until this phase is complete.

- [X] T003 [P] Create `data.aws_iam_policy_document.redshift_kms`, `aws_kms_key.redshift` (description "KMS CMK for Redshift cluster chedaws-edp-`<environment>`", deletion_window_in_days=30, enable_key_rotation=true, policy=data.aws_iam_policy_document.redshift_kms.json), and `aws_kms_alias.redshift` (alias `alias/chedaws-edp-redshift-<environment>`) in `terraform/redshift.tf` *(superseded by T021 — will move to kms.tf with lean policy)*
- [X] T004 [P] Create `random_password.redshift` in `terraform/redshift.tf` — length=32, min_lower=1, min_upper=1, min_numeric=1, min_special=1, override_special=`"!#$%&*()-_=+[]{}<>:?"`

**Checkpoint**: Foundation ready — user story implementation can begin.

---

## Phase 3: User Story 1 - Deploy Cluster Per Environment (Priority: P1) 🎯 MVP

**Goal**: Infrastructure engineer selects a Terraform workspace and runs `terraform apply` to provision a correctly sized, named, encrypted 2-node Redshift cluster with audit logging and CloudWatch monitoring.

**Independent Test**: `terraform workspace select dev && terraform apply` produces cluster `chedaws-edp-dev` with `rg.xlarge` nodes, `encrypted=true`, `publicly_accessible=false`, active CloudWatch log group `/chedaws-edp/redshift/dev`, and 3 active CloudWatch alarms.

**⚠️ Implementation note**: T009 (cluster) depends on T016 (security group, Phase 5). Write T016 before T009.

### Implementation for User Story 1

- [X] T005 [P] [US1] Create `aws_redshift_parameter_group.this` in `terraform/redshift.tf` — name `chedaws-edp-redshift-params-<environment>`, family `redshift-2.0`, parameter `require_ssl = "true"`
- [X] T006 [P] [US1] Create `aws_redshift_subnet_group.this` in `terraform/redshift.tf` — name `chedaws-edp-redshift-subnet-group-<environment>`, subnet_ids = union of `data.aws_subnets.app.ids` and `data.aws_subnets.db.ids`
- [X] T007 [P] [US1] Create `aws_sns_topic.alerts` in `terraform/sns.tf` — name `chedaws-edp-alerts-<environment>`, kms_master_key_id = `aws_kms_key.redshift.arn`, display_name = "EDP Alerts – `<ENVIRONMENT>`" *(reference updated to `module.kms["sns"].key_arn` in T024)*
- [X] T008 [P] [US1] Create `aws_cloudwatch_log_group.redshift` in `terraform/redshift.tf` — name `/chedaws-edp/redshift/<environment>`, retention_in_days = `local.redshift_log_retention`, kms_key_id = `aws_kms_key.redshift.arn` *(reference updated to `module.kms["cloudwatch_logs"].key_arn` in T023)*
- [X] T009 [US1] Create `aws_redshift_cluster.this` in `terraform/redshift.tf` — cluster_identifier=`chedaws-edp-<environment>`, database_name=`edp`, master_username=`edpadmin`, master_password=`random_password.redshift.result`, node_type=`local.redshift_node_type`, number_of_nodes=2, cluster_type=`multi-node`, cluster_subnet_group_name, cluster_parameter_group_name, vpc_security_group_ids=[`aws_security_group.redshift.id`], kms_key_id=`aws_kms_key.redshift.arn`, encrypted=true, publicly_accessible=false, enhanced_vpc_routing=true, port=5439, automated_snapshot_retention_period=`local.redshift_snapshot_retention`, skip_final_snapshot=`local.redshift_skip_final_snapshot`, final_snapshot_identifier=`chedaws-edp-<environment>-final-snapshot` (⚠️ depends on T016)
- [X] T010 [US1] Create `aws_redshift_logging.this` in `terraform/redshift.tf` — cluster_identifier=`aws_redshift_cluster.this.id`, log_destination_type=`"cloudwatch"`, log_exports=`["connectionlog","userlog","useractivitylog"]` (depends on T008, T009)
- [X] T011 [US1] Create 3× `aws_cloudwatch_metric_alarm` in `terraform/redshift.tf` — `chedaws-edp-redshift-cpu-<environment>` (CPUUtilization ≥ 85%, 2 eval periods of 300s), `chedaws-edp-redshift-disk-<environment>` (PercentageDiskSpaceUsed ≥ 80%), `chedaws-edp-redshift-connections-<environment>` (DatabaseConnections ≥ `local.redshift_connection_alarm_threshold`); all alarm_actions and ok_actions = [`aws_sns_topic.alerts.arn`], treat_missing_data=`"notBreaching"`, dimensions ClusterIdentifier=`aws_redshift_cluster.this.cluster_identifier` (depends on T007, T009)
- [X] T012 [P] [US1] Add 6 outputs to `terraform/outputs.tf`: `redshift_cluster_identifier`, `redshift_cluster_endpoint` (dns_name), `redshift_cluster_port`, `redshift_database_name`, `redshift_kms_key_arn` (aws_kms_key.redshift.arn), `redshift_sns_topic_arn`

**Checkpoint**: `terraform apply dev` succeeds. Cluster exists in AWS console with correct node type. CloudWatch log group and 3 alarms are active. 6 of 10 outputs present at this phase (`redshift_master_secret_arn` added in Phase 4; `redshift_security_group_id` added in Phase 5; `sns_kms_key_arn` and `cloudwatch_logs_kms_key_arn` added in Phase 7 T025).

---

## Phase 4: User Story 2 - Secure Credential Management (Priority: P1)

**Goal**: The Redshift master password is generated at provisioning time, stored in Secrets Manager under `/chedaws-edp/<environment>/redshift/master-password` encrypted with the Redshift KMS key, and retrievable without any manual credential handling.

**Independent Test**: `aws secretsmanager get-secret-value --secret-id /chedaws-edp/dev/redshift/master-password` returns the cluster master password within 60 seconds of apply. No plaintext password appears in any `.tf` source file or plan output.

### Implementation for User Story 2

- [X] T013 [P] [US2] Create `aws_secretsmanager_secret.redshift_password` in `terraform/redshift.tf` — name `/chedaws-edp/<environment>/redshift/master-password`, kms_key_id=`aws_kms_key.redshift.arn`, description "Redshift master password for chedaws-edp-`<environment>`", recovery_window_in_days=7
- [X] T014 [US2] Create `aws_secretsmanager_secret_version.redshift_password` in `terraform/redshift.tf` — secret_id=`aws_secretsmanager_secret.redshift_password.id`, secret_string=`random_password.redshift.result` (depends on T013, T004)
- [X] T015 [P] [US2] Add `redshift_master_secret_arn` output to `terraform/outputs.tf` — value=`aws_secretsmanager_secret.redshift_password.arn`, sensitive=false

**Checkpoint**: Secret exists in Secrets Manager with the correct path. `aws secretsmanager get-secret-value` returns the password. Secret is encrypted with the Redshift KMS key.

---

## Phase 5: User Story 3 - Network Connectivity from App and DB Tiers (Priority: P2)

**Goal**: Any host in an App-tier or DB-tier subnet can connect to the Redshift cluster on TCP port 5439. All other inbound traffic is denied.

**Independent Test**: TCP connection from App-tier subnet host to cluster endpoint:5439 succeeds. TCP connection from DB-tier subnet host succeeds. Connection from a subnet without `Tier=App` or `Tier=Db` tag is denied.

**⚠️ Implementation note**: T016 (security group) must be coded before T009 (cluster) in Phase 3, as the cluster resource references `aws_security_group.redshift.id`.

### Implementation for User Story 3

- [X] T016 [US3] Create `aws_security_group.redshift` in `terraform/redshift.tf` — name `chedaws-edp-redshift-sg-<environment>`, description "Security group for chedaws-edp-`<environment>` Redshift cluster", vpc_id=`local.vpc_id`; dynamic ingress block iterating over `[for s in data.aws_subnet.app : s.cidr_block]` with from_port=5439 to_port=5439 protocol=tcp; dynamic ingress block for `[for s in data.aws_subnet.db : s.cidr_block]`; no explicit egress (AWS default allow-all)
- [X] T017 [P] [US3] Add `redshift_security_group_id` output to `terraform/outputs.tf` — value=`aws_security_group.redshift.id`

**Checkpoint**: Security group has exactly N ingress rules (one per App-tier subnet CIDR + one per DB-tier subnet CIDR), all on port 5439 TCP. Connection test per quickstart Scenario 4 passes.

---

## Phase 6: Refactoring — File Co-location

**Purpose**: Consolidated all Redshift-dedicated resources into `terraform/redshift.tf`. Pure file-reorganisation — no resource configuration changes.

- [X] T018 Move all Redshift-dedicated resource blocks into `terraform/redshift.tf` in dependency order: resources from `terraform/kms.tf`, `terraform/secrets.tf`, `terraform/security_groups.tf`, `terraform/cloudwatch.tf`; deleted the 4 vacated files
- [X] T019 Run `cd terraform && terraform validate` — confirmed all resource references resolve correctly after consolidation
- [X] T020 [P] Run `./auto/tflint` from the repository root; resolved all warnings *(pre-KMS module run — re-run required in T027 after Phase 7)*

**Checkpoint**: `terraform/redshift.tf` contains all Redshift-dedicated resources. `terraform/sns.tf` unchanged. `terraform validate` exits 0. `terraform plan` shows zero changes.

---

## Phase 7: KMS CMK Module Creation

**Purpose**: Create the reusable `terraform/modules/kms/` module, the root `kms.tf` caller, and update all consumer references. Implements FR-014 — three service-specific CMKs via module; constitution VI satisfied by 3 `for_each` invocations.

**⚠️ IMPORTANT**: T021 creates the module files. T022 creates kms.tf and adds the `kms_services` local. T023–T025 update consumer resources. Run `terraform validate` (T026) before the Final Phase.

- [X] T021 Create `terraform/modules/kms/` with 4 files: **(a)** `variables.tf` — `variable "service_name"` (string, "Service name used in alias and description, e.g. redshift"), `variable "service_principal"` (string, "AWS service principal granted KMS actions, e.g. redshift.amazonaws.com"), `variable "environment"` (string, "Terraform workspace name, embedded in alias suffix"); **(b)** `main.tf` — `data "aws_caller_identity" "current" {}`, `data "aws_iam_policy_document" "this"` (statement 1: effect Allow, principal `arn:aws:iam::${data.aws_caller_identity.current.account_id}:root`, actions [`kms:*`], resources [`*`]; statement 2: effect Allow, principal `var.service_principal`, actions [`kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey`, `kms:CreateGrant`], resources [`*`]), `aws_kms_key.this` (description=`"KMS CMK for chedaws-edp-${var.service_name}-${var.environment}"`, deletion_window_in_days=30, enable_key_rotation=true, policy=data.aws_iam_policy_document.this.json), `aws_kms_alias.this` (name=`"alias/chedaws-edp-${var.service_name}-${var.environment}"`, target_key_id=`aws_kms_key.this.key_id`); **(c)** `outputs.tf` — `output "key_arn"` (`aws_kms_key.this.arn`), `output "key_id"` (`aws_kms_key.this.id`), `output "alias_arn"` (`aws_kms_alias.this.arn`); **(d)** `README.md` — title "KMS CMK Module", description, Usage example, **"Consumers" section** listing all 3 call sites (`module.kms["redshift"]` → Redshift cluster + SM secret, `module.kms["sns"]` → SNS topic, `module.kms["cloudwatch_logs"]` → CloudWatch Log Group) — required by constitution v1.1.0 VI
- [X] T022 Add `kms_services` local map to `terraform/locals.tf` (redshift → `"redshift.amazonaws.com"`, sns → `"sns.amazonaws.com"`, cloudwatch_logs → `"logs.${data.aws_region.current.name}.amazonaws.com"`); add `data "aws_region" "current" {}` to `terraform/data.tf` if not already present; create `terraform/kms.tf` with a single `module "kms"` block: `for_each = local.kms_services`, `source = "./modules/kms"`, `service_name = each.key`, `service_principal = each.value.service_principal`, `environment = local.environment`
- [X] T023 [P] Update `terraform/redshift.tf`: **(a)** remove the `# ── KMS ──` section (data.aws_iam_policy_document.redshift_kms, aws_kms_key.redshift, aws_kms_alias.redshift — now module-internal); **(b)** update `aws_secretsmanager_secret.redshift_password` `kms_key_id` → `module.kms["redshift"].key_arn`; **(c)** update `aws_cloudwatch_log_group.redshift` `kms_key_id` → `module.kms["cloudwatch_logs"].key_arn`; **(d)** update `aws_redshift_cluster.this` `kms_key_id` → `module.kms["redshift"].key_arn`
- [X] T024 [P] Update `terraform/sns.tf`: change `kms_master_key_id = aws_kms_key.redshift.arn` to `kms_master_key_id = module.kms["sns"].key_arn`
- [X] T025 [P] Update `terraform/outputs.tf`: **(a)** change existing `redshift_kms_key_arn` expression from `aws_kms_key.redshift.arn` to `module.kms["redshift"].key_arn`; **(b)** add `sns_kms_key_arn` output (value=`module.kms["sns"].key_arn`, description="ARN of the KMS CMK used for SNS alert topic encryption at rest"); **(c)** add `cloudwatch_logs_kms_key_arn` output (value=`module.kms["cloudwatch_logs"].key_arn`, description="ARN of the KMS CMK used for CloudWatch Log Group encryption at rest") — brings total outputs to 10
- [X] T026 Run `cd terraform && terraform validate` to confirm all module source references, for_each output references (`module.kms[…].key_arn`), and cross-file references resolve correctly

**Checkpoint**: `terraform/modules/kms/` exists with 4 files including README.md "Consumers" section. `terraform/kms.tf` contains `module "kms"` with `for_each = local.kms_services`. `terraform/redshift.tf` contains no inline KMS resources; all `kms_key_id` expressions use `module.kms[…].key_arn`. `terraform/sns.tf` uses `module.kms["sns"].key_arn`. `terraform/outputs.tf` has 10 outputs. `terraform validate` exits 0.

---

## Final Phase: Polish & Validation

**Purpose**: Lint and plan-validate across all four workspaces after Phase 7 is complete and `terraform validate` passes.

- [X] T027 [P] Re-run `./auto/tflint` from the repository root after Phase 7; resolve all warnings; add `# tflint-ignore` suppression comments with justification for any intentional exceptions (supersedes T020 which ran before Phase 7)
- [ ] T028 [P] Run `terraform workspace select dev && terraform plan`; verify: `node_type = "rg.xlarge"`, cluster `chedaws-edp-dev`, `automated_snapshot_retention_period=1`, log retention 7 days, `skip_final_snapshot=true`, connection alarm threshold 450, 3 KMS keys via `module.kms` with aliases `alias/chedaws-edp-{redshift,sns,cloudwatch}-dev`, all **10 outputs** present
- [ ] T029 [P] Run `terraform workspace select test && terraform plan`; verify: `node_type = "rg.xlarge"`, cluster `chedaws-edp-test`, all resource names carry `-test` suffix (environment isolation from dev confirmed), 3 KMS aliases end in `-test`
- [ ] T030 [P] Run `terraform workspace select uat && terraform plan`; verify: `node_type = "rg.4xlarge"`, `automated_snapshot_retention_period=7`, log retention 30 days, `skip_final_snapshot=false`, connection alarm threshold 900
- [ ] T031 [P] Run `terraform workspace select prod && terraform plan`; verify: `node_type = "rg.4xlarge"`, `automated_snapshot_retention_period=7`, log retention 90 days, `skip_final_snapshot=false`, `final_snapshot_identifier=chedaws-edp-prod-final-snapshot`
- [ ] T032 *(manual — requires AWS credentials and actual apply)* Run `terraform workspace select dev && terraform apply`; after apply completes run `aws secretsmanager get-secret-value --secret-id /chedaws-edp/dev/redshift/master-password --region ap-southeast-2 --query SecretString --output text` and confirm password is returned within 60 seconds (SC-006 verification; see quickstart.md Scenario 3)

---

## Dependencies (Execution Order)

```
T001 ──┐
T002 ──┼──► T006 (subnet group needs subnet IDs)
       └──► T016 (SG needs subnet CIDRs) ──► T009 (cluster needs SG)

T003 ──► T007 (SNS originally referenced redshift key — updated to module.kms["sns"].key_arn in T024)
T003 ──► T008 (CWL log group originally referenced redshift key — updated to module.kms["cloudwatch_logs"].key_arn in T023)
T003 ──► T013 (SM secret originally referenced redshift key — updated to module.kms["redshift"].key_arn in T023)

T004 ──► T009 (cluster needs password)
T004 ──► T014 (SM version needs password)

T005, T006, T007, T008, T016 ──► T009 (all must precede cluster)

T008, T009 ──► T010 (logging needs cluster + log group)
T007, T009 ──► T011 (alarms need SNS + cluster)
T013 ──► T014 (version needs secret)

T001–T020 complete ─► T021 (module files first)
T021 ─► T022 (kms.tf caller needs module to exist)
T022 ─► T023 (redshift.tf refs need module.kms defined)
T022 ─► T024 (sns.tf ref needs module.kms defined)
T022 ─► T025 (outputs.tf refs need module.kms defined)

T023, T024, T025 ─► T026 (validate after all KMS changes applied)
T026 ─► T027–T031 (lint/plan after validate passes)
T031 ─► T032 (manual end-to-end after all plans pass)
```

## Parallel Execution Opportunities

**Phase 1**: T001 ∥ T002 (different files, no deps)

**Phase 2**: T003 ∥ T004 (different files, no deps)

**Phase 3 (pre-cluster)**: T005 ∥ T006 ∥ T007 ∥ T008 (all independent)

**Phase 3 (post-cluster)**: T010 ∥ T011 (different resource blocks)

**Phase 4**: T013 ∥ start T015; T014 must follow T013

**Phase 7**: T021 → T022 → [T023 ∥ T024 ∥ T025] → T026 (module must exist before caller; consumer updates independent)

**Final Phase**: T027 ∥ T028 ∥ T029 ∥ T030 ∥ T031 (after T026 passes; independent workspace checks)

---

**Total tasks**: 32 (T001–T032) | **Complete**: 20 (T001–T020) | **Remaining**: 12 (T021–T032)

**Suggested MVP scope for remaining work**:

1. T021 (create `terraform/modules/kms/` — 4 files)
2. T022 (create `terraform/kms.tf` + add `kms_services` to `locals.tf`)
3. T023 ∥ T024 ∥ T025 (update redshift.tf, sns.tf, outputs.tf — parallel)
4. T026 (`terraform validate`)
5. T027 ∥ T028 ∥ T029 ∥ T030 ∥ T031 (lint + 4× plan — parallel after validate)
6. T032 (manual apply + verify)

**Remaining open tasks**:

| ID | Phase | Description |
|----|-------|-------------|
| T021 | 7 — KMS Module | Create `terraform/modules/kms/` (4 files: variables, main, outputs, README) |
| T022 | 7 — KMS Module | Add `kms_services` to `locals.tf`; create `terraform/kms.tf` caller |
| T023 | 7 — KMS Module | Update `terraform/redshift.tf` — remove KMS section; update 3 `kms_key_id` refs |
| T024 | 7 — KMS Module | Update `terraform/sns.tf` — `kms_master_key_id` → `module.kms["sns"].key_arn` |
| T025 | 7 — KMS Module | Update `terraform/outputs.tf` — update 1 + add 2 KMS ARN outputs (total 10) |
| T026 | 7 — KMS Module | `terraform validate` after Phase 7 |
| T027 | Final | Re-run `./auto/tflint` after Phase 7 |
| T028 | Final | `terraform plan` — dev workspace (verify 3× module.kms, 10 outputs) |
| T029 | Final | `terraform plan` — test workspace (verify env suffix isolation) |
| T030 | Final | `terraform plan` — uat workspace (verify rg.4xlarge, retention=7, no skip) |
| T031 | Final | `terraform plan` — prod workspace (verify log retention=90, final snapshot) |
| T032 | Final | *(manual)* `terraform apply` dev + Secrets Manager verification |
