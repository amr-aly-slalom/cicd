# Quickstart Validation Guide: MWAA Airflow Platform

**Feature**: 009-mwaa-airflow-platform | **Date**: 2026-08-03

This guide covers how to validate the feature end-to-end after deployment. It is not a full implementation guide — see [plan.md](plan.md) and [tasks.md](tasks.md) for that.

---

## Prerequisites

- Terraform workspaces configured: `dev`, `test`, `uat`, `prod`
- AWS CLI authenticated to the target account with sufficient permissions (or via `InfraBuildRole`)

No manual S3 bootstrap is required. `terraform apply` runs `terraform_data.mwaa_s3_bootstrap` automatically, which uploads `requirements.txt`, builds `plugins.zip` from `airflow/plugins/`, seeds the canary isolation prefix, and syncs all DAGs to S3 — all before `aws_mwaa_environment.airflow` is provisioned.

---

## Scenario 1 — MWAA Environment Reaches `AVAILABLE`

**Validates**: FR-001, SC-001

```powershell
# After terraform apply:
aws mwaa get-environment --name "chedaws-edp-mwaa-dev" --query "Environment.Status" --output text
# Expected: AVAILABLE
```

Check all four environments. `AVAILABLE` must be reached within 30 minutes of a clean apply.

---

## Scenario 2 — Airflow Web UI Is Accessible (Inside VPC)

**Validates**: FR-017, FR-001

```powershell
# Get the web server URL (PRIVATE_ONLY — accessible from within VPC only)
aws mwaa get-environment --name "chedaws-edp-mwaa-dev" \
  --query "Environment.WebserverUrl" --output text
# Expected: <url>.c9.ap-southeast-2.airflow.amazonaws.com
```

Open the URL from a machine on the VPC (via VPN or Direct Connect). The browser should redirect to IAM Identity Center for authentication. After login, the Airflow UI should load.

---

## Scenario 3 — CloudWatch Alarms in `OK` State

**Validates**: FR-011, FR-025, SC-006

```powershell
$env = "dev"
$alarmNames = @(
  "chedaws-edp-mwaa-scheduler-heartbeat-$env",
  "chedaws-edp-mwaa-failed-tasks-$env",
  "chedaws-edp-ecs-mwaa-cpu-utilization-$env",
  "chedaws-edp-ecs-mwaa-memory-utilization-$env",
  "chedaws-edp-ecs-mwaa-running-task-anomaly-$env"
)

foreach ($name in $alarmNames) {
  aws cloudwatch describe-alarms --alarm-names $name \
    --query "MetricAlarms[0].StateValue" --output text
}
# Expected: OK (for all alarms, within 5 minutes of environment AVAILABLE)
```

Repeat for `test`, `uat`, `prod`.

---

## Scenario 4 — Namespace IAM Role Exists with Correct Trust

**Validates**: FR-003, FR-005

```powershell
aws iam get-role --role-name "edp-dev-mwaa-ns-platform" \
  --query "Role.AssumeRolePolicyDocument"
# Expected: trust policy with Principal.AWS = arn:...:role/edp-dev-mwaa-execution
```

---

## Scenario 5 — End-to-End DAG Suite: Scheduler and Worker

**Validates**: FR-013, SC-003, User Story 5

DAGs are deployed automatically by `terraform apply` via `aws s3 sync` in `terraform_data.mwaa_s3_bootstrap`. No manual upload is needed. After apply, wait ~2 minutes for MWAA to sync the DAGs, then trigger in the Airflow UI (or via CLI):

```powershell
# Trigger the scheduler heartbeat test DAG
$webserverUrl = $(aws mwaa get-environment --name "chedaws-edp-mwaa-$env" `
  --query "Environment.WebserverUrl" --output text)
$token = $(aws mwaa create-web-login-token --name "chedaws-edp-mwaa-$env" `
  --query WebToken --output text)

# Use the Airflow REST API (authenticated with the MWAA web login token)
$headers = @{ "Authorization" = "Bearer $token" }
Invoke-RestMethod -Uri "https://$webserverUrl/api/v1/dags/platform_e2e_scheduler/dagRuns" `
  -Method POST -Headers $headers `
  -Body '{"conf": {}}' -ContentType "application/json"
```

Check DAG run status in the Airflow UI or via:

```powershell
Invoke-RestMethod -Uri "https://$webserverUrl/api/v1/dags/platform_e2e_scheduler/dagRuns" `
  -Method GET -Headers $headers
# Expected: latest run state = "success"
```

Trigger all three e2e DAGs. All tasks must reach `success` within 15 minutes (SC-003).

---

## Scenario 6 — AWS Service Authentication (No Hardcoded Credentials)

**Validates**: FR-006, SC-005, User Story 3

Prerequisite: Create the namespace AWS connection in Secrets Manager:

```powershell
aws secretsmanager create-secret \
  --name "airflow/connections/platform__aws_default" \
  --secret-string '{"conn_type": "aws", "extra": "{\"role_arn\": \"arn:aws:iam::<account_id>:role/edp-dev-mwaa-ns-platform\"}"}'
```

Trigger `platform_e2e_aws_auth` DAG. In the Airflow task log, verify:
- The task calls `s3:ListObjectsV2` on the platform DAG prefix
- No credentials appear in the log
- The call succeeds
- The assumed role ARN in CloudTrail matches `arn:...:role/edp-dev-mwaa-ns-platform`

---

## Scenario 7 — Namespace Isolation

**Validates**: FR-009, SC-004, User Story 2 (Acceptance 3)

The `platform_e2e_isolation` DAG attempts to read `dags/canary_namespace_for_isolation_test/test.txt` in the MWAA S3 bucket using the `platform` IAM role. The `platform` role has no permission on any prefix other than `dags/platform/*`.

Expected DAG task outcome: the task catches an `AccessDenied` exception and marks the step as `success` (isolation confirmed). If the task can read the object, the DAG fails (isolation breach).

Review task logs for the string `"Isolation check PASSED: AccessDenied as expected"`.

---

## Scenario 8 — Fargate Task Runs in Platform Namespace

**Validates**: FR-019, FR-020, FR-022

Trigger the Fargate test via the Airflow `EcsRunTaskOperator` in a test DAG (or manually):

```powershell
aws ecs run-task \
  --cluster "chedaws-edp-mwaa-fargate-dev" \
  --task-definition "chedaws-edp-mwaa-platform-e2e-dev" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[<app_subnet_1>,<app_subnet_2>],securityGroups=[<mwaa_sg_id>],assignPublicIp=DISABLED}"
```

Expected: task reaches `RUNNING` then `STOPPED` with `exitCode=0`. Logs visible in CloudWatch at `/chedaws-edp/fargate/platform/dev`.

Cross-namespace isolation: attempt the same `run-task` call using the `finance` namespace role (if provisioned). The call must fail with an IAM `AccessDenied` because the task definition is tagged `MwaaNamespace=platform` and the `finance` role's IAM policy condition requires `MwaaNamespace=finance`.

---

## Scenario 9 — ECR Repository Exists and Namespace Role Has Pull-Only Access

**Validates**: FR-023

```powershell
# Confirm repository exists
aws ecr describe-repositories --repository-names "chedaws-edp-mwaa-platform-dev"

# Confirm namespace role can pull (via ECR repository policy)
aws ecr get-repository-policy --repository-name "chedaws-edp-mwaa-platform-dev"
# Expected: policy allows Principal = arn:...:role/edp-dev-fargate-exec-platform
#           with actions: ecr:GetDownloadUrlForLayer, ecr:BatchGetImage, ecr:BatchCheckLayerAvailability ONLY
```

---

## Scenario 10 — HA Mode in `prod`

**Validates**: FR-002, SC-007

```powershell
aws mwaa get-environment --name "chedaws-edp-mwaa-prod" \
  --query "Environment.MaxWorkers,Environment.Schedulers" --output json
# Expected: Schedulers = 3 (HA mode)
```

Architecture review: confirm MWAA environment is deployed across ≥ 2 AZs in `prod` by inspecting the subnet IDs in `network_configuration` — both must be in different AZs.

---

## Scenario 11 — Cost Tags on All Resources

**Validates**: FR-014, SC-008

```powershell
$mwaaArn = $(aws mwaa get-environment --name "chedaws-edp-mwaa-dev" `
  --query "Environment.Arn" --output text)

aws mwaa list-tags-for-resource --resource-arn $mwaaArn
# Expected: Environment, Project, Owner, CostCentre tags present
# (via provider default_tags in providers.tf)
```

Spot-check: S3 bucket, ECR repo, IAM roles, ECS cluster, CloudWatch log groups.

---

## Rollback

If the MWAA environment provisioning fails:

1. Check `terraform plan` output — ensure the DAG S3 bucket, execution role, and security group were created before MWAA.
2. Check that bootstrap files (`requirements/requirements.txt`, `plugins/plugins.zip`) exist in S3 — MWAA errors on startup if these S3 keys are missing. Re-run `terraform apply` to trigger `terraform_data.mwaa_s3_bootstrap` if they are absent.
3. Check CloudWatch log group `/aws/mwaa/chedaws-edp-mwaa-<env>` (AWS-managed logs) for MWAA service errors.
4. `terraform destroy -target=aws_mwaa_environment.airflow` can tear down only the MWAA environment (not the supporting resources) if a rebuild is needed.
