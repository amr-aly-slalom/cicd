# Feature Specification: MWAA Airflow Platform

**Feature Branch**: `feat/airflow`

**Created**: 2026-08-03

**Status**: Draft

**Input**: User description: "provision apache airflow cluster using MWAA. This would deliver a self-serve workflow management capability for enterprise data platform. The platform team (us) is responsible to look after the infrastructure, availability, common functionalities, shared plugins, workflow authentication to aws services and offer multi-tenancy where use-cases across the business can develop and deploy their workflows without major assistance from the platform team. In short, it would be a self-serve workflow management platform as part of the enterprise data platform. Each use-case should have their own namespace and they may have one or many workflow hosted in their workspace. Configure end-to-end tests using `platform` namespace."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Platform Team Provisions MWAA Environment (Priority: P1)

The platform team provisions a managed Apache Airflow environment via MWAA that is shared across the enterprise. The environment is deployed across all four target environments (`dev`, `test`, `uat`, `prod`) with appropriate sizing, security controls, observability, and high-availability configuration.

**Why this priority**: All other capabilities depend on a running, correctly configured MWAA environment. Without this foundation, no use-case team can deploy workflows.

**Independent Test**: Can be fully tested by verifying that the MWAA environment reaches `AVAILABLE` state in all environments, that the Airflow UI is accessible, and that the scheduler heartbeat alarm is active.

**Acceptance Scenarios**:

1. **Given** infrastructure code is applied to the `dev` environment, **When** the MWAA environment is provisioned, **Then** the environment reaches `AVAILABLE` state, the Airflow web UI is accessible to authenticated users, and the scheduler heartbeat CloudWatch alarm is in `OK` state.
2. **Given** the `prod` MWAA environment is running, **When** one Availability Zone becomes unavailable, **Then** Airflow continues scheduling and executing tasks without operator intervention (high-availability mode).
3. **Given** any environment's MWAA environment fails a scheduler heartbeat, **When** the alarm threshold is breached, **Then** an SNS notification is sent to the platform team.

---

### User Story 2 - Use-Case Team Onboards a Namespace (Priority: P1)

A use-case team requests a namespace (e.g., `finance`, `marketing`, `logistics`) on the shared MWAA platform. The platform team configures the namespace, and the use-case team can deploy their DAGs into an isolated area without affecting other namespaces.

**Why this priority**: Multi-tenancy is a core promise of the platform. Without namespace isolation, use-case teams cannot operate independently and the platform cannot scale to multiple business units.

**Independent Test**: Can be fully tested by adding a new namespace entry to the platform configuration, applying it, and verifying that a DAG uploaded to that namespace's S3 prefix is visible and executable in the Airflow UI under the correct namespace label without appearing in other namespaces.

**Acceptance Scenarios**:

1. **Given** a new namespace `finance` is declared in the platform configuration, **When** the configuration is applied, **Then** an S3 prefix for `finance` DAG storage is created, and the namespace is registered with appropriate IAM permissions scoped to the `finance` team's role.
2. **Given** use-case team `finance` uploads a DAG to their designated S3 prefix, **When** Airflow syncs DAGs, **Then** the DAG appears in the Airflow UI and is executable by the `finance` team's role.
3. **Given** use-case team `finance` has deployed a DAG, **When** use-case team `logistics` browses their namespace, **Then** `logistics` cannot view, trigger, or modify `finance` DAGs (namespace isolation enforced).

---

### User Story 3 - Use-Case Team DAG Authenticates to AWS Services (Priority: P2)

A DAG belonging to a use-case team needs to interact with AWS services (e.g., trigger a Glue job, read from S3, publish to SNS). The platform provides a connection mechanism so DAGs authenticate to AWS using the namespace-specific IAM role without hardcoded credentials.

**Why this priority**: Secure, credential-free authentication to AWS services is a prerequisite for any meaningful workflow. Without this, use-case teams must manage credentials manually, which violates the Security principle.

**Independent Test**: Can be fully tested using the `platform` namespace by deploying a test DAG that calls an AWS service (e.g., lists objects in a designated S3 prefix) and verifying it succeeds using the namespace IAM role without any hardcoded credentials.

**Acceptance Scenarios**:

1. **Given** a DAG in the `platform` namespace is configured to trigger an AWS API call, **When** the DAG task runs, **Then** it authenticates via the namespace IAM role using task role assumption (no credentials in DAG code).
2. **Given** a namespace IAM role is configured with least-privilege permissions for specific AWS services, **When** a DAG task attempts to call an unauthorised AWS service, **Then** the call is denied and an appropriate error is returned.

---

### User Story 4 - Platform Team Provides Shared Plugins (Priority: P2)

The platform team maintains a set of shared Airflow plugins (operators, hooks, sensors) that all use-case teams can use in their DAGs. Plugins are versioned, centrally managed, and automatically available to all namespaces without per-team installation steps.

**Why this priority**: Shared plugins reduce duplication, enforce consistent patterns for AWS service interactions, and allow the platform team to deliver common capabilities (e.g., a Glue job operator, an S3 sensor) that use-case teams adopt without building from scratch.

**Independent Test**: Can be fully tested by publishing a shared plugin to the platform S3 plugins path and verifying that a DAG in the `platform` namespace can import and use the plugin successfully.

**Acceptance Scenarios**:

1. **Given** a shared plugin is uploaded to the platform's S3 plugins prefix by the platform team, **When** the MWAA environment picks up the updated plugins package, **Then** any namespace's DAG can import and use the plugin without additional setup.
2. **Given** a shared plugin is updated to a new version, **When** the update is applied, **Then** existing DAGs continue to run with the previous behaviour unless they explicitly import the new version (backwards-compatible by default).

---

### User Story 5 - End-to-End Test Using `platform` Namespace (Priority: P1)

The `platform` namespace serves as the canonical end-to-end test harness. The platform team deploys a set of test DAGs into the `platform` namespace that validate core capabilities: DAG scheduling, AWS service authentication, and namespace isolation. These tests run automatically after every environment deployment.

**Why this priority**: Automated end-to-end validation is essential for a shared platform. A regression in core infrastructure must be caught before use-case teams are impacted.

**Independent Test**: Can be fully tested by triggering the `platform` namespace test DAGs manually and verifying that all tasks complete successfully and produce expected outputs.

**Acceptance Scenarios**:

1. **Given** the MWAA environment is deployed, **When** the `platform` namespace end-to-end test DAG is triggered, **Then** all tasks complete with `success` status within the defined SLO (15 minutes).
2. **Given** the end-to-end test DAG includes a task that authenticates to an AWS service, **When** the task runs, **Then** it authenticates via the platform IAM role and the call succeeds.
3. **Given** the end-to-end test DAG includes a namespace isolation check, **When** the check runs, **Then** it confirms that DAGs in `platform` cannot access resources declared for other test namespaces.

---

### Edge Cases

- What happens when a namespace's S3 DAG prefix is empty? Airflow should not error; the namespace simply has no active DAGs.
- How does the system handle a DAG with a name collision across two different namespaces? Accepted risk - not enforced; the naming-convention approach couldn't catch the deployments that matter anyway (most namespaces sync straight to S3 from their own CI, bypassing this repo entirely).
- What happens if a shared plugin fails to load? Individual plugin failures must not crash the Airflow scheduler or block other namespaces.
- How does the system behave when the MWAA environment is updating (e.g., version upgrade)? Scheduled DAGs should either be queued or clearly fail-fast, not silently drop.
- What happens when a namespace IAM role is misconfigured (e.g., missing a required permission)? The DAG task should fail with a clear permission-denied error rather than a generic timeout.
- What happens when a Fargate task exceeds its allocated CPU or memory? The task must fail with a clear OOM/timeout error surfaced in the Airflow task log; the DAG should be retried according to its retry policy.
- What happens if a namespace tries to trigger a Fargate task definition that belongs to another namespace? The request must be denied by IAM policy.
- What happens when a namespace manifest is deleted without `spec.decommission: true`? CI MUST reject the deletion with an error message identifying the missing decommission flag; the manifest file must be restored and updated before deletion is permitted.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The platform MUST provision an MWAA environment shared across the enterprise, deployed to all four environments (`dev`, `test`, `uat`, `prod`).
- **FR-002**: The MWAA environment in `uat` and `prod` MUST be configured in high-availability mode (`schedulers = 2`). `dev` and `test` use a single scheduler.
- **FR-003**: The platform MUST support multiple named namespaces, where each namespace corresponds to a distinct business use-case team.
- **FR-004**: DAG storage MUST use a single shared S3 bucket; each namespace MUST have its own prefix within that bucket (e.g., `dags/<namespace>/`). Isolation is enforced via positive-grant IAM — each namespace IAM role is granted access only to its own `dags/<namespace>/` prefix. The S3 bucket policy enforces KMS encryption and TLS on all requests.
- **FR-005**: Each namespace MUST have a dedicated IAM role with least-privilege permissions scoped to that namespace's AWS resource access needs.
- **FR-006**: DAGs MUST authenticate to AWS services using namespace-specific IAM role assumption — no hardcoded credentials are permitted.
- **FR-007**: The platform MUST provide a centrally managed shared plugins package that is automatically available to all namespaces without per-team setup.
- **FR-008**: The platform team MUST be able to onboard a new namespace by adding a namespace manifest YAML and applying infrastructure without modifying existing namespace configurations.
- **FR-026**: Namespace decommissioning MUST follow a two-phase guard: a namespace manifest MUST declare `spec.decommission: true` before the manifest file may be deleted. CI MUST reject deletion of a namespace manifest whose last committed state does not contain `spec.decommission: true`. Once decommissioned, Terraform destroys the namespace's IAM role, ECR repository, and Fargate execution role; S3 DAG objects are retained for manual cleanup by the platform team.
- **FR-009**: Namespace isolation MUST be enforced such that a DAG in one namespace cannot view, trigger, or access resources of another namespace.
- **FR-010**: The MWAA environment MUST emit structured logs to CloudWatch Log Groups following the `/chedaws-edp/<component>/<env>` naming convention.
- **FR-011**: CloudWatch Alarms MUST be configured for MWAA failed task count and scheduler heartbeat in all four environments.
- **FR-012**: All CloudWatch Alarms MUST route notifications to an SNS topic provisioned as code.
- **FR-013**: The `platform` namespace MUST contain end-to-end test DAGs that validate scheduling, AWS authentication, and namespace isolation after every deployment.
- **FR-014**: All resources MUST carry cost allocation tags: `Environment`, `Project`, `Owner`, `CostCentre`.
- **FR-015**: Encryption at rest MUST be enabled on all MWAA-related S3 buckets using customer-managed KMS keys.
- **FR-016**: Encryption in transit MUST be enforced for all platform-configurable data paths: S3 requests MUST be denied when `aws:SecureTransport` is `false` (enforced via bucket policy); the Airflow web UI is TLS-only via `PRIVATE_ONLY` mode. MWAA-managed internal Airflow communications (scheduler ↔ worker, Celery broker) are encrypted by the AWS managed service and are not directly configurable by the platform team.
- **FR-018**: Users MUST authenticate to the Airflow web UI via AWS IAM Identity Center (SSO); each namespace MUST declare its SSO role name and CI role ARN in a namespace manifest YAML (following the same registration pattern as Kafka and S3 manifests). Terraform reads these manifests and provisions IAM trust and permission bindings using the existing `idc_instance_arn`. No manual console steps are required; the existing IAM Identity Center instance is reused.
- **FR-017**: The MWAA environment MUST be deployed in private subnets with the `PRIVATE_ONLY` web server access mode; the Airflow web UI is accessible only from within the VPC (via VPN or AWS Direct Connect). No public internet endpoint is permitted.
- **FR-019**: The platform MUST support offloading compute-heavy DAG tasks to AWS Fargate; DAGs MUST be able to trigger Fargate tasks via the ECS operator without managing compute infrastructure directly.
- **FR-020**: Fargate tasks MUST run within the same VPC as the MWAA environment, using private subnets.
- **FR-021**: Fargate task execution logs MUST be emitted to CloudWatch Log Groups following the `/chedaws-edp/<component>/<env>` naming convention, encrypted with a customer-managed KMS key.
- **FR-022**: Fargate tasks MUST be isolated per namespace; a namespace's Fargate task MUST NOT be triggerable by another namespace's DAG.
- **FR-023**: The platform MUST provision one AWS ECR private repository per namespace for storing Fargate container images. Each namespace's IAM role MUST be granted pull-only access to its own ECR repository; cross-namespace image access is prohibited.
- **FR-024**: Fargate task definitions provisioned by the platform team MUST NOT exceed 4 vCPU and 8 GB memory per task. This ceiling is governed by platform policy and validated by CI lint (checkov or tflint rule on `aws_ecs_task_definition` resources). Use-case teams MAY choose any valid Fargate CPU/memory combination within this ceiling; a Service Control Policy is out of scope for this feature.
- **FR-025**: CloudWatch Alarms MUST be configured at the platform level for ECS/Fargate metrics — CPU utilisation, memory utilisation, and running task count anomalies — routing to the platform SNS topic in all four environments.

### Key Entities

- **MWAA Environment**: The shared Apache Airflow cluster managed by AWS. Has configuration including Airflow version, environment class (sizing), max workers, plugins S3 path, DAGs S3 bucket, and network placement.
- **Namespace**: A logical grouping representing a use-case team. Declared via a manifest YAML at `airflow/mwaa/<namespace>.yaml` with fields: `metadata` (name, owner, description) and `spec` (SSO role name per environment, CI IAM role ARNs per environment, `fargate_enabled` boolean, optional `decommission` boolean). Owns an S3 DAG prefix, a namespace IAM role, and optionally ECR repository and Fargate execution role.
- **DAG**: A workflow definition uploaded by a use-case team to their namespace S3 prefix. Belongs to exactly one namespace.
- **Shared Plugin Package**: A versioned `.zip` archive containing Airflow operators, hooks, and sensors maintained by the platform team. Available to all namespaces.
- **Namespace IAM Role**: An IAM role assumed by Airflow task instances running DAGs in a specific namespace. Grants least-privilege access to the namespace's permitted AWS services.
- **Platform Execution Role**: The IAM role assumed by the MWAA environment itself for infrastructure-level operations (reading DAGs from S3, writing logs to CloudWatch, publishing to SNS).
- **Fargate Task**: A containerised compute unit launched on-demand by an Airflow DAG task via the ECS operator to execute compute-heavy workloads. Runs in private subnets within the same VPC as MWAA. Belongs to a namespace.
- **Fargate Task Execution Role**: An IAM role assigned to a Fargate task at runtime. Grants the task access to AWS services required by its workload, scoped per namespace.
- **Namespace ECR Repository**: A private AWS ECR repository provisioned per namespace for storing Fargate container images. Use-case teams push images; the namespace IAM role has pull-only access.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The MWAA environment reaches `AVAILABLE` state in all four environments within 30 minutes of a clean infrastructure apply.
- **SC-002**: A new use-case namespace can be onboarded (infrastructure applied and DAG deployed) by a use-case team without platform team involvement beyond the initial namespace configuration entry.
- **SC-003**: The `platform` namespace end-to-end test suite completes successfully (all tasks `success`) within 15 minutes of triggering.
- **SC-004**: Namespace isolation is fully enforced: a DAG in namespace A has zero ability to read, trigger, or modify DAGs or resources scoped to namespace B, verified by the end-to-end test suite.
- **SC-005**: 100% of DAG-to-AWS-service authentication uses namespace IAM role assumption — no DAG in any namespace contains hardcoded credentials. Verified by: (a) `checkov` scan of Terraform resources in CI for hardcoded secrets/keys, and (b) a `gitleaks` or `truffleHog` pre-commit/CI scan on `airflow/dags/` Python files.
- **SC-006**: CloudWatch Alarms for scheduler heartbeat and failed task count are in `OK` state within 5 minutes of a healthy environment reaching `AVAILABLE` status.
- **SC-007**: The `uat` and `prod` MWAA environments tolerate a single Availability Zone outage without interruption to scheduled workflows, validated by architecture review and AWS HA mode configuration (`schedulers = 2`).
- **SC-008**: All MWAA-related costs are attributed to the correct cost allocation tags in 100% of taggable resources, verifiable via AWS Cost Explorer tag coverage report.

## Clarifications

### Session 2026-08-03

- Q: What MWAA web server access mode should be used? → A: `PRIVATE_ONLY` — UI accessible only inside VPC via VPN or Direct Connect; no public endpoint.
- Q: Single shared DAGs S3 bucket or per-namespace bucket? → A: Single shared bucket with per-namespace prefix isolation enforced via S3 bucket policy conditions.
- Q: How do use-case team members authenticate to the Airflow web UI? → A: AWS IAM Identity Center (SSO) — users authenticate via federated AWS identity; IAM Identity Center groups map to Airflow RBAC roles per namespace.
- Q: What secrets backend and path convention for namespace connections/variables? → A: AWS Secrets Manager with Airflow Secrets Backend; paths follow `airflow/connections/<namespace>__<conn_id>` and `airflow/variables/<namespace>__<var_key>` conventions.
- Q: What are the max worker counts per environment? → A: `dev` and `test`: max 5 workers; `uat` and `prod`: max 10 workers.
- Q: How should compute-heavy DAG tasks be executed? → A: Via AWS Fargate using the ECS operator; Fargate tasks run in private subnets within the same VPC, are isolated per namespace, and log to CloudWatch.
- Q: Where are Fargate container images stored and who provisions the registry? → A: One ECR repository per namespace, provisioned by the platform team as part of this feature; namespace IAM roles are scoped to pull only from their own ECR repo.
- Q: How is Fargate task CPU/memory allocation governed? → A: Platform enforces a maximum ceiling of 4 vCPU / 8 GB per task; use-case teams choose any valid Fargate CPU/memory combination within that ceiling.
- Q: What is the CloudWatch Alarm scope for Fargate/ECS tasks? → A: Platform-level ECS alarms (CPU utilisation, memory utilisation, running task count anomalies) routing to the platform SNS topic; no per-namespace alarms.
- Q: What is the Airflow version to deploy? → A: `3.2.1` — confirmed as the latest supported MWAA version in `ap-southeast-2` at time of implementation.
- Q: How is FR-018 (Airflow UI SSO authentication) implemented — what is the Terraform boundary? → A: MWAA namespace manifests (similar to Kafka and S3 registration YAMLs) declare the SSO role name and CI role ARN per environment. Terraform reads these manifests and provisions IAM trust/permission bindings using the existing `idc_instance_arn` variable. No manual console steps required; the existing IAM Identity Center instance is reused.
- Q: Does `uat` use HA mode (2 schedulers) or single scheduler? → A: `uat` uses HA mode (`schedulers = 2`), same as `prod`; the `is_prod_like` gate (covering `uat` and `prod`) applies to scheduler count.
- Q: How is namespace decommissioning handled? → A: Two-phase guard — a namespace manifest MUST set `spec.decommission: true` before the manifest entry may be deleted. CI enforces this: deleting a manifest file without the decommission flag set in its last committed state is a CI validation error. On delete after `decommission: true`, Terraform destroys IAM/ECR/Fargate resources; S3 DAG objects are retained and cleaned up manually by the platform team.
- Q: What fields does the namespace manifest YAML declare? → A: Minimal schema — `metadata` (name, owner, description) + `spec` (SSO role name per environment, CI IAM role ARNs per environment, `fargate_enabled` boolean, optional `decommission` boolean). No per-namespace resource sizing in the manifest; Fargate CPU/memory defaults stay in `locals.tf`.

## Assumptions

- Each environment (`dev`, `test`, `uat`, `prod`) deploys to a single MWAA environment instance; there is no per-namespace MWAA cluster.
- Namespace isolation at the Airflow level is achieved via Airflow RBAC roles mapped to namespace-specific IAM roles and DAG-level access controls, not separate Airflow instances.
- Use-case teams upload DAGs to their namespace S3 prefix directly (e.g., via CI/CD pipelines); the platform does not provide a DAG deployment pipeline as part of this feature.
- The shared plugins package is built and versioned by the platform team; use-case teams consume it as-is and cannot add custom plugins without a platform team merge.
- Namespace-specific connections and variables are stored in AWS Secrets Manager and accessed via the Airflow Secrets Backend. Paths follow the conventions `airflow/connections/<namespace>__<conn_id>` and `airflow/variables/<namespace>__<var_key>`. Each namespace IAM role is scoped to read only its own prefix in Secrets Manager.
- VPC, subnets, security groups, and KMS keys are assumed to be provisioned by existing infrastructure. This feature will reference existing resources via remote state or data sources.
- S3 lifecycle policies for DAG storage buckets will use `INTELLIGENT_TIERING` for the DAG prefix (infrequent large-scale reads, variable access patterns) and a 90-day expiration on temporary execution artefacts.
- Environment sizing: `dev` and `test` use `mw1.small` worker class with a maximum of 5 workers; `uat` and `prod` use `mw1.medium` worker class with a maximum of 10 workers.
- Airflow version is `3.2.1` — the latest supported MWAA version in `ap-southeast-2` confirmed at time of implementation.
- Each namespace is declared via a manifest YAML at `airflow/mwaa/<namespace>.yaml` following the same registration pattern as Kafka (`kafka/producers/`) and S3 (`s3/`) manifests. The manifest schema is minimal: `metadata` (name, owner, description) + `spec` (SSO role name per environment, CI IAM role ARNs per environment, `fargate_enabled` boolean, optional `decommission` boolean). Terraform reads these YAMLs via `fileset` and provisions all namespace resources; the existing `idc_instance_arn` variable (SSO instance `ssoins-82599788fabf9a65`) is reused for IAM Identity Center bindings.
