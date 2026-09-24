# Data Model: Multi-Environment S3 Bucket Provisioning

## Core Entities

### Environment
- Represents one of the target deployment contexts: `dev`, `test`, `uat`, or `prod`.
- Provides the naming and tagging context used for the deployed bucket.

### S3 Bucket
- Represents the storage resource created for each environment.
- Stores the bucket configuration for encryption, access control, lifecycle, versioning, and public access restrictions.

### Access Policy
- Represents the baseline access model applied to the bucket.
- Restricts access to approved principals and private connectivity paths while denying public access.

### Smoke Test
- Represents the validation routine used to confirm that the provisioned bucket meets the required controls.
- Produces a pass/fail signal for deployment acceptance.

## Relationships

- One Environment maps to one S3 Bucket.
- One S3 Bucket applies one baseline Access Policy.
- One S3 Bucket is validated by one or more Smoke Tests.
