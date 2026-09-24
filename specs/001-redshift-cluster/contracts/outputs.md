# Terraform Outputs Contract: Redshift Cluster Provisioning

**Feature**: 001-redshift-cluster
**Date**: 2026-06-26
**Spec**: [spec.md](../spec.md) | **Data Model**: [data-model.md](../data-model.md)

These outputs are added to `terraform/outputs.tf` and represent the public interface of the Redshift cluster to other Terraform configurations and consumers.

---

## Outputs

### `redshift_cluster_identifier`

| Field | Value |
|-------|-------|
| Description | The cluster identifier used in AWS (e.g., `chedaws-edp-dev`) |
| Terraform expression | `aws_redshift_cluster.this.cluster_identifier` |
| Sensitive | No |
| Consumers | Application configs, other Terraform roots, monitoring dashboards |

---

### `redshift_cluster_endpoint`

| Field | Value |
|-------|-------|
| Description | The DNS endpoint of the Redshift cluster (host only, without port) |
| Terraform expression | `aws_redshift_cluster.this.dns_name` |
| Sensitive | No |
| Consumers | Application connection strings, DMS source/target configs |

---

### `redshift_cluster_port`

| Field | Value |
|-------|-------|
| Description | The port the cluster listens on (always `5439`) |
| Terraform expression | `aws_redshift_cluster.this.port` |
| Sensitive | No |
| Consumers | Application connection strings |

---

### `redshift_database_name`

| Field | Value |
|-------|-------|
| Description | The name of the default database (`edp`) |
| Terraform expression | `aws_redshift_cluster.this.database_name` |
| Sensitive | No |
| Consumers | Application configs, Glue connections, DMS endpoints |

---

### `redshift_master_secret_arn`

| Field | Value |
|-------|-------|
| Description | ARN of the Secrets Manager secret holding the master password |
| Terraform expression | `aws_secretsmanager_secret.redshift_password.arn` |
| Sensitive | No (ARN only; value is in Secrets Manager) |
| Consumers | IAM policies for applications needing DB access, CI pipelines |

---

### `redshift_security_group_id`

| Field | Value |
|-------|-------|
| Description | ID of the Redshift security group |
| Terraform expression | `aws_security_group.redshift.id` |
| Sensitive | No |
| Consumers | Future resources requiring VPC peering or additional SG rules |

---

### `redshift_kms_key_arn`

| Field | Value |
|-------|-------|
| Description | ARN of the KMS CMK used for Redshift encryption at rest |
| Terraform expression | `module.kms["redshift"].key_arn` |
| Sensitive | No |
| Consumers | IAM policies, DMS replication tasks, cross-service encryption grants |

---

### `sns_kms_key_arn`

| Field | Value |
|-------|-------|
| Description | ARN of the KMS CMK used for the SNS alert topic encryption at rest |
| Terraform expression | `module.kms["sns"].key_arn` |
| Sensitive | No |
| Consumers | Future EDP features adding SNS topics that reuse the environment's SNS CMK |

---

### `cloudwatch_logs_kms_key_arn`

| Field | Value |
|-------|-------|
| Description | ARN of the KMS CMK used for CloudWatch Log Group encryption at rest |
| Terraform expression | `module.kms["cloudwatch_logs"].key_arn` |
| Sensitive | No |
| Consumers | Future EDP features adding CloudWatch Log Groups that reuse the environment's CloudWatch Logs CMK |

---

### `redshift_sns_topic_arn`

| Field | Value |
|-------|-------|
| Description | ARN of the shared EDP CloudWatch alerts SNS topic |
| Terraform expression | `aws_sns_topic.alerts.arn` |
| Sensitive | No |
| Consumers | Future CloudWatch alarms for other EDP components (Glue, DMS, ECS) |
