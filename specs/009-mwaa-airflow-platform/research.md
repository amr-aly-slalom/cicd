# Research: MWAA Airflow Platform

**Feature**: 009-mwaa-airflow-platform | **Date**: 2026-08-03

---

## 1. MWAA Airflow Version in `ap-southeast-2`

**Decision**: Airflow `3.2.1`

**Rationale**: As of August 2026, `3.2.1` is the latest MWAA-supported version in `ap-southeast-2` (confirmed in spec clarification session). It includes `apache-airflow-providers-amazon` 9.x, which ships the `EcsRunTaskOperator` required for Fargate task offloading. Airflow 3.x is the current generation; 2.x is entering end-of-support.

**Alternatives considered**: `2.10.3` — prior generation, approaching end-of-support lifecycle. `3.1.x` — available but superseded by 3.2.1.

---

## 2. MWAA Web Server Access Mode

**Decision**: `PRIVATE_ONLY`

**Rationale**: Spec FR-017 and clarification session mandate no public internet endpoint. `PRIVATE_ONLY` restricts the Airflow web UI to within the VPC. Users access via VPN or AWS Direct Connect. `PUBLIC_ONLY` or `PRIVATE_ONLY` are the only two MWAA options; there is no middle-ground hybrid mode.

**Alternatives considered**: `PUBLIC_ONLY` — rejected per spec. No VPC endpoint required for MWAA UI in `PRIVATE_ONLY` mode; MWAA handles the internal endpoint provisioning.

---

## 3. DAG Storage: Single Bucket vs Per-Namespace Bucket

**Decision**: Single shared bucket `chedaws-edp-mwaa-<env>-<account_id>-<region>` with per-namespace S3 prefixes (`dags/<namespace>/`). Namespace isolation enforced via S3 bucket policy prefix conditions on namespace IAM roles.

**Rationale**: Spec FR-004 explicitly mandates a single shared bucket. Per-namespace bucket would require one bucket per namespace per environment (impractical at scale) and would not simplify MWAA configuration, which accepts a single `dag_s3_path`.

**Alternatives considered**: Per-namespace bucket — rejected by spec. A separate plugins bucket — rejected; plugins are platform-managed and co-located in `plugins/` prefix is cleaner.

---

## 4. Namespace IAM Role Trust and Task-Level Authentication

**Decision**: MWAA execution role (`aws_iam_role.mwaa_execution`) has `sts:AssumeRole` permission to assume any namespace IAM role (`aws_iam_role.mwaa_namespace[*]`). DAGs use an Airflow `AwsBaseHook` connection stored in Secrets Manager to assume the namespace role at task execution time.

**Rationale**: MWAA does not natively support per-namespace task roles. The established pattern is: execution role → assume namespace role via an `aws_default` Airflow connection that specifies `role_arn`. This is the AWS-recommended approach for MWAA multi-tenancy. No credentials appear in DAG code; the role ARN is stored in Secrets Manager.

**Alternatives considered**: EKS pod identity (not applicable to MWAA Fargate workers). Per-environment MWAA instance per namespace — rejected; per-namespace isolation is achieved at the IAM and S3 policy level within a shared MWAA instance.

---

## 5. Secrets Backend: Path Convention

**Decision**: AWS Secrets Manager with Airflow Secrets Backend. Path convention:
- Connections: `airflow/connections/<namespace>__<conn_id>`
- Variables: `airflow/variables/<namespace>__<var_key>`
- Separator: `__` (double underscore, matching spec clarification)

**Rationale**: Native MWAA integration with Secrets Manager requires no additional plugins. The `__` separator is the Airflow standard for connections stored in Secrets Manager. Namespace prefix in the secret path enforces isolation: each namespace IAM role is only granted `secretsmanager:GetSecretValue` on `airflow/connections/<namespace>__*`.

**Alternatives considered**: HashiCorp Vault — requires self-managed infrastructure. SSM Parameter Store — less feature-rich for Airflow connections; Secrets Manager is the AWS-preferred backend for MWAA.

---

## 6. MWAA Environment Sizing

**Decision**:
- `dev` / `test`: `mw1.small`, min 1 / max 5 workers, 1 scheduler
- `uat` / `prod`: `mw1.medium`, min 2 / max 10 workers, 2 schedulers

**Rationale**: From spec clarification. `mw1.small` (2 vCPU, 16 GB) is sufficient for dev/test workloads. `mw1.medium` (4 vCPU, 32 GB) handles uat/prod concurrency. `schedulers = 2` enables HA mode in prod per spec FR-002 and constitution §IV.

**Alternatives considered**: `mw1.large` for prod — over-provisioned for initial deployment; can be upgraded by changing `local.mwaa_environment_class`. `mw1.xlarge` — cost-prohibitive at this stage.

---

## 7. Fargate Task Namespace Isolation

**Decision**: IAM condition on `ecs:RunTask` using `StringEquals` on the `aws:ResourceTag/MwaaNamespace` resource tag. Each namespace IAM role may only trigger Fargate tasks whose ECS task definition is tagged `MwaaNamespace = <namespace>`.

**Rationale**: Spec FR-022 mandates that a namespace's Fargate tasks cannot be triggered by another namespace. Tag-based IAM conditions are the standard AWS enforcement mechanism for cross-resource isolation within a shared ECS cluster. Task definitions are tagged at provisioning time by the platform team.

**Alternatives considered**: Separate ECS cluster per namespace — operationally complex; unnecessary overhead. VPC isolation — impractical without separate VPCs. SCP on `ecs:RunTask` — out of scope for this feature.

---

## 8. Fargate CPU/Memory Ceiling Enforcement (FR-024)

**Decision**: Document the 4 vCPU / 8 GB ceiling in the namespace onboarding runbook. Task definitions provisioned by the platform team will respect the ceiling. A CI lint check on `aws_ecs_task_definition` resources can enforce this for PR-merged task definitions.

**Rationale**: AWS does not provide a native IAM condition to restrict `ecs:RegisterTaskDefinition` by CPU/memory value. An SCP (`aws:RequestedRegion` + custom condition) could block over-sized registrations but requires AWS Organizations integration and is out of scope for this feature. The ceiling is a governance control, not a hard infrastructure constraint; task definitions are platform-provisioned.

**Alternatives considered**: SCP to block task definition registration above ceiling — requires AWS Organizations admin access; deferred. Tag condition on `ecs:RunTask` — only covers invocation, not registration.

---

## 9. ECR Repository per Namespace

**Decision**: One ECR private repository per namespace (`chedaws-edp-mwaa-<namespace>-<env>`). Repository policy restricts pull to the namespace's Fargate task execution role only. Platform team has push access via their deployment pipeline.

**Rationale**: Spec FR-023. Per-namespace ECR repositories enforce image isolation. KMS encryption uses `module.kms["ecr"]`. `scan_on_push = true` satisfies the Security principle.

**Alternatives considered**: Shared ECR repository with per-namespace image tag convention — rejected; repository policy cannot restrict pull by image tag, only by principal. Per-account ECR — already per-account given single-account architecture.

---

## 10. Shared Plugins Package Management

**Decision**: Platform team uploads a versioned `plugins.zip` to `s3://<mwaa_bucket>/plugins/plugins.zip`. MWAA re-reads this path on environment restart or when `plugins_s3_object_version` is updated in the `aws_mwaa_environment` resource.

**Rationale**: MWAA's native plugin mechanism requires a single zip at a fixed S3 path. Versioning the MWAA S3 bucket means the `object_version_id` can be pinned via Terraform to control which plugin version the environment loads. Use-case teams cannot add custom plugins without a platform team merge.

**Alternatives considered**: Per-namespace plugin packages — not supported by MWAA (single `plugins_s3_path` per environment). PyPI extras in `requirements.txt` — suitable for Python packages but not for Airflow operator extensions.

---

## 11. ECS Cluster Container Insights

**Decision**: Enable Container Insights on the ECS cluster (`containerInsights = "enabled"`).

**Rationale**: Container Insights emits `CPUUtilization`, `MemoryUtilization`, and `RunningTaskCount` metrics to `ECS/ContainerInsights`, which are required for the constitution-mandated ECS CloudWatch Alarms (§II). Without Container Insights, these metrics are not emitted and alarms cannot be configured.

**Alternatives considered**: Manual CloudWatch agent — adds operational overhead; Container Insights is the managed AWS solution.

---

## 12. CloudWatch Alarm for Running Task Count — Anomaly Detection vs Threshold

**Decision**: Use `ANOMALY_DETECTION_BAND` expression alarm for `RunningTaskCount` rather than a fixed threshold.

**Rationale**: Running task count is variable and workload-dependent. A static threshold would produce false positives during high-load periods or false negatives at off-peak times. Anomaly detection adapts to historical patterns. Constitution §II requires the alarm but does not mandate the detection method.

**Alternatives considered**: Fixed threshold (e.g., > 50 tasks) — arbitrary; would need per-environment tuning. Metric math with `SUM` over 24h baseline — less adaptive.

---

## 13. Airflow Connections for AWS Service Authentication

**Decision**: Store the namespace IAM role ARN in Secrets Manager as an Airflow `aws` connection with `role_arn` set. DAGs reference the connection by ID (`<namespace>__aws_default`). The Airflow `AwsBaseHook` uses the connection to assume the role transparently.

**Rationale**: This is the standard MWAA multi-tenant pattern. No credentials in DAG code. The namespace role ARN is the only secret; it is not a credential and can be rotated without DAG changes. Airflow re-reads Secrets Manager on each DAG run (no caching of role tokens beyond session expiry).

**Alternatives considered**: Environment variables in `airflow_configuration_options` — cannot be scoped per-namespace. Hardcoded role ARNs in DAG code — rejected (spec FR-006, constitution §I).

---

## 14. DAG ID Namespace Prefix Convention (superseded)

**Original decision**: All DAGs in a namespace MUST use `<namespace>__<dag_id>` as the DAG ID (double underscore separator). Enforced by documentation and linting; cannot be enforced at the S3 prefix level.

**Reversed**: the "linting" half never actually applied to the deployments that mattered - most namespaces sync straight to S3 from their own CI via `publish-mwaa-artefact`, which never runs through this repo's checks, so the convention was enforceable only for the platform team's own in-repo DAGs. Accepted as a monitored risk instead of a convention nothing can actually check.

---

## 15. MWAA `PRIVATE_ONLY` Network Requirements

**Decision**: Security group allows inbound HTTPS (443) from `data.aws_vpc.current.cidr_block`. All egress is unrestricted (MWAA managed service requires outbound to AWS service endpoints).

**Rationale**: MWAA `PRIVATE_ONLY` mode creates an internal NLB accessible only from within the VPC. Inbound 443 from VPC CIDR is the minimum required for the Airflow web UI and API. Egress restriction requires VPC endpoints for all AWS services MWAA contacts (SQS, Secrets Manager, S3, CloudWatch Logs, KMS) — that VPC endpoint provisioning is a prerequisite owned by the networking team and referenced via existing shared infrastructure. A checkov skip annotation is added (same pattern as `aws_security_group.msk`) if unrestricted egress triggers a lint warning.

**Alternatives considered**: Egress restricted to specific AWS service CIDR ranges — AWS service IPs change; managed service egress restrictions require VPC endpoints instead. A separate security group per namespace — unnecessary; MWAA has one security group for the environment.

---

## 16. S3 Lifecycle Strategy for DAG Bucket

**Decision**: `INTELLIGENT_TIERING` at 30 days for `dags/` and `plugins/` prefixes; 30-day noncurrent version expiry; 90-day expiry on `tmp/` (execution artefacts).

**Rationale**: DAG file access patterns are mixed — active DAGs are read frequently, archived DAGs rarely. `INTELLIGENT_TIERING` automatically moves objects between access tiers without retrieval latency penalties. Plugins are read on MWAA restart (infrequent). 90-day expiry on `tmp/` prevents unbounded accumulation of execution artefacts. This strategy is documented in the spec Assumptions section per constitution §III and §V.

**Alternatives considered**: `STANDARD_IA` — retrieval fee penalty on frequently accessed DAGs makes it unsuitable. No lifecycle — rejected by constitution. Per-object manual tiering — impractical.

---

## 17. Outputs

No `outputs.tf` additions are required for this feature. MWAA environment name and ARN are available within-root via `aws_mwaa_environment.airflow.arn`. Namespace role ARNs are available via `aws_iam_role.mwaa_namespace[*].arn`.
