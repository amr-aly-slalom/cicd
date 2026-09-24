# Implementation Plan: Kafka Topic Self-Service Platform

**Branch**: `feat/kafka-topics` | **Spec**: [spec.md](spec.md)

## Summary

Teams register Kafka topics and IAM access (produce or consume) by opening a PR with a YAML file. A GitHub Actions pipeline validates YAML against JSON Schema and a naming-convention script, then runs `terraform plan` / `terraform apply` using the `hashicorp/aws` provider's `aws_msk_topic` resource to provision topics on existing `chedaws-edp-msk-<env>` clusters and `aws_iam_role` + `aws_iam_policy` resources in each MSK account. No `aws_msk_cluster_policy` is used and no third-party Kafka provider is required. A synthetic E2E canary Lambda validates cluster health every 5 minutes using the self-service IAM pipeline. The Lambda ZIP is stored in the shared platform S3 bucket provisioned by `module.platform_s3`.

## Technical Context

**Language/Version**: HCL (Terraform >= 1.5.0), Python 3.12 (CI validation script, Lambda runtime)

**Primary Dependencies**:
- `hashicorp/aws ~> 6.0` (already in `providers.tf`; `aws_msk_topic` available from ~6.42)
- `check-jsonschema` Python package (installed in CI by the `validate-yaml` job)
- `kafka-python-ng>=2.2.3` + `aws-msk-iam-sasl-signer-python>=1.0.2` (canary Lambda)

**Storage**: YAML files under `kafka/producers/` and `kafka/consumers/` (Git); Lambda ZIP in `module.platform_s3` at prefix `e2e/kafka/canary/function.zip`; Terraform state in existing S3 + DynamoDB backend

**Target Platform**: GitHub Actions self-hosted runners (EC2, App-tier subnets, `ap-southeast-2`); AWS accounts `381491832813` (dev+test), `339712719726` (uat), `637423180765` (prod)

**Constraints**:
- `replicationFactor` must equal 3 — enforced by JSON Schema
- `retentionMs` max 2,592,000,000 ms — enforced by JSON Schema
- IAM role name <= 64 characters — enforced by `terraform_data.kafka_producer_name_length_check`
- No `aws_msk_cluster_policy` — role-assumption model only
- No SASL/SCRAM; MSK IAM auth only
- Tags via `default_tags` in AWS provider; no `local.common_tags`

---

## Directory Layout

```text
kafka/
├── CODEOWNERS                           <- @chedaws-platform-team as required reviewer
├── README.md                            <- Onboarding guide
├── schema/
│   ├── producer-schema.json             <- JSON Schema v7 for producer YAML validation
│   └── consumer-schema.json             <- JSON Schema v7 for consumer YAML validation
├── producers/
│   └── <businessName>/
│       └── <appName>.yaml               <- One file per producer app
└── consumers/
    └── <slug>.yaml                      <- Flat layout; one file per consumer

terraform/
├── kafka_topics.tf                      <- aws_msk_topic + IAM resources via for_each
├── kafka_e2e_canary.tf                  <- Lambda, IAM roles, EventBridge, alarms, log group
└── providers.tf                         <- hashicorp/aws provider; data.aws_msk_cluster.this

lambda/
└── kafka-e2e-canary/
    ├── handler.py                       <- 5-step canary cycle
    └── requirements.txt

.github/
├── scripts/
│   └── validate-topic-names.py          <- Naming, placement, cross-ref, decommission guard
└── workflows/
    └── kafka-topics.yaml                <- CI/CD pipeline (reuses tf-plan.yaml/tf-apply.yaml)

specs/005-kafka-topics/
├── spec.md
├── plan.md                              <- this file
├── data-model.md
├── kafka-topics.md
├── quickstart.md
├── research.md
├── tasks.md
├── checklists/requirements.md
└── contracts/
    ├── producer-schema.json
    └── consumer-schema.json
```

---

## YAML Schema Design

### TopicRegistration

File path: `kafka/producers/<businessName>/<appName>.yaml`

Composite uniqueness key: `(apiVersion, kind, metadata.businessName, metadata.appName)`

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: ue                         # identity; matches directory name
  appName: siq                             # identity; matches file stem
  owner: ue-team
  description: >
    Optional free-text description.
spec:
  events:
    - name: order-created
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: order-updated
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
  decommissionedEvents: []                 # optional; per-event phase-1 guard
  decommission: false                      # optional; whole-app phase-1 guard
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::111122223333:role/ue-siq-producer-dev
      uat:
        iamRoles:
          - arn:aws:iam::444455556666:role/ue-siq-producer-uat
      prod:
        iamRoles:
          - arn:aws:iam::777788889999:role/ue-siq-producer-prod
```

On-premises producer — use `certificateSubject` instead of `iamRoles`:

```yaml
  producer:
    onPrem: true
    environments:
      dev:
        certificateSubject: "CN=ue-siq.dev.internal"
      prod:
        certificateSubject: "CN=ue-siq.prod.internal"
```

### ConsumerRegistration

File path: `kafka/consumers/<slug>.yaml`

Composite uniqueness key: `(apiVersion, kind, metadata.name)`

```yaml
apiVersion: kafka.chedaws.io/v1
kind: ConsumerRegistration
metadata:
  name: risk-engine-consumer
  owner: risk-team
spec:
  topics:
    - businessName: ue
      appName: siq
      eventName: order-created
    - businessName: ue
      appName: siq
      eventName: order-updated
  consumer:
    consumerGroupPrefix: risk-engine       # optional
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/risk-glue-job-dev
      prod:
        iamRoles:
          - arn:aws:iam::637423180765:role/risk-glue-job-prod
```

---

## Terraform Design

### Locals — `kafka_topics.tf`

The locals layer loads YAML files, expands per-event topics, and segments them by identity type.

```hcl
locals {
  # Load all producer YAMLs; key = relative path without extension
  _producer_files = {
    for f in fileset("${path.root}/../kafka/producers", "**/*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../kafka/producers/${f}"))
  }

  # Expand events into individual topic entries.
  # Key = assembled topic name; value = { app_key, app, event }.
  # Decommissioned apps (spec.decommission=true) and decommissioned events
  # (in spec.decommissionedEvents) are excluded before the map is built.
  topics_this_env = {
    for pair in flatten([
      for k, v in local._producer_files :
      !try(v.spec.decommission, false) && contains(keys(v.spec.producer.environments), local.environment) ? [
        for event in v.spec.events :
        {
          key     = "edp-${local.environment}.${v.metadata.businessName}.${v.metadata.appName}.${event.name}"
          app_key = k
          app     = v
          event   = event
        }
        if !contains(try(v.spec.decommissionedEvents, []), event.name)
      ] : []
    ]) :
    pair.key => pair
  }

  # Topics whose events are in decommissionedEvents (diagnostic anchor)
  topics_decommissioned_this_env = { ... }

  # Active producer apps in this environment
  _producers_this_env = {
    for k, v in local._producer_files :
    k => v
    if !try(v.spec.decommission, false) && contains(keys(v.spec.producer.environments), local.environment)
  }

  # Per-app topic key list for IAM policy assembly
  _topic_keys_per_app = {
    for k in keys(local._producers_this_env) :
    k => [for topic_key, topic_val in local.topics_this_env : topic_key if topic_val.app_key == k]
  }

  # Consumer files; keyed by metadata.name
  _consumer_files = { ... }
  consumers_this_env = { ... }

  # Segment by identity type
  aws_producers_this_env    = { ... }  # onPrem=false, iamRoles non-empty
  aws_consumers_this_env    = { ... }
  onprem_producers_this_env = { ... }  # onPrem=true, certificateSubject set
  onprem_consumers_this_env = { ... }

  # Slug collision detection
  _producer_slug_list   = [for k, v in local._producers_this_env : "${v.metadata.businessName}-${v.metadata.appName}"]
  _producer_slug_unique = distinct(local._producer_slug_list)
  _consumer_slug_list   = [for k in keys(local.consumers_this_env) : k]
  _consumer_slug_unique = distinct(local._consumer_slug_list)
}
```

### Resources — `kafka_topics.tf`

**Unique-name validation** (preconditions on `terraform_data` resources):

```hcl
resource "terraform_data" "kafka_unique_name_check" {
  lifecycle {
    precondition {
      condition     = length(local._producer_slug_list) == length(local._producer_slug_unique)
      error_message = "Duplicate producer slug(s) detected: ..."
    }
    precondition {
      condition     = length(local._consumer_slug_list) == length(local._consumer_slug_unique)
      error_message = "Duplicate consumer role-name slug(s) detected: ..."
    }
  }
}

resource "terraform_data" "kafka_producer_name_length_check" {
  for_each = local._producers_this_env
  lifecycle {
    precondition {
      condition     = length("edp-kafka-producer-${each.value.metadata.businessName}-${each.value.metadata.appName}-${local.environment}") <= 64
      error_message = "IAM role name exceeds 64 characters. Shorten businessName or appName."
    }
  }
}
```

**Kafka topics** (`aws_msk_topic` from `hashicorp/aws`):

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

**Producer IAM policy** (one per active producer app; grants produce on all app topics in this env):

```hcl
resource "aws_iam_policy" "kafka_producer" {
  for_each = local._producers_this_env

  name        = "edp-kafka-producer-${each.value.metadata.businessName}-${each.value.metadata.appName}-${local.environment}"
  description = "Least-privilege MSK produce access for ${each.value.metadata.businessName}/${each.value.metadata.appName} in ${local.environment}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ConnectToCluster"
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:DescribeCluster"]
        Resource = aws_msk_cluster.this.arn
      }],
      length(local._topic_keys_per_app[each.key]) > 0 ? [{
        Sid      = "ProduceToTopic"
        Effect   = "Allow"
        Action   = ["kafka-cluster:DescribeTopic", "kafka-cluster:WriteData"]
        Resource = [for topic_key in local._topic_keys_per_app[each.key] :
          "${aws_msk_cluster.this.arn}/topic/${topic_key}"]
      }] : []
    )
  })
}
```

**AWS producer roles** (trust policy lists workload ARNs from YAML):

```hcl
resource "aws_iam_role" "kafka_aws_producer" {
  for_each = local.aws_producers_this_env

  name        = "edp-kafka-producer-${local._producers_this_env[each.key].metadata.businessName}-${local._producers_this_env[each.key].metadata.appName}-${local.environment}"
  description = "MSK producer role for ${local._producers_this_env[each.key].metadata.businessName}/${local._producers_this_env[each.key].metadata.appName} in ${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { AWS = each.value }, Action = "sts:AssumeRole" }]
  })
}
```

**On-premises producer roles** (Roles Anywhere trust policy, CN condition derived from YAML):

```hcl
resource "aws_iam_role" "kafka_onprem_producer" {
  for_each = local.onprem_producers_this_env

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rolesanywhere.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
      Condition = {
        StringEquals = {
          "aws:PrincipalTag/x509Subject/CN" = split("CN=", each.value.certificate_subject)[1]
        }
      }
    }]
  })
}
```

Consumer resources follow the same pattern as producers; see `terraform/kafka_topics.tf` for the full implementation.

### Outputs

```hcl
output "kafka_producer_role_arns" {
  description = "Map of app key to producer IAM role ARN for this environment"
  value       = merge({ for k, v in aws_iam_role.kafka_aws_producer : k => v.arn },
                      { for k, v in aws_iam_role.kafka_onprem_producer : k => v.arn })
}

output "kafka_consumer_role_arns" {
  description = "Map of consumer slug to consumer IAM role ARN for this environment"
  value       = merge({ for k, v in aws_iam_role.kafka_aws_consumer : k => v.arn },
                      { for k, v in aws_iam_role.kafka_onprem_consumer : k => v.arn })
}

output "topics_pending_destruction" {
  description = "Topic names in decommissionedEvents — destroyed on next apply"
  value       = keys(local.topics_decommissioned_this_env)
}
```

---

## IAM Architecture

**Producer IAM**: One `aws_iam_policy` and one `aws_iam_role` per producer app per environment. The policy grants `kafka-cluster:Connect`, `kafka-cluster:DescribeCluster` on the cluster ARN, and `kafka-cluster:DescribeTopic`, `kafka-cluster:WriteData` on each of the app's assembled topic ARNs.

**Consumer IAM**: One `aws_iam_policy` and one `aws_iam_role` per consumer slug per environment. The policy grants Connect/DescribeCluster, DescribeTopic/ReadData per referenced topic, and optionally AlterGroup/DescribeGroup on the consumer group prefix ARN.

**Trust policy variants**:
- AWS workloads: `Principal: { AWS: [<role_arns>] }`, `Action: sts:AssumeRole`
- On-premises: `Principal: { Service: "rolesanywhere.amazonaws.com" }`, `Action: [sts:AssumeRole, sts:TagSession, sts:SetSourceIdentity]`, `Condition: StringEquals: { "aws:PrincipalTag/x509Subject/CN": "<CN>" }`

**E2E canary**: The canary Lambda execution role has no direct Kafka permissions. It assumes the CanaryProducerRole (via `sts:AssumeRole`) and then the CanaryConsumerRole, both provisioned by `kafka/producers/platform/e2e.yaml` and `kafka/consumers/platform-e2e-canary-consumer.yaml`.

---

## Platform S3 + KMS

The shared platform S3 bucket and KMS key are managed by `module.platform_s3` in the main Terraform configuration:

- **Bucket name**: `chedaws-edp-platform-<env>`
- **KMS key alias**: `alias/chedaws-edp-s3-<env>`
- **Canary Lambda ZIP path**: `e2e/kafka/canary/function.zip` within the platform bucket

The canary Lambda in `kafka_e2e_canary.tf` references the ZIP via `module.platform_s3` outputs. No dedicated S3 bucket is created for the Lambda.

---

## Tagging

All AWS resources inherit tags from the `default_tags` block on the AWS provider in `providers.tf`. No `local.common_tags` map is defined or used anywhere. Individual resources do not declare a `tags` argument.

---

## CI/CD Pipeline Design

### `.github/workflows/kafka-topics.yaml`

Reuses existing `tf-plan.yaml` and `tf-apply.yaml` reusable workflows. Triggered when files under `kafka/**`, `terraform/kafka_topics.tf`, `terraform/kafka_e2e_canary.tf`, or `lambda/kafka-e2e-canary/**` change.

**Job graph**:

```
validate-yaml
    ├── dev-tfplan  ->  dev-tfapply           (all matching branch pushes)
    ├── test-tfplan ->  test-tfapply          (main branch only)
    ├── uat-tfplan  ->  [uat-kafka-approval]  ->  uat-tfapply    (tag only)
    └── prod-tfplan ->  [prod-kafka-approval] ->  prod-tfapply   (tag only, after uat-tfapply)
```

### `validate-yaml` Job

```bash
pip install check-jsonschema

# Validate producer registrations
for f in kafka/producers/**/*.yaml; do
  check-jsonschema --schemafile kafka/schema/producer-schema.json "$f"
done

# Validate consumer registrations
for f in kafka/consumers/*.yaml; do
  check-jsonschema --schemafile kafka/schema/consumer-schema.json "$f"
done

# Naming, placement, decommission guard, cross-reference, duplicate check
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
```

### `validate-topic-names.py` — Checks

1. **File placement (producers)**: `path.parent.name == metadata.businessName` and `path.stem == metadata.appName`
2. **File placement (consumers)**: `path.parent.name == "consumers"` and `path.stem == metadata.name`
3. **Event name pattern**: each `event.name` matches `^[a-z][a-z0-9-]*$`
4. **Event name uniqueness**: no duplicate `name` values within `spec.events`
5. **Overlap guard**: event name MUST NOT appear in both `spec.events` and `spec.decommissionedEvents`
6. **Consumer cross-reference**: every `{businessName, appName, eventName}` triple in a consumer YAML must resolve to an active (non-decommissioned) event in a registered producer YAML
7. **Decommission guard (file deletion)**: a producer YAML cannot be deleted from git without `spec.decommission: true` having been set
8. **Duplicate producer slug**: no two producer YAMLs may share `(metadata.businessName, metadata.appName)`
9. **Duplicate consumer slug**: `metadata.name` must be unique across all consumer files
10. **Consumer > 80 topics**: warning (non-blocking) for IAM policy 6 KB limit awareness

---

## E2E Canary Design

**Resources** (in `terraform/kafka_e2e_canary.tf`):
- `aws_lambda_function.canary` — Python 3.12, timeout 60s, memory 256 MB, VPC-attached, reads Lambda ZIP from `module.platform_s3` at key `e2e/kafka/canary/function.zip`
- `aws_iam_role.canary_lambda_execution` — no direct Kafka permissions; `sts:AssumeRole` on CanaryProducerRole and CanaryConsumerRole only
- `aws_cloudwatch_event_rule.canary` — `rate(5 minutes)`, ENABLED in all 4 environments
- `aws_cloudwatch_metric_alarm.kafka_e2e_test_failure` — evaluates `KafkaE2ETestSuccess` metric; 2-period evaluation; `treat_missing_data = "breaching"`; alarm action routes to `aws_sns_topic.alerts`
- `aws_cloudwatch_log_group.canary` — `/chedaws-edp/kafka-e2e-canary/<env>`; KMS-encrypted; retention per environment

**Canary cycle sequence**:
1. Assume CanaryProducerRole via `sts:AssumeRole`
2. Flush: `seek_to_end` on partition 0 to reset consumer read pointer
3. Produce a uniquely identified test message
4. Release producer credentials; wait settle period (default 5 seconds)
5. Assume CanaryConsumerRole via `sts:AssumeRole`
6. Consume messages within a 30-second timeout
7. Validate consumed message matches produced message ID
8. Emit `KafkaE2ETestSuccess = 1` (pass) or `0` (fail) via `cloudwatch:PutMetricData`
9. `try/finally` ensures metric is always emitted even on exception

**YAML registrations for canary**:
- `kafka/producers/platform/e2e.yaml` — `metadata.businessName: platform`, `metadata.appName: e2e`, one event `canary`; `iamRoles` per env = canary Lambda execution role ARN
- `kafka/consumers/platform-e2e-canary-consumer.yaml` — references `{businessName: platform, appName: e2e, eventName: canary}`; `consumerGroupPrefix: platform-e2e-canary`

---

## Scale Analysis

| Limit | Default | At 200 apps + 500 consumers per env | Action |
|---|---|---|---|
| IAM roles per account | 1,000 (soft) | 700 per env; 1,400 in dev+test account | Request increase to 2,000 for dev+test |
| IAM managed policies per account | 1,500 (soft) | 700 per env; 1,400 in dev+test account | Request increase to 3,000 for dev+test |
| IAM policy document size | 6 KB (hard) | ~3 KB for 50-topic consumer | Warn in CI if consumer references > 80 topics |
| MSK cluster policy size | 20 KB (hard) | Not applicable — role-assumption model | — |
