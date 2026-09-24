# Lake Formation YAML-Driven Permissions

This directory holds YAML files that declare Lake Formation grants and LF-Tag
assignments. A CI/CD pipeline plans and applies the corresponding Terraform
automatically on commit — there is nothing to run manually. This document
describes what each kind of YAML file does and how to write one.

## How files are discovered (read this first)

**Placement of a file anywhere under `lakeformation/` does not matter.**
Terraform scans this entire directory tree recursively and decides what to do
with each file based solely on its `kind` field — not the subfolder it lives
in, not its filename.

The subfolders you'll see here (`database_table_access/`, `access_grants/`,
`tag_assignments/`, `lf_tags/`) are just an organizational convention for
humans. You can nest a file as deeply as you like, name it whatever you like,
and group related files into your own folders — as long as the file lives
somewhere under `lakeformation/` and has one of the `kind` values below, it
will be picked up.

Every file must declare, at minimum:

```yaml
apiVersion: ...
kind: ...
metadata:
  ...
spec:
  ...
```

If `kind` is missing, misspelled, or not one of the recognized kinds, the
pipeline's plan step fails with a clear error naming the offending file —
it will not be silently skipped.

### Environments

Every kind requires `metadata.environments`, a **single** environment name
(e.g. `test`, `dev`, `uat`, `prod`). A file only takes effect when the
pipeline is running for that environment. If you need the same grant in
multiple environments, create one file per environment.

(The `LFTagSet` kind, covered briefly at the end, is the one exception —
its `environments` field is an optional list, not a single required value.)

---

## Kind: `DatabaseAccess` / `TableAccess`

Grants named database- or table-level permissions to AD/IdC groups and/or
IAM roles.

- Use `kind: DatabaseAccess` to grant on an entire database (S3 Tables
  namespace, or Redshift schema).
- Use `kind: TableAccess` to grant on one specific table — identical to
  `DatabaseAccess` but with `metadata.tableName` added.

`apiVersion` selects the service:
- `s3tables.lakeformation.chedaws.io/v1`
- `redshift.lakeformation.chedaws.io/v1`

### Fields

| Field | Required | Meaning |
|---|---|---|
| `metadata.catalogName` | Yes | S3 Tables: the table bucket name. Redshift: the Redshift database name. |
| `metadata.databaseName` | Yes | S3 Tables: the namespace. Redshift: the schema. |
| `metadata.tableName` | Only for `TableAccess` | The table name. Must be omitted for `DatabaseAccess`. |
| `metadata.environments` | Yes | Single environment this file applies to. |
| `metadata.owner` | Yes | Free text — who owns this grant. |
| `metadata.description` | Yes | Free text. |
| `spec.groups[].name` | At least one of `groups`/`iamRoles` required | AD/IdC group DisplayName. Resolved automatically to the group's identitystore ARN. |
| `spec.groups[].grants` | Yes (per group) | List of AWS Lake Formation permission names. |
| `spec.iamRoles[].arn` | At least one of `groups`/`iamRoles` required | Full IAM role ARN. Used as-is. |
| `spec.iamRoles[].grants` | Yes (per role) | List of AWS Lake Formation permission names. |

Valid values for `grants` (per the AWS console's permission checkboxes):
database scope allows `CREATE_TABLE`, `ALTER`, `DROP`, `DESCRIBE`; table scope
allows `SELECT`, `INSERT`, `DELETE`, `DESCRIBE`, `ALTER`, `DROP`, `ALL` (`ALL`
is the console's "Super" option).

### Example — S3 Tables, database-level

```yaml
apiVersion: s3tables.lakeformation.chedaws.io/v1
kind: DatabaseAccess
metadata:
  catalogName: slalom-test-table-bucket-02   # the S3 Tables bucket name
  databaseName: finance_db                    # the S3 Tables namespace
  environments: test
  owner: platform-team
  description: All Lake Formation grants for the finance namespace in S3 Tables

spec:
  groups:
    - name: finance-analysts
      grants:
        - SELECT
        - ALTER
    - name: data-engineering
      grants:
        - DESCRIBE
  iamRoles:
    - arn: arn:aws:iam::123456789012:role/DataEngineerRole
      grants:
        - DESCRIBE
```

### Example — S3 Tables, table-level

```yaml
apiVersion: s3tables.lakeformation.chedaws.io/v1
kind: TableAccess
metadata:
  catalogName: slalom-test-table-bucket-02
  databaseName: finance_db
  tableName: transactions
  environments: test
  owner: platform-team
  description: All Lake Formation grants for the transactions table in S3 Tables

spec:
  groups:
    - name: finance-analysts
      grants:
        - SELECT
        - DESCRIBE
  iamRoles:
    - arn: arn:aws:iam::123456789012:role/DataEngineerRole
      grants:
        - SELECT
        - ALTER
        - INSERT
```

### Example — Redshift, database-level

```yaml
apiVersion: redshift.lakeformation.chedaws.io/v1
kind: DatabaseAccess
metadata:
  catalogName: dev            # the Redshift database name
  databaseName: finance       # the schema within that Redshift database
  environments: test
  owner: platform-team
  description: All Lake Formation grants for the finance schema in Redshift

spec:
  groups:
    - name: finance-analysts
      grants:
        - SELECT
        - ALTER
  iamRoles:
    - arn: arn:aws:iam::123456789012:role/DataEngineerRole
      grants:
        - DESCRIBE
```

### Example — Redshift, table-level

```yaml
apiVersion: redshift.lakeformation.chedaws.io/v1
kind: TableAccess
metadata:
  catalogName: dev
  databaseName: finance
  tableName: transactions
  environments: test
  owner: platform-team
  description: All Lake Formation grants for the transactions table in Redshift

spec:
  groups:
    - name: finance-analysts
      grants:
        - SELECT
        - DESCRIBE
  iamRoles:
    - arn: arn:aws:iam::123456789012:role/DataEngineerRole
      grants:
        - SELECT
        - ALTER
        - INSERT
```

---

## Kind: `AccessGrant`

Grants permissions to **one principal** based on LF-Tag matching, rather than
a named database/table. Write one file per principal.

`apiVersion` is always `tags.lakeformation.chedaws.io/v1`.

### How the principal is determined

`metadata.principal` is a single value:
- A value matching an IAM role ARN (`arn:aws:iam::<account>:role/<name>`) is
  used directly as the principal.
- Any other value is treated as an AD/IdC group DisplayName and resolved
  automatically to that group's identitystore ARN.

### How matching works

`spec.tags` is a list of `{key, values}` pairs. All entries in the list are
**ANDed** together — a database/table must carry every listed key with a
matching value to receive the grant. There is no fixed limit on how many
entries you can list.

`spec.database` and `spec.table` are each **independently optional** — include
whichever (or both) you need:
- `spec.database.grants`: permissions applied to any **database** matching
  the tag expression above. Valid values: `CREATE_TABLE`, `ALTER`, `DROP`,
  `DESCRIBE`.
- `spec.table.grants`: permissions applied to any **table** matching the tag
  expression above. Valid values: `SELECT`, `INSERT`, `DELETE`, `DESCRIBE`,
  `ALTER`, `DROP`, `ALL`.

Every tag key/value referenced here must already be defined in an `LFTagSet`
file (see below) — if not, the pipeline's plan step fails with a clear error.

### Example — group principal, database-only

```yaml
apiVersion: tags.lakeformation.chedaws.io/v1
kind: AccessGrant
metadata:
  principal: finance-analysts   # plain (non-ARN) value -> resolved as an AD/IdC group
  environments: test
  owner: platform-team
  description: Grants to any database tagged domain=finance AND data_classification=internal for finance-analysts

spec:
  tags:
    - key: domain
      values:
        - finance
    - key: data_classification
      values:
        - internal
  database:
    grants:
      - DESCRIBE
```

### Example — IAM role principal, both database and table

```yaml
apiVersion: tags.lakeformation.chedaws.io/v1
kind: AccessGrant
metadata:
  principal: arn:aws:iam::123456789012:role/DataEngineerRole
  environments: test
  owner: platform-team
  description: Grants to any database/table tagged domain=finance for the DataEngineerRole

spec:
  tags:
    - key: domain
      values:
        - finance
  database:
    grants:
      - CREATE_TABLE
      - DESCRIBE
  table:
    grants:
      - SELECT
      - INSERT
```

---

## Kind: `TagAssignments`

Attaches specific LF-Tag key/value pairs to a database or table (as opposed
to `AccessGrant`, which grants *access* based on tags — this kind is what
puts the tags on the resource in the first place).

`apiVersion` is always `tags.lakeformation.chedaws.io/v1`.

### Fields

| Field | Required | Meaning |
|---|---|---|
| `metadata.service` | Yes | `s3tables` or `redshift`. Selects which federated catalog `catalogName` resolves against. |
| `metadata.catalogName` | Yes | S3 Tables: the table bucket name. Redshift: the Redshift database name. |
| `metadata.databaseName` | Yes | S3 Tables: the namespace. Redshift: the schema. |
| `metadata.tableName` | Optional | If present, the tags are assigned to this table instead of the database. |
| `spec.tags[].key` | Yes (per tag) | Must be defined in an `LFTagSet` file. |
| `spec.tags[].value` | Yes (per tag) | A single value (not a list) — must be one of the allowed values for that key in the `LFTagSet` file. |

You can assign more than one tag per file — list as many `{key, value}` pairs
under `spec.tags` as needed.

### Example — S3 Tables, database-level, multiple tags

```yaml
apiVersion: tags.lakeformation.chedaws.io/v1
kind: TagAssignments
metadata:
  service: s3tables
  catalogName: slalom-test-table-bucket-02
  databaseName: finance_db
  environments: test
  owner: platform-team
  description: Assign domain/classification tags to the finance namespace

spec:
  tags:
    - key: domain
      value: finance
    - key: data_classification
      value: internal
```

### Example — S3 Tables, table-level

```yaml
apiVersion: tags.lakeformation.chedaws.io/v1
kind: TagAssignments
metadata:
  service: s3tables
  catalogName: slalom-test-table-bucket-02
  databaseName: finance_db
  tableName: transactions
  environments: test
  owner: platform-team
  description: Assign domain tag to the transactions table

spec:
  tags:
    - key: domain
      value: finance
```

### Example — Redshift, database-level

```yaml
apiVersion: tags.lakeformation.chedaws.io/v1
kind: TagAssignments
metadata:
  service: redshift
  catalogName: dev
  databaseName: finance
  environments: test
  owner: platform-team
  description: Assign domain tag to the finance schema

spec:
  tags:
    - key: domain
      value: finance
```

### Example — Redshift, table-level

```yaml
apiVersion: tags.lakeformation.chedaws.io/v1
kind: TagAssignments
metadata:
  service: redshift
  catalogName: dev
  databaseName: finance
  tableName: transactions
  environments: test
  owner: platform-team
  description: Assign domain tag to the transactions table

spec:
  tags:
    - key: domain
      value: finance
```

---

## Reference: `LFTagSet` (defining LF-Tags)

`AccessGrant` and `TagAssignments` both depend on LF-Tag keys/values that must
be defined ahead of time in an `LFTagSet` file. This kind is documented in
full elsewhere, but as a quick reference, it looks like this:

```yaml
apiVersion: lakeformation.chedaws.io/v1
kind: LFTagSet
metadata:
  name: core-tags
  owner: platform-team
  description: Core LF-Tag definitions for data classification and domain
spec:
  tags:
    - key: domain
      values: [finance, marketing, engineering]
    - key: data_classification
      values: [public, internal, confidential]
      environments: [dev, test, uat]   # optional; omit to apply to all environments
```

If an `AccessGrant` or `TagAssignments` file references a key or value not
defined here (for the active environment), the pipeline's plan step fails
with a clear error naming the offending key/value.

---

## Known limitations

- **No plan-time existence check for `DatabaseAccess` files.** `TableAccess`
  files are validated against real AWS data (via the `aws_glue_catalog_table`
  data source) before anything is created, so a nonexistent table/database
  combination fails at plan time. There is no equivalent check for
  database-only grants — a typo'd `databaseName` on a `DatabaseAccess` file
  will only fail when the pipeline applies, with an AWS API error.
- **Duplicate grants across files are not currently detected.** If two
  separate files produce the same effective grant (same principal, database
  or table, and catalog), both will apply successfully, but removing only one
  of them later can revoke access that the other file still expects to exist.
  Avoid overlapping grants across files for the same principal/resource.
- **S3 Tables currently supports a single table bucket per region.** Multiple
  buckets are not yet supported by the underlying catalog resolution.
- **Attaching tags via `TagAssignments` requires the pipeline's execution
  role to have `ASSOCIATE` permission on each LF-Tag key being assigned.**
  This is a Lake Formation prerequisite, separate from anything in this
  directory — if a `TagAssignments` file fails to apply with a permissions
  error, confirm the pipeline's role has been granted `ASSOCIATE` on the
  relevant tag key(s).
