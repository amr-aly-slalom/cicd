# Kafka Self-Service Platform

This directory is the Git-based configuration store for Kafka topics and IAM access registrations on the `chedaws-edp-msk-<env>` clusters. Teams register topics and access by opening a pull request — the CI pipeline validates the YAML and Terraform provisions the resources.

## Topic Naming Convention

Topic names are assembled by Terraform from three declared fields and the current workspace environment:

```
edp-<environment>.<business_name>.<app_name>.<event_name>
```

Rules:
- Each segment matches `^[a-z][a-z0-9-]*$`
- Example: `edp-dev.ue.siq.order-created`
- The YAML file must be placed at `kafka/producers/<business_name>/<app_name>.yaml`
- The environment prefix is derived from the Terraform workspace (`local.environment`) — it is never written in the YAML

## How to Register a Producer Topic

1. Create a YAML file at `kafka/producers/<businessName>/<appName>.yaml` using the schema at `kafka/schema/producer-schema.json`
2. Declare all events for this app in `spec.events` — one Kafka topic is created per event per environment
3. Open a pull request — the `validate-yaml` CI job runs schema validation (`check-jsonschema`) and the naming/placement script (`validate-topic-names.py`)
4. The `@chedaws-platform-team` is a required reviewer (enforced by CODEOWNERS)
5. On merge to `main`, Terraform applies to dev and test automatically

### Sample Producer YAML

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: ue
  appName: siq
  owner: ue-team
  description: UE SIQ app events
spec:
  events:
    - name: order-created
      partitions: 6
      replicationFactor: 3
      retentionMs: 86400000
      cleanupPolicy: delete
    - name: order-updated
      partitions: 6
      replicationFactor: 3
      retentionMs: 86400000
      cleanupPolicy: delete
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/ue-siq-producer-dev
      prod:
        iamRoles:
          - arn:aws:iam::637423180765:role/ue-siq-producer-prod
```

Topics created on merge: `edp-dev.ue.siq.order-created`, `edp-dev.ue.siq.order-updated` (and equivalents per declared environment). One IAM producer role is created per environment, granting produce access to all the app's topics.

### UIQ Metering Topics

**`kafka/producers/ue/uiq.yaml`**

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: ue
  appName: uiq
  owner: <team-slug>
  description: UE metering topics
spec:
  events:
    - name: hf-read-results
      partitions: 12
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: export
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: event
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: voltage-threshold-trap
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: odr
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
  producer:
    environments:
      dev:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
      test:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
      uat:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
      prod:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
```

**`kafka/producers/vpn/uiq.yaml`**

```yaml
apiVersion: kafka.chedaws.io/v1
kind: TopicRegistration
metadata:
  businessName: vpn
  appName: uiq
  owner: <team-slug>
  description: VPN metering topics
spec:
  events:
    - name: hf-read-results
      partitions: 12
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: export
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: event
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
    - name: voltage-threshold-trap
      partitions: 6
      replicationFactor: 3
      retentionMs: 604800000
      cleanupPolicy: delete
  producer:
    environments:
      dev:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
      test:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
      uat:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
      prod:
        certificateSubject:
          - "CN=IOVLVDC2KAFN1"
```

For on-premises workloads using IAM Roles Anywhere, use `certificateSubject` instead of `iamRoles`. Multiple CNs can be listed — all are trusted by a single IAM role:

```yaml
  producer:
    onPrem: true
    environments:
      dev:
        # Either one of the following is required and accepted.
        certificateSubject:
          - "CN=metering-producer.dev.internal"
          - "CN=metering-producer-standby.dev.internal"  # optional additional CNs
        iamRoles:
          - arn:aws:iam::381491832813:role/ue-siq-producer-dev
```

## How to Register a Consumer

1. Create a YAML file at `kafka/consumers/<consumer-slug>.yaml` using the schema at `kafka/schema/consumer-schema.json`
2. Reference topics using three-field objects (`businessName`, `appName`, `eventName`) — the assembled topic name is resolved per environment by Terraform
3. Open a pull request with the same review and CI flow as producer registrations
4. Reference only active (non-decommissioned) events from registered producer YAMLs

### Sample Consumer YAML

```yaml
apiVersion: kafka.chedaws.io/v1
kind: ConsumerRegistration
metadata:
  name: ue-siq-glue-streaming job
  owner: ue-team
spec:
  topics:
    - businessName: ue
      appName: siq
      eventName: order-created
    - businessName: ue
      appName: siq
      eventName: order-updated
  consumer:
    consumerGroupPrefix: ue-siq-glue-streaming-job
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::381491832813:role/ue-siq-consumer-dev
      prod:
        iamRoles:
          - arn:aws:iam::637423180765:role/ue-siq-consumer-prod
```

## Topic Decommissioning (Two-Phase Process)

### Whole-app decommissioning

Retiring an entire producer app is a **two-step process**, recommended so the destroy shows up as its own small, reviewable plan rather than bundled into a bigger diff:

**Phase 1 — Mark for deletion**: Open a PR setting `spec.decommission: true` in the producer YAML. After merge and apply, all Kafka topics and IAM resources for this app are destroyed.

**Phase 2 — Remove YAML**: Open a follow-up PR deleting the YAML file. Terraform shows no changes (resources are already gone).

Deleting the YAML directly, without the `decommission: true` phase first, destroys the same resources on the next apply either way (Terraform's `for_each` excludes anything not in the file, same as it excludes `decommission: true` entries) - the two-phase process is a convention for a clean review, not something CI enforces.

### Per-event decommissioning

Retiring a single event within an app is also a two-step process, for the same reason:

**Phase 1 — Move to decommissioned list**: Open a PR moving the event name from `spec.events` to `spec.decommissionedEvents`. After merge and apply, the topic for that event is destroyed.

**Phase 2 — Remove from decommissioned list**: Open a follow-up PR removing the event from `decommissionedEvents`. Terraform shows no changes.

An event name must not appear in both `spec.events` and `spec.decommissionedEvents` at once - `validate-topic-names.py` still catches that as an ordinary per-file check.

## Drift Detection

`terraform plan` detects any out-of-band changes to managed Kafka topic configurations (e.g., `retention.ms` altered via CLI). A scheduled CI run on `main` provides ongoing drift detection. To test:

```bash
kafka-configs.sh --bootstrap-server <broker>:9098 --command-config iam.properties \
  --entity-type topics --entity-name edp-dev.ue.siq.order-created \
  --alter --add-config retention.ms=3600000

cd terraform && TF_WORKSPACE=dev terraform plan
# Expected: aws_msk_topic.this["edp-dev.ue.siq.order-created"] will be updated in-place
```

See [specs/005-kafka-topics/quickstart.md](../specs/005-kafka-topics/quickstart.md) for all validation scenarios.

## Platform Constants

### Bootstrap Broker Endpoints

Obtain from Terraform output after `terraform workspace select <env>`:

```bash
cd terraform/kafka   # MSK and Kafka resources have their own Terraform state
terraform workspace select dev
terraform output msk_bootstrap_brokers_sasl_iam
```

| Environment | AWS Account     |
|-------------|-----------------|
| dev         | 381491832813    |
| test        | 381491832813    |
| uat         | 339712719726    |
| prod        | 637423180765    |

### IAM Roles Anywhere (On-Premises Workloads)

The Trust Anchor and Profile are pre-configured by the platform team. On-premises teams supply only the certificate CN per environment in their YAML. Contact `@chedaws-platform-team` for the current Trust Anchor ARN and Profile ARN per account.

### IAM Quota Pre-Increase

The dev+test account (`381491832813`) has default IAM limits of 1,000 roles and 1,500 managed policies. Before onboarding beyond ~500 registrations, request increases via AWS Service Quotas:

- IAM roles limit → 2,000
- Managed policies limit → 3,000

Raise requests at: **AWS Console → Service Quotas → AWS Identity and Access Management (IAM)**

## Schema Validation

Validate locally before opening a PR:

```bash
pip install pyyaml check-jsonschema

# Producer
check-jsonschema --schemafile kafka/schema/producer-schema.json \
  kafka/producers/<business_name>/<app_name>.yaml

# Consumer
check-jsonschema --schemafile kafka/schema/consumer-schema.json \
  kafka/consumers/<consumer-slug>.yaml

# Naming + placement invariants (producers)
python3 .github/scripts/validate-topic-names.py kafka/producers/

# Naming + placement + cross-reference invariants (consumers)
python3 .github/scripts/validate-topic-names.py kafka/consumers/ --consumer
```
