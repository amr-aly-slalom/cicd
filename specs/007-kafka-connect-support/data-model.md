# Data Model: Kafka Connect Support

**Date**: 2026-07-21

---

## Entities

### KafkaConnectRegistration

Represents a single Kafka Connect distributed-mode cluster (one or more workers sharing a `group.id`) and its relationship to the MSK cluster.

| Field | Type | Constraints | Description |
|---|---|---|---|
| `apiVersion` | string | const `kafka.chedaws.io/v1` | API version |
| `kind` | string | const `KafkaConnectRegistration` | Resource kind |
| `metadata.name` | string | `^[a-z][a-z0-9-]*$`, unique across all connect files | Unique slug; used verbatim in IAM and topic resource names |
| `metadata.owner` | string | minLength 1 | Team slug |
| `metadata.description` | string | optional | Free-text description |
| `spec.variant` | string | `enum: [standard, confluent]`; optional | When `confluent`, provisions `<name>-confluent-license` topic and grants IAM access to it. Absent = standard. |
| `spec.sources` | array | minItems 1 | List of `{businessName, appName}` pairs identifying the `TopicRegistration` groups this server produces for |
| `spec.sources[].businessName` | string | `^[a-z][a-z0-9-]*$` | Must match `metadata.businessName` of a registered `TopicRegistration` |
| `spec.sources[].appName` | string | `^[a-z][a-z0-9-]*$` | Must match `metadata.appName` of a registered `TopicRegistration` |
| `spec.connect.onPrem` | boolean | optional; default false | When true, IAM Roles Anywhere trust is used |
| `spec.connect.environments` | object | minProperties 1; keys `^(dev\|test\|uat\|prod)$` | Per-environment identity bindings |
| `spec.connect.environments.<env>.iamRoles` | array of ARNs | `^arn:aws:iam::[0-9]{12}:role/.+$` | Cloud IAM roles to trust; mutually exclusive with `certificateSubject` |
| `spec.connect.environments.<env>.certificateSubject` | array of CNs | `^CN=.+$` | Certificate subjects for IAM Roles Anywhere; mutually exclusive with `iamRoles` |

**Uniqueness key**: `(apiVersion, kind, metadata.name)`

**File path convention**: `kafka/connect/<businessName>/<name>.yaml` where `businessName` is the primary business unit served by this registration.

---

### TopicRegistration (modified)

The `spec.producer` field is made optional. All other fields are unchanged from the existing schema.

| Change | Before | After |
|---|---|---|
| `spec.producer` required | yes | no — optional when app is connect-owned |

**Invariant** (enforced by CI, not JSON Schema): A `TopicRegistration` file with no `spec.producer` block MUST appear as a `{businessName, appName}` source entry in exactly one active `KafkaConnectRegistration`.

---

### System Topics (derived — not a YAML entity)

System topics are not declared in any YAML file — they are derived by Terraform from the `KafkaConnectRegistration` entities present in each environment. They are not addressable by consumers.

| Topic name pattern | Partitions | Cleanup policy | Retention | Purpose |
|---|---|---|---|---|
| `<name>-connect-config` | 1 | `compact` | infinite | Stores connector and task configurations |
| `<name>-connect-offsets` | 25 | `compact` | infinite | Source connector read checkpoints (partition offsets) |
| `<name>-connect-status` | 5 | `compact,delete` | 1 day | Connector and task lifecycle state (running/failed/paused) |
| `<name>-confluent-license` | 1 | `compact` | infinite | Confluent Platform license metadata (Confluent variant only) |

---

### Connect IAM Role (derived — not a YAML entity)

One IAM role per `KafkaConnectRegistration` per environment.

| Attribute | Value |
|---|---|
| Name pattern | `edp-<env>-kafka-connect-<name>` |
| Max name length | 64 characters |
| Trust policy (cloud) | `Principal: { AWS: [<iamRoles>] }`, `Action: sts:AssumeRole` |
| Trust policy (on-prem) | `Principal: { Service: rolesanywhere.amazonaws.com }`, `Action: [sts:AssumeRole, sts:TagSession, sts:SetSourceIdentity]`, `Condition: ForAnyValue:StringEquals: aws:PrincipalTag/x509Subject/CN` |
| Permissions scope | Connect to cluster + Produce on all source business topics + Read/Write on all `<name>-*` system topics + Manage `<name>-*` consumer groups |

---

## State Transitions

### KafkaConnectRegistration lifecycle

```
[file added to kafka/connect/] → CI validates → terraform apply → IAM role + system topics created
[environment added to spec.connect.environments] → apply → new-env role + system topics created
[environment removed from spec.connect.environments] → apply → env role + system topics destroyed
[source added to spec.sources] → apply → existing role policy updated with new topic ARNs
[source removed from spec.sources] → apply → existing role policy updated (topic ARNs removed)
[file deleted from kafka/connect/] → CI rejects (no decommission guard currently) → requires decommission process
```

### TopicRegistration when connect-owned

```
[producer block present, no connect owner] → per-app IAM role provisioned by kafka_topics.tf
[producer block removed + connect registration added] → apply destroys per-app role, creates connect role
[connect registration removed + producer block restored] → apply destroys connect role, creates per-app role
```

---

## Validation Rules (CI)

| Rule | Enforced by |
|---|---|
| `metadata.name` matches `^[a-z][a-z0-9-]*$` | JSON Schema |
| `spec.sources` non-empty | JSON Schema |
| Per-env: `iamRoles` XOR `certificateSubject` | JSON Schema `oneOf` |
| `metadata.name` unique across all connect files | `validate-topic-names.py` |
| Each `{businessName, appName}` in `spec.sources` resolves to an existing `TopicRegistration` | `validate-topic-names.py` |
| `TopicRegistration` with no `producer` block appears in exactly one connect registration | `validate-topic-names.py` |
| IAM role name ≤ 64 chars | `terraform_data` precondition + `validate-topic-names.py` |
| `certificateSubject` entries match `^CN=.+$` | JSON Schema |
| `iamRoles` entries match `^arn:aws:iam::[0-9]{12}:role/.+$` | JSON Schema |
