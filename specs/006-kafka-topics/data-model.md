# Data Model: Kafka Topic Self-Service Platform

---

## Entities

### 1. TopicRegistration (producer YAML)

**File path**: `kafka/producers/<businessName>/<appName>.yaml`

**Composite uniqueness key**: `(apiVersion, kind, metadata.businessName, metadata.appName)`

| Field | Type | Required | Constraint |
|---|---|---|---|
| `apiVersion` | string | yes | const `kafka.chedaws.io/v1` |
| `kind` | string | yes | const `TopicRegistration` |
| `metadata.businessName` | string | yes | `^[a-z][a-z0-9-]*$`; must equal `path.parent.name` |
| `metadata.appName` | string | yes | `^[a-z][a-z0-9-]*$`; must equal `path.stem` |
| `metadata.owner` | string | yes | minLength 1; team slug |
| `metadata.description` | string | no | free text |
| `spec.events` | array of EventTopicConfig | yes | minItems 1; event names unique within list |
| `spec.decommissionedEvents` | array of string | no | default `[]`; each `^[a-z][a-z0-9-]*$`; MUST NOT overlap with names in `spec.events` |
| `spec.decommission` | boolean | no | default false; triggers destroy of all topics and roles for this app |
| `spec.producer.onPrem` | boolean | no | default false |
| `spec.producer.environments` | object | yes | keys ⊆ `{dev, test, uat, prod}`; ≥1 key |
| `spec.producer.environments.<env>.iamRoles` | array of string | conditional | ARN pattern `^arn:aws:iam::[0-9]{12}:role/.+$`; mutually exclusive with `certificateSubject` |
| `spec.producer.environments.<env>.certificateSubject` | string | conditional | pattern `^CN=.+$`; mutually exclusive with `iamRoles` |

**File placement rule**: `path.parent.name == metadata.businessName` and `path.stem == metadata.appName`

**Decommission state transitions**:
```
active event      -> decommissionedEvents  (Phase 1: move event name)
decommissionedEvents -> (destroyed)        (Phase 1 apply: Terraform destroys topic)
                  -> (removed from list)   (Phase 2: clean up after confirm)

whole app active  -> decommission: true    (Phase 1: set flag)
decommission: true -> (all destroyed)      (Phase 1 apply)
                  -> YAML deleted          (Phase 2: no-op from Terraform)
```

---

### 2. EventTopicConfig

An entry in `spec.events`. Defines one Kafka topic per declared environment.

| Field | Type | Required | Constraint |
|---|---|---|---|
| `name` | string | yes | `^[a-z][a-z0-9-]*$`; unique within the `events` list |
| `partitions` | integer | yes | minimum 1 |
| `replicationFactor` | integer | yes | const 3 (must equal MSK broker count) |
| `retentionMs` | integer | yes | minimum -1; maximum 2,592,000,000 |
| `cleanupPolicy` | string | yes | `delete` \| `compact` \| `compact,delete` |
| `retentionBytes` | integer | no | minimum -1; default -1 |
| `maxMessageBytes` | integer | no | minimum 1; default 1,048,576 |

---

### 3. ConsumerRegistration (consumer YAML)

**File path**: `kafka/consumers/<slug>.yaml`

**Composite uniqueness key**: `(apiVersion, kind, metadata.name)`

| Field | Type | Required | Constraint |
|---|---|---|---|
| `apiVersion` | string | yes | const `kafka.chedaws.io/v1` |
| `kind` | string | yes | const `ConsumerRegistration` |
| `metadata.name` | string | yes | `^[a-z][a-z0-9-]*$`; unique across all consumer files; equals `path.stem` |
| `metadata.owner` | string | yes | minLength 1 |
| `metadata.description` | string | no | free text |
| `spec.topics` | array of TopicRef | yes | minItems 1 |
| `spec.consumer.consumerGroupPrefix` | string | no | minLength 1; enables group IAM actions |
| `spec.consumer.onPrem` | boolean | no | default false |
| `spec.consumer.environments` | object | yes | keys ⊆ `{dev, test, uat, prod}`; ≥1 key |
| `spec.consumer.environments.<env>.iamRoles` | array of string | conditional | ARN pattern; mutually exclusive with `certificateSubject` |
| `spec.consumer.environments.<env>.certificateSubject` | string | conditional | pattern `^CN=.+$`; mutually exclusive with `iamRoles` |

---

### 4. TopicRef

An entry in `spec.topics` of a `ConsumerRegistration`. Identifies one topic by its producer app identity.

| Field | Type | Required | Constraint |
|---|---|---|---|
| `businessName` | string | yes | `^[a-z][a-z0-9-]*$`; must match `metadata.businessName` of an active TopicRegistration |
| `appName` | string | yes | `^[a-z][a-z0-9-]*$`; must match `metadata.appName` of an active TopicRegistration |
| `eventName` | string | yes | `^[a-z][a-z0-9-]*$`; must match an active event name in the referenced TopicRegistration |

---

### 5. AssembledTopicName

Derived string. Never stored in YAML. Built by Terraform:

```hcl
"edp-${local.environment}.${v.metadata.businessName}.${v.metadata.appName}.${event.name}"
```

Where `local.environment = terraform.workspace` in `{dev, test, uat, prod}`.

Examples: `edp-dev.platform.e2e.canary`, `edp-prod.ue.siq.order-created`

---

### 6. KafkaTopic (`aws_msk_topic.this`)

Managed by `kafka_topics.tf` via `for_each = local.topics_this_env`.

| Attribute | Source |
|---|---|
| `name` | `each.key` (assembled topic name) |
| `cluster_arn` | `aws_msk_cluster.this.arn` |
| `partition_count` | `each.value.event.partitions` |
| `replication_factor` | `each.value.event.replicationFactor` |
| `configs["retention.ms"]` | `each.value.event.retentionMs` |
| `configs["retention.bytes"]` | `try(each.value.event.retentionBytes, -1)` |
| `configs["cleanup.policy"]` | `each.value.event.cleanupPolicy` |
| `configs["max.message.bytes"]` | `each.value.event.maxMessageBytes` (optional) |

**Terraform key**: the assembled topic name string (e.g., `edp-dev.ue.siq.order-created`)

---

### 7. ProducerIAMPolicy (`aws_iam_policy.kafka_producer`)

One per active producer app per environment.

| Attribute | Value |
|---|---|
| `name` | `edp-kafka-producer-<businessName>-<appName>-<env>` |
| ConnectToCluster statement | `kafka-cluster:Connect`, `kafka-cluster:DescribeCluster` on cluster ARN |
| ProduceToTopic statement | `kafka-cluster:DescribeTopic`, `kafka-cluster:WriteData` on each of the app's assembled topic ARNs |

---

### 8. ConsumerIAMPolicy (`aws_iam_policy.kafka_consumer`)

One per consumer slug per environment.

| Attribute | Value |
|---|---|
| `name` | `edp-kafka-consumer-<slug>-<env>` |
| ConnectToCluster statement | `kafka-cluster:Connect`, `kafka-cluster:DescribeCluster` on cluster ARN |
| ReadTopic statements | `kafka-cluster:DescribeTopic`, `kafka-cluster:ReadData` on each referenced topic ARN |
| ConsumerGroup statement (conditional) | `kafka-cluster:AlterGroup`, `kafka-cluster:DescribeGroup` on `<cluster_arn>/group/<consumerGroupPrefix>*` |

---

### 9. ProducerIAMRole — AWS variant (`aws_iam_role.kafka_aws_producer`)

Created when `onPrem=false` and `iamRoles` is non-empty in the current environment.

| Attribute | Value |
|---|---|
| `name` | `edp-kafka-producer-<businessName>-<appName>-<env>` |
| Trust principal | `{ AWS: [<workload_role_arns>] }` |
| Trust action | `sts:AssumeRole` |

---

### 10. ProducerIAMRole — on-prem variant (`aws_iam_role.kafka_onprem_producer`)

Created when `onPrem=true` and `certificateSubject` is set in the current environment.

| Attribute | Value |
|---|---|
| `name` | `edp-kafka-producer-<businessName>-<appName>-<env>` |
| Trust principal | `{ Service: "rolesanywhere.amazonaws.com" }` |
| Trust actions | `sts:AssumeRole`, `sts:TagSession`, `sts:SetSourceIdentity` |
| Condition | `StringEquals: { "aws:PrincipalTag/x509Subject/CN": "<CN>" }` |

CN is derived from `certificateSubject` via `split("CN=", ...)[1]`.

---

### 11. ConsumerIAMRole — AWS variant (`aws_iam_role.kafka_aws_consumer`)

| Attribute | Value |
|---|---|
| `name` | `edp-kafka-consumer-<slug>-<env>` |
| Trust principal | `{ AWS: [<workload_role_arns>] }` |
| Trust action | `sts:AssumeRole` |

---

### 12. ConsumerIAMRole — on-prem variant (`aws_iam_role.kafka_onprem_consumer`)

| Attribute | Value |
|---|---|
| `name` | `edp-kafka-consumer-<slug>-<env>` |
| Trust principal | `{ Service: "rolesanywhere.amazonaws.com" }` |
| Trust actions | `sts:AssumeRole`, `sts:TagSession`, `sts:SetSourceIdentity` |
| Condition | `StringEquals: { "aws:PrincipalTag/x509Subject/CN": "<CN>" }` |

---

### 13. PlatformS3Bucket (`module.platform_s3`)

Shared platform S3 bucket managed outside `kafka_topics.tf`.

| Attribute | Value |
|---|---|
| Bucket name | `chedaws-edp-platform-<env>` |
| KMS key alias | `alias/chedaws-edp-s3-<env>` |
| Canary ZIP prefix | `e2e/kafka/canary/function.zip` |

---

### 14. PlatformKMSKey

| Attribute | Value |
|---|---|
| Alias | `alias/chedaws-edp-s3-<env>` |
| Used by | Platform S3 bucket; CloudWatch log group for canary |

---

### 15. CanaryLambdaFunction (`aws_lambda_function.canary`)

Synthetic E2E test running every 5 minutes. Reads its ZIP from `module.platform_s3` at prefix `e2e/kafka/canary/function.zip`.

| Attribute | Value |
|---|---|
| Runtime | Python 3.12 |
| Timeout | 60 seconds |
| Memory | 256 MB |
| VPC | App-tier subnets |
| IAM | `aws_iam_role.canary_lambda_execution` — no direct Kafka permissions |
| Schedule | `rate(5 minutes)` via EventBridge, ENABLED in all 4 environments |

The Lambda execution role assumes CanaryProducerRole then CanaryConsumerRole via `sts:AssumeRole`. Both roles are provisioned by the standard YAML pipeline (`kafka/producers/platform/e2e.yaml` and `kafka/consumers/platform-e2e-canary-consumer.yaml`).

---

### 16. CanaryLogGroup (`aws_cloudwatch_log_group.canary`)

| Attribute | Value |
|---|---|
| Name | `/chedaws-edp/kafka-e2e-canary/<env>` |
| Encryption | KMS via `module.kms["cloudwatch_logs"].key_arn` |
| Retention | Per-environment |

---

### 17. CanaryAlarm (`aws_cloudwatch_metric_alarm.kafka_e2e_test_failure`)

| Attribute | Value |
|---|---|
| Metric | `KafkaE2ETestSuccess`, namespace `ChedawsEDP/KafkaE2ECanary` |
| Threshold | `< 1` for 2 consecutive evaluation periods (10 minutes) |
| Missing data | `treat_missing_data = "breaching"` |
| Alarm action | `aws_sns_topic.alerts.arn` |
| Scope | Active in all 4 environments; no `count` gate |

---

### 18. CanarySchedule (`aws_cloudwatch_event_rule.canary`)

| Attribute | Value |
|---|---|
| Schedule | `rate(5 minutes)` |
| State | ENABLED in all 4 environments |

---

## Locals Data Flow (Terraform)

```
_producer_files         (all YAML files under kafka/producers/**)
      |  expand events + filter: env declared + decommission=false + event not in decommissionedEvents
topics_this_env         (map: assembled-topic-name -> { app_key, app, event })
      |  group by app_key
_producers_this_env     (map: file-path-key -> app YAML; active apps in this env)
_topic_keys_per_app     (map: app_key -> [assembled topic names])
      |  segment by identity type
aws_producers_this_env     (app_key -> iamRoles list)
onprem_producers_this_env  (app_key -> { certificate_subject })

_consumer_files         (all YAML files under kafka/consumers/*.yaml)
      |  filter: env declared; key by metadata.name
consumers_this_env      (map: slug -> consumer YAML)
      |  segment by identity type
aws_consumers_this_env     (slug -> iamRoles list)
onprem_consumers_this_env  (slug -> { consumer_slug, certificate_subject })
```

---

## Relationships

```
TopicRegistration 1--* EventTopicConfig
TopicRegistration 1--1 KafkaTopic (per event per env)
TopicRegistration 1--1 ProducerIAMPolicy (per app per env)
TopicRegistration 1--0..1 ProducerIAMRole.AWS (per app per env, when onPrem=false)
TopicRegistration 1--0..1 ProducerIAMRole.OnPrem (per app per env, when onPrem=true)

ConsumerRegistration 1--* TopicRef
ConsumerRegistration 1--1 ConsumerIAMPolicy (per slug per env)
ConsumerRegistration 1--0..1 ConsumerIAMRole.AWS (per slug per env, when onPrem=false)
ConsumerRegistration 1--0..1 ConsumerIAMRole.OnPrem (per slug per env, when onPrem=true)
ConsumerRegistration *--* KafkaTopic (consumer accesses N topics)

CanaryLambdaFunction --(assumes)--> ProducerIAMRole (via canary producer YAML)
CanaryLambdaFunction --(assumes)--> ConsumerIAMRole (via canary consumer YAML)
CanaryLambdaFunction --(ZIP from)--> PlatformS3Bucket
```

---

## Validation Rules Summary

| Rule | Enforcement |
|---|---|
| Event name regex `^[a-z][a-z0-9-]*$` | JSON Schema + `validate-topic-names.py` |
| `metadata.businessName` / `appName` regex | JSON Schema |
| Producer file placement | `validate-topic-names.py` |
| Consumer file placement (flat) | `validate-topic-names.py` |
| `replicationFactor == 3` | JSON Schema (`const: 3`) |
| `retentionMs` <= 2,592,000,000 | JSON Schema (`maximum`) |
| `cleanupPolicy` in allowed set | JSON Schema (`enum`) |
| `iamRoles` XOR `certificateSubject` per env | JSON Schema (`oneOf`) |
| `environments` non-empty | JSON Schema (`minProperties: 1`) |
| `events` non-empty | JSON Schema (`minItems: 1`) |
| Event name unique within app | `validate-topic-names.py` |
| No event in both `events` and `decommissionedEvents` | `validate-topic-names.py` |
| Consumer cross-reference (topic must exist) | `validate-topic-names.py` |
| Duplicate producer slug | `validate-topic-names.py` + `terraform_data` precondition |
| Duplicate consumer slug | `validate-topic-names.py` + `terraform_data` precondition |
| IAM role name <= 64 chars | `terraform_data.kafka_producer_name_length_check` |
| Decommission guard (no silent YAML delete) | `validate-topic-names.py` |
| Consumer > 80 topics (warning only) | `validate-topic-names.py` |
