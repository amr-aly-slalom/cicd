# Implementation Plan: MWAA Airflow Platform

**Branch**: `feat/airflow` | **Date**: 2026-08-03 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/009-mwaa-airflow-platform/spec.md`

---

## Summary

Provision a shared, multi-tenant Apache Airflow platform on AWS MWAA for the Enterprise Data Platform. Each business use-case team is assigned a named namespace with an isolated S3 DAG prefix, a dedicated namespace IAM role for least-privilege AWS service access, and (optionally) Fargate compute capacity and an ECR repository for container images. The platform team manages MWAA infrastructure, shared plugins, observability alarms, and a `platform` namespace used for automated end-to-end tests. Authentication to the Airflow web UI is via AWS IAM Identity Center (SSO); DAG-to-AWS authentication uses namespace IAM role assumption via the Airflow Connections mechanism backed by AWS Secrets Manager.

---

## Technical Context

**Language/Version**: HCL (Terraform ≥ 1.5.0), Python 3.x (end-to-end test DAGs), Airflow 3.2.1 (latest MWAA-supported version in `ap-southeast-2` at time of implementation)

**Primary Dependencies**:
- Terraform AWS provider (`hashicorp/aws ~> 6.0`) — `aws_mwaa_environment`, `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ecr_repository`, `aws_iam_role`, `aws_iam_policy`, `aws_s3_bucket`, `aws_security_group`, `aws_cloudwatch_log_group`, `aws_cloudwatch_metric_alarm`, `aws_secretsmanager_secret`
- `terraform-aws-modules/s3-bucket/aws ~> 5.14.1` — DAG/plugins S3 bucket, same pattern as existing `module.landing_s3`
- Existing `module.kms` (`terraform/modules/kms/`) — new `mwaa` and `ecr` key entries
- Existing `aws_sns_topic.alerts` — all alarms route here
- Existing `data.aws_subnets.app` — MWAA and Fargate run in App-tier subnets

**Storage**: Single shared S3 bucket for DAGs and plugins (`chedaws-edp-mwaa-<env>-<account_id>-<region>`); AWS Secrets Manager for namespace connections and variables

**Testing**: `terraform plan -var="env=<env>"` per workspace; `platform` namespace end-to-end DAGs; `tflint` before PR

**Target Platform**: AWS `ap-southeast-2`; four Terraform workspaces: `dev`, `test`, `uat`, `prod`

**Project Type**: Infrastructure-as-Code (Terraform) + Airflow DAGs (Python)

**Performance Goals**: MWAA environment reaches `AVAILABLE` within 30 minutes of a clean apply; `platform` e2e test suite completes within 15 minutes of trigger

**Constraints**:
- MWAA web server access mode: `PRIVATE_ONLY` — UI accessible only inside VPC
- `dev`/`test`: `mw1.small`, max 5 workers; `uat`/`prod`: `mw1.medium`, max 10 workers
- Fargate ceiling: 4 vCPU / 8 GB per task
- IAM role names ≤ 64 characters

**Scale/Scope**: Initial deployment with `platform` namespace; designed for ≥ 10 use-case namespaces per environment

---

## Constitution Check

*Verified against [Chedaws EDP Infrastructure Constitution](.specify/memory/constitution.md)*

- [x] **Security**: MWAA execution role is least-privilege (S3 DAGs/plugins read, CloudWatch Logs write, Secrets Manager read own prefix, KMS, SNS). Each namespace IAM role is least-privilege and scoped to that namespace's declared AWS resources. No credentials hardcoded — all secrets via AWS Secrets Manager with Airflow Secrets Backend. All IAM roles include descriptions. MWAA deployed `PRIVATE_ONLY`; Security Group restricts HTTPS/443 inbound to VPC CIDR. ECR repositories have `imageScanningConfiguration.scanOnPush = true`. Fargate task execution roles are namespace-scoped and cannot trigger tasks in other namespaces.
- [x] **Observability**: CloudWatch Log Groups for all 5 MWAA log types (DAGProcessing, Scheduler, Task, WebServer, Worker) under `/chedaws-edp/mwaa/<env>/`, KMS-encrypted, retention governed by `local.mwaa_log_retention`. Fargate task logs under `/chedaws-edp/fargate/<namespace>/<env>`. CloudWatch Alarms: MWAA failed task count, scheduler heartbeat (constitution-mandated); ECS CPU, memory, running task anomalies (constitution-mandated for ECS). All alarms active in all 4 environments; all route to `aws_sns_topic.alerts`.
- [x] **Durability**: MWAA DAG/plugins S3 bucket has versioning enabled and `INTELLIGENT_TIERING` lifecycle (DAG prefix: 30-day transition, rationale: infrequent bulk reads with variable access patterns; plugins prefix: same pattern). 90-day expiry on execution artefacts prefix. Terraform state uses existing S3 + DynamoDB backend (unmodified).
- [x] **Fault-Tolerance**: `uat` and `prod` MWAA environments use `schedulers = 3` (HA mode) spanning multiple AZs via the managed service, controlled by the `is_prod_like` local. `dev`/`test` use `schedulers = 2`. Fargate tasks run across ≥ 2 App-tier subnets (multi-AZ by subnet configuration); the ECS operator invocation in DAGs MUST specify both App-tier subnet IDs — documented in `airflow/dags/README.md`.
- [x] **Cost Optimisation**: `dev`/`test` use `mw1.small` + max 5 workers; `uat`/`prod` use `mw1.medium` + max 10 workers. All taggable resources carry `Environment`, `Project`, `Owner`, `CostCentre` via provider `default_tags`. S3 lifecycle: `INTELLIGENT_TIERING` for DAG/plugins prefixes (unknown access patterns); 90-day expiry on execution artefacts. Rationale documented in Assumptions section of spec.
- [x] **DRY & Modularity**: All Terraform under `terraform/` (no `terraform-legacy/` edits). No new local modules created — namespace resources (`aws_iam_role`, `aws_ecr_repository`) are provisioned inline via `for_each` over `local.mwaa_namespaces` and `local.mwaa_fargate_namespaces`, both derived from `fileset`/`yamldecode` over `mwaa/*.yaml` manifests. The manifest pattern is consistent with `kafka/producers/` and `s3/`. A module is only warranted when ≥ 2 distinct call sites exist; this feature has one. All resource local names are descriptive and unique within their type. **Note**: all MWAA resources were consolidated into `mwaa.tf` during implementation (see Source Code Layout note below).

**Complexity Tracking**: No violations requiring justification.

---

## Project Structure

### Documentation (this feature)

```text
specs/009-mwaa-airflow-platform/
├── plan.md              ← this file
├── spec.md              ← feature specification
├── research.md          ← Phase 0 decisions and resolved unknowns
├── data-model.md        ← entity model and Terraform variable relationships
├── quickstart.md        ← end-to-end validation scenarios
├── contracts/
│   └── namespace-manifest.md  ← YAML schema for airflow/mwaa/<namespace>.yaml manifests
└── tasks.md             ← implementation tasks (generated by /speckit-tasks)
```

### Source Code Layout

```text
terraform/
├── mwaa.tf                  ← all MWAA resources: environment, S3 bootstrap, security group,
│                               execution role, namespace roles, ECR repos, ECS cluster/task,
│                               CloudWatch log groups and alarms, Secrets Manager variables
├── locals.tf                ← extended with mwaa_* sizing/logging locals
├── kms.tf                   ← unchanged (for_each driven by locals.kms_services)
└── s3.tf                    ← module.mwaa_s3 added (DAG/plugins bucket)

airflow/
├── requirements.txt         ← pip requirements deployed to S3 on every terraform apply
├── plugins/                 ← plugin source files; zipped and deployed by terraform_data bootstrap
│   └── README.md
├── mwaa/
│   └── platform.yaml        ← platform namespace manifest (schema: contracts/namespace-manifest.md)
└── dags/
    ├── platform/
    │   ├── e2e_scheduler.py    ← scheduling heartbeat validation DAG
    │   ├── e2e_aws_auth.py     ← AWS service authentication test DAG
    │   ├── e2e_isolation.py   ← namespace isolation test DAG
    │   └── e2e_fargate.py     ← Fargate data-path smoke test DAG
    └── README.md

.github/scripts/
└── check-mwaa-decommission.sh    ← CI guard: rejects manifest deletion without decommission flag
```

**Structure Decision**: Single-project layout. All MWAA Terraform resources are consolidated in `mwaa.tf` rather than split across multiple files (`mwaa_namespaces.tf`, `ecs_fargate.tf`, `ecr.tf`, `cloudwatch.tf` as originally planned). Rationale: the resources are tightly coupled (namespace roles reference ECR repos, Fargate task definitions reference both; splitting would require cross-file references with no readability gain at the current scale). A future refactor into separate files is tracked as a follow-up. Namespace manifests live in `airflow/mwaa/<namespace>.yaml`, loaded via `fileset`/`yamldecode` in `mwaa.tf` — identical pattern to `kafka/producers/` and `s3/`. DAGs live in `airflow/dags/<namespace>/`. No new local modules (first occurrence; single call site; constitution prohibits single-use modules).

---

## Implementation Phases

### Phase 1 — KMS Extension

**File**: `terraform/locals.tf`

Add one new entry to `local.kms_services` and extend the existing `s3` entry:

```hcl
# New entry for ECR encryption
ecr = {
  service_principals = ["ecr.amazonaws.com"]
}

# Existing s3 entry — extend with both MWAA service principals
s3 = {
  service_principals = ["s3.amazonaws.com", "airflow.amazonaws.com", "airflow-env.amazonaws.com"]
}
```

`module.kms` is `for_each`-driven; adding the `ecr` entry automatically creates `module.kms["ecr"]` (alias `alias/chedaws-edp-ecr-<env>`). No changes to `terraform/kms.tf` required.

**Design decision — shared S3/MWAA KMS key**: The original plan called for a dedicated `module.kms["mwaa"]` key. During implementation it was decided to extend the existing `s3` key with `airflow.amazonaws.com` as a service principal instead. This avoids proliferating keys with overlapping purpose; the `s3` key already encrypts all S3-tier storage in the account, and MWAA's S3 bucket and environment metadata fall naturally into that tier. Per-service isolation is enforced at the IAM policy level (scoped resource ARNs and conditions). See [data-model.md §2.3](data-model.md#23-kms-key-assignments) for the full key assignment table.

---

### Phase 2 — MWAA Sizing Locals and Namespace Registry

#### 2a — Sizing Locals

**File**: `terraform/locals.tf`

Add the following to the `locals` block:

```hcl
mwaa_environment_class = local.is_prod_like ? "mw1.medium" : "mw1.small"
mwaa_max_workers       = local.is_prod_like ? 10 : 5
mwaa_min_workers       = local.is_prod_like ? 2 : 1
mwaa_schedulers        = local.is_prod_like ? 3 : 2
mwaa_log_retention     = local.is_prod_like ? 30 : 7
```

#### 2b — Namespace Registry (manifest-driven)

**File**: `terraform/mwaa_namespaces.tf` (new file — namespace locals at the top)

Namespace onboarding uses the same `fileset`/`yamldecode` pattern as `kafka/producers/` and `s3/`. The `airflow/mwaa/` directory at the repo root holds one YAML file per namespace (schema: [contracts/namespace-manifest.md](contracts/namespace-manifest.md)).

```hcl
locals {
  _mwaa_namespace_files = {
    for f in fileset("${path.root}/../airflow/mwaa", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../airflow/mwaa/${f}"))
  }

  # Exclude decommissioned namespaces so Terraform destroys their resources on apply.
  mwaa_namespaces = {
    for k, v in local._mwaa_namespace_files :
    k => v if !try(v.spec.decommission, false)
  }

  # Namespaces with Fargate compute enabled.
  mwaa_fargate_namespaces = {
    for k, v in local.mwaa_namespaces : k => v if v.spec.fargate_enabled
  }
}
```

**Adding a namespace** = create `airflow/mwaa/<namespace>.yaml` and run `terraform apply`. No `locals.tf` edit required.

#### 2c — Initial Platform Namespace Manifest

**File**: `airflow/mwaa/platform.yaml`

```yaml
apiVersion: mwaa.chedaws.io/v1
kind: Namespace
metadata:
  name: platform
  owner: platform-team
  description: Platform team end-to-end testing namespace

spec:
  fargate_enabled: true

  sso_roles:
    dev:  chedaws-ndp-admin
    test: chedaws-ndp-admin
    uat:  chedaws-ndp-admin
    prod: chedaws-ndp-admin

  ci_roles:
    dev:
      - arn:aws:iam::381491832813:role/chedaws-edp-ci-runner
    test:
      - arn:aws:iam::381491832813:role/chedaws-edp-ci-runner
```

---

### Phase 3 — DAG/Plugins S3 Bucket

**File**: `terraform/s3.tf`

Add a new S3 bucket module block for MWAA DAG and plugin storage. Pattern mirrors `module.landing_s3`:

```hcl
module "mwaa_s3" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.14.1"

  bucket = "chedaws-edp-mwaa-${local.environment}-${local.aws_account_id}-${data.aws_region.current.region}"

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = module.kms["s3"].key_arn
      }
      bucket_key_enabled = true
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle_rule = [
    {
      id      = "dags-intelligent-tiering"
      enabled = true
      prefix  = "dags/"
      transition = [{ days = 30, storage_class = "INTELLIGENT_TIERING" }]
      noncurrent_version_expiration = { days = 30 }
    },
    {
      id      = "plugins-intelligent-tiering"
      enabled = true
      prefix  = "plugins/"
      transition = [{ days = 30, storage_class = "INTELLIGENT_TIERING" }]
      noncurrent_version_expiration = { days = 30 }
    },
    {
      id      = "execution-artefacts-expiry"
      enabled = true
      prefix  = "tmp/"
      expiration = { days = 90 }
    }
  ]

  attach_policy = true
  policy        = data.aws_iam_policy_document.mwaa_s3_policy.json

  tags = { Name = "chedaws-edp-mwaa-${local.environment}" }
}
```

Add `data.aws_iam_policy_document.mwaa_s3_policy` to `terraform/s3.tf` with two `Deny` statements:
1. **Deny non-KMS uploads** — rejects `s3:PutObject` where `s3:x-amz-server-side-encryption` is not `aws:kms` (same pattern as existing `data.aws_iam_policy_document.s3_policy`).
2. **Deny non-TLS requests** — rejects all `s3:*` where `aws:SecureTransport` is `false`; enforces encryption in transit per constitution §I.

```hcl
data "aws_iam_policy_document" "mwaa_s3_policy" {
  statement {
    sid     = "DenyNonKMSUploads"
    effect  = "Deny"
    principals { type = "*"; identifiers = ["*"] }
    actions   = ["s3:PutObject"]
    resources = ["${module.mwaa_s3.s3_bucket_arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid     = "DenyNonTLSRequests"
    effect  = "Deny"
    principals { type = "*"; identifiers = ["*"] }
    actions   = ["s3:*"]
    resources = [
      module.mwaa_s3.s3_bucket_arn,
      "${module.mwaa_s3.s3_bucket_arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
```

**Namespace isolation model**: Namespace-level access isolation relies on positive-grant IAM — each namespace IAM role is granted read/write only to its own `dags/<namespace>/` S3 prefix. The bucket policy does not add per-namespace DENY conditions; the IAM positive-grant model is the primary isolation control, supplemented by the bucket policy's encryption enforcement. This is consistent with AWS-recommended MWAA multi-tenancy patterns and avoids bucket-policy complexity from dynamic per-namespace DENY generation.

---

### Phase 4 — MWAA Security Group and IAM Execution Role

**File**: `terraform/mwaa.tf`

#### 4a — Security Group

```hcl
resource "aws_security_group" "mwaa" {
  name        = "chedaws-edp-mwaa-sg-${local.environment}"
  description = "Security group for MWAA environment chedaws-edp-mwaa-${local.environment}"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.current.cidr_block]
    description = "HTTPS from VPC (Airflow web UI and API)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (MWAA managed service requires unrestricted egress)"
  }

  tags = { Name = "chedaws-edp-mwaa-sg-${local.environment}" }
}
```

#### 4b — MWAA Execution Role

```hcl
resource "aws_iam_role" "mwaa_execution" {
  name        = "edp-${local.environment}-mwaa-execution"
  description = "Execution role for MWAA environment in ${local.environment}; grants S3 DAG read, CloudWatch Logs write, Secrets Manager read, and KMS access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["airflow.amazonaws.com", "airflow-env.amazonaws.com"] }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = local.aws_account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "mwaa_execution" {
  name   = "edp-${local.environment}-mwaa-execution-policy"
  role   = aws_iam_role.mwaa_execution.id
  policy = data.aws_iam_policy_document.mwaa_execution.json
}
```

The `aws_iam_policy_document.mwaa_execution` grants:
- `s3:GetObject`, `s3:GetObjectVersion`, `s3:ListBucket`, `s3:GetBucketLocation`, `s3:GetBucketVersioning`, `s3:GetBucketPublicAccessBlock`, `s3:GetEncryptionConfiguration` on `module.mwaa_s3.s3_bucket_arn`; `s3:GetAccountPublicAccessBlock` on `*` (account-level API required by MWAA `CreateEnvironment` validation)
- `logs:CreateLogStream`, `logs:CreateLogGroup`, `logs:PutLogEvents`, `logs:GetLogEvents`, `logs:GetLogRecord`, `logs:GetLogGroupFields`, `logs:GetQueryResults`, `logs:DescribeLogGroups` scoped to `/chedaws-edp/mwaa/${local.environment}*`
- `cloudwatch:PutMetricData` on `AWS/MWAA` namespace
- `sqs:ChangeMessageVisibility`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `sqs:GetQueueUrl`, `sqs:ReceiveMessage`, `sqs:SendMessage` on MWAA-managed SQS queues (`arn:aws:sqs:*:*:airflow-celery-*`)
- `kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKey*`, `kms:Encrypt` on `module.kms["s3"].key_arn` and `module.kms["cloudwatch_logs"].key_arn`
- `secretsmanager:GetSecretValue`, `secretsmanager:DescribeSecret` on `arn:aws:secretsmanager:*:*:secret:airflow/*`
- `sns:Publish` on `aws_sns_topic.alerts.arn`

---

### Phase 5 — MWAA Environment

**File**: `terraform/mwaa.tf` (continued)

```hcl
resource "aws_mwaa_environment" "airflow" {
  name              = "chedaws-edp-mwaa-${local.environment}"
  airflow_version   = "3.2.1"
  environment_class = local.mwaa_environment_class
  max_workers       = local.mwaa_max_workers
  min_workers       = local.mwaa_min_workers
  schedulers        = local.mwaa_schedulers

  execution_role_arn = aws_iam_role.mwaa_execution.arn

  source_bucket_arn  = module.mwaa_s3.s3_bucket_arn
  dag_s3_path        = "dags/"
  plugins_s3_path    = "plugins/plugins.zip"
  requirements_s3_path = "requirements/requirements.txt"

  webserver_access_mode = "PRIVATE_ONLY"

  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    subnet_ids         = slice(tolist(data.aws_subnets.app.ids), 0, 2)
  }

  logging_configuration {
    dag_processing_logs { enabled = true; log_level = "INFO" }
    scheduler_logs      { enabled = true; log_level = "INFO" }
    task_logs           { enabled = true; log_level = "INFO" }
    webserver_logs      { enabled = true; log_level = "WARNING" }
    worker_logs         { enabled = true; log_level = "INFO" }
  }

  airflow_configuration_options = {
    "secrets.backend"                = "airflow.providers.amazon.aws.secrets.secrets_manager.SecretsManagerBackend"
    "secrets.backend_kwargs"         = jsonencode({
      connections_prefix = "airflow/connections"
      variables_prefix   = "airflow/variables"
      sep                = "__"
    })
    "core.dags_are_paused_at_creation" = "True"
    "core.load_examples"               = "False"
  }

  kms_key = module.kms["s3"].key_arn

  tags = { Name = "chedaws-edp-mwaa-${local.environment}" }
}
```

---

### Phase 6 — CloudWatch Log Groups and Alarms

**File**: `terraform/cloudwatch.tf` (new file)

#### 6a — MWAA Log Groups

Five log groups, one per MWAA log type:

```hcl
locals {
  _mwaa_log_types = ["DAGProcessing", "Scheduler", "Task", "WebServer", "Worker"]
}

resource "aws_cloudwatch_log_group" "mwaa" {
  for_each = toset(local._mwaa_log_types)

  name              = "/chedaws-edp/mwaa/${local.environment}/${lower(each.key)}"
  retention_in_days = local.mwaa_log_retention
  kms_key_id        = module.kms["cloudwatch_logs"].key_arn

  tags = { Name = "/chedaws-edp/mwaa/${local.environment}/${lower(each.key)}" }
}
```

#### 6b — MWAA Alarms (constitution-mandated)

```hcl
resource "aws_cloudwatch_metric_alarm" "mwaa_scheduler_heartbeat" {
  alarm_name          = "chedaws-edp-mwaa-scheduler-heartbeat-${local.environment}"
  alarm_description   = "MWAA scheduler heartbeat has stopped in ${local.environment}"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "SchedulerHeartbeat"
  namespace           = "AmazonMWAA"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"
  dimensions          = { Function = "Scheduler", Environment = aws_mwaa_environment.airflow.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "mwaa_failed_tasks" {
  alarm_name          = "chedaws-edp-mwaa-failed-tasks-${local.environment}"
  alarm_description   = "MWAA task failure count exceeded threshold in ${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "TaskInstanceFailures"
  namespace           = "AmazonMWAA"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  treat_missing_data  = "notBreaching"
  dimensions          = { Environment = aws_mwaa_environment.airflow.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
```

#### 6c — Fargate Log Groups (per namespace, per environment)

```hcl
resource "aws_cloudwatch_log_group" "fargate_namespace" {
  for_each = local.mwaa_fargate_namespaces

  name              = "/chedaws-edp/fargate/${each.key}/${local.environment}"
  retention_in_days = local.mwaa_log_retention
  kms_key_id        = module.kms["cloudwatch_logs"].key_arn

  tags = { Name = "/chedaws-edp/fargate/${each.key}/${local.environment}" }
}
```

#### 6d — ECS/Fargate Alarms (constitution-mandated for ECS)

```hcl
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_utilization" {
  alarm_name          = "chedaws-edp-ecs-mwaa-cpu-utilization-${local.environment}"
  alarm_description   = "ECS Fargate CPU utilisation exceeded 80% in ${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = aws_ecs_cluster.mwaa_fargate.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory_utilization" {
  alarm_name          = "chedaws-edp-ecs-mwaa-memory-utilization-${local.environment}"
  alarm_description   = "ECS Fargate memory utilisation exceeded 80% in ${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  dimensions          = { ClusterName = aws_ecs_cluster.mwaa_fargate.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_running_task_count_anomaly" {
  alarm_name          = "chedaws-edp-ecs-mwaa-running-task-anomaly-${local.environment}"
  alarm_description   = "Anomalous running ECS task count in MWAA Fargate cluster in ${local.environment}"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "ad1"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "RunningTaskCount"
      namespace   = "ECS/ContainerInsights"
      period      = 300
      stat        = "Average"
      dimensions  = { ClusterName = aws_ecs_cluster.mwaa_fargate.name }
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 2)"
    return_data = true
    label       = "RunningTaskCount (expected)"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
```

---

### Phase 7 — Namespace IAM Roles, Secrets Manager, and SSO Bindings

**File**: `terraform/mwaa_namespaces.tf` (continued — resources follow the locals block from Phase 2b)

One IAM role per namespace, scoped to that namespace's permitted resources. All `for_each` expressions consume `local.mwaa_namespaces` and `local.mwaa_fargate_namespaces` (both derived from manifest files).

```hcl
resource "aws_iam_role" "mwaa_namespace" {
  for_each = local.mwaa_namespaces

  name        = "edp-${local.environment}-mwaa-ns-${each.key}"
  description = "Namespace IAM role for MWAA namespace '${each.key}' in ${local.environment}; grants least-privilege access to namespace-scoped resources"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.mwaa_execution.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "mwaa_namespace_s3" {
  for_each = local.mwaa_namespaces

  name = "edp-${local.environment}-mwaa-ns-${each.key}-s3"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DAGPrefixReadWrite"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
        Resource = [
          "${module.mwaa_s3.s3_bucket_arn}/dags/${each.key}/*",
          module.mwaa_s3.s3_bucket_arn,
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt", "kms:DescribeKey"]
        Resource = module.kms["s3"].key_arn
      },
      {
        Sid    = "SecretsManagerReadOwn"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:aws:secretsmanager:*:${local.aws_account_id}:secret:airflow/connections/${each.key}__*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "mwaa_namespace_fargate" {
  for_each = local.mwaa_fargate_namespaces

  name = "edp-${local.environment}-mwaa-ns-${each.key}-fargate"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "RunNamespaceTasksOnly"
      Effect = "Allow"
      Action = ["ecs:RunTask", "ecs:DescribeTasks", "ecs:StopTask"]
      Resource = "*"
      Condition = {
        ArnLike = {
          "ecs:cluster" = aws_ecs_cluster.mwaa_fargate.arn
        }
        StringEquals = {
          "aws:ResourceTag/MwaaNamespace" = each.key
        }
      }
    },
    {
      Sid    = "PassTaskExecutionRole"
      Effect = "Allow"
      Action = "iam:PassRole"
      Resource = aws_iam_role.fargate_task_execution[each.key].arn
    }]
  })
}
```

#### 7a — SSO IAM Trust Bindings (FR-018)

**File**: `terraform/mwaa.tf` (continued)

Each namespace manifest declares a per-environment SSO permission set name in `spec.sso_roles`. The value must be the **exact name of a pre-existing permission set** in IAM Identity Center — this project does not provision or name permission sets; they are managed externally by the identity team. Access is granted via a **resource-based policy** (the namespace IAM role's trust policy) rather than an identity-based inline policy on the permission set. This approach avoids calling the SSO Admin API in the IAM Identity Center organisation account, which the CI pipeline cannot access.

The `_mwaa_sso_bindings` local builds a flat map of namespace → permission set name for the current environment. The trust policy on `aws_iam_role.mwaa_namespace` then includes an `IDCPermissionSet` statement that allows any role whose ARN matches the `AWSReservedSSO_<permission-set-name>_*` pattern to assume the namespace role:

```hcl
# Flat map of {namespace}-{env} entries for the current environment only.
locals {
  _mwaa_sso_bindings = {
    for k, v in local.mwaa_namespaces :
    k => try(v.spec.sso_roles[local.environment], null)
    if try(v.spec.sso_roles[local.environment], null) != null
  }
}
```

The trust policy on `aws_iam_role.mwaa_namespace` (see Phase 7 above) includes:

```hcl
try(local._mwaa_sso_bindings[each.key], null) != null ? [{
  Sid       = "IDCPermissionSet"
  Effect    = "Allow"
  Principal = { AWS = "arn:aws:iam::${local.aws_account_id}:root" }
  Action    = "sts:AssumeRole"
  Condition = {
    ArnLike = {
      "aws:PrincipalArn" = "arn:aws:iam::${local.aws_account_id}:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_${local._mwaa_sso_bindings[each.key]}_*"
    }
  }
}] : []
```

No `aws_ssoadmin_permission_set_inline_policy` is provisioned. The permission set itself needs no changes — the namespace role trust policy is the sole grant. No manual console steps are required after `terraform apply`.

#### 7b — CI IAM Role Trust (FR-018, DAG deployment)

**File**: `terraform/mwaa_namespaces.tf` (continued)

Namespace manifests declare per-environment `ci_roles`. These roles are granted `s3:PutObject` on the namespace DAG prefix so CI pipelines can deploy DAGs without going via the MWAA execution role.

```hcl
resource "aws_iam_role_policy" "mwaa_namespace_ci_deploy" {
  for_each = {
    for k, v in local.mwaa_namespaces :
    k => v if length(try(v.spec.ci_roles[local.environment], [])) > 0
  }

  name = "edp-${local.environment}-mwaa-ns-${each.key}-ci-deploy"
  role = aws_iam_role.mwaa_namespace[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CIDeployDAGs"
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${module.mwaa_s3.s3_bucket_arn}/dags/${each.key}/*"
    }]
  })
}
```

The CI role ARNs are added to the S3 bucket policy (in `s3.tf`) as trusted principals for the namespace prefix — they can write DAG files but cannot read other namespaces' prefixes.

#### 7c — Decommission Guard (FR-026)

**File**: `.github/scripts/check-mwaa-decommission.sh` (new file)

A CI script that enforces the two-phase decommission rule. It runs as a pre-merge check on any PR that deletes files matching `airflow/mwaa/*.yaml`.

```bash
#!/usr/bin/env bash
# Rejects deletion of airflow/mwaa/*.yaml manifests whose last committed state
# did not have spec.decommission set to true.
# Uses three-dot diff against the merge base so ALL commits in the PR are checked,
# not only the tip commit (prevents bypassing the guard with a multi-commit PR).
set -euo pipefail

BASE=${1:-origin/main}

deleted=$(git diff --name-only --diff-filter=D "${BASE}...HEAD" | grep '^airflow/mwaa/.*\.yaml$' || true)
[ -z "$deleted" ] && exit 0

for f in $deleted; do
  # Read the last committed version using the merge-base commit for accuracy.
  merge_base=$(git merge-base HEAD "${BASE}")
  last_state=$(git show "${merge_base}:${f}" 2>/dev/null || true)
  if [ -z "$last_state" ]; then
    echo "ERROR: Could not read last committed state of $f."
    exit 1
  fi
  # Use python to parse YAML and check spec.decommission specifically,
  # avoiding false matches on decommission fields at other nesting levels.
  decommission_flag=$(echo "$last_state" | python3 -c "
import sys, yaml
doc = yaml.safe_load(sys.stdin)
val = (doc or {}).get('spec', {}).get('decommission', False)
print('true' if val is True else 'false')
" 2>/dev/null || echo "false")
  if [ "$decommission_flag" != "true" ]; then
    echo "ERROR: $f was deleted without spec.decommission: true in its last committed state."
    echo "       Set spec.decommission: true, commit, apply Terraform to destroy resources,"
    echo "       then delete the manifest file."
    exit 1
  fi
done
echo "Decommission guard: all deleted MWAA namespace manifests are correctly flagged."
```

This script is invoked in CI (e.g., as a step in the PR pipeline). The condition `--diff-filter=D` targets only deletions; modifications and additions pass through. The `BASE` argument defaults to `origin/main`; override for other base branches (e.g., `origin/develop`).

#### 7d — CI Pipeline Registration for Decommission Guard (FR-026)

**File**: CI pipeline configuration (e.g., `.github/workflows/pr-checks.yml` or equivalent)

Add a CI step that runs `check-mwaa-decommission.sh` on every PR. The step must run before merge and must be conditioned on files matching `airflow/mwaa/*.yaml` being changed. Example for GitHub Actions:

```yaml
- name: MWAA namespace decommission guard
  if: |
    contains(github.event.pull_request.changed_files, 'airflow/mwaa/') ||
    steps.changed-files.outputs.any_changed == 'true'
  run: bash .github/scripts/check-mwaa-decommission.sh origin/${{ github.base_ref }}
```

The `BASE` argument must be `origin/<base-ref>` so the three-dot diff range resolves correctly against the remote tracking branch. The step must be a **required status check** on the target branch to prevent bypassing.

**Note**: The exact CI configuration file path depends on the current CI tooling in this repository. Identify the correct file during implementation (T020-reg) and register the guard step there.

---

### Phase 8 — ECR Repositories

**File**: `terraform/ecr.tf`

One ECR repository per namespace (only provisioned where `fargate_enabled = true`):

```hcl
resource "aws_ecr_repository" "mwaa_namespace" {
  for_each = local.mwaa_fargate_namespaces

  name                 = "chedaws-edp-mwaa-${each.key}-${local.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = module.kms["ecr"].key_arn
  }

  tags = { Name = "chedaws-edp-mwaa-${each.key}-${local.environment}", MwaaNamespace = each.key }
}

resource "aws_ecr_repository_policy" "mwaa_namespace" {
  for_each = local.mwaa_fargate_namespaces

  repository = aws_ecr_repository.mwaa_namespace[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "NamespaceRolePullOnly"
      Effect = "Allow"
      Principal = { AWS = aws_iam_role.fargate_task_execution[each.key].arn }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability"
      ]
    }]
  })
}
```

---

### Phase 9 — ECS Cluster and Fargate Task Execution Roles

**File**: `terraform/ecs_fargate.tf`

#### 9a — ECS Cluster

```hcl
resource "aws_ecs_cluster" "mwaa_fargate" {
  name = "chedaws-edp-mwaa-fargate-${local.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = { Name = "chedaws-edp-mwaa-fargate-${local.environment}" }
}
```

#### 9b — Fargate Task Execution Role (per namespace)

```hcl
resource "aws_iam_role" "fargate_task_execution" {
  for_each = local.mwaa_fargate_namespaces

  name        = "edp-${local.environment}-fargate-exec-${each.key}"
  description = "Fargate task execution role for namespace '${each.key}' in ${local.environment}; grants ECR pull from namespace repo and CloudWatch Logs write"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "fargate_task_execution_ecr_logs" {
  for_each = local.mwaa_fargate_namespaces

  name = "edp-${local.environment}-fargate-exec-${each.key}-ecr-logs"
  role = aws_iam_role.fargate_task_execution[each.key].id

  # Custom least-privilege policy replacing AmazonECSTaskExecutionRolePolicy.
  # Scopes ECR pull to this namespace's repository only; avoids the managed
  # policy's account-wide ecr:BatchGetImage grant (constitution §I).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuthToken"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        # GetAuthorizationToken does not support resource-level permissions.
        Resource = "*"
      },
      {
        Sid    = "ECRPullNamespaceRepo"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = aws_ecr_repository.mwaa_namespace[each.key].arn
      },
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.fargate_namespace[each.key].arn}:*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "fargate_task_execution_kms" {
  for_each = local.mwaa_fargate_namespaces

  name = "edp-${local.environment}-fargate-exec-${each.key}-kms"
  role = aws_iam_role.fargate_task_execution[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      Resource = [module.kms["cloudwatch_logs"].key_arn, module.kms["ecr"].key_arn]
    }]
  })
}
```

#### 9c — Platform Namespace Fargate Task Definitions

**`platform_e2e`** — full e2e runner using the namespace ECR image (build and push required):

```hcl
resource "aws_ecs_task_definition" "platform_e2e" {
  family                   = "chedaws-edp-mwaa-platform-e2e-${local.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.fargate_task_execution["platform"].arn

  container_definitions = jsonencode([{
    name      = "e2e-runner"
    image     = "${aws_ecr_repository.mwaa_namespace["platform"].repository_url}:latest"
    essential = true
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fargate_namespace["platform"].name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "e2e"
      }
    }
  }])

  tags = { Name = "chedaws-edp-mwaa-platform-e2e-${local.environment}", MwaaNamespace = "platform" }
}
```

**`platform_e2e_smoke`** — lightweight smoke test using the public Alpine image; no custom image build required. Used by `platform_e2e_fargate` to verify the Fargate data path end-to-end (IAM, networking, log delivery) without any image build step:

```hcl
resource "aws_ecs_task_definition" "platform_e2e_smoke" {
  family                   = "chedaws-edp-mwaa-platform-smoke-${local.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.fargate_task_execution["platform"].arn

  container_definitions = jsonencode([{
    name      = "smoke"
    image     = "public.ecr.aws/docker/library/alpine:latest"
    essential = true
    command   = ["sh", "-c", "echo Fargate smoke test passed at $(date -u +%Y-%m-%dT%H:%M:%SZ) && exit 0"]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.fargate_namespace["platform"].name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "smoke"
      }
    }
  }])

  tags = { Name = "chedaws-edp-mwaa-platform-smoke-${local.environment}", MwaaNamespace = "platform" }
}
```

The `fargate_task_execution` role is extended with `ecr-public:GetAuthorizationToken` and `sts:GetServiceBearerToken` (both `Resource = "*"`) to permit pulling from Public ECR. These actions do not support resource-level constraints.

---

### Phase 10 — End-to-End Test DAGs

**Directory**: `airflow/dags/platform/`

Four Python DAGs for the `platform` namespace.

All DAGs use the Airflow 3.x `@dag` decorator pattern (not the legacy `with DAG(...)` context manager).

#### `e2e_scheduler.py`
Validates the scheduler is alive by running a single `BashOperator` that echoes `{{ ts }}` (Jinja-templated execution timestamp) and exits 0. If the DAG completes `success`, the scheduler and worker are functional.

#### `e2e_aws_auth.py`
Uses `AwsBaseHook` via a `@task`-decorated `PythonOperator` to authenticate with AWS via the `platform__aws_default` connection (namespace IAM role), then calls `s3:ListObjectsV2` on the `platform` DAG prefix. Verifies credential-free authentication. Reads the bucket name from the `mwaa_s3_bucket` Airflow Variable (provisioned by Terraform via `aws_secretsmanager_secret.airflow_var_mwaa_s3_bucket`).

#### `e2e_isolation.py`
Attempts to `s3:GetObject` from `dags/canary_namespace_for_isolation_test/.keep` (bootstrapped by `bootstrap-mwaa-s3.sh`) using the `platform` IAM role. The task expects `AccessDenied`; any other outcome is a failure. Also reads the bucket name from `mwaa_s3_bucket`.

#### `e2e_fargate.py`
Submits the `platform_e2e_smoke` Fargate task (Alpine `echo` container, no custom image required) to the ECS cluster via `EcsRunTaskOperator`. Verifies the full Fargate data path: namespace IAM role can call `ecs:RunTask`, networking reaches Public ECR for the image pull, and CloudWatch Logs receives the container output. All cluster, task-definition, subnet, and security-group values are resolved at runtime from Terraform-provisioned Airflow Variables — no hardcoded infrastructure identifiers. Runs every 15 minutes (less frequent than the other e2e DAGs to keep Fargate costs low).

All four DAGs set:
- `catchup = False`
- `max_active_runs = 1`
- `tags = ["platform", "e2e"]`

Scheduler/auth/isolation DAGs run on `*/5 * * * *`; the Fargate DAG runs on `*/15 * * * *`.

**Note**: The original plan specified `schedule_interval = None` (manual trigger only). This was revised during implementation to a `*/5 * * * *` schedule to provide a continuous ambient health signal for the platform team. The trade-off is accumulated DAG run history in dev/test; this is acceptable given `max_active_runs = 1` and the 7-day log retention in non-prod environments.

---

## Key Design Decisions (from research.md)

| Decision | Choice | Rationale |
|---|---|---|
| MWAA web server access | `PRIVATE_ONLY` | Spec FR-017; no public endpoint |
| DAG bucket scope | Single shared bucket, per-namespace S3 prefix `dags/<namespace>/`; isolation via positive-grant IAM (namespace roles scoped to own prefix only); `s3:ListBucket` granted on bucket root (no prefix condition) | Spec FR-004; `ListBucket` on root is required for MWAA DAG discovery; object-level access (not listing visibility) is the isolation boundary — see [data-model.md §5](data-model.md#5-s3-iam-access-design) |
| Namespace IAM trust | Execution role → `sts:AssumeRole` → namespace role; CI runners assume a separate `mwaa_namespace_ci` role (S3-only) | Airflow task instances assume namespace role via Connections; CI runners must not reach Secrets Manager, so they get a dedicated S3-only role that cannot access namespace connections |
| Secrets backend | AWS Secrets Manager with Airflow Secrets Backend; path `airflow/connections/<namespace>__<conn_id>` | Spec clarification; native MWAA integration; namespace prefix in secret name enforces isolation |
| Airflow version | `3.2.1` (latest MWAA-supported in `ap-southeast-2`) | Latest stable; ECS operator included in `apache-airflow-providers-amazon` |
| Environment sizing | `mw1.small`/5 workers (dev/test), `mw1.medium`/10 workers (uat/prod) | Spec clarification; cost optimisation §V |
| HA mode | `schedulers = 3` in `uat`/`prod` (both covered by `is_prod_like`); `schedulers = 2` in `dev`/`test` | Spec FR-002; constitution §IV; spec clarification confirmed `uat` uses HA mode; counts raised post-implementation |
| Fargate isolation | IAM condition `aws:ResourceTag/MwaaNamespace = <namespace>` on `ecs:RunTask` | Spec FR-022; tag-based enforcement prevents cross-namespace task triggering |
| ECR per namespace | `chedaws-edp-mwaa-<namespace>-<env>` | Spec FR-023; repo policy restricts pull to namespace execution role only |
| Fargate ceiling enforcement | Document 4 vCPU / 8 GB ceiling in `airflow/dags/README.md` and enforce via a CI tflint custom rule (or checkov check) that rejects `aws_ecs_task_definition` resources with `cpu > 4096` or `memory > 8192` | SCP is out of scope; CI lint is the enforcement mechanism for platform-provisioned task definitions (FR-024 is a governance ceiling, not a hard IAM limit) |
| KMS keys | `ecr` entry added to `local.kms_services`; MWAA S3 bucket and environment use the existing `s3` key (extended with both `airflow.amazonaws.com` and `airflow-env.amazonaws.com` service principals) | A dedicated `mwaa` key was originally planned but revised: the `s3` key already covers all S3-tier storage. Both MWAA service principals are required: `airflow-env.amazonaws.com` is needed by `CreateEnvironment`; `airflow.amazonaws.com` is retained for compatibility. Per-service isolation is enforced at the IAM policy level. |
| CloudWatch Log Groups | 5 MWAA log types + 1 per Fargate-enabled namespace | All under `/chedaws-edp/mwaa/<env>/` and `/chedaws-edp/fargate/<namespace>/<env>` per constitution §II |
| ECS cluster | Single `chedaws-edp-mwaa-fargate-<env>` with Container Insights | One cluster per env; all namespace Fargate tasks share the cluster; container insights enables ECS alarms |
| Namespace registry | `fileset`/`yamldecode` over `airflow/mwaa/*.yaml` | Mirrors `kafka/producers/` and `s3/` patterns; adding a namespace = create one YAML file, no TF edit |
| Module creation | None | All resources inline; single-use patterns; constitution prohibits single-use modules |
| DAG storage lifecycle | `INTELLIGENT_TIERING` at 30d for `dags/` and `plugins/`; 90d expiry on `tmp/` | Mixed/unknown access patterns for DAGs; spec assumption documented |

---

## Rollout Notes

- Phase 1 (KMS) must be applied before phases that reference `module.kms["ecr"]`.
- Phase 3 (S3 bucket) must be applied before Phase 5 (`aws_mwaa_environment` references `source_bucket_arn`).
- Phase 9 (ECS cluster) must exist before Phase 7's fargate IAM policies reference `aws_ecs_cluster.mwaa_fargate.arn`.
- All infrastructure phases (1–9) should be in a single Terraform apply to avoid intermediate broken states.
- No manual pre-apply S3 bootstrap is required. `terraform_data.mwaa_s3_bootstrap` runs automatically after the bucket is created and before `aws_mwaa_environment.airflow` is provisioned. It uploads `requirements.txt`, builds `plugins.zip` from `airflow/plugins/`, seeds the canary isolation prefix, and syncs all DAGs from `airflow/dags/` to S3.
- MWAA environment provisioning takes 20–30 minutes per environment; plan for pipeline timeout accordingly.
- `terraform_data.mwaa_s3_bootstrap` re-runs on every apply where any source file (`airflow/requirements.txt`, `airflow/plugins/**`, `airflow/dags/**/*.py`) has changed, keeping S3 in sync with the repo automatically.
- SSO permission sets referenced in `spec.sso_roles` must exist in IAM Identity Center before users can assume namespace roles; however, Terraform no longer reads or manages them (no `data.aws_ssoadmin_permission_set` lookup). The trust policy on the namespace IAM role uses an `ArnLike` condition matching `AWSReservedSSO_<permission-set-name>_*`, so the permission set simply needs to exist in the same account. No Terraform change is required when adding a new permission set.
- The decommission guard script (`.github/scripts/check-mwaa-decommission.sh`) must be registered as a CI step that runs on any PR touching `airflow/mwaa/*.yaml` files.
