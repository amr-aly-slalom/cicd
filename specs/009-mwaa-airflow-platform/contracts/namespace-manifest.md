# Contract: MWAA Namespace Manifest YAML

**Feature**: 009-mwaa-airflow-platform | **Date**: 2026-08-03

Namespace manifests are YAML files stored at `airflow/mwaa/<namespace>.yaml` in the repository root. Terraform reads all files in that directory via `fileset`/`yamldecode` to provision namespace resources. This pattern mirrors the `kafka/producers/` and `s3/` registration directories.

---

## Schema

```yaml
apiVersion: mwaa.chedaws.io/v1
kind: Namespace
metadata:
  name: <namespace>                       # required; snake_case; used as key in for_each
  owner: <team-name>                      # required; e.g. "finance-team"
  description: <human-readable purpose>   # required

spec:
  fargate_enabled: <bool>                 # required; true if namespace uses Fargate compute

  # Per-environment SSO permission set name for Airflow RBAC (FR-018).
  # The value is the exact name of an existing permission set in IAM Identity Center —
  # this project does not provision or name permission sets; they are managed externally.
  # Access is granted via the namespace IAM role's trust policy (resource-based policy),
  # not via an inline policy attached to the permission set. The permission set must
  # exist in IAM Identity Center but Terraform does not look it up or modify it.
  sso_roles:
    dev:  <existing_permission_set_name>   # name of a pre-existing IDC permission set
    test: <existing_permission_set_name>
    uat:  <existing_permission_set_name>
    prod: <existing_permission_set_name>

  # Per-environment CI IAM role ARNs allowed to deploy DAGs to this namespace's S3 prefix
  ci_roles:
    dev:
      - arn:aws:iam::<account_id>:role/<role_name>
    test:
      - arn:aws:iam::<account_id>:role/<role_name>
    uat:
      - arn:aws:iam::<account_id>:role/<role_name>
    prod:
      - arn:aws:iam::<account_id>:role/<role_name>

  # Secrets Manager objects this namespace owns. Terraform creates the secret
  # (airflow/<env>/namespaces/<name>/<key>) in every environment; a platform
  # admin sets its value by hand afterward - see airflow/dags/edp_secrets/README.md.
  secrets:
    - <key>

  # Two-phase decommission guard (FR-026).
  # Must be set to true BEFORE the manifest file may be deleted.
  # CI rejects deletion of a manifest file whose last committed state does not
  # contain decommission: true.
  decommission: false                     # optional; default false
```

---

## Example: `platform` Namespace

```yaml
apiVersion: mwaa.chedaws.io/v1
kind: Namespace
metadata:
  name: platform
  owner: platform-team
  description: Platform team end-to-end testing namespace

spec:
  fargate_enabled: true

  sso_roles:
    dev:  chedaws-ndp-admin
    test: chedaws-ndp-admin
    uat:  chedaws-ndp-admin
    prod: chedaws-ndp-admin

  ci_roles:
    dev:
      - arn:aws:iam::381491832813:role/chedaws-edp-ci-runner
    test:
      - arn:aws:iam::381491832813:role/chedaws-edp-ci-runner

  secrets:
    - example_secret
```

---

## Lifecycle Rules

| Action | Requirement |
|---|---|
| Add namespace | Create `airflow/mwaa/<namespace>.yaml`; run `terraform apply` |
| Modify namespace | Edit YAML fields; run `terraform apply` |
| Decommission | Set `spec.decommission: true`; commit; run `terraform apply` to destroy IAM/ECR/Fargate; then delete YAML |
| Delete without decommission flag | **CI blocks**: pre-receive hook checks that the last committed state of any deleted `airflow/mwaa/*.yaml` contained `spec.decommission: true` |

---

## Terraform Consumption

The manifest is read in `terraform/mwaa.tf`:

```hcl
locals {
  _mwaa_namespace_files = {
    for f in fileset("${path.root}/../airflow/mwaa", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../airflow/mwaa/${f}"))
  }

  # Active namespaces only (decommission: true excluded)
  mwaa_namespaces = {
    for k, v in local._mwaa_namespace_files :
    k => v if !try(v.spec.decommission, false)
  }
}
```

All `for_each` expressions consume `local.mwaa_namespaces` — decommissioned namespaces are excluded before resource creation, so Terraform destroys their resources on `apply`.
