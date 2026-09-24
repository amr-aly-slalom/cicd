# Research: Redshift Cluster Provisioning

**Phase**: 0 — Pre-design research
**Date**: 2026-06-26
**Resolves**: All NEEDS CLARIFICATION items from Technical Context

---

## Decision 1: Redshift Node Type Identifiers

**Decision**: Use `rg.xlarge` for `dev`/`test` and `rg.4xlarge` for `uat`/`prod`.

**Rationale**: `rg.xlarge` and `rg.4xlarge` are valid AWS Redshift node type identifiers, confirmed via the [AWS documentation for provisioned clusters](https://docs.aws.amazon.com/redshift/latest/mgmt/working-with-clusters.html) (session 2026-06-28). RG nodes are Graviton-based and represent the current recommended generation, providing superior price/performance over the older RA3 family. They support Redshift Managed Storage (RMS — separates compute from storage) and are available in ap-southeast-2. The original spec used `rg.xlarge`/`rg.4xlarge`, and these are used as-is.

| Node type | vCPU | RAM | Default slices/node | Managed storage limit/node |
|-----------|------|-----|--------------------|-----------------------------|
| `rg.xlarge` (multi-node) | 4 | 32 GiB | 2 | 32 TB |
| `rg.4xlarge` | 16 | 128 GiB | 8 | 128 TB |

**Note**: `rg.xlarge` requires multi-node (minimum 2 nodes), which is consistent with FR-003 (exactly 2 nodes per cluster). A previous research iteration (2026-06-26) incorrectly resolved these to `ra3.xlplus`/`ra3.4xlarge`; that decision has been superseded by this finding.

**Alternatives considered**:
- `ra3.xlplus` / `ra3.4xlarge` (RA3 family): Superseded — RA3 is an older generation; RG nodes deliver better price/performance on Graviton hardware.
- `dc2.large` / `dc2.8xlarge` (Dense Compute): Rejected — local SSD storage, no RMS, older generation; scaling requires node replacement.
- `ds2.xlarge` (Dense Storage): Rejected — legacy HDD-based, not recommended for new deployments.

---

## Decision 2: CloudWatch Audit Logging for Redshift

**Decision**: Use the standalone `aws_redshift_logging` resource with `log_destination_type = "cloudwatch"` and `log_exports = ["connectionlog", "userlog", "useractivitylog"]`.

**Rationale**: The `aws_redshift_cluster` resource has a `logging` block but it targets S3 only in older provider versions. The `hashicorp/aws ~> 6.0` provider introduced the separate `aws_redshift_logging` resource which natively supports CloudWatch as a destination. Using the standalone resource keeps the cluster resource clean and avoids the commented-out logging block pattern seen in `terraform-legacy/modules/redshift/main.tf`.

| Log type attribute | What it captures |
|--------------------|-----------------|
| `connectionlog` | Authentication attempts, connections, disconnections |
| `userlog` | User creation, deletion, and rename events |
| `useractivitylog` | Every SQL statement executed (verbose; use with appropriate retention) |

The CloudWatch Log Group must be pre-created and passed to the `aws_redshift_logging` resource; Redshift will write log streams into it.

**Alternatives considered**:
- S3 bucket logging (`log_destination_type = "s3"`): Rejected — spec explicitly requires CloudWatch as destination (FR-020).
- `logging` block inside `aws_redshift_cluster`: Rejected — only supports S3; CloudWatch requires the standalone `aws_redshift_logging` resource.
- Selective log types (e.g., connection log only): Rejected — spec requires all three types (FR-020).

---

## Decision 3: Subnet CIDR Blocks for Security Group Rules

**Decision**: Use `data "aws_subnets"` (plural) to discover subnet IDs by VPC and tag, then `data "aws_subnet"` (singular) with `for_each` to retrieve individual CIDR blocks.

**Rationale**: The `aws_subnets` data source returns only a list of subnet IDs — there is no `cidr_blocks` attribute available directly. A second pass with the singular `aws_subnet` data source is the documented AWS provider pattern to resolve IDs to CIDR ranges. This approach is fully dynamic and avoids hardcoding any CIDR values.

**Pattern**:
```hcl
data "aws_subnets" "app" {
  filter { name = "vpc-id" values = [local.vpc_id] }
  tags   = { Tier = "App" }
}

data "aws_subnet" "app" {
  for_each = toset(data.aws_subnets.app.ids)
  id       = each.value
}

# In SG ingress rule:
cidr_blocks = [for s in data.aws_subnet.app : s.cidr_block]
```

**Alternatives considered**:
- Hardcoded CIDR ranges per environment in `locals.tf`: Rejected — subnets are discovered dynamically per spec FR-006/FR-007; hardcoding breaks if VPC layout changes.
- Using `data.aws_subnets.cidr_blocks` directly: Rejected — this attribute does not exist on the `aws_subnets` data source.

---

## Decision 4: Master Password Generation and Storage

**Decision**: Generate the master password with `resource "random_password"` and store it via `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version`. The Redshift cluster references the `random_password.result` directly.

**Rationale**: The spec requires the secret to be stored in Secrets Manager with a specific name including the environment identifier (FR-011: `/chedaws-edp/<environment>/redshift/master-password`). The AWS-native `manage_master_password = true` cluster option would store the secret in Secrets Manager automatically but uses an AWS-generated secret name that cannot be customised — it would not satisfy FR-011's naming requirement.

**State exposure caveat**: The `random_password.result` value will be stored in Terraform state. The S3 backend has `encrypt = true`, so the state file is AES-256 encrypted at rest. This is the accepted pattern for this project. Terraform >= 1.11 supports write-only secret attributes (`secret_string_wo`) that avoid state storage, but that version is beyond the `>= 1.5.0` minimum.

**Alternatives considered**:
- `manage_master_password = true`: Rejected — AWS auto-generates the secret name; cannot satisfy FR-011's naming requirement.
- Manual secrets injection at apply time via `-var`: Rejected — would require manual intervention, violating SC-001 (single `terraform apply`, no manual credential handling).
- Terraform >= 1.11 write-only attributes: Rejected — minimum version is 1.5.0; cannot assume 1.11.

---

## Decision 5: TLS Enforcement via Parameter Group

**Decision**: Create `aws_redshift_parameter_group` with `family = "redshift-2.0"` and `parameter { name = "require_ssl" value = "true" }`. Reference this parameter group from the cluster.

**Rationale**: AWS changed the default for `require_ssl` to `true` on January 10, 2025, for new clusters. However, explicitly setting it in a custom parameter group makes the intent declarative and auditable in Terraform — it survives any future AWS default changes and is visible in the plan output. The parameter group family `redshift-2.0` corresponds to Redshift engine version 1.0.x (confusingly named; this is the current standard family).

Note: Changing `require_ssl` on an existing cluster requires a cluster restart during the next maintenance window.

**Alternatives considered**:
- Rely on AWS default (`require_ssl = true` since Jan 2025): Rejected — not declarative; invisible in Terraform plan; vulnerable to future default reversals.
- Network-layer TLS only (via SG): Rejected — TLS is an application-layer protocol; SG operates at L4 and cannot enforce SSL negotiation.

---

## Decision 6: Default Database Name

**Decision**: Use `edp` as the default Redshift database name.

**Rationale**: The spec does not specify a database name. `edp` (Enterprise Data Platform abbreviation) is descriptive, short, valid as a Redshift database name (lowercase alphanumeric), and consistent with the project naming convention.

**Alternatives considered**:
- `dev` / `prod` (match workspace): Rejected — database name is a Redshift attribute, not an environment identifier; mixing the two creates confusion.
- `chedaws_edp`: Rejected — underscores are allowed but dashes are not in Redshift database names; `edp` is simpler.

---

## Decision 7: State Locking — Pre-existing Gap

**Finding**: The existing `providers.tf` S3 backend does not include a `dynamodb_table` attribute. The constitution requires "S3 with versioning and DynamoDB state locking enabled." This is a pre-existing gap, not introduced by this feature.

**Decision for this feature**: Document the gap. Do NOT modify the backend configuration as part of this feature — backend changes affect the entire project and require a separate PR.

---

---

## Decision 8: Service-Specific KMS Key Design

**Decision**: Create three separate environment-scoped KMS CMKs — `aws_kms_key.redshift`, `aws_kms_key.sns`, and `aws_kms_key.cloudwatch_logs` — each with a lean key policy containing only the AWS account root principal (for key management recoverability) and exactly one AWS service principal.

| `module.kms["redshift"]` | `alias/chedaws-edp-redshift-<env>` | `redshift.amazonaws.com` | `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant` |
| `module.kms["sns"]` | `alias/chedaws-edp-sns-<env>` | `sns.amazonaws.com` | `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant` |
| `module.kms["cloudwatch_logs"]` | `alias/chedaws-edp-cloudwatch-<env>` | `logs.<region>.amazonaws.com` | `Encrypt`, `Decrypt`, `ReEncrypt*`, `GenerateDataKey*`, `DescribeKey`, `CreateGrant` |

All three CMKs are provisioned via the `terraform/modules/kms/` module (see Decision 9). Each module invocation creates one `aws_kms_key`, one `aws_kms_alias`, and one `data "aws_iam_policy_document"` internally. Automatic key rotation (`enable_key_rotation = true`) and 30-day deletion window (`deletion_window_in_days = 30`) are applied to all three keys consistently with FR-015.

**Rationale**: Service-specific keys enforce least privilege at the key-policy level. The previous single `aws_kms_key.redshift` policy held both `redshift.amazonaws.com` and `logs.<region>.amazonaws.com` principals, which is over-permissive. Consolidating all key provisioning in `kms.tf` (via the module) makes the platform-wide encryption posture visible at a glance.

**CreateGrant for all services**: `kms:CreateGrant` is hardcoded in the module's action set for all service principals. Redshift requires it to pass the key to its storage layer. SNS and CloudWatch Logs do not strictly require it, but uniform inclusion simplifies the module and avoids subtle bugs when service permissions evolve. The over-permission is bounded to the named service principal on that specific key.

**Alternatives considered**:
- Single key for all services: Rejected — violates service-isolation principle.
- Shared policy template (all service principals on every key): Rejected — over-permissive.
- Separate KMS keys for S3, EBS, RDS, Glue now: Rejected — no consumers; violates constitution v1.1.0.
- Separate action sets per service (CreateGrant only for Redshift): Rejected — adds module complexity; accepted the minor over-permission.

---

## Decision 9: KMS CMK Module Design

**Decision**: Provision all service-specific KMS CMKs via a reusable Terraform module at `terraform/modules/kms/`. Invoke via a single `module "kms"` block in `terraform/kms.tf` using `for_each = local.kms_services`.

**Module interface**:

| Input | Type | Purpose |
|-------|------|---------|
| `service_name` | `string` | Embedded in resource description and alias (`chedaws-edp-<service_name>-<env>`) |
| `service_principal` | `string` | AWS service principal granted KMS actions in the key policy |
| `environment` | `string` | Embedded in alias suffix and description |

| Output | Value |
|--------|-------|
| `key_arn` | `aws_kms_key.this.arn` |
| `key_id` | `aws_kms_key.this.id` |
| `alias_arn` | `aws_kms_alias.this.arn` |

**`local.kms_services` map**:
```hcl
kms_services = {
  redshift        = { service_principal = "redshift.amazonaws.com" }
  sns             = { service_principal = "sns.amazonaws.com" }
  cloudwatch_logs = { service_principal = "logs.${data.aws_region.current.name}.amazonaws.com" }
}
```

**Consumer references**: `module.kms["redshift"].key_arn`, `module.kms["sns"].key_arn`, `module.kms["cloudwatch_logs"].key_arn`.

**Rationale**: Three distinct module invocations satisfy constitution VI (module gate requires ≥ 2 distinct call sites). The module eliminates repetition of the key + alias + policy document triplet pattern. A `README.md` with a "Consumers" section documents all three call sites as required by constitution v1.1.0. Future services (S3, Glue, RDS) will add entries to `local.kms_services`, extending the module without changes to the module itself.

**Alternatives considered**:
- Three separate named module blocks (`module "kms_redshift"`, etc.): Rejected — `for_each` is DRY; separate blocks would require manual duplication of module source/version.
- Inline resources in `kms.tf` (no module): Rejected — three service-specific keys with identical structure satisfy the constitution VI module gate; a module is appropriate and reduces future copy-paste.

---

## Summary Table

| Unknown | Decision | Status |
|---------|----------|--------|
| Node type `rg.xlarge` | `rg.xlarge` (confirmed valid) | Resolved |
| Node type `rg.4xlarge` | `rg.4xlarge` (confirmed valid) | Resolved |
| CloudWatch logging mechanism | `aws_redshift_logging` resource | Resolved |
| Subnet CIDR discovery | `aws_subnet` for_each pattern | Resolved |
| Password + Secrets Manager | `random_password` + `aws_secretsmanager_secret_version` | Resolved |
| TLS enforcement | `aws_redshift_parameter_group` with `require_ssl = true` | Resolved |
| Default database name | `edp` | Resolved |
| State DynamoDB locking | Pre-existing gap — deferred | Noted |
| KMS key design (service-specific) | 3 lean-policy CMKs via `terraform/modules/kms/` | Resolved |
| KMS module design | `for_each = local.kms_services`; module inputs `service_name`, `service_principal`, `environment`; outputs `key_arn`, `key_id`, `alias_arn` | Resolved |
