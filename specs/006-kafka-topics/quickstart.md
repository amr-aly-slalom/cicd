# Quickstart Validation Guide: Kafka Topic Self-Service Platform

This guide describes how to validate each capability end-to-end. It covers the golden path for each user story and the critical edge-case guards.

---

## Prerequisites

- AWS CLI configured with credentials for the dev account (`381491832813`)
- `terraform` >= 1.5.0 installed; `terraform workspace select dev` active
- `python3` with `pyyaml` and `check-jsonschema` installed: `pip install pyyaml check-jsonschema`
- Bootstrap brokers from Terraform output: `terraform output msk_bootstrap_brokers_sasl_iam`

---

## Scenario 1: Register a New Producer App

### Setup

Create `kafka/producers/payments/invoicing.yaml`:

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: payments
  appName: invoicing
  owner: payments-team
spec:
  events:
    - name: created
      partitions: 6
      replicationFactor: 3
      retentionMs: 86400000
      cleanupPolicy: delete
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/payments-invoicing-producer-dev
```

### Validate

```bash
# Schema validation
check-jsonschema --schemafile kafka/schema/producer-schema.json \
  kafka/producers/payments/invoicing.yaml
# Expected: ok -- validation passed

# Naming, placement, and cross-reference validation
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
# Expected: OK: all YAML files passed validation

# Terraform plan
cd terraform && terraform workspace select dev && terraform plan
# Expected new resources:
#   aws_msk_topic.this["edp-dev.payments.invoicing.created"] + create
#   aws_iam_policy.kafka_producer["payments/invoicing"] + create
#   aws_iam_role.kafka_aws_producer["payments/invoicing"] + create
#   aws_iam_role_policy_attachment.kafka_aws_producer["payments/invoicing"] + create
```

### Confirm after apply

```bash
aws iam get-role --role-name edp-kafka-producer-payments-invoicing-dev
# Expected: role ARN returned; trust policy lists the declared ARN
```

---

## Scenario 2: Register a Consumer

### Setup

Create `kafka/consumers/payments-invoicing-consumer.yaml`:

```yaml
apiVersion: kafka.chedaws.io/v1
kind: ConsumerRegistration
metadata:
  name: payments-invoicing-consumer
  owner: accounts-team
spec:
  topics:
    - businessName: payments
      appName: invoicing
      eventName: created
  consumer:
    consumerGroupPrefix: accounts-reconciler
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::999988887777:role/accounts-glue-job-dev
```

### Validate

```bash
check-jsonschema --schemafile kafka/schema/consumer-schema.json \
  kafka/consumers/payments-invoicing-consumer.yaml
# Expected: ok -- validation passed

python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
# Expected: OK: all YAML files passed validation

cd terraform && terraform plan
# Expected new resources:
#   aws_iam_policy.kafka_consumer["payments-invoicing-consumer"] + create
#   aws_iam_role.kafka_aws_consumer["payments-invoicing-consumer"] + create
#   aws_iam_role_policy_attachment.kafka_aws_consumer["payments-invoicing-consumer"] + create
```

### Confirm after apply

```bash
aws iam get-role --role-name edp-kafka-consumer-payments-invoicing-consumer-dev
# Trust policy principal: arn:aws:iam::999988887777:role/accounts-glue-job-dev
# Attached policy includes ReadData on edp-dev.payments.invoicing.created topic ARN
# and AlterGroup/DescribeGroup on <cluster_arn>/group/accounts-reconciler*
```

---

## Scenario 3: On-Premises Producer via IAM Roles Anywhere

### Setup

Create `kafka/producers/metering/reads.yaml`:

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: metering
  appName: reads
  owner: metering-team
spec:
  events:
    - name: raw
      partitions: 3
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
  producer:
    onPrem: true
    environments:
      dev:
        certificateSubject: "CN=metering-producer.dev.internal"
```

### Validate

```bash
check-jsonschema --schemafile kafka/schema/producer-schema.json \
  kafka/producers/metering/reads.yaml
# Expected: ok -- validation passed

cd terraform && terraform plan
# Expected new resources:
#   aws_msk_topic.this["edp-dev.metering.reads.raw"] + create
#   aws_iam_policy.kafka_producer["metering/reads"] + create
#   aws_iam_role.kafka_onprem_producer["metering/reads"] + create
#   aws_iam_role_policy_attachment.kafka_onprem_producer["metering/reads"] + create
```

### Confirm after apply

```bash
aws iam get-role --role-name edp-kafka-producer-metering-reads-dev
# Trust policy principal: Service = rolesanywhere.amazonaws.com
# Condition: aws:PrincipalTag/x509Subject/CN = metering-producer.dev.internal
```

---

## Scenario 4: CI Validation Guards

### 4a — snake_case field rejected by schema

Create a YAML using snake_case field names:

```yaml
spec:
  events:
    - name: created
      partitions: 6
      replication_factor: 3     # snake_case — invalid
      retention_ms: 86400000    # snake_case — invalid
      cleanup_policy: delete    # snake_case — invalid
```

```bash
check-jsonschema --schemafile kafka/schema/producer-schema.json /tmp/test-snake.yaml
# Expected: FAIL — additionalProperties violation
```

### 4b — File placement mismatch (wrong directory)

Create `kafka/producers/risk/invoicing.yaml` with `metadata.businessName: payments` (directory is `risk`):

```bash
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
# Expected: FAIL — file directory 'risk' does not match metadata.businessName 'payments'
```

### 4c — Duplicate (businessName, appName) pair

Create a second file `kafka/producers/payments/invoicing-v2.yaml` with `metadata.businessName: payments` and `metadata.appName: invoicing` (same as the file in Scenario 1):

```bash
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
# Expected: FAIL — Duplicate producer slug (payments, invoicing)
```

### 4d — Consumer references non-existent producer topic

Create a consumer YAML referencing `{businessName: payments, appName: invoicing, eventName: non-existent}`:

```bash
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
# Expected: FAIL — topic reference (payments, invoicing, non-existent) does not exist in any active producer
```

---

## Scenario 5: Per-Event Decommission (Two-Phase)

### Phase 1 — Guard

Update `invoicing.yaml`: move `created` from `spec.events` to `spec.decommissionedEvents`:

```yaml
spec:
  events: []
  decommissionedEvents:
    - created
```

```bash
cd terraform && terraform plan
# Expected: aws_msk_topic.this["edp-dev.payments.invoicing.created"] will be destroyed
# Other resources (IAM role, policy) remain if the app still has other events
```

### Phase 2 — Cleanup

After apply confirms the topic is gone, open a follow-up PR to remove `created` from `decommissionedEvents`:

```bash
cd terraform && terraform plan
# Expected: No changes
```

---

## Scenario 6: Whole-App Decommission (Two-Phase)

### Phase 1 — Guard

Set `spec.decommission: true` in `kafka/producers/payments/invoicing.yaml`:

```bash
cd terraform && terraform plan
# Expected:
#   aws_msk_topic.this["edp-dev.payments.invoicing.created"] will be destroyed
#   aws_iam_role.kafka_aws_producer["payments/invoicing"] will be destroyed
#   aws_iam_policy.kafka_producer["payments/invoicing"] will be destroyed
#   (and attachments)
```

### Phase 2 — Remove YAML

After apply confirms all resources are destroyed:

```bash
git rm kafka/producers/payments/invoicing.yaml
cd terraform && terraform plan
# Expected: No changes — all resources already destroyed in Phase 1
```

---

## Scenario 7: Duplicate Detection at Plan Time

Register two files with the same `(businessName, appName)`:

```bash
# kafka/producers/payments/invoicing.yaml  (businessName: payments, appName: invoicing)
# kafka/producers/payments/invoicing-alt.yaml  (businessName: payments, appName: invoicing)

cd terraform && terraform plan
# Expected: Error from terraform_data.kafka_unique_name_check precondition:
#   Duplicate producer slug(s) detected: payments-invoicing
```

The native `for_each` key collision on `topics_this_env` also fires independently if the same assembled topic name appears in both files.

---

## Scenario 8: Overlap Guard (Event in Both Lists)

Create a YAML where an event name appears in both `spec.events` and `spec.decommissionedEvents`:

```yaml
spec:
  events:
    - name: created
      ...
  decommissionedEvents:
    - created   # same name as in events — invalid
```

```bash
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/
# Expected: FAIL — event 'created' appears in both spec.events and spec.decommissionedEvents
```

---

## Outputs Validation

```bash
cd terraform && terraform workspace select dev
terraform output kafka_producer_role_arns
# Expected: map with keys = app keys (e.g., "payments/invoicing"), values = IAM role ARNs

terraform output kafka_consumer_role_arns
# Expected: map with keys = consumer slugs, values = IAM role ARNs

terraform output topics_pending_destruction
# Expected: list of assembled topic names currently in decommissionedEvents
```

---

## References

- YAML schemas: [contracts/producer-schema.json](contracts/producer-schema.json) and [contracts/consumer-schema.json](contracts/consumer-schema.json)
- Data model: [data-model.md](data-model.md)
- Architecture reference: [kafka-topics.md](kafka-topics.md)
- Design decisions: [research.md](research.md)
