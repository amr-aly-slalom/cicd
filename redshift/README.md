# Redshift Namespace Access - Self-Service

This directory registers per-namespace Redshift access for MWAA namespaces.
Registering a namespace here provisions, in Redshift itself: a schema named
after the namespace, and a group (`<namespace>_group`) with `USAGE`/`CREATE`
on that schema. On the AWS side, it grants the corresponding MWAA namespace
IAM role (`airflow/mwaa/<namespace>.yaml`) permission to fetch short-lived
Redshift credentials scoped to a DB user named `<namespace>_mwaa`, which
joins that group.

**This is not a standalone namespace concept.** `metadata.name` must match
an existing, non-decommissioned `airflow/mwaa/<name>.yaml` - this registers
Redshift access *for* an MWAA namespace, the same way `s3/<namespace>.yaml`
registers S3 producer access for a (separately-named) S3 namespace.

## Folder Convention

```
redshift/
└── namespaces/
    └── <name>.yaml       # one file per namespace
```

`<name>` must equal `metadata.name`, which must equal an active MWAA
namespace name.

## How to Register

1. Create `redshift/namespaces/<name>.yaml`:

   ```yaml
   apiVersion: redshift.chedaws.io/v1
   kind: Namespace
   metadata:
     name: platform
     owner: platform-team
     description: Platform team's Redshift schema
   spec: {}
   ```

2. Push your branch. CI validates the file (schema, cross-reference against
   `airflow/mwaa/`, duplicates) via `.github/scripts/validate-redshift-registrations.py`
   before anything is planned or applied.
3. On apply, Terraform provisions the schema/group/GRANTs via the Redshift
   Data API (no direct network path to the cluster needed - same reasoning
   as the MWAA S3 bootstrap provisioner) and grants the namespace's MWAA
   role `redshift:GetClusterCredentials`/`CreateClusterUser`/`JoinGroup`,
   scoped to that namespace's own `dbuser`/`dbgroup` ARNs only - one
   namespace's role cannot fetch credentials for another's.

## Accessing Other Schemas

A namespace sometimes needs to read a schema it doesn't own, e.g. one that
GoldenGate CDC replication populates directly. Add `spec.additional_schemas`,
keyed by environment:

```yaml
spec:
  additional_schemas:
    dev:
      - replicat
```

Each entry must already exist in that environment - Terraform errors clearly
on apply if it doesn't, since this only grants `USAGE` on the schema and
`SELECT` on its tables to the namespace's own group, it never creates or owns
the schema. Because the grant only covers tables that exist at apply time,
re-apply after a new table lands in an additional schema to pick it up.

All three cross-object fields on this page (`additional_schemas`,
`writable_schemas`, `writable_databases`) are keyed by environment
(`dev`/`test`/`uat`/`prod`), because what they point at is created outside
Terraform and doesn't exist everywhere. An environment
that isn't listed gets no grants. Add it once its schemas exist; listing it
early fails the apply rather than silently skipping, because a skipped grant
would never be retried when the schema appears later.

### Writing to a schema someone else owns

`spec.writable_schemas` is the read-write counterpart, for when a namespace
must write into a schema another principal owns:

```yaml
spec:
  writable_schemas:
    dev:
      - control
```

Same must-already-exist rule; the grant adds `CREATE` on the schema and
`SELECT`/`INSERT`/`UPDATE`/`DELETE`/`TRUNCATE` on its tables (`dbt seed`
truncates before reloading, and `DELETE` doesn't imply `TRUNCATE`). It also sets
`ALTER DEFAULT PRIVILEGES` for the schema's owner, so tables that owner
creates later stay accessible - `additional_schemas` has no equivalent,
which is exactly why it needs the re-apply noted above.

## Creating Schemas With Unknown Names

Some projects create schemas whose names aren't knowable at apply time - the
CDC `config_manager` dbt project creates one per source system, 39 and
growing, driven by its own `contracts/source_systems.tsv`. Enumerating those
in `additional_schemas` would mean a Terraform PR per source system, so
`spec.writable_databases` grants `CREATE ON DATABASE` instead:

```yaml
spec:
  writable_databases:
    dev:
      - edp
      - edp_raw_dev
```

The namespace then creates schemas freely and **owns** each one, so it gets
full DDL/DML inside without any further grant, while still getting nothing on
schemas other teams already own. Without this, `dbt seed`/`dbt run` fails on
its first `CREATE SCHEMA` with `permission denied for database edp`.

Each database must already exist in that environment - this only grants, it
never creates one. `GRANT ... ON DATABASE` updates the cluster-wide catalog,
so all of these are issued over the bootstrap's single connection to the
cluster's default database.

Listing a database here also lets the namespace's IAM role fetch Redshift
credentials for it (`redshift:GetClusterCredentials` is scoped to the
cluster's default database plus these). Connecting with credentials issued
for a database the role isn't scoped to fails at login with
`FATAL 28000 IAM authentication failed`, not with a permissions error.

## Authentication (namespace role -> Redshift)

Whatever runs under a namespace's MWAA role (dbt or otherwise - the DB user
is `<namespace>_mwaa`, not `<namespace>_dbt`, deliberately) fetches
short-lived DB credentials at runtime via `redshift:GetClusterCredentials`
with `DbUser=<namespace>_mwaa`, `DbGroups=[<namespace>_group]`,
`AutoCreate=true`. The user is created lazily on first use if it doesn't
exist yet; the group and its schema GRANTs are provisioned up front by this
directory's Terraform, since `GetClusterCredentials` never creates groups.

## Removing a Namespace

Two-phase, matching Kafka/MWAA/S3 elsewhere in this repo: set
`spec.decommission: true` and merge, then delete the YAML in a follow-up PR
once the apply has run. This is a convention, not something CI enforces -
deleting the YAML directly destroys the same resources on the next apply
either way, it just doesn't show the destroy as its own reviewable plan
first. Note this only stops Terraform from continuing to grant IAM access -
it does not itself drop the schema/group in Redshift; that's a manual
follow-up (see the caveat in `terraform/mwaa/redshift_namespaces.tf`).

## Schema Validation

`redshift/schema/namespace.schema.json` - deliberately kept outside
`redshift/namespaces/` so it's never picked up as a namespace file itself.
Validated as part of `validate-redshift-registrations.py`, not a separate
`check-jsonschema` step (that script already runs the same Draft-07
validation internally, same as `validate-s3-registrations.py`).
