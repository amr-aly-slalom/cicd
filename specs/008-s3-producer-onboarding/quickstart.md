# Quickstart: S3 Data Producer Self-Onboarding

**Feature**: `specs/008-s3-producer-onboarding`
**Branch**: `feat/s3-glue`

---

## Prerequisites

- AWS CLI configured with `InfraBuildRole` credentials for the target environment
- Terraform >= 1.0 with workspace set (`terraform workspace select dev`)
- Python 3.x available for CI validation scripts
- `tflint` installed and configured (`auto/tflint`)
- Access to the GitHub repository with PR creation permissions

---

## Scenario 1: Register a New Namespace and Dataset (CSV, no schema)

**Goal**: Provision namespace-level write access for a cross-account producer to `s3://chedaws-edp-landing-bucket-dev/finance/`. The IAM role `edp-dev-s3-producer-finance` grants write access to any prefix under `finance/*`.

### Step 1 — Create the namespace registration file

```
s3/finance.yaml
```

```yaml
apiVersion: s3.chedaws.io/v1
kind: Namespace
metadata:
  name: finance
  owner: finance-platform-team
  description: Financial data namespace for core banking extracts
spec:
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::111122223333:role/finance-data-exporter
      test:
        iamRoles:
          - arn:aws:iam::111122223333:role/finance-data-exporter
```

### Step 2 — Create the dataset registration file

```
s3/finance/transactions.yaml
```

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: finance
  name: transactions
  owner: finance-platform-team
  description: Daily transaction extracts from core banking system
spec:
  format: csv
```

### Step 3 — Validate locally

```bash
python .github/scripts/validate-s3-registrations.py
```

**Expected output**: `All registrations valid. No duplicates detected.`

### Step 4 — Open a PR and merge

The CI pipeline:
1. Runs `validate-s3-registrations.py`
2. Runs `terraform plan -var="env=dev"` and attaches the plan output
3. On merge to `main`: runs `terraform apply -var="env=dev"` automatically

### Step 5 — Verify provisioned resources

```bash
# Verify namespace IAM role exists
aws iam get-role --role-name edp-dev-s3-producer-finance

# Verify policy is attached
aws iam list-attached-role-policies --role-name edp-dev-s3-producer-finance
```

**Expected**: Role `edp-dev-s3-producer-finance` exists with attached policy `edp-dev-s3-producer-finance`.

### Step 6 — Verify write access (assume role from producer account)

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<edp-account-id>:role/edp-dev-s3-producer-finance \
  --role-session-name test-write

# Using assumed credentials:
aws s3 cp test.csv s3://chedaws-edp-landing-bucket-dev/finance/transactions/test.csv \
  --sse aws:kms \
  --sse-kms-key-id alias/chedaws-edp-s3-dev
```

**Expected**: Upload succeeds.

### Step 7 — Verify prefix isolation

```bash
# Attempt write within namespace to a different table prefix — must succeed (namespace role allows finance/*)
aws s3 cp test.csv s3://chedaws-edp-landing-bucket-dev/finance/other_table/test.csv \
  --sse aws:kms \
  --sse-kms-key-id alias/chedaws-edp-s3-dev

# Attempt write to a different namespace — must fail
aws s3 cp test.csv s3://chedaws-edp-landing-bucket-dev/other-namespace/test.csv \
  --sse aws:kms \
  --sse-kms-key-id alias/chedaws-edp-s3-dev
```

**Expected**: Write to `finance/other_table/` succeeds (namespace role scoped to `finance/*`). Write to `other-namespace/` returns `AccessDenied`.

---

## Scenario 2: Register a Structured Dataset with Glue Schema (JSON)

**Goal**: Provision a Glue table for a JSON dataset so it is queryable via Athena. The namespace registration already exists at `s3/risk.yaml`.

### Namespace registration file (if not yet created)

```
s3/risk.yaml
```

```yaml
apiVersion: s3.chedaws.io/v1
kind: Namespace
metadata:
  name: risk
  owner: risk-analytics-team
  description: Risk analytics data namespace
spec:
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::444455556666:role/risk-score-exporter
```

### Dataset registration file

```
s3/risk/credit_scores.yaml
```

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
        comment: Unique customer identifier
      - name: score
        type: int
        comment: Credit score 0-999
      - name: score_date
        type: date
        comment: Date score was calculated
      - name: year
        type: string
      - name: month
        type: string
    partitionKeys:
      - year
      - month
```

### Verify Glue resources after apply

```bash
# Verify Glue database (env-prefixed name)
aws glue get-database --name edp_dev_risk

# Verify Glue table
aws glue get-table --database-name edp_dev_risk --name credit_scores
```

**Expected**: Database `edp_dev_risk` exists; table `credit_scores` exists with JSON SerDe, columns `customer_id`, `score`, `score_date`, partition keys `year`, `month`.

### Verify Athena query (optional)

```sql
-- In Athena, querying the dev catalog:
SELECT * FROM edp_dev_risk.credit_scores LIMIT 10;
```

**Expected**: Query executes without errors. Returns data if objects exist at the prefix.

---

## Scenario 3: Register an On-Premises Producer (Namespace Level)

**Goal**: Provision namespace-level write access for an on-premises server using IAM Roles Anywhere.

### Namespace registration file excerpt

```yaml
spec:
  producer:
    environments:
      dev:
        certificateSubject:
          - "CN=ONPREM-SERVER-01"
```

### Verify IAM Roles Anywhere profile includes the new namespace role

```bash
aws rolesanywhere get-profile --profile-id <profile-id>
```

**Expected**: Profile `role_arns` list includes `arn:aws:iam::<account>:role/edp-dev-s3-producer-<namespace>`.

---

## Scenario 4: Decommission a Dataset

**Goal**: Remove optional table-level IAM role (if any) and Glue resources for a retired dataset. The namespace IAM role is unaffected.

### Phase 1 — Set decommission flag

Edit the table YAML to add:

```yaml
spec:
  decommission: true
```

Open a PR. Terraform plan shows:
- `aws_iam_role.s3_table_aws_producer["<key>"]` — destroy (if table had `spec.producer`)
- `aws_iam_policy.s3_table_producer["<key>"]` — destroy (if table had `spec.producer`)
- `aws_glue_catalog_table.producer_dataset["<key>"]` — destroy (if schema existed)
- `aws_glue_catalog_database.producer_domain["<env>_<namespace>"]` — destroy (if last schema-bearing table in this env/domain)
- `aws_iam_role.s3_domain_aws_producer["<namespace>"]` — no change (namespace role unaffected)

Merge the PR.

### Phase 2 — Delete the YAML file

Open a second PR deleting the table YAML file. CI script verifies that `spec.decommission: true` was present in the previous commit.

**Expected**: CI passes; PR merges cleanly. Terraform state no longer references the dataset.

### Negative test — CI blocks direct file deletion

Open a PR that deletes a table YAML file without having merged `spec.decommission: true` first.

**Expected**: CI validation fails with `DecommissionGuardError: file deleted without decommission flag`.

### Namespace YAML deletion — no guard

Deleting a namespace YAML (`s3/<namespace>.yaml`) requires no prior decommission step. CI does not block the deletion. Terraform destroys the namespace IAM role and policy immediately on apply.

---

## Scenario 5: Duplicate Name Rejected by CI

### Duplicate namespace

Create two namespace files with the same `namespace`:

```
s3/finance.yaml   <- already exists
s3/finance.yaml   <- same path (or different path with same metadata.namespace)
```

**Expected**: `validate-s3-registrations.py` exits non-zero with `DuplicateNamespaceError`.

### Duplicate table

Create two table files with the same `(namespace, name)`:

```
s3/finance/transactions.yaml   <- already exists
s3/finance/transactions.yaml   <- same path, or different path with same metadata
```

**Expected**: `validate-s3-registrations.py` exits non-zero with `DuplicateRegistrationError`.

---

## Scenario 6: Cross-environment database isolation (dev vs test)

Register the same `namespace: finance` namespace in both `dev` and `test` environments (both use account `381491832813`).

```bash
# dev workspace
aws glue get-database --name edp_dev_finance   # <- exists

# test workspace
aws glue get-database --name edp_test_finance  # <- exists, separate database
```

**Expected**: Both databases exist independently. No collision between workspaces sharing the same account.

---

## Scenario 7: Optional Table-Level Role (Narrower Scope)

**Goal**: A team wants an additional, narrower IAM role scoped to a single table prefix (`finance/transactions/*`) for a service that should not be able to write to any other finance table. The namespace role `edp-dev-s3-producer-finance` already exists.

### Table registration file with optional `spec.producer`

```
s3/finance/transactions.yaml
```

```yaml
apiVersion: s3.chedaws.io/v1
kind: Table
metadata:
  namespace: finance
  name: transactions
  owner: finance-platform-team
  description: Daily transaction extracts from core banking system
spec:
  format: csv
  producer:
    environments:
      dev:
        iamRoles:
          - arn:aws:iam::111122223333:role/finance-transactions-writer
```

### Verify provisioned resources

```bash
# Namespace role (unchanged)
aws iam get-role --role-name edp-dev-s3-producer-finance

# Optional table-scoped role (new)
aws iam get-role --role-name edp-dev-s3-producer-finance-transactions

# Verify table role policy scope
aws iam list-attached-role-policies --role-name edp-dev-s3-producer-finance-transactions
```

**Expected**:
- `edp-dev-s3-producer-finance` exists with S3 scope `finance/*`
- `edp-dev-s3-producer-finance-transactions` exists with S3 scope `finance/transactions/*`

### Verify narrower scope of table role

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<edp-account-id>:role/edp-dev-s3-producer-finance-transactions \
  --role-session-name test-narrow

# Using assumed credentials — write to scoped prefix must succeed
aws s3 cp test.csv s3://chedaws-edp-landing-bucket-dev/finance/transactions/test.csv \
  --sse aws:kms \
  --sse-kms-key-id alias/chedaws-edp-s3-dev

# Write to another table prefix must fail
aws s3 cp test.csv s3://chedaws-edp-landing-bucket-dev/finance/other_table/test.csv \
  --sse aws:kms \
  --sse-kms-key-id alias/chedaws-edp-s3-dev
```

**Expected**: Write to `finance/transactions/` succeeds. Write to `finance/other_table/` returns `AccessDenied`.

---

---

## E2E Verifier Scenarios

The following scenarios validate the daily-scheduled Lambda verifier. Run them after `terraform apply` in the target environment with the Lambda ZIP built.

**Prerequisites**:
1. Self-onboarding infrastructure applied (Glue tables and namespace IAM roles exist).
2. `terraform apply -var="env=<env>"` completed successfully.
3. Lambda ZIP built: `pip install -r requirements.txt -t package/ && cd package && zip -r ../function.zip . && cd .. && zip function.zip handler.py`

---

### E2E Scenario 1 — Manual Lambda Invocation (Smoke Test)

**Purpose**: Confirm the full generate → write → query → validate → cleanup cycle succeeds after a fresh `terraform apply`.

```bash
aws lambda invoke \
  --function-name chedaws-edp-s3-e2e-verifier-dev \
  --region ap-southeast-2 \
  --log-type Tail \
  --query 'LogResult' \
  --output text \
  response.json | base64 --decode
```

**Expected outcome**:
- `response.json` contains `null` (Lambda returned successfully).
- Decoded log output contains `"status": "PASS"` with all three tables showing `"outcome": "PASS"`.
- `"cleanup": {"outcome": "SUCCESS"}`.

**Verify via CloudWatch Logs**:
```bash
aws logs tail /chedaws-edp/s3-e2e-verifier/dev \
  --region ap-southeast-2 --since 5m --format short
```

---

### E2E Scenario 2 — Verify Athena Table Queryability (Manual)

**Purpose**: Confirm Glue tables are queryable via Athena workgroup `edp-e2e-dev`.

```bash
aws athena start-query-execution \
  --query-string "SELECT * FROM edp_dev_platform.e2e_csv LIMIT 10" \
  --work-group edp-e2e-dev \
  --region ap-southeast-2
```

**Expected outcome**: Query completes with `SUCCEEDED`. Result file appears at `s3://chedaws-edp-landing-bucket-dev/athena-query-results/e2e/<QueryExecutionId>.csv`.

---

### E2E Scenario 3 — Regression Detection Test

**Purpose**: Confirm that a deliberate SerDe misconfiguration is detected.

1. Temporarily change `s3/platform/e2e_avro.yaml` → set `spec.format: json`.
2. Apply Terraform: `terraform apply -var="env=dev"`.
3. Invoke the Lambda manually (E2E Scenario 1).
4. **Expected**: Log entry contains `"name": "e2e_avro", "outcome": "FAIL"` while `e2e_csv` and `e2e_json` show `"outcome": "PASS"`.
5. Revert the YAML change and re-apply.

---

### E2E Scenario 4 — CloudWatch Alarm State

**Purpose**: Confirm alarms are in `OK` state after a successful run.

```bash
aws cloudwatch describe-alarms \
  --alarm-names \
    chedaws-edp-s3-e2e-validation-failure-dev \
    chedaws-edp-s3-e2e-cleanup-failure-dev \
    chedaws-edp-s3-e2e-lambda-errors-dev \
  --region ap-southeast-2 \
  --query 'MetricAlarms[].{Name:AlarmName, State:StateValue}'
```

**Expected outcome**: All three alarms show `StateValue: OK`.

---

### E2E Scenario 5 — Athena Results Lifecycle Rule

**Purpose**: Confirm the 7-day expiry lifecycle rule is applied.

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket chedaws-edp-landing-bucket-dev \
  --region ap-southeast-2 \
  --query "Rules[?ID=='athena-query-results-e2e-expiry']"
```

**Expected outcome**: Rule returned with `Status: Enabled`, `Filter.Prefix: athena-query-results/e2e/`, `Expiration.Days: 7`.

---

### E2E Scenario 6 — Zero Residual Objects After Successful Run

**Purpose**: Confirm cleanup left no test data in the `platform/` prefix.

```bash
aws s3 ls s3://chedaws-edp-landing-bucket-dev/platform/ --recursive --region ap-southeast-2
```

**Expected outcome**: No output (zero objects).

---

### E2E Terraform Plan Sanity Check

Before applying, review the plan for all four environments:

```bash
terraform plan -var="env=dev"
terraform plan -var="env=test"
terraform plan -var="env=uat"
terraform plan -var="env=prod"
```

**Expected** adds per environment:
- 1 `aws_iam_role` + `aws_iam_role_policy` (Lambda execution role)
- 1 `aws_lambda_function` + `aws_s3_object`
- 1 `aws_cloudwatch_log_group`
- 1 `aws_cloudwatch_event_rule` + `aws_cloudwatch_event_target` + `aws_lambda_permission`
- 1 `aws_athena_workgroup`
- 3 `aws_cloudwatch_metric_alarm`
- 1 lifecycle rule update to `module.landing_s3` (in-place)
- Glue database `edp_<env>_platform` + 3 Glue tables (driven by the new YAML files)
- 1 `aws_iam_role` + `aws_iam_role_policy_attachment` for the namespace IAM role

---

## Drift Detection

Make a manual change to any managed IAM role's trust policy in the AWS Console. Then run:

```bash
terraform plan -var="env=dev"
```

**Expected**: Plan shows a corrective update to restore the declared trust policy. No manual intervention is needed to detect the drift.

---

## Useful Commands

```bash
# Validate all registrations (namespace and table)
python .github/scripts/validate-s3-registrations.py

# Plan for dev
terraform -chdir=terraform plan -var="env=dev"

# Lint
auto/tflint

# List all active S3 namespace producer roles in an environment
aws iam list-roles --query 'Roles[?starts_with(RoleName, `edp-dev-s3-producer-`)].RoleName'

# List all EDP Glue databases for dev
aws glue get-databases --query 'DatabaseList[?starts_with(Name, `edp_dev_`)].Name'
```
