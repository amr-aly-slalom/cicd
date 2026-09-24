# Implementation Plan: Redshift Cluster Provisioning

**Branch**: `feat/redshift-cluster` | **Date**: 2026-06-29 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/001-redshift-cluster/spec.md`

## Summary

Provision an Amazon Redshift cluster per Terraform workspace environment (`dev`, `test`, `uat`, `prod`). Each cluster has 2 nodes (`rg.xlarge` for dev/test, `rg.4xlarge` for uat/prod), is placed in the environment's VPC using dynamically discovered App- and DB-tier subnets, and has its master password stored in Secrets Manager under `/chedaws-edp/<environment>/redshift/master-password`. Three service-specific KMS CMKs (Redshift, SNS, CloudWatch Logs) are provisioned via a reusable `terraform/modules/kms/` module, invoked from `kms.tf` as a single `module "kms"` block with `for_each = local.kms_services`. TLS is enforced via a custom parameter group. All three Redshift audit log types are exported to a KMS-encrypted CloudWatch Log Group with environment-tiered retention. Three CloudWatch metric alarms (CPU, disk, connections) publish to a shared per-environment SNS topic encrypted with its own KMS CMK. All Redshift resources are inline in the `terraform/` root; only the KMS CMK pattern is extracted into a module (3 distinct call sites satisfy constitution v1.1.0 VI). Resources exclusively dedicated to Redshift are co-located in `redshift.tf`; `kms.tf` holds the `module "kms"` invocation; `sns.tf` holds the SNS topic (intended for reuse by future EDP features).

## Technical Context

**Language/Version**: Terraform >= 1.5.0, HCL

**Primary Dependencies**:
- `hashicorp/aws ~> 6.0` — core provider; `aws_redshift_cluster`, `aws_redshift_logging`, `aws_redshift_parameter_group`, `aws_redshift_subnet_group`, `aws_security_group`, `aws_kms_key` (×3, module-internal), `aws_kms_alias` (×3, module-internal), `aws_secretsmanager_secret`, `aws_cloudwatch_log_group`, `aws_cloudwatch_metric_alarm`, `aws_sns_topic`, `aws_subnets`, `aws_subnet`
- `hashicorp/random ~> 3.0` — `random_password` for master password generation

**Storage**: Terraform state in S3 (`chedaws-prod-terraform-state-file`), AES-256 encrypted. DynamoDB state locking not configured (pre-existing gap — not in scope).

**Testing**: `tflint` via `auto/tflint`; `terraform plan` for all four workspaces.

**Target Platform**: AWS ap-southeast-2; 4 Terraform workspaces (`dev`, `test`, `uat`, `prod`). Dev and test share AWS account `381491832813`.

**Project Type**: IaC — inline resources in `terraform/` root.

**Performance Goals**: N/A — cluster sizing is fixed per spec.

**Constraints**:
- 2 nodes per cluster; `rg.xlarge` (dev/test) / `rg.4xlarge` (uat/prod)
- Inline resources — no Terraform module created
- `publicly_accessible = false`; single-AZ (multi-AZ deferred)
- Enhanced VPC routing enabled (required for CloudWatch audit log delivery)
- RG node types (`rg.xlarge`/`rg.4xlarge`) confirmed valid per AWS documentation (see [research.md](research.md))
- File co-location: `kms.tf` invokes `module "kms"` with `for_each = local.kms_services` (all KMS logic encapsulated in `terraform/modules/kms/`); all Redshift-dedicated resources (Secrets Manager, Security Group, CloudWatch log group and alarms, cluster resources) in `redshift.tf`; `sns.tf` separate (reusable by future EDP features); `data.tf`/`locals.tf`/`outputs.tf` follow Terraform convention

**Scale/Scope**: 4 environments × 1 cluster = 4 cluster deployments; ~21 new AWS resources per workspace (3 KMS keys provisioned via module).

## Constitution Check

*GATE: Evaluated pre-design and re-evaluated post-design. All items pass.*

- [x] **Security**: Three service-specific KMS CMKs in `kms.tf` — each with a lean key policy (root IAM + exactly one AWS service principal) — encrypt the cluster, Secrets Manager secret, SNS topic, and CloudWatch log group at rest. No secrets hardcoded — `random_password` result passed to cluster and stored in Secrets Manager. Security Group restricts TCP/5439 to App-tier and DB-tier CIDRs only. TLS enforced via custom parameter group (`require_ssl = true`). IAM access via existing `chedaws-edp-ci-runner` role.
- [x] **Observability**: CloudWatch Log Group at `/chedaws-edp/redshift/<environment>` with all three audit log types. Three metric alarms (CPU, disk, connections) linked to SNS topic. Follows naming convention. Constitution II’s “cloudwatch module” requirement is satisfied inline per constitution VI (single consumer — no module created, v1.1.0).
- [x] **Durability**: Automated snapshots enabled — 1 day (dev/test), 7 days (uat/prod). Final snapshot on destroy for uat/prod. **Pre-existing gap**: DynamoDB state locking not configured in backend (not introduced by this feature; tracked separately).
- [x] **Fault-Tolerance**: No ECS, MWAA, Glue, or DMS resources in this feature. Redshift single-AZ is explicitly accepted by the team (clarification 2026-06-26); multi-AZ deferred to a future requirement.
- [x] **Cost Optimisation**: Dev/test use `rg.xlarge` (4 vCPU, 32 GiB); uat/prod use `rg.4xlarge` (16 vCPU, 128 GiB). CloudWatch log retention tiered (7/30/90 days). All cost allocation tags applied via provider `default_tags`.
- [x] **DRY & Modularity**: Three service-specific KMS CMKs are provisioned via `terraform/modules/kms/` — a reusable module with inputs `service_name`, `service_principal`, `environment` and outputs `key_arn`, `key_id`, `alias_arn`. Invoked from `kms.tf` as a single `module "kms"` block with `for_each = local.kms_services` over the three service keys (`"redshift"`, `"sns"`, `"cloudwatch_logs"`). The module's `README.md` MUST include a "Consumers" section documenting all three call sites — satisfying the constitution VI reusability plan requirement. All other resources (Redshift cluster and its dedicated co-located resources in `redshift.tf`; SNS topic in `sns.tf`) remain inline (single consumer — no second call site justifying an additional module). No edits to `terraform-legacy/`.

## Project Structure

### Documentation (this feature)

```text
specs/001-redshift-cluster/
├── plan.md              ← this file
├── research.md          ← Phase 0: node types, logging, CIDR, password, TLS, KMS module design
├── data-model.md        ← Phase 1: all entities, attributes, relationships
├── quickstart.md        ← Phase 1: 7 validation scenarios
├── contracts/
│   └── outputs.md       ← Phase 1: 10 Terraform outputs contract
└── tasks.md             ← Phase 2 (updated 2026-06-29): tasks; T001–T020 complete, T021–T031 remaining
```

### Source Code (`terraform/`)

```text
terraform/
├── data.tf              # MODIFY: add aws_subnets.app, aws_subnets.db,
│                        #         aws_subnet.app (for_each), aws_subnet.db (for_each)
├── locals.tf            # MODIFY: add redshift_node_type, redshift_snapshot_retention,
│                        #         redshift_skip_final_snapshot, redshift_log_retention,
│                        #         redshift_connection_alarm_threshold,
│                        #         kms_services (map of service_principal per service key)
├── outputs.tf           # MODIFY: add 10 outputs (8 Redshift + 2 KMS ARNs)
├── providers.tf         # UNCHANGED
├── variables.tf         # UNCHANGED
│
├── kms.tf               # NEW: module "kms" { for_each = local.kms_services
│                        #       source = "./modules/kms"
│                        #       for each: service_name, service_principal, environment }
│                        # (all KMS key/alias/policy logic encapsulated in modules/kms/)
│
├── redshift.tf          # NEW: random_password.redshift,
│                        #      aws_secretsmanager_secret.redshift_password,
│                        #      aws_secretsmanager_secret_version.redshift_password,
│                        #      aws_redshift_parameter_group, aws_redshift_subnet_group,
│                        #      aws_security_group.redshift,
│                        #      aws_cloudwatch_log_group.redshift
│                        #        (kms_key_id = module.kms["cloudwatch_logs"].key_arn),
│                        #      aws_cloudwatch_metric_alarm.redshift_{cpu,disk,connections},
│                        #      aws_redshift_cluster
│                        #        (kms_key_id = module.kms["redshift"].key_arn),
│                        #      aws_redshift_logging
├── sns.tf               # NEW: aws_sns_topic.alerts
│                        #        (kms_master_key_id = module.kms["sns"].key_arn)
│
└── modules/
    └── kms/             # NEW: reusable KMS CMK module
        ├── main.tf      #   aws_kms_key.this, aws_kms_alias.this,
        │                #   data.aws_iam_policy_document.this (lean policy)
        ├── variables.tf #   service_name (string), service_principal (string),
        │                #   environment (string)
        ├── outputs.tf   #   key_arn, key_id, alias_arn
        └── README.md    #   MUST include "Consumers" section (constitution VI)
```
**Structure Decision**: `terraform/modules/kms/` module created per clarification session 2026-06-29: (1) `kms.tf` — invokes `module "kms"` with `for_each = local.kms_services`; all KMS key/alias/policy logic encapsulated in `terraform/modules/kms/`; the platform-wide encryption posture remains visible at a glance in `kms.tf`; (2) `redshift.tf` — all resources exclusively dedicated to the Redshift feature: Secrets Manager (`random_password.redshift`, `aws_secretsmanager_secret.redshift_password`, `aws_secretsmanager_secret_version.redshift_password`), Security Group (`aws_security_group.redshift`), CloudWatch (`aws_cloudwatch_log_group.redshift` with `kms_key_id = module.kms["cloudwatch_logs"].key_arn`, three metric alarms), and the cluster resources (`aws_redshift_parameter_group`, `aws_redshift_subnet_group`, `aws_redshift_cluster`, `aws_redshift_logging`); (3) `sns.tf` — the SNS alert topic with `kms_master_key_id = module.kms["sns"].key_arn`, in a separate file because it is intended for reuse by future EDP features. The `kms_services` local map drives `for_each` and is defined in `locals.tf`. Conventional files (`data.tf`, `locals.tf`, `outputs.tf`) retain `aws_subnets`/`aws_subnet` data source blocks, local values, and outputs respectively.

### Key Locals to Add (`terraform/locals.tf`)

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

redshift_log_retention = {
  dev  = 7
  test = 7
  uat  = 30
  prod = 90
}[local.environment]

redshift_connection_alarm_threshold = {
  dev  = 450
  test = 450
  uat  = 900
  prod = 900
}[local.environment]

kms_services = {
  redshift = {
    service_principal = "redshift.amazonaws.com"
  }
  sns = {
    service_principal = "sns.amazonaws.com"
  }
  cloudwatch_logs = {
    service_principal = "logs.${data.aws_region.current.name}.amazonaws.com"
  }
}
```

### Resource Naming Convention

All resource names include `local.environment` as suffix. Pattern: `chedaws-edp-<component>-<environment>`.

| Resource | Name |
|----------|------|
| KMS key alias – Redshift | `alias/chedaws-edp-redshift-<environment>` |
| KMS key alias – SNS | `alias/chedaws-edp-sns-<environment>` |
| KMS key alias – CloudWatch Logs | `alias/chedaws-edp-cloudwatch-<environment>` |
| Secrets Manager secret | `/chedaws-edp/<environment>/redshift/master-password` |
| Parameter group | `chedaws-edp-redshift-params-<environment>` |
| Subnet group | `chedaws-edp-redshift-subnet-group-<environment>` |
| Security group | `chedaws-edp-redshift-sg-<environment>` |
| Redshift cluster | `chedaws-edp-<environment>` |
| CloudWatch log group | `/chedaws-edp/redshift/<environment>` |
| SNS topic | `chedaws-edp-alerts-<environment>` |
| CloudWatch alarms | `chedaws-edp-redshift-{cpu,disk,connections}-<environment>` |

### Resource Creation Order

```
1.  random_password.redshift          (no deps)
2.  module.kms["redshift"]            (no deps — creates aws_kms_key + aws_kms_alias + policy doc internally)
3.  module.kms["sns"]                 (no deps)
4.  module.kms["cloudwatch_logs"]     (no deps)
5.  data.aws_subnets.{app,db}         (data sources — no deps)
6.  data.aws_subnet.{app,db}          ← data.aws_subnets.{app,db}
7.  aws_secretsmanager_secret         ← module.kms["redshift"].key_arn
8.  aws_secretsmanager_secret_version ← aws_secretsmanager_secret, random_password
9.  aws_redshift_parameter_group      (no deps)
10. aws_redshift_subnet_group         ← data.aws_subnets.{app,db}
11. aws_security_group.redshift       ← data.aws_subnet.{app,db}
12. aws_cloudwatch_log_group.redshift ← module.kms["cloudwatch_logs"].key_arn
13. aws_sns_topic.alerts              ← module.kms["sns"].key_arn
14. aws_cloudwatch_metric_alarm.×3    ← aws_sns_topic.alerts
15. aws_redshift_cluster              ← items 2, 7, 9, 10, 11 + random_password
16. aws_redshift_logging              ← aws_redshift_cluster + aws_cloudwatch_log_group
```

## Complexity Tracking

> No constitution violations requiring justification. No complexity entries needed.
