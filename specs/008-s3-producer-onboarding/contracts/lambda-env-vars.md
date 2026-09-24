# Contract: Lambda Environment Variables

**Component**: `chedaws-edp-s3-e2e-verifier-<env>`  
**Set by**: `aws_lambda_function.s3_e2e_verifier` in `terraform/s3_e2e_verifier.tf`

| Variable | Type | Example (dev) | Description |
|---|---|---|---|
| `ENVIRONMENT` | string | `dev` | Terraform workspace name. Used for structured log output and metric dimensions. |
| `NAMESPACE_ROLE_ARN` | string | `arn:aws:iam::381491832813:role/edp-dev-s3-producer-platform` | ARN of the namespace IAM role to assume for S3 writes. Must be trusted by this role. |
| `LANDING_BUCKET` | string | `chedaws-edp-landing-bucket-dev` | Name of the landing S3 bucket. Write destination and Athena result source. |
| `ATHENA_WORKGROUP` | string | `edp-e2e-dev` | Athena workgroup name. Enforces result location to `athena-query-results/platform/`. |
| `GLUE_DATABASE` | string | `edp_dev_platform` | Fully-qualified Glue database name queried by Athena. |
| `ATHENA_QUERY_TIMEOUT_SECONDS` | string | `30` (dev/test), `90` (uat/prod) | Maximum seconds to poll for each Athena query before treating it as a timeout failure. Sized per environment via `local.is_prod_like ? 90 : 30` to prevent the 120 s dev/test Lambda timeout being exhausted by 3 × 90 s polls. |
