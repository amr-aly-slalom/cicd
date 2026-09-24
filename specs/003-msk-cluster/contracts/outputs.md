# Terraform Outputs Contract: Amazon MSK Cluster Provisioning

**Feature**: 003-msk-cluster | **Date**: 2026-06-30

---

## Overview

These outputs are added to `terraform/outputs.tf`. They expose the MSK cluster bootstrap endpoints and metadata needed by downstream consumers (Glue Streaming jobs, operations tooling, CI pipelines).

---

## Output Definitions

### `msk_cluster_arn`

```hcl
output "msk_cluster_arn" {
  value       = aws_msk_cluster.this.arn
  description = "ARN of the MSK cluster (e.g., used in Glue Streaming connection configuration)"
}
```

**Consumers**: Glue Streaming job network configuration; IAM policy condition keys; cross-feature references.

---

### `msk_cluster_name`

```hcl
output "msk_cluster_name" {
  value       = aws_msk_cluster.this.cluster_name
  description = "Name of the MSK cluster (e.g., chedaws-edp-msk-dev)"
}
```

**Consumers**: CloudWatch dashboard filters; operational runbooks; CI validation scripts.

---

### `msk_bootstrap_brokers_sasl_iam`

```hcl
output "msk_bootstrap_brokers_sasl_iam" {
  value       = aws_msk_cluster.this.bootstrap_brokers_sasl_iam
  description = "Comma-separated IAM-authenticated bootstrap broker endpoints (port 9098). Primary endpoint for AWS Glue Streaming jobs and other IAM-authenticated consumers."
}
```

**Format**: `b-1.chedaws-edp-msk-dev.<uuid>.kafka.ap-southeast-2.amazonaws.com:9098,b-2....`

**Populated when**: `encryption_in_transit.client_broker = "TLS"` AND `client_authentication.sasl.iam = true`.

**Consumers**: AWS Glue Streaming job connection properties (`bootstrapServers`); MSK client configuration.

---

### `msk_bootstrap_brokers_tls`

```hcl
output "msk_bootstrap_brokers_tls" {
  value       = aws_msk_cluster.this.bootstrap_brokers_tls
  description = "Comma-separated TLS bootstrap broker endpoints (port 9094). For use by TLS-only clients that do not use IAM auth (e.g., administrative tooling, Kafka CLI)."
}
```

**Format**: `b-1.chedaws-edp-msk-dev.<uuid>.kafka.ap-southeast-2.amazonaws.com:9094,b-2....`

**Populated when**: `encryption_in_transit.client_broker = "TLS"` or `"TLS_PLAINTEXT"`.

**Note**: Because `client_authentication.sasl.iam = true` is the sole auth mechanism, clients connecting on port 9094 without IAM auth will be rejected by MSK IAM policy. This output is primarily for admin tools that bypass the security group (e.g., MSK CLI from within the VPC).

**Consumers**: Kafka CLI tools; MSK administrative scripts.

---

### `msk_current_version`

```hcl
output "msk_current_version" {
  value       = aws_msk_cluster.this.current_version
  description = "Current MSK cluster version string (e.g., K13V1IB3VIYZZH). Required for in-place cluster updates via the AWS API."
}
```

**Consumers**: Future Terraform updates that modify `kafka_version` or `configuration_info`; operational runbooks for rolling broker upgrades.

---

## Security Note

Bootstrap broker endpoints are VPC-internal DNS names and are not sensitive. They do not contain credentials and are safe to store in Terraform state or expose as CI pipeline outputs. No sensitive values are exposed by these outputs.

---

## Non-Outputs (Deliberately Excluded)

| Value | Reason excluded |
|-------|-----------------|
| `zookeeper_connect_string` | ZooKeeper endpoints are for AWS internal use only in MSK; clients do not use them directly |
| IAM credentials / passwords | MSK IAM auth requires no passwords; no secrets to output |
| KMS key ARN | Accessible via `module.kms["msk"].key_arn` within the same root module; no need to duplicate as output |
