# S3 Tables (Iceberg) Self-Service

This directory is the Terraform configuration for the S3 Tables (Apache Iceberg)
table bucket and its namespaces. Teams register a namespace by adding a YAML file
under `s3tables/namespaces/` — Terraform reads every namespace file it finds and
provisions the corresponding S3 Tables resources in whichever environment(s) that
file declares.

**Tables themselves are created outside Terraform** — typically by whatever
producer writes to them (for example, the E2E verifier Lambda creates its own
table on first run via `CREATE TABLE IF NOT EXISTS`). This directory is only
about registering namespaces, and the IAM roles/Athena workgroups attached to
them.

The module does still support declaring tables in YAML (see
`terraform/modules/s3tables/`), for cases where owning a table's full lifecycle
in Terraform is genuinely wanted. That path is not documented here since it is
not the expected way to create a table — read the module source directly if you
need it.

**Everything runs through GitHub Actions CI/CD — no manual steps.** Nobody
selects an environment, runs `terraform apply`, or validates YAML by hand.
Pushing/merging/tagging is all that's required; the pipeline figures out which
environment to deploy to and validates every file automatically (see
[Deployment Flow](#deployment-flow) and [Schema Validation](#schema-validation)).

## Deployment Flow

Which environment gets deployed is driven entirely by the CI/CD pipeline, based on
where your code is in the promotion flow — not by anyone manually passing
`-var="environment=..."`:

| Action | Environment deployed |
|---|---|
| Push to a feature branch | `dev` |
| Merge that branch into `main` | `test` |
| Promote from `test` | `uat` |
| Add a release tag | `prod` |

A namespace only actually gets created/updated in a given environment if that
environment appears as a key under its own `spec.environments` map (see
[YAML Schema Reference](#yaml-schema-reference) below) — the pipeline stage just
determines *which* environment is being targeted for that run; the namespace
YAML still determines *which namespaces* are eligible for it.

## Folder Convention

Namespace YAML files live in a single flat directory. There is no
per-environment folder. Which environment(s) a namespace deploys to is declared
**inside the file itself**, not by where the file is placed.

```
s3tables/
└── namespaces/
    └── <name>.yaml       # one file per namespace
```

For example, a `bronze` namespace:

```
s3tables/
└── namespaces/
    └── bronze.yaml
```

**Every namespace file must live directly under `s3tables/namespaces/`.**
Nothing else in the folder is read for namespace registration.

Rules (enforced by `terraform plan`, not just convention):
- Every namespace file must declare `metadata.name`. A file missing it fails
  `plan` with a clear error.
- The same namespace `metadata.name` must not be declared more than once,
  anywhere under `s3tables/namespaces/` — `plan` fails with a clear error
  naming the duplicate and every file it was found in.

## How to Register a Namespace

1. Create `s3tables/namespaces/<name>.yaml`, declaring `metadata.name`.
2. Optionally declare `spec.environments` to control which environment(s) it
   deploys to, and which IAM roles (if any) may produce into it there — see
   the schema reference below. Omit `spec.environments` entirely to create a
   namespace-only namespace (no producer) in **all four** environments.
3. Push your branch, then open a pull request — no local validation or
   Terraform commands are needed. The GitHub Actions pipeline automatically
   runs `check-jsonschema` against the file and blocks the merge on any
   violation (see [Schema Validation](#schema-validation))
4. Pushing the branch itself deploys to `dev`; merging to `main` deploys to
   `test`; promotion/tagging moves it to `uat`/`prod` (see
   [Deployment Flow](#deployment-flow)) — the namespace is provisioned
   automatically at each stage, for every environment its `spec.environments`
   resolves to (see above)

### Sample YAML

**Namespace-only, in every environment** — omit `spec.environments` entirely:

```yaml
apiVersion: s3tables.chedaws.io/v1
kind: Namespace
metadata:
  name: bronze
  owner: platform-team
  description: Bronze layer raw ingestion namespace
spec: {}
```

This creates namespace `bronze` in `dev`, `test`, `uat`, and `prod` — no
producer role or Athena workgroup in any of them.

**Namespace in specific environments only, with a producer in some of them:**

```yaml
apiVersion: s3tables.chedaws.io/v1
kind: Namespace
metadata:
  name: bronze
  owner: platform-team
  description: Bronze layer raw ingestion namespace
spec:
  environments:
    dev:
      iamRoles:
        - arn:aws:iam::123456789012:role/bronze-producer-dev
    test: {}
```

This creates namespace `bronze` only in `dev` and `test` — `uat`/`prod` are
skipped entirely, since they're not keys in the map at all (not an error).
`dev` also gets a producer role, since it lists `iamRoles`; `test` gets the
namespace only, since its value is empty. When `spec.environments` is
present, **only the environments listed are used — there is no default-fill**
for environments left out of the map.

`metadata.owner` and `metadata.description` are optional and purely
informational — Terraform never reads them.

## YAML Schema Reference

One file describes exactly one namespace: `s3tables/namespaces/<name>.yaml`.

| Field                | Required | Description                                                                 |
|----------------------|----------|-------------------------------------------------------------------------------|
| `apiVersion`         | **yes**  | Must be the literal string `s3tables.chedaws.io/v1`.                         |
| `kind`               | **yes**  | Must be the literal string `Namespace`.                                     |
| `metadata.name`      | **yes**  | Namespace identifier. Must match `^[a-z0-9][a-z0-9_]{0,254}$` (lowercase letters, digits, underscores; 1–255 characters; must start with a letter or digit). This is the identity field — file name and location are not read. |
| `metadata.owner`     | no       | Informational only — not read by Terraform.                                  |
| `metadata.description` | no    | Informational only — not read by Terraform.                                  |
| `spec.environments`  | no       | Map keyed by `dev`/`test`/`uat`/`prod`. Controls where the namespace is created, and optionally which IAM roles produce into it there. **Omit entirely** to default to all four environments, namespace-only. When present, an unrecognized key fails `plan` (likely a typo), and only the listed environments are used. |

### `spec.environments.<env>`

Each key's value is an object — `{}` for namespace-only, or with `iamRoles`
for a producer:

| Field | Required | Description |
|---|---|---|
| `iamRoles` | no | Non-empty list of IAM role ARNs that may assume the generated producer role for this namespace in this environment. Omit to create the namespace here with no producer role. |

Listing `iamRoles` for an environment provisions, in that environment:

- IAM role `edp-<env>-s3tables-producer-<namespace>`, trusting the listed ARNs
- An inline policy scoped to that namespace's database in the federated Glue
  catalog `s3tablescatalog/<table bucket>`, with Athena, S3 Tables data and KMS
  access. This role does **not** include table-creation rights — see the note
  above about tables being created outside Terraform.
- Athena workgroup `edp-<env>-tables-<namespace>`, with
  `enforce_workgroup_configuration = true` pinning query results to
  `athena-query-results/<namespace>/` in the S3 Tables Athena results bucket

S3 Tables producers are AWS-only. Unlike the `s3/` registry there is no IAM Roles
Anywhere / `certificateSubject` path.

## Schema Validation

A JSON Schema for namespace files lives at **`schema/namespace.schema.json`**. It
is deliberately kept *outside* `s3tables/` so it can never be picked up by the
module's own file scan.

**This runs entirely inside the GitHub Actions pipeline — there is nothing to
install or run locally.** A dedicated step validates every namespace file on
each push/PR:

```bash
check-jsonschema --schemafile ./schema/namespace.schema.json s3tables/namespaces/*.yaml
```

Any violation fails that step and blocks the pull request from merging. If you
want to check a file before pushing, the same command works locally too
(requires `pip install check-jsonschema`), but it's optional — the pipeline is
the actual enforcement mechanism, not a convenience.

### Why this is worth running

The module reads optional keys with Terraform's `try()`, which cannot tell a
**misspelled** key from an **absent** one. That makes typos fail *silently* — the
plan looks completely healthy, and the namespace is just quietly wrong:

| If you write | Terraform alone would... | The schema catches it |
|---|---|---|
| `enviroments:` | create the namespace **nowhere** | ✅ unknown property + missing required |
| `iamRole:` instead of `iamRoles` | create **no producer role** | ✅ unknown property |
| `kind: namespace` (wrong case) | ignored entirely, nothing created | ✅ `const` mismatch |
| missing/wrong `apiVersion` | ignored entirely, nothing created | ✅ missing required property / `const` mismatch |

The schema sets `"additionalProperties": false` at every level, so any key it
doesn't recognize is rejected by name. It also validates required fields, the
`dev`/`test`/`uat`/`prod` enum, and the namespace name pattern.

### What the schema does *not* check

Anything that spans more than one file, or depends on Terraform variables, stays
the module's job (enforced by `precondition` blocks at plan time):

- Duplicate namespace `metadata.name` across two different files
- Namespace length *after* the `edp_<env>_` prefix is applied
- IAM role and Athena workgroup name length limits

So: schema for fast, per-file, pre-AWS feedback; Terraform preconditions for
whole-repo correctness. Both are worth having.

## Bucket Configuration Reference

The table bucket itself is configured in Terraform, not YAML — see
`aws_s3tables_table_bucket.this` in `terraform/s3tables/s3tables.tf`. There is exactly
**one table bucket per account per environment**, named
`chedaws-edp-table-bucket-<env>`, encrypted with the `s3tables` KMS key.

`enable_namespace_prefix` is set to `true` on the module call, so the namespace
name in AWS is `edp_<env>_<namespace>` — a namespace written as `bronze` in YAML
is created as `edp_test_bronze` in the `test` table bucket. Always write the
unprefixed name in YAML; the prefix is applied by Terraform.

## Removing a Namespace

`aws_s3tables_namespace` has no `prevent_destroy` guard. This means:

- Deleting a namespace's YAML file from `s3tables/namespaces/`, or removing an
  environment key from its `spec.environments` map, **does** delete the real
  namespace on the next apply, in that environment.
- A namespace cannot be destroyed while it still contains tables. Since tables
  are typically created outside Terraform (see the note at the top of this
  file), removing a namespace's YAML may fail the apply until whatever created
  its tables removes them first.

## Environments

| Environment | Reached by                          |
|-------------|----------------------------------------|
| dev         | Pushing a branch                        |
| test        | Merging that branch into `main`         |
| uat         | Promoting from `test`                   |
| prod        | Adding a release tag                    |

See [Deployment Flow](#deployment-flow) above for the full picture. The pipeline
passes the corresponding `environment` value to Terraform automatically at each
stage — `environment` selects which key of a namespace's own declared
`spec.environments` map to match against; it does not select a folder (there is
only one shared `s3tables/namespaces/` tree). A namespace not listing the
environment being deployed as a key is skipped for that run, not an error.
