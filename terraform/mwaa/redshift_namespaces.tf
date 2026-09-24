# Redshift access for MWAA namespaces: redshift/namespaces/<name>.yaml.
#
# Both halves of a namespace's Redshift access live here - the Redshift-side
# schema/group/GRANT bootstrap and the IAM policy that lets the namespace's
# role fetch credentials for that group - so the policy can depend on the
# bootstrap directly. Moved out of the core state, which still owns the
# cluster itself; its identifier, database and master secret are read from
# core's outputs.

# --- Locals ---

locals {
  _redshift_namespace_files = {
    for f in fileset("${path.root}/../../redshift/namespaces", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${path.root}/../../redshift/namespaces/${f}"))
  }

  redshift_namespaces = {
    for k, v in local._redshift_namespace_files :
    k => v if !try(v.spec.decommission, false)
  }

  _redshift_namespace_slug_list   = [for k, v in local.redshift_namespaces : v.metadata.name]
  _redshift_namespace_slug_unique = distinct(local._redshift_namespace_slug_list)

  # The cross-object grants are keyed by environment, same shape as
  # airflow/mwaa/*.yaml's ci_roles - the schemas they reference are created
  # outside Terraform and don't exist in every environment. An environment a
  # namespace doesn't list gets an empty list, i.e. no grants. See
  # redshift/README.md.
  _redshift_namespace_additional_schemas = {
    for k, v in local.redshift_namespaces : k => try(v.spec.additional_schemas[local.environment], [])
  }
  _redshift_namespace_writable_schemas = {
    for k, v in local.redshift_namespaces : k => try(v.spec.writable_schemas[local.environment], [])
  }
  _redshift_namespace_writable_databases = {
    for k, v in local.redshift_namespaces : k => try(v.spec.writable_databases[local.environment], [])
  }

  # sort() keeps the IAM policy document stable across plans.
  _redshift_namespace_credential_databases = {
    for k, v in local.redshift_namespaces : k => sort(distinct(concat(
      [data.terraform_remote_state.redshift.outputs.redshift_database_name],
      local._redshift_namespace_writable_databases[k],
    )))
  }
}

# --- Validations ---

resource "terraform_data" "redshift_namespace_registration_checks" {
  lifecycle {
    precondition {
      condition     = length(local._redshift_namespace_slug_list) == length(local._redshift_namespace_slug_unique)
      error_message = "Duplicate namespace values detected in redshift/namespaces/*.yaml: ${join(", ", setsubtract(toset(local._redshift_namespace_slug_list), toset(local._redshift_namespace_slug_unique)))}"
    }
    precondition {
      # CI (validate-redshift-registrations.py) already enforces this per-file
      # at PR time; this is the equivalent whole-repo check at plan time, same
      # split as S3's registrations (see terraform/s3/s3.tf).
      condition     = alltrue([for k, v in local.redshift_namespaces : contains(keys(local.mwaa_namespaces), v.metadata.name)])
      error_message = "redshift/namespaces/*.yaml declares a namespace with no matching active airflow/mwaa/<name>.yaml."
    }
  }
}

# --- Schema/Group/GRANT bootstrap ---

# Provisions the Redshift-side schema/group/GRANTs for every registered
# namespace, via the Redshift Data API (see
# scripts/redshift_namespace_bootstrap.sh) - no VPC/network path to the
# cluster is needed from CI, same reasoning as
# terraform_data.mwaa_s3_bootstrap's use of the AWS CLI for S3 instead of a
# direct connection.
#
# for_each keeps namespaces independent: removing one from the YAML set
# does not re-run this for every other namespace. triggers_replace hashes
# the script itself (so a logic fix re-runs for every namespace, not just
# ones whose YAML also changed - see mwaa_s3_bootstrap.sh's own comment on
# why this matters) plus the namespace name (so adding one only bootstraps
# that one).
#
# Deliberately has no destroy provisioner: removing a namespace's YAML
# (after the two-phase decommission guard - see redshift/README.md) stops
# granting IAM access, but does NOT drop the schema/group in Redshift.
# Dropping a schema requires it to be empty first, which isn't something
# Terraform can safely decide on its own - that's a manual follow-up.
resource "terraform_data" "redshift_namespace_bootstrap" {
  for_each = local.redshift_namespaces

  triggers_replace = [
    filemd5("${path.root}/scripts/redshift_namespace_bootstrap.sh"),
    each.value.metadata.name,
    join(",", local._redshift_namespace_additional_schemas[each.key]),
    join(",", local._redshift_namespace_writable_schemas[each.key]),
    join(",", local._redshift_namespace_writable_databases[each.key]),
  ]

  provisioner "local-exec" {
    environment = {
      CLUSTER_ID         = data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier
      DATABASE           = data.terraform_remote_state.redshift.outputs.redshift_database_name
      SECRET_ARN         = data.terraform_remote_state.redshift.outputs.redshift_master_secret_arn
      REGION             = data.aws_region.current.region
      NAMESPACE          = each.value.metadata.name
      ROLE_ARN           = "arn:aws:iam::${local.aws_account_id}:role/chedaws-edp-ci-runner"
      ADDITIONAL_SCHEMAS = join(",", local._redshift_namespace_additional_schemas[each.key])
      WRITABLE_SCHEMAS   = join(",", local._redshift_namespace_writable_schemas[each.key])
      WRITABLE_DATABASES = join(",", local._redshift_namespace_writable_databases[each.key])
    }
    command = "bash \"${path.root}/scripts/redshift_namespace_bootstrap.sh\""
  }
}

# --- IAM: grant the MWAA namespace role scoped Redshift credential access ---

# One namespace's role can only ever request credentials for its own DB
# user/group - Resource-scoped to <name>_mwaa/<name>_group specifically, not
# a wildcard. This is why GetClusterCredentials (not GetClusterCredentialsWithIAM,
# which grants more broadly and relies entirely on Redshift-side GRANTs for
# restriction - see specs/002-iam-ic-redshift-ci) was chosen for this path.
#
# Connecting with credentials issued for a database the dbname resources don't
# list fails at login with "FATAL 28000 IAM authentication failed" - what cdc
# hit on edp_raw_dev on 2026-09-15 while every connection to edp succeeded.
#
# depends_on the bootstrap so a namespace's schema and group exist in
# Redshift before its role is granted credentials for them.
resource "aws_iam_role_policy" "mwaa_namespace_redshift" {
  for_each = local.redshift_namespaces

  depends_on = [terraform_data.redshift_namespace_bootstrap]

  name = "redshift-credentials"
  role = aws_iam_role.mwaa_namespace[each.value.metadata.name].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetRedshiftCredentials"
        Effect = "Allow"
        Action = [
          "redshift:GetClusterCredentials",
          "redshift:CreateClusterUser",
        ]
        Resource = concat(
          [
            "arn:aws:redshift:${data.aws_region.current.region}:${local.aws_account_id}:dbuser:${data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier}/${each.value.metadata.name}_mwaa",
          ],
          [
            for db in local._redshift_namespace_credential_databases[each.key] :
            "arn:aws:redshift:${data.aws_region.current.region}:${local.aws_account_id}:dbname:${data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier}/${db}"
          ],
        )
      },
      {
        Sid      = "JoinRedshiftGroup"
        Effect   = "Allow"
        Action   = "redshift:JoinGroup"
        Resource = "arn:aws:redshift:${data.aws_region.current.region}:${local.aws_account_id}:dbgroup:${data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier}/${each.value.metadata.name}_group"
      }
    ]
  })
}
