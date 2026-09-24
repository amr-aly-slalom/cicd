# S3 Producer Registrations

This directory contains YAML registration files that declare S3 data producers and their datasets. Terraform reads these files to provision IAM roles and Glue catalog resources automatically.

Two document kinds are supported: `Namespace` and `Table`.

---

## Directory layout

```
s3/
  <namespace>.yaml          # Namespace — one per namespace
  <namespace>/
    <name>.yaml         # Table — one per table
  schema/
    namespace-schema.json       # JSON Schema for Namespace
    table-schema.json      # JSON Schema for Table
```

The file stem must match `metadata.name` (for both namespace files and table files). The CI validation script enforces this.

---

## Namespace

Declares a data namespace and provisions an IAM role (`edp-<env>-s3-producer-<namespace>`) with `s3:PutObject` access scoped to `<namespace>/*` in the EDP landing bucket.

### Full example

```yaml
apiVersion: s3.chedaws.io/v1
kind: Namespace
metadata:
  name: finance                    # required — lowercase, hyphens allowed, matches file stem
  owner: finance-platform-team     # required — team slug
  description: Financial data namespace for core banking extracts   # optional
spec:
  producer:
    environments:                  # required — at least one environment
      dev:
        iamRoles:                  # cross-account IAM roles that assume the EDP role
          - arn:aws:iam::111122223333:role/finance-data-exporter
      test:
        iamRoles:
          - arn:aws:iam::111122223333:role/finance-data-exporter
      uat:
        iamRoles:
          - arn:aws:iam::444455556666:role/finance-data-exporter-uat
      prod:
        iamRoles:
          - arn:aws:iam::444455556666:role/finance-data-exporter-prod
```

### On-premises producer (IAM Roles Anywhere)

Use `certificateSubject` instead of `iamRoles`. Exactly one of the two must be present per environment.

```yaml
spec:
  producer:
    environments:
      dev:
        certificateSubject:
          - "CN=ONPREM-SERVER-01"
```

### Field reference

| Field | Required | Description |
|---|---|---|
| `apiVersion` | yes | Must be `s3.chedaws.io/v1` |
| `kind` | yes | Must be `Namespace` |
| `metadata.name` | yes | Lowercase, hyphens allowed (`^[a-z][a-z0-9-]*$`). Determines the IAM role name and S3 prefix. Hyphens are normalised to underscores in Glue database names. |
| `metadata.owner` | yes | Team slug responsible for this namespace |
| `metadata.description` | no | Human-readable description |
| `spec.producer.environments` | yes | Map of environment keys (`dev`, `test`, `uat`, `prod`) to producer identity. At least one environment required. |
| `spec.producer.environments.<env>.iamRoles` | one of | ARN list of IAM roles in the producer's account. Pattern: `arn:aws:iam::<12-digit-account>:role/<name>` |
| `spec.producer.environments.<env>.certificateSubject` | one of | Certificate CN list for IAM Roles Anywhere. Pattern: `CN=<value>` |

### What gets provisioned

- `aws_iam_role` named `edp-<env>-s3-producer-<namespace>` in the EDP account for each declared environment
- `aws_iam_policy` granting:
  - `s3:PutObject`, `s3:PutObjectTagging`, `s3:GetObject` on `<namespace>/*`
  - `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` on `athena-query-results/<namespace>/*` (Athena query results)
  - `kms:GenerateDataKey`, `kms:Decrypt` on the landing bucket KMS key
  - `athena:StartQueryExecution`, `athena:GetQueryExecution`, `athena:GetQueryResults`, `athena:StopQueryExecution`
  - `glue:GetDatabase`, `glue:GetTable`, `glue:GetTables`, `glue:GetPartition`, `glue:GetPartitions` scoped to `edp_<env>_<namespace>`
- Trust policy allows `sts:AssumeRole` from the declared `iamRoles` or `certificateSubject` principals

---

## Table

Declares a dataset within a namespace. Optionally provisions a table-scoped IAM role (narrower than the namespace role) and/or a Glue catalog table (making the dataset queryable via Athena).

### Minimal example (format only)

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: finance
  name: transactions          # lowercase, underscores only, matches file stem
  owner: finance-platform-team
spec:
  format: csv                      # csv | json | avro
```

No Glue table or table-scoped IAM role is provisioned. The namespace role (`edp-<env>-s3-producer-finance`) already grants write access to `finance/transactions/*`.

### With Glue schema (queryable via Athena)

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: risk
  name: credit_scores
  owner: risk-analytics-team
  description: Daily credit score snapshots
spec:
  format: json
  schema:
    columns:
      - name: customer_id
        type: string
        comment: Unique customer identifier    # optional
      - name: score
        type: int
        comment: Credit score 0-999
      - name: score_date
        type: date
      - name: year
        type: string
      - name: month
        type: string
    partitionKeys:                 # optional — must be a subset of column names
      - year
      - month
```

Provisioned: Glue database `edp_<env>_risk` (if not already present) and Glue table `credit_scores` with the appropriate SerDe for the declared format.

### With optional table-scoped IAM role

```yaml
spec:
  format: csv
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::111122223333:role/finance-transactions-writer
```

Provisioned: `aws_iam_role` named `edp-<env>-s3-producer-<namespace>-<name>` with `s3:PutObject`/`s3:GetObject` scoped to `<namespace>/<name>/*`, Athena query execution, Glue read on the table, and S3 read/write on `athena-query-results/<namespace>/<name>/*`. Use this when a service needs narrower access than the namespace role provides.

### Decommissioning a table (two-phase)

```yaml
spec:
  decommission: true
```

Set this flag and merge first. Terraform destroys the table-scoped IAM role (if any) and Glue resources. Then open a second PR that deletes the YAML file - a convention for a clean, reviewable destroy plan, not something CI enforces: deleting the YAML directly destroys the same resources on the next apply either way.

The namespace YAML (`s3/<namespace>.yaml`) works the same way - deleting it directly destroys the namespace IAM role on apply.

### Field reference

| Field | Required | Description |
|---|---|---|
| `apiVersion` | yes | Must be `s3.chedaws.io/v1` |
| `kind` | yes | Must be `Table` |
| `metadata.namespace` | yes | Must match the parent directory name under `s3/` |
| `metadata.name` | yes | Lowercase, underscores only (`^[a-z][a-z0-9_]*$`). Matches the file stem. Used as-is for the Glue table name and S3 prefix. |
| `metadata.owner` | yes | Team slug responsible for this dataset |
| `metadata.description` | no | Human-readable description |
| `spec.format` | yes | `csv`, `json`, or `avro`. Determines the Glue SerDe when a schema is also declared. |
| `spec.schema.columns` | no | Ordered column definitions. When present, triggers Glue database + table provisioning. |
| `spec.schema.columns[].name` | yes | Snake_case, lowercase (`^[a-z][a-z0-9_]*$`) |
| `spec.schema.columns[].type` | yes | One of: `string`, `int`, `bigint`, `double`, `boolean`, `timestamp`, `date` |
| `spec.schema.columns[].comment` | no | Column description shown in Glue and Athena |
| `spec.schema.partitionKeys` | no | Column names to use as Hive partition keys. Must be a subset of declared column names. |
| `spec.producer` | no | Same structure as `Namespace.spec.producer`. Provisions a narrower table-scoped IAM role. |
| `spec.decommission` | no | Set `true` to destroy table-level resources on next apply. Required before deleting the YAML file. |

### Glue SerDe by format

| `spec.format` | Glue SerDe | S3 object expectations |
|---|---|---|
| `csv` | `org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe` | Comma-delimited, UTF-8, no quoting required |
| `json` | `org.openx.data.jsonserde.JsonSerDe` | Newline-delimited JSON (one JSON object per line) |
| `avro` | `org.apache.hadoop.hive.serde2.avro.AvroSerDe` | Binary Avro with embedded schema |

---

## Finding Your Provisioned Resources

After your PR is merged and `terraform apply` completes, use the formulas below to locate every resource from your registration inputs.

### Resource naming formulas

All names are deterministic. Replace `<env>` with `dev`, `test`, `uat`, or `prod`.

| Resource | Name formula | Example (namespace `finance`, env `dev`) |
|---|---|---|
| Namespace IAM role | `edp-<env>-s3-producer-<namespace>` | `edp-dev-s3-producer-finance` |
| IAM policy | `edp-<env>-s3-producer-<namespace>` | `edp-dev-s3-producer-finance` |
| Table IAM role | `edp-<env>-s3-producer-<namespace>-<table>` | `edp-dev-s3-producer-finance-transactions` |
| Glue database | `edp_<env>_<namespace>` (hyphens → underscores) | `edp_dev_finance` |
| Glue table | `<table>` as declared in `metadata.name` | `transactions` |
| S3 prefix | `s3://chedaws-edp-landing-bucket-<env>/<namespace>/<table>/` | `s3://chedaws-edp-landing-bucket-dev/finance/transactions/` |
| Athena workgroup | `edp-<env>-<namespace>` | `edp-dev-finance` |
| Athena results prefix | `s3://chedaws-edp-landing-bucket-<env>/athena-query-results/<namespace>/` | `s3://chedaws-edp-landing-bucket-dev/athena-query-results/finance/` |

### Look up outputs with Terraform

```bash
cd terraform

# All S3 producer role ARNs (namespace + table roles) for this environment -
# S3 producer onboarding lives in its own stack and state (terraform/s3/),
# which has its own workspace selection
terraform -chdir=s3 workspace select <env>
terraform -chdir=s3 output s3_producer_role_arns

# IAM Roles Anywhere profile ARN (on-prem workloads) - the profile is shared
# with Kafka's on-prem roles and lives in the kafka stack's own state
terraform -chdir=kafka workspace select <env>
terraform -chdir=kafka output rolesanywhere_profile_arn
```

### Find resources in the AWS Console

**IAM role** — navigate to IAM → Roles → search for `edp-<env>-s3-producer-<namespace>`.

**Glue database and tables** — navigate to Glue → Databases → filter by `edp_<env>_<namespace>`. Tables appear under the database.

**S3 location** — navigate to S3 → `chedaws-edp-landing-bucket-<env>` → browse to `<namespace>/<table>/`.

**Athena workgroup** — navigate to Athena → Workgroups → `edp-<env>-<namespace>`. Query results are written to `athena-query-results/<namespace>/` in the same bucket.

### Verify a table is queryable

After your first data upload, run the following in the Athena console (select workgroup `edp-<env>-<namespace>`):

```sql
SELECT * FROM "edp_<env>_<namespace>"."<table>" LIMIT 10;
```

If the Glue table has partition keys, run `MSCK REPAIR TABLE "edp_<env>_<namespace>"."<table>"` first to register the partitions.

---

## Validation

The CI pipeline runs `python .github/scripts/validate-s3-registrations.py` on every PR. It checks:

- All YAML files conform to their respective JSON schemas
- No duplicate `name` values across namespace files
- No duplicate `(namespace, name)` pairs across table files
- File stem matches `metadata.name` (namespace files) or `metadata.name` (table files)
- Table files reside under the correct namespace directory
- Deleted table files had `spec.decommission: true` in the previous commit

Run it locally before pushing:

```bash
python .github/scripts/validate-s3-registrations.py
```

Expected output: `All registrations valid. No duplicates detected.`
