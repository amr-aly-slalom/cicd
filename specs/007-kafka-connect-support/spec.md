# Feature Specification: Kafka Connect Support

**Feature Branch**: `feat/kafka-connect`

**Created**: 2026-07-21

**Status**: Draft

**Input**: User description: "There is a kafka-connect server setup in an on-prem VM. I have been told that all events in kafka/producers/ue/siq.yaml and kafka/producers/ue/uiq.yaml will be sent to AWS MSK from that kafka connect server. Hence we need one IAM role for that on-prem server, instead of two. I have been told that kafka-connect requires three extra topics `connect-config`, `connect-offsets` and `connect-status`. And because the it's a confluent version of Kafka connect, it requires a `_confluent-license` topic. More kafka-connect server will connect to the MSK cluster in future, hence we need to make sure that we have consistent pattern and process to provision resources. We also need to ensure that the IAM role for producer and consumer have all necessary permission when the producer or consumer are a kafka connect server. Let's refactor current producer and consumer contracts to accommodate kafka connect."

## Clarifications

### Session 2026-07-21

- Q: Should Kafka Connect system topics be shared across all connect servers on the MSK cluster, or isolated per connect server (registration)? → A: Per-registration prefixed topics — each `KafkaConnectRegistration` gets its own prefixed system topics (e.g., `<registration-name>-connect-config`, `<registration-name>-connect-offsets`, `<registration-name>-connect-status`, `<registration-name>-confluent-license`). This correctly isolates distinct Kafka Connect distributed-mode clusters from each other and prevents configuration and offset collision across separate connect server deployments.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Register a Kafka Connect server as a shared producer (Priority: P1)

A platform engineer has a single on-prem Kafka Connect server (`CN=IOVLVDC2KAFN1`) that acts as the producer for all UE topics (currently split across `ue/siq.yaml` and `ue/uiq.yaml`). Today, two separate IAM roles are created — one per app — but the same certificate is trusted by both. The engineer needs to consolidate this into one IAM role covering all events that the connect server produces, and register that server's identity once using a new `kafkaConnect` contract type.

**Why this priority**: The current two-role model is redundant and will multiply further as more apps are onboarded. Fixing this first unblocks the correct IAM provisioning model that all future Kafka Connect registrations depend on.

**Independent Test**: Deploy the `ue` Kafka Connect producer registration to a test environment and verify: one IAM role is created (not two), the role's trust policy references `CN=IOVLVDC2KAFN1`, and the role's permission policy covers `Produce` on all five business topics (`hf-read-results`, `voltage-threshold-trap`, `ssnevent`, `export`, `odr`) plus the four prefixed system topics (`ue-connect-config`, `ue-connect-offsets`, `ue-connect-status`, `ue-confluent-license`).

**Acceptance Scenarios**:

1. **Given** the `ue` Kafka Connect producer YAML references two existing `TopicRegistration` sources and declares `type: kafka-connect` with `variant: confluent`, **When** Terraform applies, **Then** exactly one IAM role is created for the connect server and is trusted for all source topic groups.
2. **Given** the connect server's certificate subject appears in the registration, **When** Terraform applies, **Then** an IAM Roles Anywhere trust is established for `CN=IOVLVDC2KAFN1` on that single role.
3. **Given** the producer is `type: kafka-connect` with registration name `ue`, **When** Terraform evaluates the IAM permissions, **Then** the role receives `Produce` and `Describe` access on the prefixed system topics `ue-connect-config`, `ue-connect-offsets`, and `ue-connect-status`.
4. **Given** the Confluent variant is declared, **When** Terraform evaluates permissions, **Then** `ue-confluent-license` is included in addition to the three standard prefixed system topics.

---

### User Story 2 - Register additional Kafka Connect servers consistently (Priority: P2)

A new team wants to onboard a second on-prem Kafka Connect server that produces a different set of events. The engineer should be able to follow the same registration pattern established in User Story 1, with no bespoke Terraform required.

**Why this priority**: Consistency for future onboarding is a stated goal. The pattern must be generic enough that a second server requires only a new YAML file, not any Terraform changes.

**Independent Test**: Author a second Kafka Connect producer YAML for a different `businessName`/`appName` combination, run the full CI pipeline, and verify: a second IAM role is provisioned with its own unique name and permission scope, without touching the first server's role or any existing resources.

**Acceptance Scenarios**:

1. **Given** a new Kafka Connect producer YAML is added for a different team, **When** Terraform plans, **Then** only net-new resources are planned (no changes to existing roles or topics).
2. **Given** two Kafka Connect servers each have their own prefixed system topics, **When** Terraform applies, **Then** each server has its own IAM role and its own isolated set of prefixed system topics (e.g., `ue-connect-config` vs `vpn-connect-config`); no topics or roles are shared.
3. **Given** the new server does not use the Confluent variant, **When** Terraform applies, **Then** no `<name>-confluent-license` topic or IAM permission is created for that server.

---

### User Story 3 - Kafka Connect consumer registration with system topic permissions (Priority: P3)

A downstream team deploys a Kafka Connect sink connector (on-prem or cloud-based) that consumes business events produced via MSK. Its IAM role must also include the Kafka Connect system topic permissions required for the connector to operate.

**Why this priority**: Consumer-side Kafka Connect support completes the full contract model. Lower priority than producer because the immediate need is the UE producer; consumer support can follow once the producer pattern is validated.

**Independent Test**: Author a Kafka Connect consumer YAML for an existing topic, apply, and verify the consumer IAM role includes `Consume` on the referenced business topics and `Produce`/`Describe` on the system topics (Kafka Connect connectors both read and write to their internal system topics).

**Acceptance Scenarios**:

1. **Given** a consumer registration declares `type: kafka-connect`, **When** Terraform applies, **Then** the consumer IAM role includes permissions on the three standard system topics in addition to the declared business topic consume permissions.
2. **Given** the consumer registration declares `variant: confluent`, **When** Terraform applies, **Then** `<name>-confluent-license` is also included.
3. **Given** a consumer registration declares `type: kafka-connect` and `onPrem: true` with `certificateSubject`, **When** Terraform applies, **Then** an IAM Roles Anywhere trust is established for the consumer IAM role using the `ForAnyValue:StringEquals` condition on `aws:PrincipalTag/x509Subject/CN`.

---

### Edge Cases

- What happens when a Kafka Connect producer registration references a `TopicRegistration` app that does not exist?
- What happens when two different connect servers list overlapping `certificateSubject` values?
- How does the system handle a `kafkaConnect` producer where no `variant` is specified — should it default to standard (no `_confluent-license`) or require explicit declaration?
- What happens when the Confluent license topic name changes in a future release?
- How are prefixed system topics named across environments — do they incorporate the environment prefix (`edp-<env>`) or remain as `<registration-name>-connect-config` across all environments?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The platform MUST support a new `kafkaConnect` producer registration type that consolidates IAM provisioning for a single Kafka Connect server spanning multiple `TopicRegistration` sources into one IAM role.
- **FR-002**: A `kafkaConnect` producer registration MUST declare all source `TopicRegistration` groups it draws events from (by `businessName` and `appName`), so that the single IAM role's permission scope is derived from all referenced groups.
- **FR-003**: When a producer or consumer registration is of type `kafka-connect`, the platform MUST automatically provision and grant IAM permissions on three prefixed system topics unique to that registration: `<registration-name>-connect-config`, `<registration-name>-connect-offsets`, and `<registration-name>-connect-status`.
- **FR-004**: When a Kafka Connect registration declares `variant: confluent`, the platform MUST additionally provision and grant IAM permissions on `<registration-name>-confluent-license`.
- **FR-005**: The `kafkaConnect` producer registration contract MUST support `onPrem: true` with `certificateSubject` as the identity mechanism, using the existing IAM Roles Anywhere pattern.
- **FR-006**: The `kafkaConnect` consumer registration MUST support the same identity mechanisms as the existing consumer contract (`iamRoles` for cloud consumers, `certificateSubject` for on-prem), with the prefixed system topic permissions added automatically.
- **FR-007**: Each `KafkaConnectRegistration` MUST result in its own isolated set of system topics on MSK (`<name>-connect-config`, `<name>-connect-offsets`, `<name>-connect-status`, and optionally `<name>-confluent-license`), with appropriate configuration (partitions, retention, cleanup policy).
- **FR-008**: System topics MUST be provisioned once per registration — two separate `KafkaConnectRegistration` resources MUST NOT share system topics, as each represents a distinct Kafka Connect distributed-mode cluster with its own `group.id` and independent offset tracking.
- **FR-009**: The existing `TopicRegistration` and `ConsumerRegistration` YAML schemas MUST be extended or a new schema introduced to represent Kafka Connect registrations, and the JSON Schema validators MUST be updated accordingly.
- **FR-010**: The CI validation pipeline MUST validate Kafka Connect registrations using the updated schemas before any `terraform plan` stage.
- **FR-011**: Existing `TopicRegistration` YAML files for `ue/siq` and `ue/uiq` MUST be refactored so they no longer generate separate per-app IAM roles; the Kafka Connect registration becomes the authoritative source for the shared IAM role.
- **FR-012**: A `kafkaConnect` producer registration MUST be nameable distinctly from its source `TopicRegistration` groups, with a unique name used in IAM resource naming (to avoid resource naming collisions as more connect servers are onboarded).

### Key Entities

- **KafkaConnectRegistration**: A new contract kind (`kind: KafkaConnectRegistration`) declaring a named connect server identity, the list of source `TopicRegistration` groups it aggregates, whether it is on-prem or cloud, the variant (standard or confluent), and per-environment identity bindings.
- **System Topics**: The set of Kafka internal topics required by a Kafka Connect distributed-mode cluster (`connect-config`, `connect-offsets`, `connect-status`, and optionally `_confluent-license`). Each `KafkaConnectRegistration` receives its own isolated, prefixed set (e.g., `ue-connect-config`) to prevent configuration and offset collision across separate connect deployments sharing the same MSK broker.
- **Connect IAM Role**: One IAM role per Kafka Connect server per environment. Covers produce/describe permissions on all aggregated business topics plus system topic access. Trusts the server's certificate subject (on-prem) or assumes a cloud IAM role ARN.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The UE Kafka Connect server (`CN=IOVLVDC2KAFN1`) is represented by exactly one IAM role in each active environment, down from two previously.
- **SC-002**: Adding a new Kafka Connect server registration requires only a new YAML file — zero Terraform module changes or new resource blocks needed.
- **SC-003**: Each Kafka Connect registration results in its own isolated set of prefixed system topics on MSK; registering a second connect server does not share or overwrite the first server's system topics.
- **SC-004**: CI validation rejects a Kafka Connect registration that references a non-existent `TopicRegistration` source before any `terraform plan` runs.
- **SC-005**: A Kafka Connect IAM role's permission policy is fully derivable from the YAML contracts alone — no manual Terraform edits are required to grant access to additional business topics when a new source group is added to an existing connect server registration.
- **SC-006**: The refactored `ue/siq` and `ue/uiq` YAML files continue to produce identical business topic resources (same topic names, partitions, retention) after the IAM provisioning responsibility is transferred to the Kafka Connect registration.

## Assumptions

- Each Kafka Connect registration's system topics are named with a `<registration-name>-` prefix (e.g., `ue-connect-config`) to isolate distinct distributed-mode clusters sharing the same MSK broker. They do not follow the `edp-<env>.<businessName>.<appName>.<event>` convention used for business topics.
- The `_confluent-license` topic applies only to the Confluent Platform distribution of Kafka Connect; a non-Confluent (Apache) Kafka Connect server does not require it.
- The on-prem Kafka Connect server uses IAM Roles Anywhere with an existing PKI trust anchor already provisioned in AWS; this feature does not provision the trust anchor itself.
- Kafka Connect system topics require `connect-config` with `cleanupPolicy: compact` (1 partition, `retentionMs: -1`), `connect-offsets` with `cleanupPolicy: compact` (25 partitions, `retentionMs: -1`), `connect-status` with `cleanupPolicy: compact,delete` (5 partitions, `retentionMs: 86400000`).
- The `_confluent-license` topic requires `cleanupPolicy: compact`.
- A single Kafka Connect server is scoped to one on-prem VM per registration; a VM hosting multiple connect workers is still treated as one logical server identity.
- The existing `ue/siq.yaml` and `ue/uiq.yaml` IAM blocks will have their per-app IAM role generation disabled (or removed) once the Kafka Connect registration takes ownership of the shared IAM role. Topic resources in those files are not affected.
- All four environments (`dev`, `test`, `uat`, `prod`) may not be active for every Kafka Connect registration — the registration contract follows the same per-environment opt-in pattern as existing producer contracts.
- The consumer-side Kafka Connect support (User Story 3) will reuse the updated `ConsumerRegistration` schema with an added `type` and optional `variant` field rather than requiring a separate contract file.
