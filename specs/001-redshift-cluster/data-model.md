# Data Model: Redshift Cluster Provisioning

**Phase**: 1 — Design
**Date**: 2026-06-26
**Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md)

All entities are Terraform-managed AWS resources. KMS CMKs are provisioned via the `terraform/modules/kms/` module (invoked from `kms.tf`). All other entities are defined inline in the `terraform/` root configuration. One complete set of entities is created per Terraform workspace (environment).

---

## Entity: KMS Module

**Terraform module**: `module "kms"` (via `for_each = local.kms_services`)
**Module source**: `terraform/modules/kms/`
**Invoked from**: `terraform/kms.tf`

| Input | Type | Description |
|-------|------|-------------|
| `service_name` | `string` | Service key used in alias and description (e.g., `"redshift"`, `"sns"`, `"cloudwatch_logs"`) |
| `service_principal` | `string` | AWS service principal granted KMS actions (e.g., `"redshift.amazonaws.com"`) |
| `environment` | `string` | Terraform workspace name; embedded in alias suffix |

| Output | Value |
|--------|-------|
| `key_arn` | `aws_kms_key.this.arn` |
| `key_id` | `aws_kms_key.this.id` |
| `alias_arn` | `aws_kms_alias.this.arn` |

**Module files**: `main.tf`, `variables.tf`, `outputs.tf`, `README.md` (MUST include "Consumers" section)

**Relationships**:
- Invoked three times from `kms.tf` via `for_each = local.kms_services` with keys `"redshift"`, `"sns"`, `"cloudwatch_logs"`
- Outputs consumed as `module.kms["redshift"].key_arn`, `module.kms["sns"].key_arn`, `module.kms["cloudwatch_logs"].key_arn`

---

## Entity: KMS Customer Managed Key – Redshift

**Terraform resource** (module-internal): `aws_kms_key.this` (within `module.kms["redshift"]`)
**Terraform alias** (module-internal): `aws_kms_alias.this`
**Provisioned via**: `module.kms["redshift"]` in `terraform/modules/kms/`

| Attribute | Value / Rule |
|-----------|-------------|
| `description` | `"KMS CMK for Redshift cluster chedaws-edp-<environment>"` |
| `deletion_window_in_days` | `30` (maximum; key deletion protection) |
| `enable_key_rotation` | `true` |
| `policy` | Lean: root IAM (`kms:*`) + `redshift.amazonaws.com` (`Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant`) |
| `alias` | `alias/chedaws-edp-redshift-<environment>` |
| Name tag | `chedaws-edp-redshift-kms-<environment>` |

**Relationships**:
- Output `key_arn` referenced by `aws_redshift_cluster.this` as `kms_key_id`
- Output `key_arn` referenced by `aws_secretsmanager_secret.redshift_password` as `kms_key_id`

---

## Entity: KMS Customer Managed Key – SNS

**Terraform resource** (module-internal): `aws_kms_key.this` (within `module.kms["sns"]`)
**Terraform alias** (module-internal): `aws_kms_alias.this`
**Provisioned via**: `module.kms["sns"]` in `terraform/modules/kms/`

| Attribute | Value / Rule |
|-----------|-------------|
| `description` | `"KMS CMK for SNS topic chedaws-edp-alerts-<environment>"` |
| `deletion_window_in_days` | `30` |
| `enable_key_rotation` | `true` |
| `policy` | Lean: root IAM (`kms:*`) + `sns.amazonaws.com` (`Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant`) |
| `alias` | `alias/chedaws-edp-sns-<environment>` |
| Name tag | `chedaws-edp-sns-kms-<environment>` |

**Relationships**:
- Output `key_arn` referenced by `aws_sns_topic.alerts` as `kms_master_key_id`

---

## Entity: KMS Customer Managed Key – CloudWatch Logs

**Terraform resource** (module-internal): `aws_kms_key.this` (within `module.kms["cloudwatch_logs"]`)
**Terraform alias** (module-internal): `aws_kms_alias.this`
**Provisioned via**: `module.kms["cloudwatch_logs"]` in `terraform/modules/kms/`

| Attribute | Value / Rule |
|-----------|-------------|
| `description` | `"KMS CMK for CloudWatch Log Group /chedaws-edp/redshift/<environment>"` |
| `deletion_window_in_days` | `30` |
| `enable_key_rotation` | `true` |
| `policy` | Lean: root IAM (`kms:*`) + `logs.<region>.amazonaws.com` (`Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant`) |
| `alias` | `alias/chedaws-edp-cloudwatch-<environment>` |
| Name tag | `chedaws-edp-cloudwatch-kms-<environment>` |

**Relationships**:
- Output `key_arn` referenced by `aws_cloudwatch_log_group.redshift` as `kms_key_id`

---

## Entity: Random Password

**Terraform resource**: `resource.random_password.redshift`
**File**: `terraform/redshift.tf`

| Attribute | Value |
|-----------|-------|
| `length` | `32` |
| `min_lower` | `1` |
| `min_upper` | `1` |
| `min_numeric` | `1` |
| `min_special` | `1` |
| `special` | `true` |
| `override_special` | `"!#$%&*()-_=+[]{}<>:?"` |

**Relationships**:
- Value passed to `aws_secretsmanager_secret_version.redshift_password` as `secret_string`
- Value passed to `aws_redshift_cluster.this` as `master_password`

**Note**: The generated value is stored in Terraform state (S3, AES-256 encrypted).

---

## Entity: Secrets Manager Secret (Metadata)

**Terraform resource**: `aws_secretsmanager_secret.redshift_password`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `name` | `/chedaws-edp/<environment>/redshift/master-password` |
| `kms_key_id` | `module.kms["redshift"].key_arn` |
| `description` | `"Redshift master password for chedaws-edp-<environment>"` |
| `recovery_window_in_days` | `7` |
| Name tag | `chedaws-edp-redshift-secret-<environment>` |

**Relationships**:
- Holds the secret version via `aws_secretsmanager_secret_version.redshift_password`

---

## Entity: Secrets Manager Secret Version

**Terraform resource**: `aws_secretsmanager_secret_version.redshift_password`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `secret_id` | `aws_secretsmanager_secret.redshift_password.id` |
| `secret_string` | `random_password.redshift.result` |

---

## Entity: Redshift Parameter Group

**Terraform resource**: `aws_redshift_parameter_group.this`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `name` | `chedaws-edp-redshift-params-<environment>` |
| `family` | `redshift-2.0` |
| `parameter: require_ssl` | `"true"` |
| `description` | `"Parameter group for chedaws-edp-<environment> Redshift cluster"` |

**Relationships**:
- Referenced by `aws_redshift_cluster.this` as `cluster_parameter_group_name`

---

## Entity: Redshift Subnet Group

**Terraform resource**: `aws_redshift_subnet_group.this`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `name` | `chedaws-edp-redshift-subnet-group-<environment>` |
| `subnet_ids` | Union of `data.aws_subnets.app.ids` and `data.aws_subnets.db.ids` |
| `description` | `"Subnet group for chedaws-edp-<environment> Redshift cluster"` |

**Relationships**:
- Depends on `data.aws_subnets.app` (tag `Tier=App`, filtered by `local.vpc_id`)
- Depends on `data.aws_subnets.db` (tag `Tier=Db`, filtered by `local.vpc_id`)
- Referenced by `aws_redshift_cluster.this` as `cluster_subnet_group_name`

---

## Entity: Security Group

**Terraform resource**: `aws_security_group.redshift`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `name` | `chedaws-edp-redshift-sg-<environment>` |
| `description` | `"Security group for chedaws-edp-<environment> Redshift cluster"` |
| `vpc_id` | `local.vpc_id` |
| Ingress rule (App) | TCP port 5439 from each CIDR in `data.aws_subnet.app[*].cidr_block` |
| Ingress rule (DB) | TCP port 5439 from each CIDR in `data.aws_subnet.db[*].cidr_block` |
| Egress rule | Allow all outbound (AWS default) |

**Validation rule**: If either `data.aws_subnets.app.ids` or `data.aws_subnets.db.ids` is empty, `terraform plan` will produce zero ingress rules, surfacing the misconfiguration at plan time.

**Relationships**:
- Depends on `data.aws_subnet.app` and `data.aws_subnet.db` (CIDR resolution)
- Referenced by `aws_redshift_cluster.this` as `vpc_security_group_ids`

---

## Entity: Redshift Cluster

**Terraform resource**: `aws_redshift_cluster.this`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `cluster_identifier` | `chedaws-edp-<environment>` |
| `database_name` | `edp` |
| `master_username` | `edpadmin` |
| `master_password` | `random_password.redshift.result` |
| `node_type` | `rg.xlarge` (dev/test) · `rg.4xlarge` (uat/prod) — via `local.redshift_node_type` |
| `number_of_nodes` | `2` |
| `cluster_type` | `multi-node` (because `number_of_nodes = 2`) |
| `cluster_subnet_group_name` | `aws_redshift_subnet_group.this.name` |
| `cluster_parameter_group_name` | `aws_redshift_parameter_group.this.name` |
| `vpc_security_group_ids` | `[aws_security_group.redshift.id]` |
| `kms_key_id` | `module.kms["redshift"].key_arn` |
| `encrypted` | `true` |
| `publicly_accessible` | `false` |
| `skip_final_snapshot` | `true` (dev/test) · `false` (uat/prod) — via `local.redshift_skip_final_snapshot` |
| `final_snapshot_identifier` | `chedaws-edp-<environment>-final-snapshot` |
| `automated_snapshot_retention_period` | `1` (dev/test) · `7` (uat/prod) — via `local.redshift_snapshot_retention` |
| `enhanced_vpc_routing` | `true` (required for CloudWatch logging) |
| `port` | `5439` |

**Locals required** (to be added to `terraform/locals.tf`):

```hcl
redshift_node_type = {
  dev  = "rg.xlarge"
  test = "rg.xlarge"
  uat  = "rg.4xlarge"
  prod = "rg.4xlarge"
}[local.environment]

redshift_snapshot_retention = {
  dev  = 1
  test = 1
  uat  = 7
  prod = 7
}[local.environment]

redshift_skip_final_snapshot = contains(["dev", "test"], local.environment)
```

**Relationships**:
- Depends on `aws_redshift_subnet_group.this`, `aws_redshift_parameter_group.this`, `aws_security_group.redshift`, `module.kms["redshift"]`, `random_password.redshift`

---

## Entity: Redshift Audit Logging

**Terraform resource**: `aws_redshift_logging.this`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `cluster_identifier` | `aws_redshift_cluster.this.id` |
| `log_destination_type` | `"cloudwatch"` |
| `log_exports` | `["connectionlog", "userlog", "useractivitylog"]` |

**Note**: Requires `enhanced_vpc_routing = true` on the cluster and the CloudWatch Log Group to exist before the logging resource is applied.

**Relationships**:
- Depends on `aws_redshift_cluster.this` and `aws_cloudwatch_log_group.redshift`

---

## Entity: CloudWatch Log Group

**Terraform resource**: `aws_cloudwatch_log_group.redshift`
**File**: `terraform/redshift.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `name` | `/chedaws-edp/redshift/<environment>` |
| `retention_in_days` | `7` (dev/test) · `30` (uat) · `90` (prod) — via `local.redshift_log_retention` |
| `kms_key_id` | `module.kms["cloudwatch_logs"].key_arn` |

**Locals required**:

```hcl
redshift_log_retention = {
  dev  = 7
  test = 7
  uat  = 30
  prod = 90
}[local.environment]
```

---

## Entity: SNS Alert Topic

**Terraform resource**: `aws_sns_topic.alerts`
**File**: `terraform/sns.tf`

| Attribute | Value / Rule |
|-----------|-------------|
| `name` | `chedaws-edp-alerts-<environment>` |
| `kms_master_key_id` | `module.kms["sns"].key_arn` |
| `display_name` | `"EDP Alerts – <ENVIRONMENT>"` |

**Note**: Subscription wiring (email, PagerDuty, Slack) is explicitly out of scope for this feature. The topic is the shared notification channel for all future EDP CloudWatch alarms.

---

## Entity: CloudWatch Alarms (×3)

**Terraform resources**: `aws_cloudwatch_metric_alarm.redshift_cpu`, `aws_cloudwatch_metric_alarm.redshift_disk`, `aws_cloudwatch_metric_alarm.redshift_connections`
**File**: `terraform/redshift.tf`

| Name | Metric | Namespace | Statistic | Period | Threshold |
|------|--------|-----------|-----------|--------|-----------|
| `chedaws-edp-redshift-cpu-<env>` | `CPUUtilization` | `AWS/Redshift` | Average | 300s | 85% |
| `chedaws-edp-redshift-disk-<env>` | `PercentageDiskSpaceUsed` | `AWS/Redshift` | Average | 300s | 80% |
| `chedaws-edp-redshift-connections-<env>` | `DatabaseConnections` | `AWS/Redshift` | Average | 300s | 450 (dev/test) · 900 (uat/prod) |

All alarms:
- `comparison_operator`: `"GreaterThanOrEqualToThreshold"`
- `evaluation_periods`: `2`
- `alarm_actions`: `[aws_sns_topic.alerts.arn]`
- `ok_actions`: `[aws_sns_topic.alerts.arn]`
- `dimensions`: `{ ClusterIdentifier = aws_redshift_cluster.this.cluster_identifier }`
- `treat_missing_data`: `"notBreaching"`

---

## Data Sources

**File**: `terraform/data.tf` (additions)

| Resource | Filter | Purpose |
|----------|--------|---------|
| `data.aws_subnets.app` | `vpc-id = local.vpc_id`, tag `Tier=App` | Discover App-tier subnet IDs |
| `data.aws_subnets.db` | `vpc-id = local.vpc_id`, tag `Tier=Db` | Discover DB-tier subnet IDs |
| `data.aws_subnet.app` | `for_each = toset(data.aws_subnets.app.ids)` | Resolve App subnet CIDR blocks |
| `data.aws_subnet.db` | `for_each = toset(data.aws_subnets.db.ids)` | Resolve DB subnet CIDR blocks |

---

## Entity Relationship Diagram

```
random_password.redshift ──────────────────────────┐
                                                    │ master_password
module.kms["redshift"] ────────────────────────────┼──► aws_redshift_cluster.this
    └──► aws_secretsmanager_secret.redshift_password│         │
                                         ▲          │         ▼
         random_password.redshift.result─┘          │  aws_redshift_logging.this
                                                    │
module.kms["cloudwatch_logs"] ──────────────────────┘
    └──► aws_cloudwatch_log_group.redshift ─────────► aws_redshift_logging.this

module.kms["sns"]
    └──► aws_sns_topic.alerts ◄──── aws_cloudwatch_metric_alarm.redshift_*

aws_redshift_subnet_group.this ────────────────────► aws_redshift_cluster.this
    ├── data.aws_subnets.app
    └── data.aws_subnets.db

aws_security_group.redshift ───────────────────────► aws_redshift_cluster.this
    ├── data.aws_subnet.app (CIDRs)
    └── data.aws_subnet.db (CIDRs)

aws_redshift_parameter_group.this ─────────────────► aws_redshift_cluster.this
```
