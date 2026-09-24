# Data Model: MWAA Airflow Platform

**Feature**: 009-mwaa-airflow-platform | **Date**: 2026-08-03

---

## 1. Entity Map

```
MWAA Environment (1)
│  shared across all namespaces per environment
│  uses: DAG/Plugins S3 Bucket, MWAA KMS Key, MWAA Execution Role
│  logs to: 5 CloudWatch Log Groups (/chedaws-edp/mwaa/<env>/*)
│
├── Namespace (1..N)
│   owns:
│   ├── S3 DAG Prefix        dags/<namespace>/  (within shared MWAA S3 bucket)
│   ├── Namespace IAM Role   edp-<env>-mwaa-ns-<namespace>
│   │     assumed by MWAA Execution Role → task-level auth to AWS services
│   │     reads Secrets Manager prefix: airflow/connections/<namespace>__*
│   │
│   └── [if fargate_enabled]
│       ├── ECR Repository       chedaws-edp-mwaa-<namespace>-<env>
│       ├── Fargate Task Exec    edp-<env>-fargate-exec-<namespace>
│       ├── Fargate Task Def(s)  chedaws-edp-mwaa-<namespace>-*-<env>
│       └── CW Log Group         /chedaws-edp/fargate/<namespace>/<env>
│
├── ECS Cluster (1 per env)   chedaws-edp-mwaa-fargate-<env>
│
├── Shared Plugins S3 Prefix  plugins/plugins.zip  (within shared MWAA S3 bucket)
│
└── Platform Alarms (per env)
    ├── SchedulerHeartbeat    → aws_sns_topic.alerts
    ├── TaskInstanceFailures  → aws_sns_topic.alerts
    ├── ECS CPU Utilization   → aws_sns_topic.alerts
    ├── ECS Memory Util       → aws_sns_topic.alerts
    └── ECS RunningTask Anomaly → aws_sns_topic.alerts
```

---

## 2. Terraform Variable Relationships

### 2.1 `local.mwaa_namespaces` — The Namespace Registry

Namespaces are declared as YAML files at `airflow/mwaa/<namespace>.yaml` (schema: [contracts/namespace-manifest.md](contracts/namespace-manifest.md)). Terraform loads them via `fileset`/`yamldecode` in `mwaa.tf`:

```hcl
locals {
  _mwaa_namespace_files = {
    for f in fileset("${path.root}/../airflow/mwaa", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../airflow/mwaa/${f}"))
  }
  mwaa_namespaces = {
    for k, v in local._mwaa_namespace_files :
    k => v if !try(v.spec.decommission, false)
  }
  mwaa_fargate_namespaces = {
    for k, v in local.mwaa_namespaces : k => v if v.spec.fargate_enabled
  }
}
```

This pattern mirrors `kafka/producers/` and `s3/`. Active namespaces (`decommission != true`) drive all `for_each` resource creation:

| Resource | `for_each` expression |
|---|---|
| `aws_iam_role.mwaa_namespace` | `local.mwaa_namespaces` |
| `aws_iam_role_policy.mwaa_namespace_s3` | `local.mwaa_namespaces` |
| `aws_iam_role_policy.mwaa_namespace_fargate` | `local.mwaa_fargate_namespaces` |
| `aws_iam_role.mwaa_namespace_ci` | `local.mwaa_namespaces` (where `ci_roles[env]` non-empty) |
| `aws_iam_role_policy.mwaa_namespace_ci_deploy` | `aws_iam_role.mwaa_namespace_ci` |
| `aws_iam_role.mwaa_namespace` trust policy (`IDCPermissionSet` statement) | `local._mwaa_sso_bindings` (where `sso_roles[env]` defined) — no `aws_ssoadmin` resource; SSO access is granted via `ArnLike` condition on the role trust policy |
| `aws_ecr_repository.mwaa_namespace` | `local.mwaa_fargate_namespaces` |
| `aws_ecr_repository_policy.mwaa_namespace` | `local.mwaa_fargate_namespaces` |
| `aws_ecr_lifecycle_policy.mwaa_namespace` | `local.mwaa_fargate_namespaces` |
| `aws_iam_role.fargate_task_execution` | `local.mwaa_fargate_namespaces` |
| `aws_iam_role_policy.fargate_task_execution_kms` | `local.mwaa_fargate_namespaces` |
| `aws_cloudwatch_log_group.fargate_namespace` | `local.mwaa_fargate_namespaces` |
| `aws_secretsmanager_secret.airflow_var_mwaa_s3_bucket` | singleton (one per env) |

**Adding a namespace** = create `airflow/mwaa/<namespace>.yaml` and run `terraform apply`. No `.tf` file modifications required.

---

### 2.2 Environment-Sizing Locals

| Local | `dev`/`test` | `uat`/`prod` | Used by |
|---|---|---|---|
| `mwaa_environment_class` | `"mw1.small"` | `"mw1.medium"` | `aws_mwaa_environment.airflow` |
| `mwaa_max_workers` | `5` | `10` | `aws_mwaa_environment.airflow` |
| `mwaa_min_workers` | `1` | `2` | `aws_mwaa_environment.airflow` |
| `mwaa_schedulers` | `1` | `2` | `aws_mwaa_environment.airflow` |
| `mwaa_log_retention` | `7` (days) | `30` (days) | `aws_cloudwatch_log_group.mwaa`, `aws_cloudwatch_log_group.fargate_namespace` |

---

### 2.3 KMS Key Assignments

| KMS Key | Alias | Service Principal | Used by |
|---|---|---|---|
| `module.kms["s3"]` | `alias/chedaws-edp-s3-<env>` | `s3.amazonaws.com`, `airflow.amazonaws.com` | Landing S3, platform S3, **MWAA S3 bucket SSE, MWAA environment** |
| `module.kms["ecr"]` | `alias/chedaws-edp-ecr-<env>` | `ecr.amazonaws.com` | ECR repository encryption |
| `module.kms["cloudwatch_logs"]` | `alias/chedaws-edp-cloudwatch_logs-<env>` | `logs.<region>.amazonaws.com` | All CloudWatch Log Groups (existing key) |

**Design decision**: The MWAA S3 bucket and MWAA environment share the existing `module.kms["s3"]` key rather than a dedicated `module.kms["mwaa"]` key. Rationale: a single S3-tier KMS key is the established pattern in this account; `airflow.amazonaws.com` is already registered as a service principal on the `s3` key; adding a separate MWAA key would create two keys with overlapping purpose and identical policy. The plan originally specified a separate `mwaa` key but this was revised after implementation review — per-service key isolation is achieved at the policy level (IAM conditions), not by multiplying keys.

---

## 3. IAM Role Dependency Graph

```
aws_iam_role.mwaa_execution
  └─ can assume ──→ aws_iam_role.mwaa_namespace["platform"]
                        └─ can run ──→ aws_ecs_task_definition.platform_e2e
                                           uses ──→ aws_iam_role.fargate_task_execution["platform"]
                                                        pulls from ──→ aws_ecr_repository.mwaa_namespace["platform"]

aws_iam_role.fargate_task_execution["platform"]
  └─ trust: ecs-tasks.amazonaws.com
  └─ inline: ECR pull (namespace repo only), CloudWatch Logs write, KMS decrypt

aws_iam_role.mwaa_namespace_ci["platform"]          ← CI runner assumes THIS role, not mwaa_namespace
  └─ trust: ci_roles[env] ARNs from namespace YAML
  └─ inline: s3:PutObject/GetObject/DeleteObject on dags/<namespace>/* only
             kms:GenerateDataKey/Decrypt on module.kms["s3"]
```

**Design decision — dedicated CI role**: CI runners assume `mwaa_namespace_ci` (S3 DAG prefix only), not the full `mwaa_namespace` role. This prevents a compromised CI runner from reading namespace Secrets Manager entries via the namespace role's `SecretsManagerReadOwn` policy.

---

## 4. S3 Bucket Layout

```
chedaws-edp-mwaa-<env>-<account_id>-<region>/
├── dags/
│   ├── platform/              ← platform namespace DAG prefix
│   │   ├── e2e_scheduler.py
│   │   ├── e2e_aws_auth.py
│   │   └── e2e_isolation.py
│   ├── finance/               ← example future namespace
│   └── <namespace>/           ← one prefix per registered namespace
├── plugins/
│   └── plugins.zip            ← shared plugins package (platform team managed)
├── requirements/
│   └── requirements.txt       ← Python dependencies (platform team managed)
└── tmp/                       ← execution artefacts (90-day expiry lifecycle)
```

---

## 5. S3 IAM Access Design

The `DAGPrefixReadWrite` policy statement in `aws_iam_role_policy.mwaa_namespace_s3` grants `s3:ListBucket` on the **bucket root** (not restricted by prefix condition). This is intentional:

- MWAA's DAG processor calls `ListBucket` on the bucket root to discover DAG files; prefix-restricted listing would prevent the MWAA execution role (which assumes the namespace role) from discovering DAGs.
- Namespace teams can see the existence of other namespace prefixes via `ListBucket`, but cannot read or write objects outside their own `dags/<namespace>/*` prefix (controlled by the `GetObject`/`PutObject`/`DeleteObject` resource constraint).
- The isolation boundary is object-level access, not directory listing visibility. This is consistent with AWS's S3 IAM model.

---

## 6. Secrets Manager Path Convention

| Secret path | Contains | Accessible by |
|---|---|---|
| `airflow/connections/<namespace>__aws_default` | `{"role_arn": "arn:aws:iam::<account>:role/edp-<env>-mwaa-ns-<namespace>"}` | Namespace IAM role (`secretsmanager:GetSecretValue` on `airflow/connections/<namespace>__*`) |
| `airflow/variables/<namespace>__<var_key>` | arbitrary string variable value | Same namespace IAM role |
| `airflow/variables/mwaa_s3_bucket` | MWAA S3 bucket name | MWAA execution role (`secretsmanager:GetSecretValue` on `airflow/*`) |

The Airflow Secrets Backend reads secrets at DAG parse/execution time. Connection ID in Airflow: `<namespace>__aws_default`.

`airflow/variables/mwaa_s3_bucket` is provisioned by Terraform (`aws_secretsmanager_secret.airflow_var_mwaa_s3_bucket`) and consumed by the platform e2e DAGs via `Variable.get("mwaa_s3_bucket")`.

---

## 7. CloudWatch Log Groups

| Log Group Name | Resource | Retention |
|---|---|---|
| `/chedaws-edp/mwaa/<env>/dagprocessing` | `aws_cloudwatch_log_group.mwaa["DAGProcessing"]` | 7d (dev/test), 30d (uat/prod) |
| `/chedaws-edp/mwaa/<env>/scheduler` | `aws_cloudwatch_log_group.mwaa["Scheduler"]` | 7d / 30d |
| `/chedaws-edp/mwaa/<env>/task` | `aws_cloudwatch_log_group.mwaa["Task"]` | 7d / 30d |
| `/chedaws-edp/mwaa/<env>/webserver` | `aws_cloudwatch_log_group.mwaa["WebServer"]` | 7d / 30d |
| `/chedaws-edp/mwaa/<env>/worker` | `aws_cloudwatch_log_group.mwaa["Worker"]` | 7d / 30d |
| `/chedaws-edp/fargate/platform/<env>` | `aws_cloudwatch_log_group.fargate_namespace["platform"]` | 7d / 30d |

All log groups encrypted with `module.kms["cloudwatch_logs"].key_arn`.

---

## 8. CloudWatch Alarms

| Alarm Name | Metric | Namespace | Threshold | Dimensions |
|---|---|---|---|---|
| `chedaws-edp-mwaa-scheduler-heartbeat-<env>` | `SchedulerHeartbeat` | `AmazonMWAA` | `< 1` (Sum, 1m) | `Function=Scheduler`, `Environment=<mwaa_name>` |
| `chedaws-edp-mwaa-failed-tasks-<env>` | `TaskInstanceFailures / (TaskInstanceFailures + TaskInstanceSuccesses)` | `AmazonMWAA` | `>= 0.5` for 2 × 15m, only when >= 10 tasks finished per 15m | `Environment=<mwaa_name>`, `DAG=All`, `Task=All` |
| `chedaws-edp-mwaa-triggerer-heartbeat-<env>` | `TriggererHeartbeat` | `AmazonMWAA` | `< 1` (Sum, 5m), missing = breaching | `Function=Triggerer`, `Environment=<mwaa_name>` |
| `chedaws-edp-mwaa-s3-sync-errors-<env>` | `S3SyncErrors` summed over Scheduler/Worker/Webserver | `AmazonMWAA` | `>= 3` for 2 × 15m | `Function=S3 Sync`, `AirflowComponent=<component>`, `Environment=<mwaa_name>` |
| `chedaws-edp-ecs-mwaa-cpu-utilization-<env>` | `CPUUtilization` | `AWS/ECS` | `>= 80%` (Avg, 5m) | `ClusterName=<cluster_name>` |
| `chedaws-edp-ecs-mwaa-memory-utilization-<env>` | `MemoryUtilization` | `AWS/ECS` | `>= 80%` (Avg, 5m) | `ClusterName=<cluster_name>` |
| `chedaws-edp-ecs-mwaa-running-task-anomaly-<env>` | `RunningTaskCount` | `ECS/ContainerInsights` | Anomaly band (2σ) | `ClusterName=<cluster_name>` |

All alarms: `alarm_actions = [aws_sns_topic.alerts.arn]`, `ok_actions = [aws_sns_topic.alerts.arn]`, active in all 4 environments.

---

## 9. Resource Naming Convention

| Resource type | Name pattern |
|---|---|
| MWAA environment | `chedaws-edp-mwaa-<env>` |
| MWAA S3 bucket | `chedaws-edp-mwaa-<env>-<account_id>-<region>` |
| MWAA security group | `chedaws-edp-mwaa-sg-<env>` |
| MWAA execution role | `edp-<env>-mwaa-execution` |
| Namespace IAM role | `edp-<env>-mwaa-ns-<namespace>` |
| Namespace CI-only role | `edp-<env>-mwaa-ns-<namespace>-ci` |
| Fargate execution role | `edp-<env>-fargate-exec-<namespace>` |
| ECS cluster | `chedaws-edp-mwaa-fargate-<env>` |
| ECR repository | `chedaws-edp-mwaa-<namespace>-<env>` |
| ECS task definition family | `chedaws-edp-mwaa-<namespace>-<purpose>-<env>` |
