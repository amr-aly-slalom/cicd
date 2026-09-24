# Quickstart: Multi-Environment S3 Bucket Provisioning

## Prerequisites

- Terraform CLI installed
- AWS access configured for the target account role
- Existing workspace names for `dev`, `test`, `uat`, and `prod`

## Deployment Steps

1. Select the target workspace for the environment.
2. Run `terraform init` from the `terraform/` directory.
3. Run `terraform plan -var="aws_region=ap-southeast-2"` to review the bucket changes.
4. Apply the configuration with `terraform apply` once the plan is reviewed.
5. Run the smoke-test validation for the deployed bucket.

## Validation Checklist

- Bucket exists in the intended environment.
- Server-side encryption is enabled.
- Public access is blocked.
- Required tags are present.
- Baseline access policy is applied.
- Smoke tests pass for the environment.
