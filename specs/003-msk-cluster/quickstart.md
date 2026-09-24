# Quickstart & Validation Guide: Amazon MSK Cluster Provisioning

**Feature**: 003-msk-cluster | **Date**: 2026-06-30

---

## Prerequisites

- AWS CLI configured with a profile/role that can assume `chedaws-edp-ci-runner` in each target account
- Terraform >= 1.5.0 installed
- `tflint` available at `auto/tflint`
- Active Terraform workspace for the target environment (see Setup below)
- The spec-001 (Redshift cluster) feature must have been applied to the target environment first — this feature depends on:
  - `aws_sns_topic.alerts` (SNS alert topic per environment)
  - `module.kms["cloudwatch_logs"]` (CloudWatch Logs CMK per environment)

---

## Setup

```powershell
# From repo root
cd terraform

# Initialise (first time or after provider changes)
terraform init

# Select target environment workspace
terraform workspace select dev      # or test, uat, prod
terraform workspace show            # confirm active workspace
```

---

## Validation Scenarios

### Scenario 1 — Deploy MSK Cluster (all environments)

**Run**:

```powershell
terraform workspace select dev
terraform plan -out=plan-dev.tfplan
# Review plan: expect ~10 new resources (security_group, cloudwatch_log_group,
# msk_cluster, appautoscaling_target, appautoscaling_policy, 4× cloudwatch_metric_alarm)
terraform apply plan-dev.tfplan
```

Repeat for `test`, `uat`, `prod`.

**Expected outcomes**:

| Environment | Cluster name | Broker count | Instance type | Storage/broker |
|-------------|-------------|--------------|---------------|---------------|
| dev | `chedaws-edp-msk-dev` | 2 | `kafka.m7g.large` | 100 GiB |
| test | `chedaws-edp-msk-test` | 2 | `kafka.m7g.large` | 100 GiB |
| uat | `chedaws-edp-msk-uat` | 3 | `kafka.m7g.2xlarge` | 500 GiB |
| prod | `chedaws-edp-msk-prod` | 3 | `kafka.m7g.2xlarge` | 500 GiB |

**Verification via AWS CLI**:

```bash
aws kafka list-clusters --query 'ClusterInfoList[?ClusterName==`chedaws-edp-msk-dev`].[ClusterName,NumberOfBrokerNodes,State]' --output table
# Expected: chedaws-edp-msk-dev | 2 | ACTIVE
```

---

### Scenario 2 — Confirm Auto-Scaling Configuration

After applying any environment, verify Application Auto Scaling registration:

```bash
aws application-autoscaling describe-scalable-targets \
  --service-namespace kafka \
  --query 'ScalableTargets[*].[ResourceId,MinCapacity,MaxCapacity]' \
  --output table
```

**Expected for dev/test**: `MaxCapacity = 1024`
**Expected for uat/prod**: `MaxCapacity = 16384`

Verify the scaling policy:

```bash
aws application-autoscaling describe-scaling-policies \
  --service-namespace kafka \
  --query 'ScalingPolicies[*].[PolicyName,PolicyType,TargetTrackingScalingPolicyConfiguration.TargetValue]' \
  --output table
# Expected: target value = 70.0 for each environment
```

---

### Scenario 3 — Confirm MSK IAM Authentication Endpoint

Retrieve bootstrap brokers from Terraform output:

```bash
terraform output msk_bootstrap_brokers_sasl_iam
# Expected: comma-separated host:9098 pairs
```

Verify the endpoint is reachable from an App-tier EC2 instance or Glue job (network connectivity test):

```bash
# From a host in an App-tier subnet (Tier=App):
nc -zv <broker-endpoint> 9098
# Expected: Connection succeeded
```

---

### Scenario 4 — Confirm Security Group Restricts Non-App-Tier Access

From a host in a subnet WITHOUT the `Tier=App` tag:

```bash
nc -zv <broker-endpoint> 9098 -w 5
# Expected: Connection timed out (blocked by security group)
```

---

### Scenario 5 — Confirm CloudWatch Alarms Exist

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "chedaws-edp-msk-" \
  --query 'MetricAlarms[*].[AlarmName,StateValue,Threshold]' \
  --output table
```

**Expected alarms per environment (dev/test — 6 alarms)**:
- `chedaws-edp-msk-under-replicated-dev-1`
- `chedaws-edp-msk-under-replicated-dev-2`
- `chedaws-edp-msk-offline-partitions-dev`
- `chedaws-edp-msk-disk-dev-1`
- `chedaws-edp-msk-disk-dev-2`
- *(no active-controller alarm for dev/test)*

**Expected alarms per environment (uat/prod — 8 alarms)**:
- `chedaws-edp-msk-under-replicated-uat-1`, `-2`, `-3`
- `chedaws-edp-msk-offline-partitions-uat`
- `chedaws-edp-msk-active-controller-uat`
- `chedaws-edp-msk-disk-uat-1`, `-2`, `-3`

Initial state should be `INSUFFICIENT_DATA` (no broker traffic until topics are created).

---

### Scenario 6 — Confirm KMS Encryption

```bash
aws kafka describe-cluster \
  --cluster-arn $(terraform output -raw msk_cluster_arn) \
  --query 'ClusterInfo.EncryptionInfo'
```

**Expected**:
- `EncryptionAtRest.DataVolumeKMSKeyId` = ARN of `module.kms["msk"]` key (not the AWS-managed key)
- `EncryptionInTransit.ClientBroker` = `"TLS"`
- `EncryptionInTransit.InCluster` = `true`

---

### Scenario 7 — Confirm Broker Logs Flowing to CloudWatch

After the cluster reaches `ACTIVE` state, verify the log group exists:

```bash
aws logs describe-log-groups --log-group-name-prefix "/chedaws-edp/msk/" \
  --query 'logGroups[*].[logGroupName,retentionInDays]' --output table
```

**Expected retention periods**: 7 days (dev/test), 30 days (uat/prod).

Within a few minutes of the cluster becoming active, verify that broker log streams appear:

```bash
aws logs describe-log-streams \
  --log-group-name "/chedaws-edp/msk/dev" \
  --order-by LastEventTime --descending \
  --query 'logStreams[0:3].[logStreamName,lastEventTimestamp]' --output table
```

---

### Scenario 8 — Vertical Scaling Test (uat/prod only)

This is a plan-only test to confirm no cluster recreation is triggered:

```powershell
terraform workspace select uat
# Temporarily change msk_instance_type uat = "kafka.m7g.4xlarge" in locals.tf
terraform plan
# Expect: ~ 1 to update in-place (aws_msk_cluster.this)
# Must NOT see: -/+ destroy and then create
# Revert locals.tf after confirming
```

---

## Linting

```powershell
# From repo root
.\auto\tflint
# Expected: 0 warnings, 0 errors
```

---

## Cleanup (dev/test only)

```powershell
terraform workspace select dev
terraform destroy
# Review the destroy plan before confirming
```

**Warning**: Destroying an MSK cluster is irreversible. Any data in topics will be permanently lost. Always confirm the active workspace before running `destroy`.

---

## References

- [data-model.md](../data-model.md) — Entity attributes and locals structure
- [contracts/outputs.md](../contracts/outputs.md) — Terraform output definitions
- [research.md](../research.md) — Technology decisions and rationale
- [spec.md](../spec.md) — Feature specification and acceptance criteria
