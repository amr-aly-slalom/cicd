# Kafka Topic Self-Service Platform

**Feature**: 005-kafka-topics

---

## 1. Problem Statement

Amazon MSK clusters are deployed across four environments (`dev`, `test`, `uat`, `prod`) with `auto.create.topics.enable=false`. Streaming producers — running in other AWS accounts or on-premises data centres — need Kafka topics created and write access provisioned before they can stream data. Streaming consumers need read access provisioned to receive messages. Without a self-service workflow there is no audit trail, no schema enforcement, and no drift detection.

This document describes a Git-based self-service platform that lets producers and consumers declare their needs in YAML files via Pull Request. An automated CI/CD pipeline validates those declarations and provisions the required Kafka topics and IAM access without manual intervention.

---

## 2. Goals

- **G-01**: Any producer team registers a new Kafka app (one or more events) by opening a PR with a single YAML file. No platform team action is needed for provisioning.
- **G-02**: Any consumer team requests read access to existing topics by opening a PR with a YAML file.
- **G-03**: Cross-account AWS workloads receive access via IAM role assumption. No `aws_msk_cluster_policy` is used.
- **G-04**: On-premises workloads authenticate via IAM Roles Anywhere.
- **G-05**: Topic configuration is managed as code with full drift detection.
- **G-06**: Topic decommissioning is a deliberate two-phase process — per-event and whole-app.
- **G-07**: All registrations are validated against a JSON Schema before any Terraform step runs.
- **G-08**: A synthetic E2E canary validates MSK cluster health every 5 minutes.

## 3. Non-Goals

- Schema Registry management (Confluent or AWS Glue)
- Kafka ACL-based authorisation — MSK uses IAM authorisation only
- Topic partition reassignment or rack-aware replication tuning
- Consumer group management beyond IAM group-prefix grants
- Network connectivity between external accounts/on-prem and MSK VPCs

---

## 4. Architecture Overview

```
+------------------------------------------------------------------------+
|  Git Repository: chedaws-tf-edp-infra                                  |
|                                                                        |
|  kafka/producers/<businessName>/<appName>.yaml  <- Producer PR         |
|  kafka/consumers/<slug>.yaml                    <- Consumer PR         |
|                                                                        |
|  terraform/kafka_topics.tf                                             |
|    fileset() + yamldecode() -> for_each -> aws_msk_topic + IAM         |
+--------------------+---------------------------------------------------+
                     | push / PR
                     v
+------------------------------------------------------------------------+
|  GitHub Actions: .github/workflows/kafka-topics.yaml                   |
|                                                                        |
|  validate-yaml  ->  dev-tfplan  ->  dev-tfapply                        |
|               ->  test-tfplan ->  test-tfapply   (main only)           |
|               ->  uat-tfplan  ->  uat-tfapply    (tag + approval)      |
|               ->  prod-tfplan ->  prod-tfapply   (tag + approval)      |
+--------------------+---------------------------------------------------+
                     | terraform apply
                     v
+----------------------------------------------------------------------+
|  AWS MSK Cluster: chedaws-edp-msk-<env>                              |
|  +-- aws_msk_topic: edp-<env>.<businessName>.<appName>.<eventName>   |
|  +-- aws_iam_policy: produce/consume actions per app or slug         |
|  +-- aws_iam_role (AWS): trust policy allows external ARNs           |
|  +-- aws_iam_role (on-prem): trust policy allows Roles Anywhere      |
+----------------------------------------------------------------------+
```

MSK is configured with `sasl.iam = true` and `client_broker = TLS`. All clients authenticate using AWS IAM (SigV4) over port 9098. SASL/SCRAM and mTLS remain disabled.

---

## 5. Topic Naming Convention

All topics use the assembled name:

```
edp-<env>.<businessName>.<appName>.<eventName>
```

- `env`: Terraform workspace — `dev`, `test`, `uat`, or `prod`. Never specified in YAML.
- `businessName`: business unit identifier, e.g., `ue`, `vpn`, `platform`.
- `appName`: application identifier, e.g., `siq`, `uiq`, `e2e`.
- `eventName`: name of the event, e.g., `order-created`, `canary`.

All segments use lowercase letters, digits, and hyphens only. Underscores and uppercase are rejected by JSON Schema.

Examples: `edp-dev.ue.siq.order-created`, `edp-prod.platform.e2e.canary`

Terraform assembles the name — teams never construct it manually.

---

## 6. YAML Formats

### 6.1 Producer Registration — TopicRegistration

**File path**: `kafka/producers/<businessName>/<appName>.yaml`

The directory name must equal `metadata.businessName`; the file stem must equal `metadata.appName`. CI blocks mismatches.

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: ue                         # required — equals directory name
  appName: siq                             # required — equals file stem
  owner: ue-team                           # required
  description: >
    UE SIQ app producing order lifecycle events.

spec:
  events:
    - name: order-created
      partitions: 6                        # required; minimum 1
      replicationFactor: 3                 # required; must equal MSK broker count (3)
      retentionMs: 604800000               # required; milliseconds; max 2,592,000,000
      cleanupPolicy: delete                # required; delete | compact | compact,delete
      retentionBytes: -1                   # optional; default -1
      maxMessageBytes: 1048576             # optional; default 1,048,576 (1 MiB)
    - name: order-updated
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete

  decommissionedEvents: []                 # optional; per-event phase-1 decommission guard

  decommission: false                      # optional; whole-app phase-1 decommission guard

  producer:
    environments:                          # required; at least one environment
      dev:
        iamRoles:
          - arn:aws:iam::111122223333:role/ue-siq-producer-dev
      test:
        iamRoles:
          - arn:aws:iam::111122223333:role/ue-siq-producer-test
      uat:
        iamRoles:
          - arn:aws:iam::444455556666:role/ue-siq-producer-uat
      prod:
        iamRoles:
          - arn:aws:iam::777788889999:role/ue-siq-producer-prod
```

**On-premises producer** — use `certificateSubject` instead of `iamRoles` and set `onPrem: true`:

```yaml
  producer:
    onPrem: true
    environments:
      dev:
        certificateSubject: "CN=ue-siq.dev.internal"
      prod:
        certificateSubject: "CN=ue-siq.prod.internal"
```

`iamRoles` and `certificateSubject` are mutually exclusive within the same environment entry.

### 6.2 Consumer Registration — ConsumerRegistration

**File path**: `kafka/consumers/<slug>.yaml` (flat layout; no subdirectories)

Topics are referenced by `{businessName, appName, eventName}` objects. CI verifies each reference resolves to an active event in a registered producer YAML.

```yaml
apiVersion: kafka.chedaws.io/v1
kind: ConsumerRegistration
metadata:
  name: risk-engine-consumer             # required — equals file stem; unique across all consumers
  owner: risk-team
  description: >
    Glue Streaming job computing real-time fraud scores.

spec:
  topics:
    - businessName: ue
      appName: siq
      eventName: order-created
    - businessName: ue
      appName: siq
      eventName: order-updated

  consumer:
    consumerGroupPrefix: risk-engine     # optional; enables group IAM actions on prefix/*
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/risk-glue-job-dev
      uat:
        iamRoles:
          - arn:aws:iam::339712719726:role/risk-glue-job-uat
      prod:
        iamRoles:
          - arn:aws:iam::637423180765:role/risk-glue-job-prod
```

---

## 7. Repository Layout

```
chedaws-tf-edp-infra/
+-- kafka/
|   +-- CODEOWNERS                            <- @chedaws-platform-team as required reviewer
|   +-- README.md                             <- Onboarding guide
|   +-- schema/
|   |   +-- producer-schema.json              <- JSON Schema v7 for TopicRegistration
|   |   +-- consumer-schema.json              <- JSON Schema v7 for ConsumerRegistration
|   +-- producers/
|   |   +-- <businessName>/
|   |       +-- <appName>.yaml
|   +-- consumers/
|       +-- <slug>.yaml
|
+-- terraform/
|   +-- kafka_topics.tf                       <- aws_msk_topic + IAM resources
|   +-- kafka_e2e_canary.tf                   <- Canary Lambda + alarms + log group
|
+-- lambda/
|   +-- kafka-e2e-canary/
|       +-- handler.py
|       +-- requirements.txt
|
+-- .github/
    +-- scripts/
    |   +-- validate-topic-names.py           <- Naming, placement, cross-ref, decommission guard
    +-- workflows/
        +-- kafka-topics.yaml                 <- CI/CD pipeline
```

---

## 8. Terraform Implementation

### 8.1 Provider

`aws_msk_topic` is a native resource in `hashicorp/aws ~> 6.0` (available from ~6.42). No third-party Kafka provider is required. The `aws_msk_topic` resource communicates with the MSK management API over HTTPS — no TCP broker connection is needed from CI runners during `terraform plan` or `terraform apply`.

`data "aws_msk_cluster" "this"` in `providers.tf` provides the cluster ARN used in IAM policy documents.

### 8.2 Terraform Locals

```
_producer_files         <- fileset() + yamldecode() all producer YAMLs
      |  expand events; filter: env declared + decommission=false + event not in decommissionedEvents
topics_this_env         <- map: assembled-topic-name -> { app_key, app, event }
_producers_this_env     <- map: file-path-key -> app YAML (active apps in this env)
_topic_keys_per_app     <- map: app_key -> [assembled topic names for this env]
aws_producers_this_env  <- app_key -> iamRoles list (onPrem=false)
onprem_producers_this_env <- app_key -> { certificate_subject } (onPrem=true)

_consumer_files         <- fileset() + yamldecode() all consumer YAMLs
consumers_this_env      <- map: metadata.name -> consumer YAML (env declared)
aws_consumers_this_env  <- slug -> iamRoles list (onPrem=false)
onprem_consumers_this_env <- slug -> { consumer_slug, certificate_subject } (onPrem=true)
```

### 8.3 `aws_msk_topic` Resource

```hcl
resource "aws_msk_topic" "this" {
  for_each = local.topics_this_env

  cluster_arn        = aws_msk_cluster.this.arn
  name               = each.key
  partition_count    = each.value.event.partitions
  replication_factor = each.value.event.replicationFactor

  configs = jsonencode(merge(
    {
      "retention.ms"    = tostring(each.value.event.retentionMs)
      "retention.bytes" = tostring(try(each.value.event.retentionBytes, -1))
      "cleanup.policy"  = each.value.event.cleanupPolicy
    },
    can(each.value.event.maxMessageBytes) ? {
      "max.message.bytes" = tostring(each.value.event.maxMessageBytes)
    } : {}
  ))
}
```

`configs_actual` returned by the resource contains all broker-level default keys. Terraform only tracks keys declared in `configs` — no drift is reported for broker defaults.

### 8.4 IAM Resources

**Producer policy** — one per active producer app (all topics for that app in this env):

```hcl
resource "aws_iam_policy" "kafka_producer" {
  for_each = local._producers_this_env
  name     = "edp-kafka-producer-${each.value.metadata.businessName}-${each.value.metadata.appName}-${local.environment}"
  policy = jsonencode({
    Statement = concat(
      [{ Sid = "ConnectToCluster", Effect = "Allow",
         Action = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"],
         Resource = aws_msk_cluster.this.arn }],
      length(local._topic_keys_per_app[each.key]) > 0 ? [{
        Sid = "ProduceToTopic", Effect = "Allow",
        Action = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"],
        Resource = [for t in local._topic_keys_per_app[each.key] : "${aws_msk_cluster.this.arn}/topic/${t}"]
      }] : []
    )
  })
}
```

**Consumer policy** — one per consumer slug:

```hcl
resource "aws_iam_policy" "kafka_consumer" {
  for_each = local.consumers_this_env
  name     = "edp-kafka-consumer-${each.key}-${local.environment}"
  policy = jsonencode({
    Statement = concat(
      [{ Sid = "ConnectToCluster", Effect = "Allow",
         Action = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"],
         Resource = aws_msk_cluster.this.arn }],
      [for topic in each.value.spec.topics : {
        Sid    = "ReadTopic${replace(topic.businessName, "-", "")}X${replace(topic.appName, "-", "")}X${replace(topic.eventName, "-", "")}"
        Effect = "Allow"
        Action = ["kafka-cluster:DescribeTopic", "kafka-cluster:ReadData"]
        Resource = "${aws_msk_cluster.this.arn}/topic/edp-${local.environment}.${topic.businessName}.${topic.appName}.${topic.eventName}"
      }],
      can(each.value.spec.consumer.consumerGroupPrefix) ? [{
        Sid      = "ConsumerGroup", Effect = "Allow",
        Action   = ["kafka-cluster:AlterGroup", "kafka-cluster:DescribeGroup"],
        Resource = "${aws_msk_cluster.this.arn}/group/${each.value.spec.consumer.consumerGroupPrefix}*"
      }] : []
    )
  })
}
```

---

## 9. IAM Permissions Model

### What each policy grants

| Actor | IAM Actions | On resources |
|---|---|---|
| Producer | `kafka-cluster:Connect`, `kafka-cluster:DescribeCluster` | Cluster ARN |
| Producer | `kafka-cluster:DescribeTopic`, `kafka-cluster:WriteData` | Each of the app's assembled topic ARNs |
| Consumer | `kafka-cluster:Connect`, `kafka-cluster:DescribeCluster` | Cluster ARN |
| Consumer | `kafka-cluster:DescribeTopic`, `kafka-cluster:ReadData` | Each referenced topic ARN |
| Consumer (with prefix) | `kafka-cluster:AlterGroup`, `kafka-cluster:DescribeGroup` | `<cluster_arn>/group/<consumerGroupPrefix>*` |

### Trust policy generated by Terraform

**AWS workload** (same-account or cross-account):
```json
{
  "Effect": "Allow",
  "Principal": { "AWS": "arn:aws:iam::111122223333:role/ue-siq-producer-dev" },
  "Action": "sts:AssumeRole"
}
```

**On-premises workload**:
```json
{
  "Effect": "Allow",
  "Principal": { "Service": "rolesanywhere.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"],
  "Condition": {
    "StringEquals": { "aws:PrincipalTag/x509Subject/CN": "ue-siq.dev.internal" }
  }
}
```

### What the workload team does

**Cross-account AWS workload** — two options:

Option A (Java `aws-msk-iam-auth` library):
```properties
sasl.jaas.config=software.amazon.msk.auth.iam.IAMLoginModule required
  awsRoleArn="<terraform output: kafka_producer_role_arns[\"ue/siq\"]>";
```

Option B (`~/.aws/config`):
```ini
[profile kafka-producer]
role_arn    = <terraform output: kafka_producer_role_arns["ue/siq"]>
source_profile = default
```

The workload's own IAM role must have `sts:AssumeRole` permission on the MSK-account role.

**On-premises workload** (`aws_signing_helper`):
```bash
aws_signing_helper credential-process \
  --certificate /etc/kafka/certs/client.pem \
  --private-key  /etc/kafka/certs/client.key \
  --trust-anchor-arn <documented in kafka/README.md> \
  --profile-arn      <documented in kafka/README.md> \
  --role-arn         <terraform output: kafka_producer_role_arns["ue/siq"]>
```

---

## 10. On-Premises Access

On-premises producers and consumers authenticate via IAM Roles Anywhere. Terraform provisions an IAM role with `rolesanywhere.amazonaws.com` as the trust principal. The trust condition checks the certificate CN against the `certificateSubject` value declared in the YAML.

**How it works**:
1. The on-prem workload uses `aws_signing_helper` with a private key and certificate issued by a trusted CA.
2. The IAM Roles Anywhere Trust Anchor (associated with that CA) and Profile are pre-configured by the platform team.
3. `aws_signing_helper` obtains temporary AWS credentials for the role provisioned by Terraform.
4. The workload uses those credentials with the Kafka MSK IAM SASL library to produce or consume.

The CN extracted from `certificateSubject` (via `split("CN=", ...)[1]`) is used in the `StringEquals` condition on `aws:PrincipalTag/x509Subject/CN`.

---

## 11. CI Pipeline

### Workflow Triggers

`.github/workflows/kafka-topics.yaml` triggers on push to `main`, `feature/*`, `feat/*`, or `workflow_dispatch` when files under `kafka/**`, `terraform/kafka_topics.tf`, `terraform/kafka_e2e_canary.tf`, or `lambda/kafka-e2e-canary/**` change.

### `validate-yaml` Job (every PR)

```bash
pip install check-jsonschema

# Schema validation
for f in kafka/producers/**/*.yaml; do
  check-jsonschema --schemafile kafka/schema/producer-schema.json "$f"
done
for f in kafka/consumers/*.yaml; do
  check-jsonschema --schemafile kafka/schema/consumer-schema.json "$f"
done

# Naming, placement, decommission guard, cross-reference, duplicate check
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
```

### `validate-topic-names.py` — Invariants

1. Producer file placement: `path.parent.name == metadata.businessName`, `path.stem == metadata.appName`
2. Consumer file placement: `path.parent.name == "consumers"`, `path.stem == metadata.name`
3. Event name pattern `^[a-z][a-z0-9-]*$`
4. Event name unique within `spec.events`
5. Overlap guard: event name MUST NOT appear in both `spec.events` and `spec.decommissionedEvents`
6. Consumer cross-reference: every `{businessName, appName, eventName}` triple must resolve to an active event
7. Decommission guard: deleted producer YAML must have had `spec.decommission: true` in the prior commit
8. Duplicate producer slug: no two active files may share `(metadata.businessName, metadata.appName)`
9. Duplicate consumer slug: `metadata.name` unique across all consumer files
10. Warning (non-blocking): consumer YAML referencing > 80 topics (IAM policy 6 KB limit)

### Plan and Apply Gating

| Environment | Trigger | Apply gate |
|---|---|---|
| `dev` | Every push to matching branch | Automatic after plan passes |
| `test` | Merge to `main` | Automatic after plan passes |
| `uat` | Tag push | `uat-kafka-approval` GitHub Environment (manual approve) |
| `prod` | Tag push (after uat) | `prod-kafka-approval` GitHub Environment (manual approve) |

---

## 12. Decommission Process

### Per-Event Decommission

**Phase 1 — Guard**: Move the event name from `spec.events` to `spec.decommissionedEvents`. Open a PR. The pipeline plans destroy for that event's topics across all declared environments; other topics and the IAM role remain unchanged. Platform team reviews and approves. On apply, the topics are destroyed.

**Phase 2 — Cleanup**: In a follow-up PR, remove the event name from `spec.decommissionedEvents`. This is a no-op from Terraform's perspective.

CI blocks any PR that removes an event name directly from `spec.events` without it first appearing in `spec.decommissionedEvents`.

### Whole-App Decommission

**Phase 1 — Guard**: Set `spec.decommission: true`. Open a PR. The pipeline plans destroy for all of the app's topics and its IAM role across all declared environments. Platform team reviews and approves. On apply, all resources are destroyed.

**Phase 2 — Cleanup**: In a follow-up PR, delete the YAML file. This is a no-op from Terraform's perspective.

CI blocks any PR that deletes a YAML file without `spec.decommission: true` having been set in the prior commit.

### Partition Changes

Kafka allows increasing partition counts but not decreasing. Decreasing `partitions` in a YAML will cause `aws_msk_topic` to error at apply time. Never decrease `partitions`. If a lower count is required, decommission and recreate the topic.

---

## 13. Duplicate-Name Enforcement

Two layers prevent duplicate assembled topic names:

**Layer 1 — CI Python script**: `validate-topic-names.py` checks that no two producer YAMLs share `(metadata.businessName, metadata.appName)`. Since the file path encodes both values and one file per app is enforced structurally, duplicate slug detection catches any attempt to create a conflict via `spec` fields.

**Layer 2 — Terraform preconditions**: `terraform_data.kafka_unique_name_check` contains two `precondition` blocks. The native `for_each` map key collision (same assembled topic name appearing in `topics_this_env`) causes an immediate plan error. The `precondition` block provides a more descriptive error message. Both checks run at plan time.

An additional precondition in `terraform_data.kafka_producer_name_length_check` enforces that the derived IAM role name `edp-kafka-producer-<businessName>-<appName>-<env>` does not exceed 64 characters.

---

## 14. Scale Analysis

The role-assumption model eliminates the hard 20 KB `aws_msk_cluster_policy` constraint. Each producer app and consumer slug gets its own IAM role and policy — independent objects with no aggregate document size limit.

### IAM Role Quota

Default: 1,000 roles per account (soft limit).

At full scale (`dev+test` share account `381491832813`):
- <= 200 producer apps + <= 500 consumers per environment × 2 environments = <= 1,400 roles
- Requires quota increase to 2,000 before crossing ~500 registrations in dev+test

UAT and prod each use their own accounts and stay within the 1,000 default at <= 700 roles each.

### IAM Managed Policy Quota

Default: 1,500 policies per account (soft limit).

Same calculation: dev+test combined ~1,400 policies. Request increase to 3,000 alongside the role quota increase.

### IAM Policy Document Size

Each `aws_iam_policy` document is limited to 6 KB (hard limit). A consumer policy referencing 50 topics is approximately 3 KB. CI warns (non-blocking) when a consumer YAML references more than 80 topics.

| Limit | Default | At 200P + 500C per env | Action |
|---|---|---|---|
| IAM roles per account | 1,000 (soft) | 700 per env; 1,400 in dev+test | Request increase to 2,000 for dev+test |
| IAM managed policies per account | 1,500 (soft) | 700 per env; 1,400 in dev+test | Request increase to 3,000 for dev+test |
| IAM policy document size | 6 KB (hard) | ~3 KB for 50-topic consumer | Warn in CI if > 80 topics |
| MSK cluster policy size | 20 KB (hard) | Not applicable | — |

---

## 15. E2E Synthetic Canary

### Overview

A Lambda function runs every 5 minutes via EventBridge in all four environments. It validates end-to-end MSK cluster health by producing a test message to `edp-<env>.platform.e2e.canary` and consuming it.

### Lambda IAM Model

The Lambda execution role has **no direct Kafka permissions**. All Kafka operations are performed under assumed role credentials:
- Assumes `CanaryProducerRole` (provisioned by `kafka/producers/platform/e2e.yaml`) to flush and produce
- Assumes `CanaryConsumerRole` (provisioned by `kafka/consumers/platform-e2e-canary-consumer.yaml`) to consume and validate

### Canary Cycle Sequence

1. Assume CanaryProducerRole via `sts:AssumeRole`
2. Flush: `seek_to_end` on partition 0 (repositions read pointer; does not delete messages)
3. Produce a message with a unique `cycle_id`
4. Release producer credentials; wait settle period (default 5 seconds)
5. Assume CanaryConsumerRole via `sts:AssumeRole`
6. Consume messages within a 30-second timeout
7. Validate the consumed message ID matches `cycle_id`
8. Emit `KafkaE2ETestSuccess = 1` (pass) or `0` (fail) to CloudWatch namespace `ChedawsEDP/KafkaE2ECanary`

A `try/finally` block ensures the metric is always emitted, even when an exception is raised before step 7.

### Lambda ZIP Location

The Lambda ZIP is stored in `module.platform_s3` at prefix `e2e/kafka/canary/function.zip`. Terraform references it via the platform S3 module outputs and sets `source_code_hash` for change detection. No dedicated S3 bucket is provisioned.

### Alarm

`aws_cloudwatch_metric_alarm.kafka_e2e_test_failure` per environment:
- Metric: `KafkaE2ETestSuccess`, namespace `ChedawsEDP/KafkaE2ECanary`
- Dimensions: `{TopicName: edp-<env>.platform.e2e.canary, Environment: <env>}`
- Threshold: `< 1` for 2 consecutive evaluation periods (10 minutes)
- `treat_missing_data = "breaching"` — crash guard when Lambda is killed before emitting
- Alarm action: `aws_sns_topic.alerts.arn`
- Active in all 4 environments; no `count` gate

### Log Group

`/chedaws-edp/kafka-e2e-canary/<env>` — KMS-encrypted with `module.kms["cloudwatch_logs"].key_arn`; per-environment retention.

Each log entry includes: `cycle_id`, `status` (pass/fail), `step`, `duration_ms`, `message_id`, and `error` (on failure only).
