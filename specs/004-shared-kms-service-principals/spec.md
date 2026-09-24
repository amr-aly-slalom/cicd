# Feature Specification: Shared KMS Key for Multiple Similar Service Principals

**Feature Branch**: `004-shared-kms-service-principals`

**Created**: 2026-06-30

**Status**: Draft

**Input**: User description: "one KMS can be used for multiple similar aws service principal"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Group Similar Services Under One KMS Key (Priority: P1)

As an infrastructure operator, I want to assign multiple similar AWS service principals to a single KMS key, so that the number of customer-managed KMS keys in the account is reduced and key management is simplified.

**Why this priority**: The current design creates one KMS key per AWS service. Services with related purposes (e.g., two regional CloudWatch Logs endpoints, or two closely coupled pipeline services) share identical trust requirements and key-policy shape. Consolidating them under one key reduces cost, audit surface, and operational overhead.

**Independent Test**: Can be verified by declaring a shared KMS entry in infrastructure configuration with two service principals, applying the infrastructure change, and confirming that both service principals appear in the resulting KMS key policy and that both services can encrypt/decrypt data with that key.

**Acceptance Scenarios**:

1. **Given** a KMS key entry is configured with two service principals, **When** the infrastructure is applied, **Then** the KMS key policy contains a single `AllowServiceAccess` statement that grants the required actions to both service principals.
2. **Given** a KMS key entry is configured with two service principals, **When** the infrastructure is applied, **Then** each service can independently use the key for encryption and decryption operations.
3. **Given** an existing single-principal KMS key entry, **When** a second principal is added to that entry, **Then** the existing KMS key is updated in-place (no replacement) and no encryption/decryption disruption occurs.

---

### User Story 2 - Single-Principal Entries Remain Unchanged (Priority: P2)

As an infrastructure operator, I want existing single-principal KMS key entries to continue working without modification, so that introducing the multi-principal capability is non-breaking.

**Why this priority**: Backward compatibility is essential; the four existing service entries (Redshift, SNS, CloudWatch Logs, MSK) must not require immediate migration.

**Independent Test**: Can be verified by confirming that an existing single-service-principal entry applies without error and produces a key policy identical to the pre-change baseline.

**Acceptance Scenarios**:

1. **Given** a KMS key entry that declares only one service principal, **When** infrastructure is applied, **Then** the key policy grants actions to exactly that one principal (unchanged behaviour).
2. **Given** the four existing KMS entries (redshift, sns, cloudwatch_logs, msk) with their current single principals, **When** the infrastructure is applied after the feature is delivered, **Then** all four keys plan with no changes.

---

### Edge Cases

- What happens when an empty list of service principals is provided? Validation must reject this and surface a clear error before any infrastructure change is attempted.
- What happens when duplicate service principals are specified in the same entry? Duplicates MUST be silently deduplicated (set semantics); the resulting key policy contains each unique principal exactly once, with no error raised.
- What happens when a service that previously had its own key is merged into a shared key? The old key is destroyed and services must be re-encrypted — this is a disruptive migration and must be explicitly planned as a separate activity.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The KMS module MUST accept one or more AWS service principals per key, replacing the current single-value input.
- **FR-002**: The KMS key policy MUST include all declared service principals in the `AllowServiceAccess` statement, granting each principal the same set of permitted KMS actions currently defined.
- **FR-003**: Infrastructure configuration MUST allow operators to declare a named KMS entry with a list of one or more service principals without changing any other field.
- **FR-004**: A KMS entry with a single service principal MUST behave identically to the pre-change behaviour (no breaking change for existing entries).
- **FR-005**: The configuration MUST validate that at least one service principal is provided per entry; an empty principal list MUST be rejected before any infrastructure change is applied.
- **FR-006**: The KMS alias and key description MUST continue to use the entry's logical name (e.g., `cloudwatch_logs`) regardless of how many service principals are listed.

### Key Entities *(include if feature involves data)*

- **KMS Service Entry**: A named configuration record that maps a logical service name to one or more AWS service principals and produces exactly one KMS customer-managed key and one alias.
- **Service Principal**: An AWS service identity (e.g., `logs.us-east-1.amazonaws.com`) that is granted encrypt/decrypt permissions on the KMS key via its resource policy.
- **KMS Key Policy**: The resource-level IAM policy attached to the KMS key that controls which principals may use the key.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Operators can declare a shared KMS entry with two or more service principals and apply it successfully in a single Terraform run without errors.
- **SC-002**: All four existing KMS entries (redshift, sns, cloudwatch_logs, msk) plan with zero changes after the feature is delivered, confirming backward compatibility.
- **SC-003**: Infrastructure linting and policy-compliance scans (tflint, Checkov) pass with no new violations introduced by this change.
- **SC-004**: The number of KMS keys required to cover a new group of similar services is reduced from N (one per service) to 1 (one shared key), for any group of two or more services with identical trust requirements.

## Assumptions

- This feature delivers only the multi-principal capability (module change). No existing KMS entries will be consolidated and no new shared entries will be added to the live configuration as part of this delivery; all concrete groupings are explicitly follow-on work.
- All service principals within a shared entry receive identical KMS action permissions; per-principal permission differentiation is out of scope.
- The KMS module alias and description naming convention continues to use the entry's logical name, not a concatenation of all service names.
- "Similar" is informal guidance only — no enforcement or validation of service-principal category is performed by the configuration or module. Operators are responsible for ensuring that principals grouped under one key have compatible trust requirements and that consolidation does not violate least-privilege principles (Constitution §I).
- Multi-region service principals (e.g., CloudWatch Logs in a second region) are the primary expected use case for this feature, though the implementation must not restrict the feature to that scenario.

## Clarifications

### Session 2026-06-30

- Q: How should duplicate service principals in the same entry be handled — silently deduplicate or reject with an error? → A: Silently deduplicate (set semantics; no error raised).
- Q: Is "similar" a formally enforced constraint or informal operator guidance? → A: Informal guidance only — no enforcement in configuration or module.
- Q: Should this feature deliver a concrete shared KMS entry in the live configuration, or only the module capability? → A: Capability only — all concrete groupings are follow-on work.
