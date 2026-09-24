# Feature Specification: Redshift Cluster Provisioning

**Feature Branch**: `feat/redshift-cluster`

**Created**: 2026-06-26

**Status**: Draft

**Input**: User description: "We are developing an enterprise data platform. We have 4 environments: dev, test, uat and prod. The same terraform project will be used to deploy all the 4 environments. We will use terraform workspace to identify each environment. Create an amazon redshift cluster with 2 nodes of instance type `rg.xlarge` for dev/test and `rg.4xlarge` for uat/prod. VPC ids for each environment can be found in locals.tf. Find subnets using `aws_subnets` data object. For App Subnets use tag `Tier=App` and for DB subnets use tag `Tier=Db`. Name the cluster as `chedaws-edp-<environment>`. The master username is `edpadmin`. Generate a random password and store that in secrets manager. Allow connectivity from App and DB subnets. Create a new KMS CMK. All resource names should have a environment suffix, so that resources from multiple environment in the same account don't conflict."

## Clarifications

### Session 2026-06-29

- Q: Should all Terraform resources exclusively serving the Redshift feature (KMS key, Security Group, Secrets Manager secret and password, CloudWatch Log Group, CloudWatch alarms) be co-located in `redshift.tf` rather than separate files? → A: Yes — all resources exclusively dedicated to Redshift are co-located in `redshift.tf`. Only `sns.tf` remains a separate file because the SNS alerts topic is intended for reuse by future EDP features.
- Q: Should the Redshift-specific `aws_subnets` and `aws_subnet` data source blocks also move to `redshift.tf`, or remain in `data.tf`? → A: Remain in `data.tf` — data source blocks follow Terraform convention (all data lookups in one place) regardless of which feature uses them.
- Q: Which services should have dedicated KMS CMKs created in `kms.tf` within this feature? → A: Redshift + SNS + CloudWatch Logs (3 service-specific keys); keys for services not yet provisioned (S3, EBS, RDS, Glue, etc.) are deferred to the features that introduce those services.
- Q: Should the CloudWatch Log Group `/chedaws-edp/redshift/<environment>` be encrypted using the dedicated CloudWatch Logs KMS key? → A: Yes — the `aws_cloudwatch_log_group` resource MUST set `kms_key_id = aws_kms_key.cloudwatch_logs.arn`; FR-020 updated accordingly.
- Q: What key policy structure should each service-specific KMS key use? → A: Lean/service-specific — each key grants root IAM full access plus exactly one AWS service principal (e.g., the Redshift key only grants `redshift.amazonaws.com`; the SNS key only grants `sns.amazonaws.com`; the CloudWatch Logs key only grants `logs.<region>.amazonaws.com`).
- Q: Do 3 distinct module invocations (for redshift, sns, cloudwatch_logs) from the same `kms.tf` satisfy constitution VI's module gate? → A: Yes — 3 distinct `module` blocks are 3 distinct call sites; a reusable `terraform/modules/kms/` module is justified. This supersedes the 2026-06-26 "inline, no module" answer, which applied when only 1 KMS key was planned.
- Q: What inputs should the `terraform/modules/kms/` module accept? → A: Minimal — `service_name` (string), `service_principal` (string), `environment` (string); KMS action set hardcoded inside the module (including `kms:CreateGrant` for all service principals).
- Q: Should `kms:CreateGrant` be included in the hardcoded actions for all service keys? → A: Yes — include `CreateGrant` in the hardcoded set for all services; minor over-permission for SNS/CloudWatch Logs is acceptable given the actions are scoped to the named service principal on that specific key.
- Q: What outputs should the module expose? → A: `key_arn`, `key_id`, and `alias_arn` — covers current (`kms_key_id` arguments) and anticipated future (IAM policy conditions, cross-account grants) consumer patterns.
- Q: Should `kms.tf` use three separate named module blocks or a single `for_each` block? → A: Single `module "kms"` block with `for_each = local.kms_services` over a map of `{ service_principal }` keyed by service name — DRY; consumers reference outputs via `module.kms["redshift"].key_arn`, `module.kms["sns"].key_arn`, `module.kms["cloudwatch_logs"].key_arn`.

### Session 2026-06-28

- Q: Are `rg.xlarge` and `rg.4xlarge` valid AWS Redshift node type identifiers? → A: Yes — confirmed via AWS documentation. RG nodes are Graviton-based and supersede RA3; `rg.xlarge` is the correct type for dev/test and `rg.4xlarge` for uat/prod. All `ra3` references in this spec are replaced accordingly.

### Session 2026-06-26

- Q: How many Redshift clusters will be provisioned per environment? → A: Exactly one cluster per environment; there is no plan to create multiple clusters within a single environment.
- Q: Should Redshift resources be extracted into a reusable module or written inline? → A: Inline in the root Terraform configuration — no second module consumer is planned, so a module is not justified per constitution v1.1.0.
- Q: Should CloudWatch alarms for the Redshift cluster be included in this feature? → A: Yes — include alarms for CPU utilisation, disk space used %, and connection count.
- Q: Should uat/prod Redshift clusters span multiple Availability Zones? → A: No — single-AZ is acceptable for all environments; multi-AZ Redshift is deferred to a future requirement.
- Q: Where should Redshift audit logs be captured? → A: CloudWatch Logs — connection log, user log, and user activity log must all be exported to CloudWatch (not S3).
- Q: What CloudWatch Log Group retention periods should apply per environment? → A: Tiered — 7 days for `dev`/`test`, 30 days for `uat`, 90 days for `prod`.
- Q: Where should CloudWatch alarms send notifications? → A: An SNS topic per environment (`chedaws-edp-alerts-<environment>`); the same topic will serve as the shared notification channel for all future EDP CloudWatch alarms. Subscription wiring is out of scope for this feature.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Deploy Cluster Per Environment (Priority: P1)

An infrastructure engineer runs `terraform apply` with the appropriate Terraform workspace selected (`dev`, `test`, `uat`, or `prod`) and a correctly sized, named, and encrypted Redshift cluster is provisioned in the target VPC.

**Why this priority**: This is the core deliverable — every other story depends on the cluster existing.

**Independent Test**: Select the `dev` workspace, run `terraform apply`, and verify that a 2-node Redshift cluster named `chedaws-edp-dev` exists in the `dev` VPC with `rg.xlarge` nodes and is encrypted with a new KMS key.

**Acceptance Scenarios**:

1. **Given** the `dev` workspace is active, **When** `terraform apply` is run, **Then** a 2-node Redshift cluster named `chedaws-edp-dev` is created using `rg.xlarge` nodes in the dev VPC, encrypted with a dedicated KMS key.
2. **Given** the `uat` workspace is active, **When** `terraform apply` is run, **Then** a 2-node Redshift cluster named `chedaws-edp-uat` is created using `rg.4xlarge` nodes in the uat VPC, encrypted with a dedicated KMS key.
3. **Given** both `dev` and `test` workspaces have been applied (they share the same AWS account), **When** both clusters are listed in the AWS console, **Then** no name conflicts exist — `chedaws-edp-dev` and `chedaws-edp-test` are distinct resources with distinct resource names throughout.
4. **Given** the `prod` workspace is active, **When** `terraform apply` is run, **Then** the cluster is created with `rg.4xlarge` nodes and snapshot retention meets the minimum 7-day requirement.

---

### User Story 2 - Secure Credential Management (Priority: P1)

An infrastructure engineer or a data engineer can retrieve the Redshift master password from AWS Secrets Manager without it ever being visible in Terraform state or source code.

**Why this priority**: Hardcoded credentials violate the constitution's NON-NEGOTIABLE Security principle and represent a critical compliance risk.

**Independent Test**: After applying `dev` workspace, verify that no plaintext password appears in `terraform.tfstate`, in any `.tf` file, or in Terraform plan output, and that the password is retrievable from AWS Secrets Manager.

**Acceptance Scenarios**:

1. **Given** a Redshift cluster has been provisioned, **When** the Secrets Manager secret for that environment is read, **Then** it contains the master password used by the cluster.
2. **Given** the Terraform source files are inspected, **When** searching for the master password value, **Then** no hardcoded credentials are found in any `.tf` file.
3. **Given** a new environment is provisioned, **When** the password is generated, **Then** it is unique to that environment and stored in a Secrets Manager secret whose name includes the environment identifier.

---

### User Story 3 - Network Connectivity from App and DB Tiers (Priority: P2)

A data engineer or application service running in either the App subnet tier or the DB subnet tier can establish a connection to the Redshift cluster on the standard port.

**Why this priority**: The cluster has no value if services cannot connect to it; however, cluster existence (P1) must come first.

**Independent Test**: After provisioning `dev`, attempt a TCP connection to the cluster endpoint on port 5439 from an EC2 instance in an App-tier subnet (`Tier=App`) and from one in a DB-tier subnet (`Tier=Db`). Both should succeed; a connection from a subnet with neither tag should be denied.

**Acceptance Scenarios**:

1. **Given** a Redshift cluster has been provisioned, **When** a connection is attempted from an instance in an App-tier subnet within the same VPC, **Then** the connection is accepted on port 5439.
2. **Given** a Redshift cluster has been provisioned, **When** a connection is attempted from an instance in a DB-tier subnet within the same VPC, **Then** the connection is accepted on port 5439.
3. **Given** a Redshift cluster has been provisioned, **When** a connection is attempted from a subnet that has neither `Tier=App` nor `Tier=Db` tags, **Then** the connection is denied by the security group.

---

### Edge Cases

- What happens when the `aws_subnets` data lookup returns zero subnets for `Tier=App` or `Tier=Db` in a given VPC? The plan must fail with a descriptive error rather than silently creating a misconfigured subnet group.
- What happens if a workspace name is provided that is not one of `dev`, `test`, `uat`, `prod`? The deployment must fail with a clear error (the locals map lookup will error on unknown workspace).
- What happens when `dev` and `test` workspaces are applied into the same account simultaneously? All named resources must carry the environment suffix to prevent conflicts.
- What happens if the KMS key for one environment is accidentally deleted? Redshift snapshots and data for that environment become inaccessible; key deletion protection must be enabled.
- Multi-AZ Redshift (native multi-AZ mode or cross-AZ subnet group spanning) is **explicitly out of scope** for this feature; it is deferred to a future requirement.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Terraform configuration MUST use `terraform.workspace` to determine the active environment (`dev`, `test`, `uat`, or `prod`).
- **FR-002**: A Redshift cluster MUST be provisioned with the name `chedaws-edp-<environment>` (e.g., `chedaws-edp-dev`).
- **FR-003**: The Redshift cluster MUST consist of exactly 2 nodes.
- **FR-004**: The node type MUST be `rg.xlarge` when the environment is `dev` or `test`, and `rg.4xlarge` when the environment is `uat` or `prod`. (RG nodes are Graviton-based and confirmed valid per AWS documentation and clarification session 2026-06-28.)
- **FR-005**: The cluster MUST be placed in the VPC corresponding to the active workspace as defined in `locals.tf`.
- **FR-006**: App-tier subnets MUST be discovered dynamically using the `aws_subnets` data source filtered by the tag `Tier=App` within the active environment's VPC.
- **FR-007**: DB-tier subnets MUST be discovered dynamically using the `aws_subnets` data source filtered by the tag `Tier=Db` within the active environment's VPC.
- **FR-008**: A Redshift subnet group MUST be created that includes all discovered App-tier and DB-tier subnets.
- **FR-009**: The Redshift master username MUST be `edpadmin`.
- **FR-010**: A random master password MUST be generated at provisioning time and MUST NOT be hardcoded in any Terraform source file or committed to version control.
- **FR-011**: The generated master password MUST be stored in AWS Secrets Manager in a secret whose name includes the environment identifier (e.g., `/chedaws-edp/<environment>/redshift/master-password`).
- **FR-012**: A security group MUST be created that allows inbound TCP traffic on the Redshift port (5439) from the CIDR ranges of all discovered App-tier and DB-tier subnets.
- **FR-013**: The security group MUST deny all other inbound traffic not originating from App-tier or DB-tier subnet CIDRs.
- **FR-014**: Three environment-specific, service-specific AWS KMS Customer Managed Keys (CMKs) MUST be provisioned via a reusable Terraform module at `terraform/modules/kms/`. The root `kms.tf` MUST invoke this module using a single `module "kms"` block with `for_each = local.kms_services`, where `local.kms_services` is a map keyed by service name (`"redshift"`, `"sns"`, `"cloudwatch_logs"`) with each value containing the `service_principal` string. The module MUST accept three inputs: `service_name` (string), `service_principal` (string), and `environment` (string); and MUST expose three outputs: `key_arn`, `key_id`, and `alias_arn`. Each key MUST carry a lean key policy granting only the root IAM principal (full `kms:*` for key management recoverability) and the named service principal with the hardcoded action set: `kms:Encrypt`, `kms:Decrypt`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`, `kms:DescribeKey`, and `kms:CreateGrant`. The Redshift CMK (`module.kms["redshift"].key_arn`) MUST be used for Redshift cluster encryption at rest; the SNS CMK (`module.kms["sns"].key_arn`) MUST be used for the SNS alert topic; the CloudWatch Logs CMK (`module.kms["cloudwatch_logs"].key_arn`) MUST be used for the CloudWatch Log Group. KMS keys for services not yet provisioned (S3, EBS, RDS, Glue, etc.) are explicitly deferred to the features that introduce those services, which will add entries to `local.kms_services`.
- **FR-015**: KMS key deletion protection MUST be enabled on all three service-specific CMKs. The pending deletion window MUST be set to 30 days (`deletion_window_in_days = 30`). Automatic key rotation (`enable_key_rotation = true`) MUST be enabled on all three keys.
- **FR-016**: Automated Redshift snapshots MUST be enabled with a retention period of at least 1 day for `dev`/`test` and at least 7 days for `uat`/`prod`.
- **FR-017**: Every AWS resource provisioned by this feature MUST have a name or identifier that includes the environment suffix to prevent conflicts when multiple environments share the same AWS account.
- **FR-018**: Every taggable resource MUST carry the standard cost allocation and operational tags defined in the provider's `default_tags` block in `terraform/providers.tf` (`Environment`, `Project`, `ApplicationOwner`, `BusinessUnit`, `ManagedBy`, `Team`, `Application`, `GitRepo`). No per-resource `tags` argument or `local.common_tags` merge is required; the provider applies these tags automatically to every resource.
- **FR-019**: CloudWatch metric alarms MUST be created for the Redshift cluster covering at minimum: CPU utilisation (%), percentage disk space used, and database connection count. Alarm thresholds MUST be environment-appropriate and are defined as follows: CPUUtilization ≥ 85% (all environments), PercentageDiskSpaceUsed ≥ 80% (all environments), DatabaseConnections ≥ 450 (`dev`/`test`) or ≥ 900 (`uat`/`prod`). All alarms evaluate over 2 periods of 300 seconds and treat missing data as `notBreaching`. Each alarm MUST publish to an SNS topic named `chedaws-edp-alerts-<environment>`, which MUST be created as part of this feature. This topic is the shared notification channel for all future EDP CloudWatch alarms in the environment; subscription wiring (email, PagerDuty, Slack) is explicitly out of scope for this feature.
- **FR-020**: Redshift audit logging MUST be enabled with CloudWatch Logs as the destination (not S3). All three audit log types MUST be exported: connection log (authentication attempts, connections, disconnections), user log (user definition changes), and user activity log (SQL statements executed). A dedicated CloudWatch Log Group MUST be created named `/chedaws-edp/redshift/<environment>`, with retention periods of 7 days for `dev`/`test`, 30 days for `uat`, and 90 days for `prod`. The Log Group MUST be encrypted at rest using the dedicated CloudWatch Logs CMK (`kms_key_id = module.kms["cloudwatch_logs"].key_arn`).
- **FR-021**: TLS MUST be enforced for all client connections to the Redshift cluster. A custom Redshift parameter group MUST be created with `require_ssl = true`, and the cluster MUST reference this parameter group.

### Key Entities *(include if feature involves data)*

- **Redshift Cluster**: The primary analytics compute resource. Attributes: name, node type, node count, master username, encrypted password reference, VPC placement, subnet group, security group, KMS key ARN, snapshot retention.
- **Subnet Group**: A named collection of VPC subnets (App-tier + DB-tier) in which the cluster nodes are placed.
- **Security Group**: Controls inbound access to the cluster. Ingress rules are derived from the CIDR ranges of App-tier and DB-tier subnets.
- **KMS CMK (Redshift)**: Environment-scoped CMK provisioned via `module.kms["redshift"]` (`terraform/modules/kms/`), invoked from `kms.tf`. Used exclusively for Redshift cluster encryption at rest. Key policy: root IAM + `redshift.amazonaws.com`. Output consumed by callers: `key_arn`.
- **KMS CMK (SNS)**: Environment-scoped CMK provisioned via `module.kms["sns"]` (`terraform/modules/kms/`), invoked from `kms.tf`. Used exclusively for the SNS alert topic. Key policy: root IAM + `sns.amazonaws.com`. Output consumed by callers: `key_arn`.
- **KMS CMK (CloudWatch Logs)**: Environment-scoped CMK provisioned via `module.kms["cloudwatch_logs"]` (`terraform/modules/kms/`), invoked from `kms.tf`. Used exclusively for the CloudWatch Log Group. Key policy: root IAM + `logs.<region>.amazonaws.com`. Output consumed by callers: `key_arn`.
- **Secrets Manager Secret**: Stores the Redshift master password. Scoped per environment; name includes the environment identifier.
- **Parameter Group**: A custom Redshift parameter group with `require_ssl = true` to enforce TLS for all client connections.
- **SNS Alert Topic**: An environment-scoped SNS topic (`chedaws-edp-alerts-<environment>`) that receives CloudWatch alarm notifications. Intended as the shared alerting channel for all future EDP alarms in the environment; subscription management is out of scope for this feature.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An infrastructure engineer can deploy the Redshift cluster to all four environments by selecting the appropriate Terraform workspace and running a single `terraform apply`, with no manual credential handling required.
- **SC-002**: All four environments (`dev`, `test`, `uat`, `prod`) can coexist in the same or different AWS accounts without any resource name conflicts.
- **SC-003**: No Redshift master password or other secret value is present in plaintext in any Terraform source file, plan output, or version-controlled artifact.
- **SC-004**: The Redshift cluster is reachable from any host in an App-tier or DB-tier subnet and is unreachable from all other subnets within the VPC.
- **SC-005**: Each environment has its own set of dedicated, service-specific KMS keys (Redshift, SNS, CloudWatch Logs) — compromising or deleting one environment's key, or one service's key, has no impact on other environments or other services within the same environment.
- **SC-006**: Infrastructure engineers can confirm the active environment's Redshift password by retrieving it from Secrets Manager within 60 seconds of cluster provisioning completing.
- **SC-007**: `dev`/`test` clusters consume smaller instance types (`rg.xlarge`) and `uat`/`prod` clusters consume larger instance types (`rg.4xlarge`), demonstrating environment-aware cost optimisation.
- **SC-008**: CloudWatch alarms for CPU utilisation, disk space used %, and connection count are active for the Redshift cluster in every environment and are configured with thresholds appropriate to each environment's workload.
- **SC-009**: After cluster provisioning, connection log, user log, and user activity log entries are observable in the CloudWatch Log Group `/chedaws-edp/redshift/<environment>`. Any connection attempt using a non-SSL client is rejected by the cluster.

## Assumptions

- `rg.xlarge` and `rg.4xlarge` are valid AWS Redshift Graviton-based node type identifiers, confirmed via AWS documentation. They are the preferred node types for new clusters over the older RA3 family. FR-004 uses these types.
- Dev and test environments share the same AWS account (`381491832813`) and VPC (`vpc-033a54f281e4e2219`); the environment suffix on all resource names prevents conflicts between them.
- The standard Redshift port (5439) is used for all connectivity.
- Snapshot automated retention periods: 1 day for `dev`/`test`, 7 days for `uat`/`prod` (minimum; can be extended without a spec change).
- The Secrets Manager secret path convention is `/chedaws-edp/<environment>/redshift/master-password`; this can be adjusted during implementation without changing the spec intent.
- All Redshift resources (cluster, subnet group, security group, Secrets Manager secret, CloudWatch alarms, CloudWatch Log Group) MUST be defined inline in the root Terraform configuration. No `terraform/modules/redshift-cluster/` module will be created; only one cluster per environment is planned and no second module consumer exists, making a module non-compliant with constitution v1.1.0.
- A reusable KMS CMK module EXISTS at `terraform/modules/kms/` with inputs `service_name` (string), `service_principal` (string), `environment` (string) and outputs `key_arn`, `key_id`, `alias_arn`. The module encapsulates the key resource, lean policy document, and alias. It MUST include a `README.md` with a "Consumers" section per constitution v1.1.0. Constitution VI is satisfied by three distinct module invocations (`"redshift"`, `"sns"`, `"cloudwatch_logs"`) via `for_each`.
- Terraform file organization follows a feature-centric co-location pattern with the following file responsibilities: (1) `kms.tf` — invokes `module "kms"` with `for_each = local.kms_services` to provision the three service-specific CMKs; actual key resources, policy documents, and aliases reside in `terraform/modules/kms/`; the platform-wide KMS posture remains visible at a glance in `kms.tf`; (2) `redshift.tf` — all resources exclusively dedicated to the Redshift feature (Security Group, Secrets Manager secret and password generator, Redshift subnet group, cluster, parameter group, CloudWatch Log Group, and CloudWatch metric alarms); (3) `sns.tf` — the SNS alert topic, which is intended for reuse by future EDP features; (4) Terraform conventional files (`data.tf`, `locals.tf`, `outputs.tf`) retain all data source blocks, local values, and output definitions respectively. The previous pattern of co-locating inline KMS resources inside `redshift.tf` is superseded by this `kms.tf` + module approach.
- Multi-AZ placement is not required; the subnet group will include subnets from the discovered App-tier and DB-tier subnets without an explicit multi-AZ constraint. Native Redshift multi-AZ mode is deferred to a future requirement.
- Resource tagging is handled exclusively via the provider's `default_tags` block in `terraform/providers.tf` — no `local.common_tags` map is used or required. The existing `default_tags` include `Environment`, `Project`, `ApplicationOwner`, `BusinessUnit`, `ManagedBy`, `Team`, `Application`, and `GitRepo`. FR-018 has been updated to reflect these actual tag keys.
- Outbound rules for the security group follow AWS defaults (allow all outbound); no explicit egress restrictions are required beyond what the VPC NACLs provide.
- The cluster will be created with `publicly_accessible = false`; all access is VPC-internal only.
