# Feature Specification: Amazon MSK Cluster Provisioning

**Feature Branch**: `feat/msk-cluster`

**Created**: 2026-06-30

**Status**: Draft

**Input**: User description: "create amazon msk cluster with `kafka.m7g` instance class. dev and test environment don't need to have highly available configuration, but uat and prod must have highly available configuration. dev and test environments should have smallest instances possible with 200 GB storage. uat and prod should have 2xlarge for now, with the provision to vertical scalling if the demand increases. uat and prod should have 2 TB disk storage at the start, with the provision to increase the storage on demand. We will have 4 large stream of data and estimated data volumes are: 100 GB/day, 50 GB/day, 30 GB/day and 30 GB/day. We don't need to create the topics now, the data volumes are shared to analyze cluster configuration at this point. There will more smaller data streams coming to the cluster. All these data streams will be consumed by AWS Glue Streaming job to load them in S3Tables, which is not in scope of our development today."

## Clarifications

### Session 2026-06-30

- Q: What starting EBS storage per broker should be used for dev/test, given MSK storage auto-scaling? → A: 100 GB (reduced from 200 GB; MSK EBS storage auto-scaling handles organic growth beyond the starting size)
- Q: What starting EBS storage per broker should be used for uat/prod, given MSK storage auto-scaling? → A: 500 GB (reduced from 2,048 GB; MSK EBS storage auto-scaling handles growth as stream volumes accumulate)
- Q: In which VPC subnet tier should MSK broker nodes be placed? → A: App-tier subnets (`Tier=App`); Glue Streaming jobs will be deployed in the same App-tier subnets
- Q: Should the MSK security group allow inbound connections from DB-tier (`Tier=Db`) subnet CIDRs in addition to App-tier? → A: App-tier only — restrict ingress to `Tier=App` subnet CIDRs; no DB-tier access granted (least privilege; no current DB-tier consumers identified)
- Q: Should MSK storage auto-scaling be enabled for dev/test at the 100 GB starting size, or kept disabled (manual resize only)? → A: Enabled with a lower ceiling — auto-scaling enabled for all environments; dev/test max is 1,024 GB (1 TB) per broker; uat/prod max remains 16,384 GB (16 TB) per broker

### Session 2026-06-30 (round 2)

- Q: What is the smallest supported MSK broker instance type for dev/test? → A: `kafka.m7g.large` — confirmed as the smallest available instance in the `kafka.m7g` family; `kafka.m7g.small` is not available in the target region.
- Q: What log retention period should be used for prod? → A: 30 days — same as uat; 90-day retention is not required. Retention for dev/test remains 7 days.
- Q: Is `"3.9.x"` a valid Kafka version string for the MSK `kafka_version` argument, or does it need to be pinned to an exact patch (e.g., `"3.9.0"`)? → A: `"3.9.x"` is the correct and valid version string — Amazon MSK accepts the minor-version notation directly.
- Q: The constitution requires `enhanced_monitoring` ≥ `PER_BROKER` for all environments, but FR-015 specifies `DEFAULT` for dev/test — which takes precedence? → A: Follow the constitution — dev/test upgraded to `PER_BROKER`; uat/prod remain `PER_TOPIC_PER_BROKER`.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Deploy MSK Cluster Per Environment (Priority: P1)

An infrastructure engineer selects the appropriate Terraform workspace (`dev`, `test`, `uat`, or `prod`) and runs `terraform apply` to provision a correctly sized, named, and encrypted Amazon MSK cluster in the target VPC.

**Why this priority**: This is the core deliverable — the MSK cluster must exist before any streaming pipelines can be validated.

**Independent Test**: Select the `dev` workspace, run `terraform apply`, and verify that an MSK cluster named `chedaws-edp-msk-dev` exists in the `dev` VPC with 2 `kafka.m7g.large` broker nodes, 100 GB EBS storage per broker, and KMS encryption at rest.

**Acceptance Scenarios**:

1. **Given** the `dev` workspace is active, **When** `terraform apply` is run, **Then** a 2-broker MSK cluster named `chedaws-edp-msk-dev` is created in the dev VPC using `kafka.m7g.large` instances with 100 GB EBS storage per broker and storage auto-scaling enabled up to 1 TB per broker.
2. **Given** the `test` workspace is active, **When** `terraform apply` is run, **Then** a 2-broker MSK cluster named `chedaws-edp-msk-test` is created in the test VPC using `kafka.m7g.large` instances with 100 GB EBS storage per broker and storage auto-scaling enabled up to 1 TB per broker.
3. **Given** the `uat` workspace is active, **When** `terraform apply` is run, **Then** a 3-broker MSK cluster named `chedaws-edp-msk-uat` is created across 3 Availability Zones using `kafka.m7g.2xlarge` instances with 500 GB EBS storage per broker and storage auto-scaling enabled up to 16 TB per broker.
4. **Given** the `prod` workspace is active, **When** `terraform apply` is run, **Then** a 3-broker MSK cluster named `chedaws-edp-msk-prod` is created across 3 Availability Zones using `kafka.m7g.2xlarge` instances with 500 GB EBS storage per broker and storage auto-scaling enabled up to 16 TB per broker.
5. **Given** both `dev` and `test` workspaces have been applied into the same AWS account, **When** all MSK clusters are listed in the console, **Then** no resource name conflicts exist — `chedaws-edp-msk-dev` and `chedaws-edp-msk-test` are fully distinct resources.

---

### User Story 2 - Environment-Appropriate High-Availability (Priority: P2)

An infrastructure engineer can confirm that dev and test MSK clusters use a minimal, cost-optimised non-HA broker layout, while UAT and prod clusters are distributed across three Availability Zones so that the loss of a single AZ does not interrupt streaming ingestion.

**Why this priority**: HA configuration directly determines both cost and resilience. Correct sizing per environment ensures budget control in lower environments and production-grade fault tolerance where it matters.

**Independent Test**: After applying all four environments, inspect the `dev` cluster and confirm brokers span a maximum of 2 AZs. Inspect the `prod` cluster and confirm brokers span exactly 3 AZs. Simulate AZ failure in a sandbox and confirm the prod cluster continues accepting messages.

**Acceptance Scenarios**:

1. **Given** the `dev` workspace has been applied, **When** the MSK cluster topology is inspected, **Then** broker nodes are distributed across a maximum of 2 Availability Zones (non-HA, cost-optimised).
2. **Given** the `test` workspace has been applied, **When** the MSK cluster topology is inspected, **Then** broker nodes are distributed across a maximum of 2 Availability Zones (non-HA, cost-optimised).
3. **Given** the `uat` workspace has been applied, **When** the MSK cluster topology is inspected, **Then** broker nodes are distributed across exactly 3 Availability Zones, and the cluster continues operating if any single AZ becomes unavailable.
4. **Given** the `prod` workspace has been applied, **When** the MSK cluster topology is inspected, **Then** broker nodes are distributed across exactly 3 Availability Zones, and the cluster continues operating if any single AZ becomes unavailable.

---

### User Story 3 - Vertical and Storage Scaling for UAT/Prod (Priority: P2)

An infrastructure engineer can increase the broker instance type (vertical scale up) or expand EBS storage for UAT and prod MSK clusters by updating a Terraform local value and re-applying, without replacing the cluster or losing data.

**Why this priority**: Anticipated stream growth (additional smaller streams beyond the initial four) requires a safe, non-disruptive scaling path. Instance type and storage limits must not block the platform's ability to absorb new data sources.

**Independent Test**: On a UAT cluster provisioned at `kafka.m7g.2xlarge` with 500 GB per broker, update the mapped instance type in `locals.tf` to `kafka.m7g.4xlarge` and run `terraform plan` — verify the plan shows an in-place broker update rather than cluster replacement.

**Acceptance Scenarios**:

1. **Given** a UAT MSK cluster is running at `kafka.m7g.2xlarge`, **When** the instance type mapped value in `locals.tf` is updated to `kafka.m7g.4xlarge` and `terraform apply` is run, **Then** brokers are upgraded in place without cluster recreation or data loss.
2. **Given** an MSK cluster in any environment with per-broker EBS storage approaching the provisioned limit, **When** the 80% utilisation threshold is reached, **Then** EBS volume capacity expands automatically without cluster interruption or operator intervention (up to 1 TB/broker for dev/test; up to 16 TB/broker for uat/prod).
3. **Given** a UAT MSK cluster running at 500 GB per broker, **When** the per-broker storage variable is increased and `terraform apply` is run, **Then** storage is expanded in place without cluster replacement or data loss.

---

### User Story 4 - Secure Connectivity for AWS Glue Streaming (Priority: P3)

An AWS Glue Streaming job running in an App-tier subnet within the EDP VPC can connect to the MSK cluster's IAM-authenticated endpoint, while all inbound connections from outside App-tier subnets are blocked.

**Why this priority**: MSK delivers no value without controlled, secure consumer connectivity. Cluster existence (P1) and correct sizing (P2) must come first; connectivity validation follows.

**Independent Test**: From a host or Glue job in an App-tier subnet, verify a successful TCP connection to the MSK IAM bootstrap endpoint on port 9098. From a host in a subnet outside the App-tier CIDR ranges, verify the connection is refused.

**Acceptance Scenarios**:

1. **Given** an MSK cluster has been provisioned, **When** a connection is attempted from an AWS Glue Streaming job (or a host in an App-tier subnet), **Then** the connection to the MSK IAM-authenticated Kafka endpoint (port 9098) is accepted.
2. **Given** an MSK cluster has been provisioned, **When** a connection is attempted from a host in a subnet outside the App-tier CIDR ranges, **Then** the connection is denied by the MSK security group.

---

### Edge Cases

- What happens if the `aws_subnets` data lookup returns fewer than 2 App-tier subnets for `dev`/`test` or fewer than 3 App-tier subnets for `uat`/`prod`? The Terraform plan MUST fail with a descriptive error rather than silently creating a misconfigured broker layout.
- What happens if a workspace name is provided that is not one of `dev`, `test`, `uat`, `prod`? The deployment MUST fail with a clear error (locals map lookup error on unknown key).
- What happens when `dev` and `test` workspaces are applied into the same account simultaneously? All named resources MUST carry the environment suffix to prevent conflicts.
- What happens when EBS storage auto-scaling reaches the configured ceiling (1 TB/broker for dev/test; 16 TB/broker for uat/prod)? The `KafkaDataLogsDiskUsed` CloudWatch alarm will fire when utilisation approaches 80% of the current provisioned size, notifying operators before the ceiling is hit. Once the ceiling itself is reached, the Terraform auto-scaling maximum value MUST be raised manually and `terraform apply` re-run.
- What happens if the MSK KMS CMK for an environment is accidentally deleted? MSK cluster data becomes inaccessible; KMS key deletion protection MUST be enabled on all MSK CMKs with a 30-day deletion window.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The Terraform configuration MUST use `terraform.workspace` to determine the active environment (`dev`, `test`, `uat`, or `prod`).
- **FR-002**: An MSK cluster MUST be provisioned with the name `chedaws-edp-msk-<environment>` (e.g., `chedaws-edp-msk-dev`).

> *FR-003 through FR-007: all environment-specific sizing values (instance type, broker count, storage) MUST be implemented as Terraform local maps keyed by environment name, enabling any value to be updated via a single `locals.tf` entry without modifying resource blocks.*

- **FR-003**: The broker instance type MUST be `kafka.m7g.large` for `dev` and `test` environments, and `kafka.m7g.2xlarge` for `uat` and `prod` environments. A Terraform local value MUST be defined as a map keyed by environment name to instance type so that vertical scaling (e.g., to `kafka.m7g.4xlarge`) can be performed by updating a single entry in `locals.tf` without modifying resource blocks.
- **FR-004**: The number of broker nodes MUST be 2 for `dev` and `test` (non-HA; distributed across 2 Availability Zones), and 3 for `uat` and `prod` (HA; distributed across 3 Availability Zones). A Terraform local value MUST map environment names to broker counts.
- **FR-005**: The EBS storage volume per broker MUST be 100 GiB for `dev` and `test`, and 500 GiB for `uat` and `prod`. *(Values are in gibibytes (GiB) as used by the Terraform `volume_size` argument; storage ceiling values in FR-006 and FR-007 are also GiB.)* These starting sizes are deliberately smaller than the long-term retention requirement because MSK EBS storage auto-scaling expands capacity incrementally as topics are onboarded. A Terraform local value MUST map environment names to per-broker starting storage sizes.
- **FR-006**: MSK storage auto-scaling MUST be enabled for `uat` and `prod` environments. The maximum auto-scaling storage per broker MUST be set to 16,384 GiB (16 TiB). Auto-scaling MUST trigger before per-broker utilisation reaches 80%.
- **FR-007**: MSK storage auto-scaling MUST be enabled for `dev` and `test` environments. The maximum auto-scaling storage per broker MUST be set to 1,024 GiB (1 TiB). Auto-scaling MUST trigger before per-broker utilisation reaches 80%. The lower ceiling (vs 16 TiB for uat/prod) limits cost exposure in non-production environments while preventing silent storage exhaustion.
- **FR-008**: The MSK cluster MUST be placed in the VPC corresponding to the active workspace, as defined in `locals.tf`.
- **FR-009**: App-tier subnets MUST be discovered dynamically using the `aws_subnets` data source filtered by tag `Tier=App` within the active environment's VPC. MSK broker nodes MUST be placed in these App-tier subnets, co-locating them with AWS Glue Streaming jobs (which will also run in App-tier subnets) to minimise cross-subnet latency. The existing `aws_subnets` data source for `Tier=App` in `data.tf` (shared with the Redshift feature) MUST be reused rather than duplicated.
- **FR-010**: IAM access control (MSK IAM authentication) MUST be enabled as the sole client authentication mechanism. SASL/SCRAM and mTLS client certificate authentication MUST NOT be configured.
- **FR-011**: All data in transit between MSK clients and brokers MUST use TLS. The `encryption_in_transit` configuration MUST set `client_broker = "TLS"`. Inter-broker encryption MUST also be enforced via TLS.
- **FR-012**: An environment-specific KMS CMK MUST be added for MSK by inserting `"msk"` into `local.kms_services` in `locals.tf` with `service_principal = "kafka.amazonaws.com"`. The MSK cluster MUST reference this CMK (`module.kms["msk"].key_arn`) for encryption at rest. The existing `module "kms"` block in `kms.tf` will automatically provision the new key via `for_each`. The MSK KMS CMK MUST have a 30-day deletion window (`deletion_window_in_days = 30`).
- **FR-013**: A dedicated security group MUST be created for the MSK cluster. It MUST allow inbound TCP traffic on port 9098 (Kafka IAM-authenticated endpoint) and port 9094 (Kafka TLS endpoint) from the CIDR ranges of all discovered App-tier (`Tier=App`) subnets in the active environment's VPC.
- **FR-014**: The MSK security group MUST deny all inbound traffic not originating from App-tier subnet CIDRs. Outbound traffic follows AWS defaults (allow all). *(Together with FR-013, this defines the complete MSK security group ingress policy.)*
- **FR-015**: MSK enhanced CloudWatch monitoring MUST be set to `PER_TOPIC_PER_BROKER` for `uat` and `prod` environments, and `PER_BROKER` for `dev` and `test`. All environments MUST meet the constitutional minimum of `PER_BROKER`.
- **FR-016**: CloudWatch metric alarms MUST be created for the MSK cluster for the following conditions:
  - `UnderReplicatedPartitions` ≥ 1 (all environments; any under-replicated partition is a data durability risk)
  - `OfflinePartitionsCount` ≥ 1 (all environments; an offline partition means data is unavailable)
  - `ActiveControllerCount` < 1 (uat/prod only; loss of controller means the cluster cannot elect new leaders)
  - `KafkaDataLogsDiskUsed` at or above the 80% threshold of total broker storage (all environments; triggers before storage is exhausted)

  All alarms MUST publish to the SNS topic `chedaws-edp-alerts-<environment>` (provisioned by the Redshift cluster feature). All alarms MUST evaluate over 2 consecutive periods of 60 seconds. Missing data MUST be treated as `notBreaching`.

- **FR-017**: MSK broker logs MUST be delivered to a CloudWatch Log Group named `/chedaws-edp/msk/<environment>` with environment-tiered retention: 7 days for `dev`/`test`, and 30 days for `uat` and `prod`. The Log Group MUST be encrypted using the existing CloudWatch Logs CMK (`module.kms["cloudwatch_logs"].key_arn`) provisioned by the Redshift cluster feature.
- **FR-018**: Every AWS resource provisioned by this feature MUST have a name or identifier that includes the environment suffix (e.g., `-dev`, `-test`, `-uat`, `-prod`) to prevent conflicts when multiple environments share the same AWS account.
- **FR-019**: Every taggable resource MUST carry the standard cost allocation and operational tags defined in the provider's `default_tags` block in `terraform/providers.tf`. No per-resource `tags` argument or `local.common_tags` merge is required; the provider applies these tags automatically.
- **FR-020**: All MSK-related resources (MSK cluster, security group, CloudWatch Log Group, CloudWatch alarms) MUST be defined inline in the root Terraform configuration in a new file `terraform/msk.tf`. No `terraform/modules/msk-cluster/` module will be created; only one MSK cluster per environment is planned and no second module consumer exists, making a module non-compliant with constitution v1.1.0.
- **FR-021**: The Apache Kafka version deployed on MSK MUST be defined as a local value in `locals.tf` so that version upgrades can be performed by updating a single value without modifying resource blocks. The version MUST be the AWS Recommended version supported by Amazon MSK at the time of implementation (prefer the version marked "Recommended" in the MSK console over the absolute latest release, as AWS commits to extended support for recommended versions).

### Key Entities

- **MSK Cluster**: The primary streaming broker resource. Attributes: name, broker instance type, broker count, Kafka version, VPC placement, subnet list, security group, KMS key ARN, per-broker EBS storage, client authentication configuration, in-transit encryption mode.
- **Broker EBS Storage**: Per-broker EBS volume with configurable starting size. Storage auto-scaling is enabled for all environments, triggered at 80% utilisation, with environment-appropriate ceilings: 1,024 GB (1 TB) per broker for `dev`/`test`; 16,384 GB (16 TB) per broker for `uat`/`prod`.
- **Security Group (MSK)**: Controls inbound access to MSK broker nodes. Ingress from App-tier subnet CIDRs on ports 9094 (TLS) and 9098 (IAM).
- **KMS CMK (MSK)**: Environment-scoped CMK provisioned via `module.kms["msk"]` (`terraform/modules/kms/`). Key policy: root IAM + `kafka.amazonaws.com`. Output `key_arn` referenced by the MSK cluster for EBS encryption at rest.
- **CloudWatch Log Group**: MSK broker log destination. Name: `/chedaws-edp/msk/<environment>`. Encrypted using the existing CloudWatch Logs CMK from the Redshift cluster feature.
- **CloudWatch Alarms**: Monitor MSK operational health (UnderReplicatedPartitions, OfflinePartitionsCount, ActiveControllerCount, KafkaDataLogsDiskUsed). Publish to the environment-specific SNS alert topic.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An infrastructure engineer can deploy an MSK cluster to all four environments by selecting the appropriate Terraform workspace and running a single `terraform apply`, with no manual steps required.
- **SC-002**: All four environments (`dev`, `test`, `uat`, `prod`) can coexist in the same or different AWS accounts without any MSK resource name conflicts.
- **SC-003**: The `dev` and `test` MSK clusters demonstrably consume fewer cloud resources than `uat` and `prod` clusters (smaller instance types, fewer broker nodes, lower starting storage, and a lower storage auto-scaling ceiling of 1 TB vs 16 TB per broker), reflecting environment-aware cost optimisation.
- **SC-004**: UAT and prod MSK clusters remain operational and continue accepting producer connections when a single Availability Zone becomes unavailable (3-broker, 3-AZ HA layout).
- **SC-005**: MSK broker storage automatically expands before reaching 80% of provisioned capacity in all environments, requiring no operator intervention for routine stream volume growth. The maximum auto-scaling ceiling is 1 TB per broker for `dev`/`test` and 16 TB per broker for `uat`/`prod`.
- **SC-006**: The broker instance type for UAT and prod can be vertically scaled to a larger `kafka.m7g` variant by updating a single local value in `locals.tf` and running `terraform apply`, without cluster recreation.
- **SC-007**: All streaming traffic between Glue Streaming jobs and MSK brokers is encrypted in transit (TLS), and data at rest on MSK broker EBS volumes is encrypted using a dedicated environment-scoped CMK.
- **SC-008**: MSK operational health metrics (`UnderReplicatedPartitions`, `OfflinePartitionsCount`, `KafkaDataLogsDiskUsed`) are actively alarmed for all four environments, with notifications routed to the environment-specific SNS alert topic within 2 minutes of a threshold breach.
- **SC-009**: MSK broker log entries are observable in the CloudWatch Log Group `/chedaws-edp/msk/<environment>` for all four environments within minutes of cluster provisioning completing.

## Assumptions

- `kafka.m7g.large` is the smallest available instance type in the `kafka.m7g` family supported as an MSK broker instance type in the AWS ap-southeast-2 (Sydney) region. `kafka.m7g.small` is not available for MSK in this region.
- `kafka.m7g.2xlarge` is selected as the initial instance type for UAT and prod. Amazon MSK supports in-place broker instance type changes (vertical scaling) without cluster recreation. Future vertical scaling to `kafka.m7g.4xlarge`, `kafka.m7g.8xlarge`, or larger requires only updating the mapped value in `locals.tf`.
- Dev and test environments share the same AWS account (`381491832813`) and VPC (`vpc-033a54f281e4e2219`); the environment suffix on all resource names prevents resource conflicts.
- MSK broker nodes are placed in App-tier subnets (`Tier=App`). AWS Glue Streaming jobs will also run in App-tier subnets, co-locating producers and consumers with the MSK brokers to minimise cross-subnet latency and eliminate the need for tier-crossing security group rules.
- IAM authentication is the sole client authentication mechanism. This eliminates credential management (no SASL usernames/passwords or client TLS certificates to rotate) and aligns with the AWS-native service model. AWS Glue Streaming natively supports MSK IAM authentication without additional configuration.
- Kafka topics are out of scope for this feature. The data volume estimates (100 + 50 + 30 + 30 = 210 GB/day from four main streams, plus additional smaller streams) are used solely to validate cluster sizing:
  - At replication factor 3, total daily writes = 630 GB/day.
  - With 7-day Kafka topic retention: 4,410 GB total cluster storage required.
  - With 3 brokers at 500 GB each (1,500 GB starting total), initial provisioned storage is below the 4,410 GB retention target. MSK EBS storage auto-scaling will expand each broker's volume incrementally as topics are onboarded, triggering before 80% of the current provisioned size is reached. No data loss occurs during auto-scaling expansion.
  - Sustained producer throughput ≈ 7.5 MB/sec, peak estimate 15–22 MB/sec. `kafka.m7g.2xlarge` (8 vCPU, 32 GB RAM, ~12.5 Gbps network) is well within capacity for these volumes.
- The SNS alert topic (`chedaws-edp-alerts-<environment>`) provisioned by the Redshift cluster feature (spec 001) is used as the CloudWatch alarm notification destination. This topic is expected to exist in all target environments before this feature is applied.
- The CloudWatch Logs CMK (`module.kms["cloudwatch_logs"].key_arn`) provisioned by the Redshift cluster feature (spec 001) is reused for encrypting the MSK broker CloudWatch Log Group. No new Log Group CMK is required.
- MSK broker logs are enabled at the `INFO` level. Debug-level logging is not enabled as it would generate excessive log volume, particularly in production.
- The Kafka version is set to the latest stable version supported by Amazon MSK at the time of implementation, defined as a local value in `locals.tf`.
- The `module "kms"` block in `kms.tf` already uses `for_each = local.kms_services`. Adding `"msk"` to `local.kms_services` in `locals.tf` is sufficient to provision the MSK CMK — no changes to `kms.tf` resource blocks are needed.
- All MSK resources MUST be defined inline in `terraform/msk.tf`. No reusable MSK module will be created; constitution v1.1.0 prohibits modules with fewer than two distinct call sites, and only one MSK cluster per environment is planned.
- EBS storage auto-scaling is enabled for all environments. Maximum per-broker ceiling: 1,024 GB (1 TB) for `dev`/`test` and 16,384 GB (16 TB) for `uat`/`prod`. Both ceilings can be raised by updating the respective local values without a spec change.
- The `publicly_accessible` setting for MSK broker nodes is `false`; all access is VPC-internal only.
- Outbound security group rules follow AWS defaults (allow all outbound); no explicit egress restrictions are required beyond VPC NACLs.
