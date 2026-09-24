# Implementation Plan: Kafka Connect Support

**Branch**: `feat/kafka-connect` | **Date**: 2026-07-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/007-kafka-connect-support/spec.md`

## Summary

Teams register a named Kafka Connect server by adding a `KafkaConnectRegistration` YAML file under `kafka/connect/`. The registration declares which `TopicRegistration` source apps the server aggregates, whether it is on-prem or cloud, and whether it uses the Confluent variant. Terraform provisions one IAM role per connect server per environment, granting produce access on all aggregated business topics plus the server's own prefixed system topics (`<name>-connect-config`, `<name>-connect-offsets`, `<name>-connect-status`, and optionally `<name>-confluent-license`). The UE connect server (`CN=IOVLVDC2KAFN1`) currently covered by two per-app IAM roles (`ue/siq` and `ue/uiq`) is replaced by a single `ue-connect` registration. Existing `TopicRegistration` YAML files are simplified — their `producer` block is removed when a connect registration takes ownership; topic definitions are untouched.

## Technical Context

**Language/Version**: HCL (Terraform >= 1.5.0), Python 3.12 (CI validation), JSON Schema draft-07

**Primary Dependencies**:
- `hashicorp/aws ~> 6.0` (already in `providers.tf`; `aws_msk_topic` available from ~6.42)
- `check-jsonschema` (CI YAML validation, already used)
- `PyYAML` (already used in `validate-topic-names.py`)

**Storage**: YAML files under `kafka/connect/` (Git); `kafka/schema/connect-schema.json` (new); Terraform state in existing S3 + DynamoDB backend

**Target Platform**: GitHub Actions self-hosted runners, AWS `ap-southeast-2`, accounts `381491832813` (dev+test), `339712719726` (uat), `637423180765` (prod)

**Project Type**: Infrastructure-as-Code (Terraform) + YAML contract extension + CI pipeline update

**Constraints**:
- IAM role name ≤ 64 characters; enforced by `terraform_data` precondition
- `replicationFactor: 3` required for all system topics (matches MSK broker count)
- No `aws_msk_cluster_policy`; role-assumption model only
- Tags via `default_tags` in provider; no `local.common_tags`
- No edits to `terraform-legacy/`

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

- [x] **Security**: Connect IAM roles use least-privilege `kafka-cluster:WriteData`/`ReadData`/`DescribeTopic` on specific topic ARNs; no cluster-wide wildcards; IAM Roles Anywhere trust condition scoped with `ForAnyValue:StringEquals` on `aws:PrincipalTag/x509Subject/CN`; no secrets hardcoded; IAM policy descriptions included.
- [x] **Observability**: No new compute/pipeline resources introduced — IAM roles and MSK topics are control-plane resources with no CloudWatch log streams. No new CloudWatch alarms required. Existing MSK broker-level monitoring is unchanged.
- [x] **Durability**: MSK topics are stateful; system topics use `compact` or `compact,delete` cleanup policy with explicit retention values; no S3 buckets introduced; Terraform state backend is unchanged.
- [x] **Fault-Tolerance**: No ECS, Glue, or MWAA resources introduced; not applicable.
- [x] **Cost Optimisation**: No new compute resources; MSK topics have defined retention policies (`retentionMs` explicitly set); `default_tags` applied via existing provider block.
- [x] **DRY & Modularity**: No module — connect IAM and system topic resources follow the same `for_each`-over-YAML pattern already established in `kafka_topics.tf`. A module for this feature would have only one call site, which is prohibited. Resource local names are descriptive: `kafka_connect_system_topic`, `kafka_aws_connect`, `kafka_onprem_connect`, `kafka_connect`. Terraform file named `kafka_connect.tf`. No generic placeholder names.

## Project Structure

### Documentation (this feature)

```text
specs/007-kafka-connect-support/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
├── quickstart.md        ← Phase 1 output
├── contracts/
│   └── connect-schema.json   ← Phase 1 output
└── tasks.md             ← Phase 2 output (/speckit-tasks)
```

### Source Code Layout

```text
kafka/
├── schema/
│   ├── producer-schema.json          ← MODIFIED: make spec.producer optional
│   ├── consumer-schema.json          ← MODIFIED: add optional type/variant fields
│   └── connect-schema.json           ← NEW: KafkaConnectRegistration schema
├── producers/
│   ├── ue/
│   │   ├── siq.yaml                  ← MODIFIED: remove producer block
│   │   └── uiq.yaml                  ← MODIFIED: remove producer block
│   └── (other producers unchanged)
├── consumers/
│   └── (unchanged)
└── connect/                          ← NEW directory
    └── ue/
        └── ue-connect.yaml           ← NEW: UE Kafka Connect registration

terraform/
├── kafka_topics.tf                   ← MODIFIED: skip per-app IAM for connect-owned apps
└── kafka_connect.tf                  ← NEW: connect IAM roles + system topics

.github/
├── scripts/
│   └── validate-topic-names.py       ← MODIFIED: add connect validation checks
└── workflows/
    └── kafka-topics.yaml             ← MODIFIED: add connect schema validation step
```

---

## YAML Schema Design

### KafkaConnectRegistration — `kafka/connect/<businessName>/<name>.yaml`

Composite uniqueness key: `(apiVersion, kind, metadata.name)`

On-prem (Confluent) example — the UE registration:

```yaml
apiVersion: kafka.chedaws.io/v1
kind: KafkaConnectRegistration
metadata:
  name: ue-connect
  owner: ue-platform-team
  description: >
    Confluent Kafka Connect server for UE business unit.
    Aggregates ue/siq and ue/uiq producer groups.
spec:
  variant: confluent
  sources:
    - businessName: ue
      appName: siq
    - businessName: ue
      appName: uiq
  connect:
    onPrem: true
    environments:
      test:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
```

Cloud-based (standard) example:

```yaml
apiVersion: kafka.chedaws.io/v1
kind: KafkaConnectRegistration
metadata:
  name: vpn-connect
  owner: vpn-platform-team
spec:
  sources:
    - businessName: vpn
      appName: siq
  connect:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/vpn-connect-worker-dev
      prod:
        iamRoles:
          - arn:aws:iam::637423180765:role/vpn-connect-worker-prod
```

### Modified TopicRegistration — connect-owned apps

When a `TopicRegistration` app's IAM is taken over by a `KafkaConnectRegistration`, the `producer` block is removed. Topic definitions are retained unchanged.

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: ue
  appName: siq
  owner: ue-siq-team
spec:
  events:
    - name: hf-read-results
      partitions: 12
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: voltage-threshold-trap
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
  # producer block removed — IAM owned by kafka/connect/ue/ue-connect.yaml
```

`spec.producer` is made optional in `producer-schema.json`. The Python CI script enforces the rule that a `TopicRegistration` without a `producer` block must appear as a source in exactly one active `KafkaConnectRegistration`.

---

## Terraform Design

### Locals — `kafka_connect.tf`

```hcl
locals {
  _connect_files = {
    for f in fileset("${path.root}/../kafka/connect", "**/*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../kafka/connect/${f}"))
  }

  connect_registrations_this_env = {
    for k, v in local._connect_files :
    v.metadata.name => v
    if contains(keys(v.spec.connect.environments), local.environment)
  }

  # (businessName/appName) pairs fully owned by a connect registration in this env.
  # Used to suppress per-app IAM role creation in kafka_topics.tf.
  connect_owned_apps_this_env = toset(flatten([
    for name, reg in local.connect_registrations_this_env : [
      for src in reg.spec.sources :
      "${src.businessName}/${src.appName}"
    ]
  ]))

  # Per-registration: all assembled business topic ARNs across source apps
  _connect_business_topic_arns = {
    for name, reg in local.connect_registrations_this_env :
    name => flatten([
      for src in reg.spec.sources : [
        for topic_key, topic_val in local.topics_this_env :
        "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${topic_key}"
        if(topic_val.app.metadata.businessName == src.businessName &&
           topic_val.app.metadata.appName == src.appName)
      ]
    ])
  }

  # Per-registration prefixed system topics to provision on MSK
  _connect_system_topics = {
    for pair in flatten([
      for name, reg in local.connect_registrations_this_env : concat(
        [
          { reg_name = name, suffix = "connect-config",  partitions = 1,  cleanup = "compact",        retention_ms = -1 },
          { reg_name = name, suffix = "connect-offsets", partitions = 25, cleanup = "compact",        retention_ms = -1 },
          { reg_name = name, suffix = "connect-status",  partitions = 5,  cleanup = "compact,delete", retention_ms = 86400000 },
        ],
        try(reg.spec.variant, "standard") == "confluent" ? [
          { reg_name = name, suffix = "confluent-license", partitions = 1, cleanup = "compact", retention_ms = -1 },
        ] : []
      )
    ]) :
    "${pair.reg_name}-${pair.suffix}" => pair
  }

  aws_connect_this_env = {
    for name, reg in local.connect_registrations_this_env :
    name => reg.spec.connect.environments[local.environment].iamRoles
    if(!try(reg.spec.connect.onPrem, false) &&
       can(reg.spec.connect.environments[local.environment].iamRoles))
  }

  onprem_connect_this_env = {
    for name, reg in local.connect_registrations_this_env :
    name => { certificate_subjects = reg.spec.connect.environments[local.environment].certificateSubject }
    if(try(reg.spec.connect.onPrem, false) &&
       can(reg.spec.connect.environments[local.environment].certificateSubject))
  }
}
```

### Modified Locals — `kafka_topics.tf`

Add one local to derive apps still needing their own IAM roles (not connect-owned):

```hcl
  _producers_needing_iam_this_env = {
    for k, v in local._producers_this_env :
    k => v
    if !contains(local.connect_owned_apps_this_env,
                 "${v.metadata.businessName}/${v.metadata.appName}")
  }
```

Change `for_each` on `aws_iam_policy.kafka_producer`, `aws_iam_role.kafka_aws_producer`, `aws_iam_role.kafka_onprem_producer` (and their policy attachments) from `_producers_this_env` to `_producers_needing_iam_this_env`. The `terraform_data.kafka_producer_name_length_check` also switches to `_producers_needing_iam_this_env`.

Topic resources (`aws_msk_topic.this`) remain on `topics_this_env` — business topics are always provisioned regardless of IAM ownership.

### Resources — `kafka_connect.tf`

**System topics** (per-registration, prefixed):

```hcl
resource "aws_msk_topic" "kafka_connect_system_topic" {
  for_each = local._connect_system_topics

  cluster_arn        = aws_msk_cluster.this.arn
  name               = each.key
  partition_count    = each.value.partitions
  replication_factor = 3

  configs = jsonencode({
    "cleanup.policy" = each.value.cleanup
    "retention.ms"   = tostring(each.value.retention_ms)
  })
}
```

**Connect IAM policy** (one per registration; business topics + system topics):

```hcl
resource "aws_iam_policy" "kafka_connect" {
  for_each = local.connect_registrations_this_env

  name        = "edp-${local.environment}-kafka-connect-${each.key}"
  description = "MSK connect access for ${each.key} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ConnectToCluster"
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
        Resource = aws_msk_cluster.this.arn
      }],
      length(local._connect_business_topic_arns[each.key]) > 0 ? [{
        Sid      = "ProduceBusinessTopics"
        Effect   = "Allow"
        Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
        Resource = local._connect_business_topic_arns[each.key]
      }] : [],
      [{
        Sid    = "SystemTopicsReadWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
        ]
        Resource = [
          for suffix in concat(
            ["connect-config", "connect-offsets", "connect-status"],
            try(each.value.spec.variant, "standard") == "confluent" ? ["confluent-license"] : []
          ) :
          "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${each.key}-${suffix}"
        ]
      }],
      [{
        Sid    = "SystemTopicsConsumerGroup"
        Effect = "Allow"
        Action = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
        Resource = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/${each.key}-*"
      }]
    )
  })
}
```

**AWS connect roles**:

```hcl
resource "aws_iam_role" "kafka_aws_connect" {
  for_each = local.aws_connect_this_env

  name        = "edp-${local.environment}-kafka-connect-${each.key}"
  description = "MSK connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = each.value }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_aws_connect" {
  for_each   = local.aws_connect_this_env
  role       = aws_iam_role.kafka_aws_connect[each.key].name
  policy_arn = aws_iam_policy.kafka_connect[each.key].arn
}
```

**On-prem connect roles** (IAM Roles Anywhere):

```hcl
resource "aws_iam_role" "kafka_onprem_connect" {
  for_each = local.onprem_connect_this_env

  name        = "edp-${local.environment}-kafka-connect-${each.key}"
  description = "MSK on-prem connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
      Condition = {
        "ForAnyValue:StringEquals" = {
          "aws:PrincipalTag/x509Subject/CN" = [
            for cn in each.value.certificate_subjects : split("CN=", cn)[1]
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_onprem_connect" {
  for_each   = local.onprem_connect_this_env
  role       = aws_iam_role.kafka_onprem_connect[each.key].name
  policy_arn = aws_iam_policy.kafka_connect[each.key].arn
}
```

**Name length validation**:

```hcl
resource "terraform_data" "kafka_connect_name_length_check" {
  for_each = local.connect_registrations_this_env

  lifecycle {
    precondition {
      condition     = length("edp-${local.environment}-kafka-connect-${each.key}") <= 64
      error_message = "Connect IAM role name exceeds 64 characters. Shorten registration name."
    }
  }
}
```

**Outputs** (in `kafka_connect.tf`):

```hcl
output "kafka_connect_role_arns" {
  description = "Map of connect registration name to IAM role ARN for this environment"
  value = merge(
    { for k, v in aws_iam_role.kafka_aws_connect : k => v.arn },
    { for k, v in aws_iam_role.kafka_onprem_connect : k => v.arn },
    { for k, v in aws_iam_role.kafka_consumer_connect_aws : k => v.arn },
    { for k, v in aws_iam_role.kafka_consumer_connect_onprem : k => v.arn },
  )
}

output "kafka_connect_system_topic_names" {
  description = "System topic names provisioned for Kafka Connect registrations in this environment"
  value       = keys(aws_msk_topic.kafka_connect_system_topic)
}
```

---

### Consumer-Side Connect Resources — `kafka_connect.tf` (Phase 5 / User Story 3)

Consumer connect registrations are `ConsumerRegistration` YAMLs with `spec.consumer.type: kafka-connect`. They are loaded from the existing `kafka/consumers/` path via a filtered local; no separate directory is needed.

**Locals** (added in T021):

```hcl
  # ConsumerRegistrations with type: kafka-connect active in this environment
  consumer_connect_this_env = {
    for k, v in local._consumers_this_env :
    v.metadata.name => v
    if try(v.spec.consumer.type, "standard") == "kafka-connect"
  }

  # Per consumer-connect registration: assembled business topic ARNs for consume access
  _consumer_connect_business_topic_arns = {
    for name, reg in local.consumer_connect_this_env :
    name => [
      for t in reg.spec.topics :
      "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${local.topic_name_prefix}.${t.businessName}.${t.appName}.${t.eventName}"
    ]
  }

  # Per consumer-connect registration: system topics to provision (same config as producer-side)
  _consumer_connect_system_topics = {
    for pair in flatten([
      for name, reg in local.consumer_connect_this_env : concat(
        [
          { reg_name = name, suffix = "connect-config",  partitions = 1,  cleanup = "compact",        retention_ms = -1 },
          { reg_name = name, suffix = "connect-offsets", partitions = 25, cleanup = "compact",        retention_ms = -1 },
          { reg_name = name, suffix = "connect-status",  partitions = 5,  cleanup = "compact,delete", retention_ms = 86400000 },
        ],
        try(reg.spec.consumer.variant, "standard") == "confluent" ? [
          { reg_name = name, suffix = "confluent-license", partitions = 1, cleanup = "compact", retention_ms = -1 },
        ] : []
      )
    ]) :
    "${pair.reg_name}-${pair.suffix}" => pair
  }

  aws_consumer_connect_this_env = {
    for name, reg in local.consumer_connect_this_env :
    name => reg.spec.consumer.environments[local.environment].iamRoles
    if(!try(reg.spec.consumer.onPrem, false) &&
       can(reg.spec.consumer.environments[local.environment].iamRoles))
  }

  onprem_consumer_connect_this_env = {
    for name, reg in local.consumer_connect_this_env :
    name => { certificate_subjects = reg.spec.consumer.environments[local.environment].certificateSubject }
    if(try(reg.spec.consumer.onPrem, false) &&
       can(reg.spec.consumer.environments[local.environment].certificateSubject))
  }
```

**Consumer connect IAM policy** (T022):

```hcl
resource "aws_iam_policy" "kafka_consumer_connect" {
  for_each = local.consumer_connect_this_env

  name        = "edp-${local.environment}-kafka-consumer-connect-${each.key}"
  description = "MSK consumer connect access for ${each.key} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ConnectToCluster"
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
        Resource = aws_msk_cluster.this.arn
      }],
      length(local._consumer_connect_business_topic_arns[each.key]) > 0 ? [{
        Sid      = "ConsumeBusinessTopics"
        Effect   = "Allow"
        Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
        Resource = local._consumer_connect_business_topic_arns[each.key]
      }] : [],
      [{
        Sid    = "SystemTopicsReadWrite"
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
        ]
        Resource = [
          for suffix in concat(
            ["connect-config", "connect-offsets", "connect-status"],
            try(each.value.spec.consumer.variant, "standard") == "confluent" ? ["confluent-license"] : []
          ) :
          "${replace(aws_msk_cluster.this.arn, ":cluster/", ":topic/")}/${each.key}-${suffix}"
        ]
      }],
      [{
        Sid    = "SystemTopicsConsumerGroup"
        Effect = "Allow"
        Action = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"]
        Resource = "${replace(aws_msk_cluster.this.arn, ":cluster/", ":group/")}/${each.key}-*"
      }]
    )
  })
}
```

**Consumer connect roles** (T023):

```hcl
resource "aws_iam_role" "kafka_consumer_connect_aws" {
  for_each = local.aws_consumer_connect_this_env

  name        = "edp-${local.environment}-kafka-consumer-connect-${each.key}"
  description = "MSK consumer connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = each.value }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_consumer_connect_aws" {
  for_each   = local.aws_consumer_connect_this_env
  role       = aws_iam_role.kafka_consumer_connect_aws[each.key].name
  policy_arn = aws_iam_policy.kafka_consumer_connect[each.key].arn
}

resource "aws_iam_role" "kafka_consumer_connect_onprem" {
  for_each = local.onprem_consumer_connect_this_env

  name        = "edp-${local.environment}-kafka-consumer-connect-${each.key}"
  description = "MSK on-prem consumer connect role for ${each.key} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
      Condition = {
        "ForAnyValue:StringEquals" = {
          "aws:PrincipalTag/x509Subject/CN" = [
            for cn in each.value.certificate_subjects : split("CN=", cn)[1]
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "kafka_consumer_connect_onprem" {
  for_each   = local.onprem_consumer_connect_this_env
  role       = aws_iam_role.kafka_consumer_connect_onprem[each.key].name
  policy_arn = aws_iam_policy.kafka_consumer_connect[each.key].arn
}
```

**Consumer system topics** are provisioned by extending `aws_msk_topic.kafka_connect_system_topic`'s `for_each` to merge both `_connect_system_topics` and `_consumer_connect_system_topics`:

```hcl
resource "aws_msk_topic" "kafka_connect_system_topic" {
  for_each = merge(local._connect_system_topics, local._consumer_connect_system_topics)
  # ... same body as producer-side
}
```

**IAM role name pattern**: `edp-<env>-kafka-consumer-connect-<name>` (max 64 chars; add a parallel `terraform_data` precondition following the same pattern as `kafka_connect_name_length_check`).

---

## Schema Design

### `kafka/schema/connect-schema.json` (new)

JSON Schema draft-07. Key constraints:

- `kind: const: "KafkaConnectRegistration"`
- `metadata.name`: `^[a-z][a-z0-9-]*$`; used verbatim in IAM resource names
- `spec.variant`: `enum: ["standard", "confluent"]`; optional; absent = standard
- `spec.sources`: array, minItems 1, each `{businessName, appName}` with `^[a-z][a-z0-9-]*$` patterns
- `spec.connect.environments`: per-env `oneOf [iamRoles XOR certificateSubject]` (same shape as existing schemas)
- `additionalProperties: false` throughout

See [contracts/connect-schema.json](contracts/connect-schema.json) for full schema.

### `kafka/schema/producer-schema.json` (modified)

`spec.producer` is made optional (`required: ["events"]` instead of `required: ["events", "producer"]`). JSON Schema validates the shape when `producer` is present; the Python CI script validates the cross-file rule: a `TopicRegistration` without a `producer` block must appear as a source in exactly one active `KafkaConnectRegistration`.

---

## CI/CD Pipeline Changes

### `validate-topic-names.py` additions (5 new checks)

1. **Connect YAML schema validation**: load and validate all `kafka/connect/**/*.yaml` against `connect-schema.json`.
2. **Connect registration name uniqueness**: `metadata.name` must be unique across all connect files.
3. **Source cross-reference**: every `{businessName, appName}` in `spec.sources` must resolve to an existing `TopicRegistration` file.
4. **Orphan check**: a `TopicRegistration` with no `producer` block must appear as a source in exactly one active `KafkaConnectRegistration`.
5. **Connect name length**: `edp-<env>-kafka-connect-<name>` ≤ 64 characters for all declared environments.

### `kafka-topics.yaml` workflow

Add connect schema validation step to the `validate-yaml` job:

```bash
# Validate connect registrations
for f in kafka/connect/**/*.yaml; do
  check-jsonschema --schemafile kafka/schema/connect-schema.json "$f"
done
```

The existing `kafka/**` path trigger already covers `kafka/connect/`.

---

## IAM Architecture Summary

| Registration type | Role name pattern | Trust | Topic permissions |
|---|---|---|---|
| TopicRegistration (AWS, no connect owner) | `edp-<env>-kafka-producer-<biz>-<app>` | `Principal: { AWS: [...] }` | Produce on app's events |
| TopicRegistration (on-prem, no connect owner) | `edp-<env>-kafka-producer-<biz>-<app>` | Roles Anywhere + CN | Produce on app's events |
| KafkaConnectRegistration (AWS) | `edp-<env>-kafka-connect-<name>` | `Principal: { AWS: [...] }` | Produce on all source events + RW on `<name>-connect-*` system topics |
| KafkaConnectRegistration (on-prem) | `edp-<env>-kafka-connect-<name>` | Roles Anywhere + CN | Produce on all source events + RW on `<name>-connect-*` system topics |
| ConsumerRegistration `type: kafka-connect` (AWS) | `edp-<env>-kafka-consumer-connect-<name>` | `Principal: { AWS: [...] }` | Consume on declared business topics + RW on `<name>-connect-*` system topics |
| ConsumerRegistration `type: kafka-connect` (on-prem) | `edp-<env>-kafka-consumer-connect-<name>` | Roles Anywhere + CN | Consume on declared business topics + RW on `<name>-connect-*` system topics |

---

## Migration: UE Connect Server

**Before** (two IAM roles — both trusted for `CN=IOVLVDC2KAFN1`):
- `edp-test-kafka-producer-ue-siq`
- `edp-test-kafka-producer-ue-uiq`

**After** (one IAM role):
- `edp-test-kafka-connect-ue-connect` — covers all 5 business topics + 4 prefixed system topics

**Migration steps** (handled in tasks):
1. Add `kafka/connect/ue/ue-connect.yaml`
2. Remove `producer` block from `kafka/producers/ue/siq.yaml`
3. Remove `producer` block from `kafka/producers/ue/uiq.yaml`
4. `terraform apply` — destroys two old roles, creates one connect role + 4 system topics
5. UE team reconfigures the on-prem connect server's IAM Roles Anywhere credential to assume the new role ARN

**Risk**: Brief window during apply where the old roles are destroyed before the new role exists. Coordinate with UE team; apply during a maintenance window or use a separate PR to add the connect role first, validate access, then remove the old producer blocks in a follow-up PR.
