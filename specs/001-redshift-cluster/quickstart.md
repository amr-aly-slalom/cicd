# Quickstart Validation Guide: Redshift Cluster Provisioning

**Feature**: 001-redshift-cluster
**Date**: 2026-06-26
**Spec**: [spec.md](spec.md) | **Data Model**: [data-model.md](data-model.md) | **Outputs Contract**: [contracts/outputs.md](contracts/outputs.md)

This guide validates that the Redshift cluster feature works end-to-end for all four environments. It is a verification/run guide — it does not contain implementation code.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Terraform | >= 1.5.0 |
| AWS CLI | >= 2.x, configured with a profile that can assume `chedaws-edp-ci-runner` |
| `tflint` | Available via `auto/tflint` script |
| Workspace | One of: `dev`, `test`, `uat`, `prod` |
| S3 state bucket | `chedaws-prod-terraform-state-file` (must exist) |
| VPC + tagged subnets | Target VPC must have subnets tagged `Tier=App` and `Tier=Db` |

---

## Validation Scenarios

### Scenario 1 — Lint and plan pass for all workspaces

**Purpose**: Validates FR-001 (workspace-driven), FR-002 (cluster name), FR-004 (node type).

**Steps**:
```bash
# From repo root
./auto/tflint

cd terraform
terraform init

for env in dev test uat prod; do
  terraform workspace select $env
  terraform plan -out=plan-$env.tfplan
done
```

**Expected outcomes**:
- `tflint` exits 0 with no unresolved warnings
- `dev` and `test` plans show `node_type = "rg.xlarge"`, cluster named `chedaws-edp-dev` / `chedaws-edp-test`
- `uat` and `prod` plans show `node_type = "rg.4xlarge"`, cluster named `chedaws-edp-uat` / `chedaws-edp-prod`
- All four plans show `encrypted = true`, `publicly_accessible = false`, `number_of_nodes = 2`
- Each plan includes: 1× `module "kms"` block with 3 instances (Redshift, SNS, CloudWatch Logs — each creating 1 KMS key + 1 KMS alias), 1× parameter group, 1× subnet group, 1× security group, 1× cluster, 1× logging resource, 1× Secrets Manager secret, 1× SNS topic, 1× CloudWatch log group, 3× CloudWatch alarms

---

### Scenario 2 — `dev` workspace apply and cluster verification

**Purpose**: Validates FR-002 through FR-021 end-to-end for the `dev` environment.

**Steps**:
```bash
cd terraform
terraform workspace select dev
terraform apply plan-dev.tfplan
```

**Expected outcomes**:
- Apply succeeds with no errors
- `terraform output redshift_cluster_endpoint` returns a DNS name
- `terraform output redshift_cluster_identifier` returns `chedaws-edp-dev`
- `terraform output redshift_master_secret_arn` returns an ARN of the form `arn:aws:secretsmanager:ap-southeast-2:381491832813:secret:/chedaws-edp/dev/redshift/master-password-*`

---

### Scenario 3 — Secrets Manager password retrieval

**Purpose**: Validates FR-010, FR-011, SC-003, SC-006.

**Steps**:
```bash
aws secretsmanager get-secret-value \
  --secret-id /chedaws-edp/dev/redshift/master-password \
  --region ap-southeast-2 \
  --query SecretString \
  --output text
```

**Expected outcomes**:
- Command returns the master password within 60 seconds of apply completion
- No password value appears in any `.tf` file or Terraform plan output
- The secret name contains the environment identifier `dev`

---

### Scenario 4 — TLS enforcement and connectivity

**Purpose**: Validates FR-012, FR-013, FR-021, SC-004, SC-009.

**Steps** (run from an EC2 instance or AWS Cloud9 in the `dev` VPC):
```bash
# Should SUCCEED (from App or DB tier subnet)
psql "host=<cluster-endpoint> port=5439 dbname=edp user=edpadmin sslmode=require" \
  -c "SELECT 1;"

# Should FAIL (non-SSL connection rejected by parameter group require_ssl=true)
psql "host=<cluster-endpoint> port=5439 dbname=edp user=edpadmin sslmode=disable" \
  -c "SELECT 1;"
```

**Expected outcomes**:
- SSL connection (`sslmode=require`) from an App-tier or DB-tier subnet host succeeds
- Non-SSL connection (`sslmode=disable`) is rejected with an SSL error
- A connection attempt from a subnet with neither `Tier=App` nor `Tier=Db` tag times out (security group denies)

---

### Scenario 5 — CloudWatch Log Group and audit logging

**Purpose**: Validates FR-019, FR-020, SC-008, SC-009.

**Steps**:
```bash
# Verify log group exists with correct retention
aws logs describe-log-groups \
  --log-group-name-prefix /chedaws-edp/redshift/dev \
  --region ap-southeast-2 \
  --query 'logGroups[].{name:logGroupName,retention:retentionInDays}'

# Verify log streams appear after a connection is made
aws logs describe-log-streams \
  --log-group-name /chedaws-edp/redshift/dev \
  --region ap-southeast-2
```

**Expected outcomes**:
- Log group `/chedaws-edp/redshift/dev` exists with `retentionInDays = 7`
- After a successful connection, log streams for `connectionlog`, `userlog`, and `useractivitylog` appear

---

### Scenario 6 — CloudWatch alarms active

**Purpose**: Validates FR-019, SC-008.

**Steps**:
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix chedaws-edp-redshift \
  --region ap-southeast-2 \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,actions:AlarmActions}'
```

**Expected outcomes**:
- Three alarms are listed: CPU, disk space, connections — all with prefix `chedaws-edp-redshift-*-dev`
- Each alarm's `AlarmActions` contains the ARN of `chedaws-edp-alerts-dev` SNS topic
- Alarm state is `OK` or `INSUFFICIENT_DATA` (not `ALARM`) immediately after provisioning

---

### Scenario 7 — Multi-environment name isolation (`dev` + `test` in same account)

**Purpose**: Validates FR-017, SC-002 — no resource name conflicts.

**Steps**:
```bash
cd terraform
terraform workspace select test
terraform apply -auto-approve   # apply test environment

# List all Redshift clusters in the shared account
aws redshift describe-clusters \
  --region ap-southeast-2 \
  --query 'Clusters[].ClusterIdentifier'
```

**Expected outcomes**:
- Both `chedaws-edp-dev` and `chedaws-edp-test` appear in the cluster list
- No `ResourceAlreadyExistsException` errors during apply
- All associated resources (SG, Redshift KMS key, SNS KMS key, CloudWatch Logs KMS key, SNS topic, log group, parameter group) are suffixed with `-dev` or `-test` respectively; all three KMS keys are provisioned via `module.kms` with the environment embedded in each alias

---

## Cleanup

```bash
cd terraform
for env in dev test; do
  terraform workspace select $env
  terraform destroy -auto-approve
done
```

**Note**: `uat` and `prod` have `skip_final_snapshot = false`, so a final snapshot named `chedaws-edp-<environment>-final-snapshot` will be created automatically on destroy — verify and delete this manually if needed.
