# Quickstart & Validation Guide: Kafka Connect Support

**Date**: 2026-07-21

This guide describes how to validate that the Kafka Connect support feature is working correctly end-to-end. It covers the UE connect registration (P1) and a second server registration (P2).

---

## Prerequisites

- Terraform >= 1.5.0 with the `hashicorp/aws ~> 6.0` provider configured for the target account
- `check-jsonschema` installed (`pip install check-jsonschema`)
- `PyYAML` installed (`pip install pyyaml`)
- Access to the test environment AWS account (`381491832813`)

---

## Scenario 1: UE Kafka Connect producer registration (P1)

### Setup

Ensure the following files exist after the feature is implemented:

- `kafka/connect/ue/ue-connect.yaml` — new connect registration
- `kafka/producers/ue/siq.yaml` — `producer` block removed
- `kafka/producers/ue/uiq.yaml` — `producer` block removed

### Step 1 — CI schema validation

```bash
# Validate the connect registration
check-jsonschema --schemafile kafka/schema/connect-schema.json kafka/connect/ue/ue-connect.yaml

# Validate the modified producer files
check-jsonschema --schemafile kafka/schema/producer-schema.json kafka/producers/ue/siq.yaml
check-jsonschema --schemafile --schemafile kafka/schema/producer-schema.json kafka/producers/ue/uiq.yaml

# Run cross-file validation
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/ kafka/connect/
```

**Expected**: All commands exit 0. No errors about orphaned TopicRegistrations or missing sources.

### Step 2 — Terraform plan (test environment)

```bash
terraform plan -var="env=test"
```

**Expected plan output**:
- **Destroy**: `aws_iam_role.kafka_onprem_producer["ue/siq"]`, `aws_iam_role.kafka_onprem_producer["ue/uiq"]`, `aws_iam_policy.kafka_producer["ue/siq"]`, `aws_iam_policy.kafka_producer["ue/uiq"]`, and their policy attachments
- **Create**: `aws_iam_role.kafka_onprem_connect["ue-connect"]`, `aws_iam_policy.kafka_connect["ue-connect"]`, `aws_iam_role_policy_attachment.kafka_onprem_connect["ue-connect"]`
- **Create**: `aws_msk_topic.kafka_connect_system_topic["ue-connect-connect-config"]`, `aws_msk_topic.kafka_connect_system_topic["ue-connect-connect-offsets"]`, `aws_msk_topic.kafka_connect_system_topic["ue-connect-connect-status"]`, `aws_msk_topic.kafka_connect_system_topic["ue-connect-confluent-license"]`
- **No change**: All `aws_msk_topic.this["edp-test.ue.siq.*"]` and `aws_msk_topic.this["edp-test.ue.uiq.*"]` (business topics unchanged)

**Verify IAM role count**: Confirm exactly one `aws_iam_role.kafka_onprem_connect` is created, replacing the two previous `aws_iam_role.kafka_onprem_producer` resources.

### Step 3 — IAM policy content verification

After `terraform apply`, retrieve the created policy document and verify:

```bash
aws iam get-policy-version \
  --policy-arn $(aws iam list-policies --query "Policies[?PolicyName=='edp-test-kafka-connect-ue-connect'].Arn" --output text) \
  --version-id v1 \
  --query 'PolicyVersion.Document'
```

**Expected policy statements**:
1. `ConnectToCluster` — `kafka-cluster:Connect`, `kafka-cluster:DescribeCluster` on cluster ARN
2. `ProduceBusinessTopics` — `kafka-cluster:DescribeTopic`, `kafka-cluster:WriteData` on 5 business topic ARNs: `edp-test.ue.siq.hf-read-results`, `edp-test.ue.siq.voltage-threshold-trap`, `edp-test.ue.uiq.ssnevent`, `edp-test.ue.uiq.export`, `edp-test.ue.uiq.odr`
3. `SystemTopicsReadWrite` — `kafka-cluster:DescribeTopic`, `kafka-cluster:WriteData`, `kafka-cluster:ReadData` on 4 system topic ARNs: `ue-connect-connect-config`, `ue-connect-connect-offsets`, `ue-connect-connect-status`, `ue-connect-confluent-license`
4. `SystemTopicsConsumerGroup` — `kafka-cluster:AlterGroup`, `kafka-cluster:DescribeGroup` on group ARN matching `ue-connect-*`

### Step 4 — Trust policy verification

```bash
aws iam get-role \
  --role-name edp-test-kafka-connect-ue-connect \
  --query 'Role.AssumeRolePolicyDocument'
```

**Expected**: Trust policy principal is `rolesanywhere.amazonaws.com`; condition `ForAnyValue:StringEquals` on `aws:PrincipalTag/x509Subject/CN` includes `IOVLVDC2KAFN1`.

### Step 5 — System topic verification

```bash
terraform output kafka_connect_system_topic_names
```

**Expected**: `["ue-connect-connect-config", "ue-connect-connect-offsets", "ue-connect-connect-status", "ue-connect-confluent-license"]`

---

## Scenario 2: Second Kafka Connect server (P2 — no Terraform changes needed)

### Setup

Add a new file `kafka/connect/vpn/vpn-connect.yaml` (cloud-based, standard variant):

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
      test:
        iamRoles:
          - arn:aws:iam::381491832813:role/vpn-connect-worker-test
```

And remove the `producer` block from `kafka/producers/vpn/siq.yaml`.

### Step 1 — Terraform plan

```bash
terraform plan -var="env=test"
```

**Expected**: Only net-new resources are planned. The `ue-connect` role and its system topics show **no change**. New resources for `vpn-connect` are planned:
- `aws_iam_role.kafka_aws_connect["vpn-connect"]`
- `aws_iam_policy.kafka_connect["vpn-connect"]`
- `aws_iam_role_policy_attachment.kafka_aws_connect["vpn-connect"]`
- `aws_msk_topic.kafka_connect_system_topic["vpn-connect-connect-config"]`
- `aws_msk_topic.kafka_connect_system_topic["vpn-connect-connect-offsets"]`
- `aws_msk_topic.kafka_connect_system_topic["vpn-connect-connect-status"]`
- **No** `vpn-connect-confluent-license` (standard variant, no Confluent)

**Key check**: Confirm `ue-connect-connect-config` topic and role are NOT in the plan diff — they must remain untouched.

---

## Scenario 3: CI rejects invalid connect registration

### Invalid source reference

Create a connect YAML that references a non-existent app:

```yaml
apiVersion: kafka.chedaws.io/v1
kind: KafkaConnectRegistration
metadata:
  name: bad-connect
  owner: test-team
spec:
  sources:
    - businessName: nonexistent
      appName: app
  connect:
    environments:
      test:
        certificateSubject:
          - "CN=test"
```

```bash
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/ kafka/connect/
```

**Expected**: Exit non-zero with an error message identifying the unresolved source `{nonexistent, app}`.

### Orphaned TopicRegistration

Remove the `producer` block from `kafka/producers/ue/siq.yaml` without adding a connect registration:

```bash
python3 .github/scripts/validate-topic-names.py kafka/producers/ kafka/consumers/ kafka/connect/
```

**Expected**: Exit non-zero with an error identifying `ue/siq` as a `TopicRegistration` with no `producer` block and no connect registration claiming it.

---

## Outputs to verify after full apply

```bash
terraform output kafka_connect_role_arns
# Expected: {"ue-connect": "arn:aws:iam::381491832813:role/edp-test-kafka-connect-ue-connect"}

terraform output kafka_connect_system_topic_names
# Expected includes: ue-connect-connect-config, ue-connect-connect-offsets,
#                    ue-connect-connect-status, ue-connect-confluent-license

terraform output kafka_producer_role_arns
# Expected: ue/siq and ue/uiq keys are ABSENT (no longer provisioned as standalone producer roles)
```
