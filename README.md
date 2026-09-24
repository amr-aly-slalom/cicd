# Chedaws TF EDP Infra

Terraform infrastructure as code for deploying and managing AWS cloud resources for the Chedaws Enterprise Data Platform (EDP) workload accounts.

## Overview

This repository provisions data platform infrastructure on AWS using a flat Terraform layout with workspace-based environment selection. Resources are defined directly in the `terraform/` directory and deployed via GitHub Actions CI/CD pipelines.

## Claude Code Authentication

### AWS CLI Authentication for Amazon Bedrock

Add the following configuration in `$HOME/.aws/config`.

```config
[profile bedrock]
region = ap-southeast-2
output = json
ca_bundle = C:\Users\<username>\.aws\corp-ca-bundle.pem # replace
```

- Please `<>` section with appropriate value.
- Copy `./docs/corp-ca-bundle.pem` to `$HOME/aws/`

Add the following configuration in `$HOME/.aws/credentials`.

```config
[bedrock]
aws_access_key_id=
aws_secret_access_key=
aws_session_token=
```

Please get these values from AWS access portal, "Access Keys (Option 2)" next to you sso role that has access to Bedrock.

## Architecture

### Supported Environments

| Environment | AWS Account     | Deployment Trigger         |
|-------------|-----------------|----------------------------|
| dev         | 381491832813    | Push to `main`, `feature/*`, `feat/*` |
| test        | 381491832813    | Push to `main` only        |
| uat         | 339712719726    | Tag `v*` (currently disabled) |
| prod        | 637423180765    | Tag `v*` (currently disabled) |

### Deployed Components

- **Redshift** – Provisioned multi-node cluster with enhanced VPC routing, SSL required, KMS encryption, and CloudWatch logging
- **MSK** – Apache Kafka cluster (`kafka.m7g.large` dev/test, `kafka.m7g.2xlarge` uat/prod) with IAM-only auth, TLS in-transit, KMS encryption, auto-scaling EBS storage, and CloudWatch alarms
- **KMS** – Customer-managed encryption keys for Redshift, SNS, CloudWatch Logs, MSK, Platform S3, S3 Tables, and Glue Data Catalog
- **SNS** – Encrypted alert topic for CloudWatch alarms
- **CloudWatch** – Log group for Redshift audit logs and metric alarms (CPU, disk, connections)
- **IAM Identity Centre** – Redshift IdC application for Trusted Identity Propagation
- **Secrets Manager** – Redshift master password storage
- **Platform S3 Bucket** – Shared, environment-specific S3 bucket encrypted with a dedicated KMS CMK (`alias/chedaws-edp-s3-<env>`), versioned, public access blocked, lifecycle policy (INTELLIGENT_TIERING after 30 days), and bucket policy enforcing KMS-only uploads. Bucket name pattern: `chedaws-edp-platform-<env>-<account-id>-<region>`. Remote state outputs: `platform_s3_bucket_arn`, `platform_s3_bucket_name`, `platform_s3_kms_key_arn`.
- **S3 Tables** – S3 Tables table bucket (`chedaws-edp-table-bucket-<env>`) with KMS encryption via two dedicated service principals (`s3tables.amazonaws.com` and `maintenance.s3tables.amazonaws.com`).
- **Kafka Self-Service Platform** – Git-driven topic and IAM access registration for MSK clusters via YAML pull requests; see [`kafka/README.md`](kafka/README.md). Topic names follow `edp-<env>.<business_name>.<app_name>.<event_name>` and are assembled by Terraform from three fields declared in the producer YAML plus the workspace environment. Producer files live at `kafka/producers/<business_name>/<app_name>.yaml` (one file per app, listing all events); consumer files live at `kafka/consumers/<consumer-slug>.yaml` (flat). Unique-name and IAM role-name length validation are enforced at `terraform plan` time via `terraform_data` preconditions in [`terraform/kafka_topics.tf`](terraform/kafka_topics.tf).
- **S3 Producer Self-Onboarding** – Git-driven IAM access and Glue catalog registration for S3 data producers. Producer teams declare their namespace at `s3/<namespace>.yaml` (provisions `edp-<env>-s3-producer-<namespace>` IAM role scoped to `<namespace>/*` in the landing bucket) and individual datasets at `s3/<namespace>/<name>.yaml` (optionally provisions a narrower table-scoped role and a Glue database/table for Athena queries). Supported `spec.format` values: `csv`, `json`, `avro`, `parquet`. CI validation runs `.github/scripts/validate-s3-registrations.py` (schema, path consistency, duplicate detection). New resources: [`terraform/s3_producers.tf`](terraform/s3_producers.tf) (IAM), [`terraform/glue.tf`](terraform/glue.tf) (Glue catalog + KMS encryption), a dedicated `module.kms["glue"]` key (`alias/chedaws-edp-glue-<env>`), and a `glue` entry in `local.kms_services`.
- **S3 E2E Verifier** – Daily-scheduled Lambda (`chedaws-edp-s3-e2e-verifier-<env>`) that validates the S3 producer self-onboarding infrastructure end-to-end. On each run it generates three sample rows, assumes the `platform` namespace IAM role to write CSV/JSON/Avro/Parquet files to the landing bucket, queries each Glue table via a dedicated Athena workgroup (`edp-e2e-<env>`), compares returned rows against the generated input, cleans up all written objects, and publishes `S3E2ETestSuccess` and `S3E2ECleanupSuccess` metrics to CloudWatch. Three alarms per environment route failures to the existing EDP SNS topic. Runs daily at 06:00 UTC in all four environments. Terraform resources: [`terraform/s3_e2e_verifier.tf`](terraform/s3_e2e_verifier.tf). Lambda source: [`lambda/s3-e2e-verifier/`](lambda/s3-e2e-verifier/).
- **MWAA Airflow Platform** – Shared multi-tenant Apache Airflow 3.2.1 environment on AWS MWAA (`chedaws-edp-mwaa-<env>`). Each use-case team registers a namespace via a YAML manifest at `airflow/mwaa/<namespace>.yaml` which provisions an isolated S3 DAG prefix, a least-privilege namespace IAM role, and (optionally) an ECR repository and Fargate compute capacity for containerised task execution. Authentication to the Airflow web UI is via IAM Identity Centre (SSO); DAG-to-AWS authentication uses namespace IAM role assumption via the Airflow Connections Secrets Manager backend. Five CloudWatch Log Groups and five metric alarms per environment (scheduler heartbeat, failed task count, ECS CPU/memory/anomaly) route to the EDP SNS topic. See [`specs/009-mwaa-airflow-platform/`](specs/009-mwaa-airflow-platform/) for full specification and onboarding guide.

## Directory Structure

```
├── terraform/                    # Active Terraform configuration
│   ├── providers.tf              # AWS provider, backend (S3), required versions
│   ├── variables.tf              # Input variables (region, IdC instance ARN)
│   ├── locals.tf                 # Environment-specific settings (via workspace)
│   ├── data.tf                   # Data sources (account, region, subnets)
│   ├── redshift.tf               # Redshift cluster, security group, alarms, IdC
│   ├── kms.tf                    # KMS module instantiation (for_each over 6 services)
│   ├── sns.tf                    # SNS alert topic
│   ├── msk.tf                    # MSK cluster, security group, auto-scaling, alarms
│   ├── s3.tf                     # Platform shared S3 bucket (community module)
│   ├── s3_table.tf               # S3 Tables table bucket
│   ├── kafka_topics.tf           # MSK topics and producer/consumer IAM roles
│   ├── kafka_e2e_canary.tf       # Canary Lambda, EventBridge rule, CloudWatch alarm
│   ├── s3_producers.tf           # S3 namespace/table producer IAM roles and policies
│   ├── glue.tf                   # Glue databases, tables, and catalog encryption
│   ├── s3_e2e_verifier.tf        # S3 E2E verifier Lambda, IAM, Athena, alarms
│   ├── outputs.tf                # Exported values
│   └── modules/
│       └── kms/                  # Reusable KMS key + alias module
├── kafka/                        # Git-based Kafka self-service configuration store
│   ├── producers/                # Producer YAML files (<businessName>/<appName>.yaml)
│   ├── consumers/                # Consumer YAML files (<consumer-slug>.yaml)
│   └── schema/                   # JSON schemas for producer and consumer YAMLs
├── s3/                           # Git-based S3 producer self-service configuration store
│   ├── <namespace>.yaml         # Namespace YAML (kind: Namespace)
│   ├── <namespace>/             # Per-namespace directory
│   │   └── <name>.yaml      # Table YAML (kind: Table)
│   └── schema/                   # JSON schemas for namespace and table YAMLs
├── airflow/                      # MWAA Airflow platform assets
│   ├── dags/                     # DAG files, one subdirectory per namespace
│   ├── mwaa/                     # Namespace YAML manifests (<namespace>.yaml)
│   └── plugins/                  # Shared Airflow plugins (plugins.zip)
├── lambda/kafka-e2e-canary/      # Kafka E2E canary Lambda source (handler.py)
├── lambda/s3-e2e-verifier/       # S3 E2E verifier Lambda source (handler.py, requirements.txt)
├── docs/
│   └── conventions.md            # Logging and error-handling conventions
├── terraform-legacy/             # Previous codebase (archived, not deployed)
│   ├── accounts/chedaws-wl-ndp/  # Old account-level configuration
│   └── modules/                  # Old modules (DMS, Glue, MWAA, ECS, S3, etc.)
└── .github/
    ├── scripts/
    │   ├── validate-topic-names.py          # Kafka YAML CI validation script
    │   └── validate-s3-registrations.py     # S3 YAML CI validation script
    └── workflows/
        ├── terraform.yaml            # Branch/main pushes - one job per environment (dev, test)
        ├── release.yaml              # v* tag pushes - verify the tag is on main, then uat
        ├── post-deploy-tests.yaml    # Manual (workflow_dispatch) post-deploy test run
        └── tf-deploy.yaml            # Per environment: build (checks + plans), then deploy-<stack>
```

In the Actions UI each environment is a single group - `dev / build`,
`dev / deploy-core`, `dev / deploy-redshift`, and so on - because
`terraform.yaml` and `release.yaml` call `tf-deploy.yaml` once per environment.
Release jobs live in their own workflow so branch and main runs don't list
them as skipped.

The `build` job bundles every validation step and every stack's plan into one
job (rather than one job each) because the self-hosted runners can only run a
single job at a time — separate jobs just queued for the same runner instead of
running in parallel, while paying repeated checkout/setup cost. A stack's plan
is skipped when a stack it depends on has no applied state in that environment
yet (`.github/scripts/tf-upstreams-deployed.sh`), and its `deploy-<stack>` job
is skipped with it.

## Conventions

Logging and error-handling conventions live in
[`docs/conventions.md`](docs/conventions.md) - read it before writing or
reviewing logging code anywhere in this repo.

## Prerequisites

- Terraform >= 1.10.0 (the S3 backends use `use_lockfile`; after pulling this change, run `terraform init -reconfigure` in any stack you had already initialised)
- AWS CLI configured with credentials (the provider assumes `chedaws-edp-ci-runner` role in the target account)
- AWS region: `ap-southeast-2` (Sydney)
- For the Python tooling: [uv](https://docs.astral.sh/uv/) (it provisions Python 3.12 itself, so no separate Python install is needed)
- For `make tf-trivy`: Docker (runs the same tool the `Run Trivy` CI step uses — see `TRIVY_IMAGE` in the `Makefile`)

## Usage

### Deploying Infrastructure

Environments are selected via **Terraform workspaces**, not variables:

```bash
cd terraform
terraform init
terraform workspace select dev    # or: terraform workspace select -or-create dev
terraform plan
terraform apply
```

### Switching Environments

```bash
terraform workspace select test
terraform plan
terraform apply
```

Valid workspace names: `dev`, `test`, `uat`, `prod`.

### Running the checks locally

On a fresh clone, one command sets up everything - the Python environment,
`tflint`, and a git pre-commit hook that runs every check before each commit:

```bash
make setup   # uv sync + tf-tools + wires .githooks/pre-commit via core.hooksPath
make check   # run everything by hand: py-check + tf-check
```

| Target | Runs |
| --- | --- |
| `make py-check` | `lint` (ruff), `typecheck` (ty), `test` (pytest) |
| `make tf-check` | `tf-fmt`, `tf-lint` (tflint), `tf-trivy` |
| `make fmt` | ruff autofix + format — opt-in, **not** a CI gate |
| `make clean` | removes `.venv` and tool caches |

Each sub-target runs standalone too (`make lint`, `make tf-trivy`, …).

**Pre-commit hook.** `.githooks/pre-commit` runs `make precommit` -
fmt/tflint/ruff/ty/pytest - before every commit. `tf-trivy` is
deliberately left out: it needs Docker, which a commit shouldn't be blocked
on not having installed; it still runs in CI (and by hand via `make
tf-trivy` or `make check`). Skip the hook for a single commit with `git
commit --no-verify`; re-run `make setup` after a fresh clone or if `git
config core.hooksPath` ever gets reset.

Opening the repo in VS Code picks up `.venv` and ruff automatically via
`.vscode/`.

**CI calls `make` directly again.** `tf-deploy.yaml`'s `build` job runs
`make <target>` for fmt/lint/typecheck/test/tf-lint, the same commands
`make check` runs locally - this had briefly regressed to hand-written
per-step commands (`make` wasn't reliably installable via `dnf` on these
runners - EDP-597), but `make` is baked directly into the pre-built CI
image now (see `docker/ci-image/Dockerfile`), which sidesteps that
entirely regardless of what the bare runner has installed.

Checkov is gone - replaced by Trivy (`make tf-trivy` locally, the `Run
Trivy` step in CI), a compiled Go binary baked into the same CI image
rather than a Docker-container Action needing its own image pull on every
run. Trivy uses its own check IDs (`AVD-AWS-*`), not checkov's (`CKV_*`) -
a different ruleset, not a faster version of the same one.

Dependencies and tool config live in the root `pyproject.toml`, pinned by
`uv.lock` — the single source of truth for the **development** environment.
Deployed artefacts pin separately, because they ship independently of it:

| File | Installed into |
| --- | --- |
| `lambda/*/requirements.txt` | each Lambda's deployment zip |
| `airflow/requirements.txt` | the MWAA environment |
| `airflow/dags/edp_dbt/requirements.txt` | the dbt venv, pre-built at `terraform apply` time and synced via `dags/` - see `airflow/dags/edp_dbt/README.md` |

Only `airflow/dags/edp_dbt` is currently linted and typechecked. The rest
of the repo's Python has never been checked and doesn't pass yet; add paths
to `PY_LINT_PATHS` in the `Makefile` and `files` in `pyproject.toml` as they
are cleaned up.

## CI/CD Pipeline

GitHub Actions on self-hosted runners (`cloud-platform, xlarge, x64`):

1. **Static-Check** – `terraform fmt -check`, tflint (severity=error), Trivy
2. **Plan** – Selects workspace, runs `terraform plan`, uploads plan artifact to S3
3. **Apply** – Downloads plan artifact, runs `terraform apply`

Promotion:
- `feature/*` and `feat/*` branches → deploy to **dev** only
- `main` → deploy to **dev** and **test**
- `v*` tags → deploy to **uat** and **prod** (currently commented out)

## Configuration

Environment-specific values are resolved in `locals.tf` using `terraform.workspace`:

- AWS account IDs and VPC IDs
- Redshift node type (`rg.xlarge` for dev/test, `rg.4xlarge` for uat/prod)
- Snapshot retention periods
- CloudWatch log retention
- Alarm thresholds

## Security

- KMS CMKs with automatic key rotation for Redshift, SNS, CloudWatch Logs, MSK, S3 (platform bucket), S3 Tables, and Glue Data Catalog
- Redshift master password in Secrets Manager (KMS-encrypted)
- SSL required on all Redshift connections
- Security group restricts port 5439 to App and DB tier subnets only
- Enhanced VPC routing enabled (no public internet egress)
- Trivy compliance scanning in CI
- IAM role assumption for cross-account deployments

## Legacy Code

The `terraform-legacy/` directory contains the previous infrastructure codebase with modules for DMS, Glue, MWAA, ECS, S3, and others. This code is archived and no longer deployed. It is retained for reference during migration.
