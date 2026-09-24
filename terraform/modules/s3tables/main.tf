locals {
  valid_sse_algorithms = ["AES256", "aws:kms"]
  name_pattern         = "^[a-z0-9][a-z0-9_]{0,254}$"
  valid_environments   = ["dev", "test", "uat", "prod"]
  namespace_files = sort(tolist(setunion(
    fileset(var.config_dir, "namespaces/*.yaml"),
    fileset(var.config_dir, "namespaces/*.yml"),
  )))

  raw_namespace_entries = [
    for f in local.namespace_files : {
      source  = f
      content = yamldecode(file("${var.config_dir}/${f}"))
    }
  ]

  namespaces_missing_name = sort([
    for e in local.raw_namespace_entries : e.source
    if try(e.content.metadata.name, null) == null
  ])

  namespaces_with_empty_environments = sort([
    for e in local.raw_namespace_entries : e.source
    if try(e.content.spec.environments, null) != null && length(e.content.spec.environments) == 0
  ])

  namespaces_with_invalid_environment_names = sort(flatten([
    for e in local.raw_namespace_entries : [
      for env in keys(try(e.content.spec.environments, {})) : "${e.source}: \"${env}\""
      if !contains(local.valid_environments, env)
    ] if try(e.content.spec.environments, null) != null
  ]))

  namespace_entries = [
    for e in local.raw_namespace_entries : {
      source    = e.source
      file_name = split("/", e.source)[length(split("/", e.source)) - 1]
      name      = e.content.metadata.name
      environments = try(e.content.spec.environments, null) == null ? {
        for env in local.valid_environments : env => {}
        } : {
        for env in keys(e.content.spec.environments) : env => {}
      }
    } if try(e.content.metadata.name, null) != null
  ]

  namespaces_name_not_matching_file = sort([
    for e in local.namespace_entries :
    "${e.source}: metadata.name is \"${e.name}\", expected \"${trimsuffix(trimsuffix(e.file_name, ".yaml"), ".yml")}\""
    if e.name != trimsuffix(trimsuffix(e.file_name, ".yaml"), ".yml")
  ])

  active_namespace_entries = [
    for e in local.namespace_entries : e
    if contains(keys(e.environments), var.environment)
  ]

  namespace_names = sort(distinct([for e in local.active_namespace_entries : e.name]))

  duplicate_namespaces = sort([
    for name, group in { for e in local.active_namespace_entries : e.name => e... } :
    "${name} (in ${join(", ", sort([for e in group : e.source]))})"
    if length(group) > 1
  ])

  invalid_namespace_names = sort(distinct([
    for e in local.active_namespace_entries : "${e.source}: ${e.name}"
    if !can(regex(local.name_pattern, e.name))
  ]))

  namespace_prefix = "edp_${var.environment}_"

  namespace_names_too_long = var.enable_namespace_prefix ? sort([
    for name in local.namespace_names :
    "${name} -> ${local.namespace_prefix}${name} (${length(local.namespace_prefix) + length(name)} chars)"
    if length(local.namespace_prefix) + length(name) > 255
  ]) : []

  namespace_aws_names = {
    for name in local.namespace_names :
    name => var.enable_namespace_prefix ? "${local.namespace_prefix}${name}" : name
  }

  # ---------------------------------------------------------------------------
  # Table YAML parsing
  # ---------------------------------------------------------------------------

  table_files = sort(tolist(setunion(
    fileset(var.config_dir, "tables/*.yaml"),
    fileset(var.config_dir, "tables/*.yml"),
  )))
  duplicate_table_file_names = sort([
    for name, group in {
      for f in local.table_files : trimsuffix(trimsuffix(f, ".yaml"), ".yml") => f...
    } : "${name} (${join(", ", sort(group))})"
    if length(group) > 1
  ])

  raw_table_entries = [
    for f in local.table_files : {
      source  = f
      content = yamldecode(file("${var.config_dir}/${f}"))
    }
  ]

  tables_missing_namespace_or_name = sort([
    for e in local.raw_table_entries : e.source
    if try(e.content.metadata.namespace, null) == null || try(e.content.metadata.name, null) == null
  ])

  table_entries = [
    for e in local.raw_table_entries : {
      source    = e.source
      namespace = e.content.metadata.namespace
      name      = e.content.metadata.name

      schema = [
        for field in try(e.content.spec.schema.columns, []) : {
          name     = try(field.name, null)
          type     = try(field.type, null)
          required = try(field.required, false)
        }
      ]
      encryption = try(e.content.spec.encryption, null) == null ? null : {
        sse_algorithm = try(e.content.spec.encryption.sse_algorithm, null)
        kms_key_arn   = try(e.content.spec.encryption.kms_key_arn, null)
      }

      policy = try(e.content.spec.policy, null)

      replication = try(e.content.spec.replication, null) == null ? null : {
        role         = try(e.content.spec.replication.role, null)
        destinations = try(e.content.spec.replication.destinations, [])
      }
    } if try(e.content.metadata.namespace, null) != null && try(e.content.metadata.name, null) != null
  ]

  tables_with_orphaned_namespace = sort([
    for e in local.table_entries : "${e.source}: namespace \"${e.namespace}\""
    if !contains([for ns in local.namespace_entries : ns.name], e.namespace)
  ])

  active_table_entries = [
    for e in local.table_entries : e
    if contains(local.namespace_names, e.namespace)
  ]

  invalid_table_names = sort([
    for e in local.active_table_entries : "${e.source}: ${e.name}"
    if !can(regex(local.name_pattern, e.name))
  ])

  tables_with_invalid_columns = sort(flatten([
    for e in local.active_table_entries : [
      for col in e.schema : "${e.source}: column ${jsonencode(col.name)}"
      if col.name == null || col.type == null
    ]
  ]))

  tables_grouped = {
    for e in local.active_table_entries : "${e.namespace}.${e.name}" => e...
  }

  tables = { for key, group in local.tables_grouped : key => group[0] }

  duplicate_tables = sort([
    for key, group in local.tables_grouped :
    "${key} (in ${join(", ", sort([for e in group : e.source]))})"
    if length(group) > 1
  ])
}

resource "terraform_data" "registry_validation" {
  input = {
    namespace_files = local.namespace_files
    table_files     = local.table_files
  }

  lifecycle {
    precondition {
      condition     = length(local.duplicate_table_file_names) == 0
      error_message = "Duplicate table file names: ${join("; ", local.duplicate_table_file_names)}. File names under '${var.config_dir}/tables/' have no meaning to Terraform - namespace and table identity come entirely from each file's own metadata - but two files sharing a name almost always means one is shadowing the other by mistake."
    }

    precondition {
      condition     = length(local.namespaces_missing_name) == 0
      error_message = "These namespace file(s) are missing `metadata.name`: ${join(", ", local.namespaces_missing_name)}. Every namespace file must declare a name."
    }

    precondition {
      condition     = length(local.namespaces_with_empty_environments) == 0
      error_message = "These namespace file(s) declare `spec.environments` but list zero environments: ${join(", ", local.namespaces_with_empty_environments)}. Remove the `spec.environments` key entirely to default to all four environments, or list at least one."
    }

    precondition {
      condition     = length(local.namespaces_with_invalid_environment_names) == 0
      error_message = "These namespace file(s) declare an environment name that isn't one of dev/test/uat/prod: ${join(", ", local.namespaces_with_invalid_environment_names)}. Likely a typo."
    }

    precondition {
      condition     = length(local.namespaces_name_not_matching_file) == 0
      error_message = "These namespace file(s) declare a `metadata.name` that doesn't match the file name: ${join("; ", local.namespaces_name_not_matching_file)}. Not a functional requirement - identity comes from metadata.name, not the file name - but keeping them aligned makes the registry easy to browse."
    }

    precondition {
      condition     = length(local.duplicate_namespaces) == 0
      error_message = "Duplicate namespace definitions: ${join("; ", local.duplicate_namespaces)}. Each namespace must be declared exactly once."
    }

    precondition {
      condition     = length(local.invalid_namespace_names) == 0
      error_message = "Invalid namespace names: ${join("; ", local.invalid_namespace_names)}. Names must be 1-255 characters of lowercase letters, digits and underscores, starting with a letter or digit."
    }

    precondition {
      condition     = length(local.namespace_names_too_long) == 0
      error_message = "Adding the 'edp_${var.environment}_' prefix would push these namespace name(s) over the 255-character AWS limit: ${join(", ", local.namespace_names_too_long)}. Shorten the namespace name in YAML, or set enable_namespace_prefix = false."
    }

    # ─── Table files ────────────────────────────────────────────────────────

    precondition {
      condition     = length(local.tables_missing_namespace_or_name) == 0
      error_message = "These table file(s) are missing `metadata.namespace` and/or `metadata.name`: ${join(", ", local.tables_missing_namespace_or_name)}. Every table file must declare both explicitly."
    }

    precondition {
      condition     = length(local.tables_with_orphaned_namespace) == 0
      error_message = "These table file(s) reference a namespace that has no corresponding namespace YAML file: ${join("; ", local.tables_with_orphaned_namespace)}. Create <namespace>.yaml or fix the reference."
    }

    precondition {
      condition     = length(local.invalid_table_names) == 0
      error_message = "Invalid table names: ${join("; ", local.invalid_table_names)}. Names must be 1-255 characters of lowercase letters, digits and underscores, starting with a letter or digit."
    }

    precondition {
      condition     = length(local.tables_with_invalid_columns) == 0
      error_message = "These schema column(s) are missing `name` and/or `type`: ${join("; ", local.tables_with_invalid_columns)}. Both are required on every column."
    }

    precondition {
      condition     = length(local.duplicate_tables) == 0
      error_message = "Duplicate table definitions: ${join("; ", local.duplicate_tables)}. Each namespace.table pair must be declared exactly once among files active for environment '${var.environment}'."
    }
  }
}

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------

resource "aws_s3tables_namespace" "this" {
  # Keyed by the bare name from YAML; the value is the name as created in AWS.
  for_each = local.namespace_aws_names

  namespace        = each.value
  table_bucket_arn = var.bucket_arn

  depends_on = [terraform_data.registry_validation]
}

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

resource "aws_s3tables_table" "this" {
  for_each = local.tables

  name             = each.value.name
  namespace        = aws_s3tables_namespace.this[each.value.namespace].namespace
  table_bucket_arn = var.bucket_arn
  format           = "ICEBERG"

  encryption_configuration = each.value.encryption == null ? null : {
    sse_algorithm = each.value.encryption.sse_algorithm
    kms_key_arn   = each.value.encryption.kms_key_arn
  }

  dynamic "metadata" {
    for_each = length(each.value.schema) > 0 ? [each.value.schema] : []

    content {
      iceberg {
        schema {
          dynamic "field" {
            for_each = metadata.value
            content {
              name     = field.value.name
              type     = field.value.type
              required = field.value.required
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition = (
        each.value.encryption == null ||
        contains(local.valid_sse_algorithms, coalesce(each.value.encryption.sse_algorithm, "<missing>"))
      )
      error_message = "Table '${each.key}' (${each.value.source}): encryption.sse_algorithm must be one of: ${join(", ", local.valid_sse_algorithms)}."
    }

    precondition {
      condition = (
        each.value.encryption == null ||
        each.value.encryption.sse_algorithm != "aws:kms" ||
        each.value.encryption.kms_key_arn != null
      )
      error_message = "Table '${each.key}' (${each.value.source}): encryption.kms_key_arn is required when encryption.sse_algorithm is \"aws:kms\"."
    }

    precondition {
      condition     = each.value.policy == null || can(jsondecode(each.value.policy))
      error_message = "Table '${each.key}' (${each.value.source}): policy must be a valid JSON document."
    }

    precondition {
      condition = (
        each.value.replication == null ||
        (each.value.replication.role != null && length(each.value.replication.destinations) > 0)
      )
      error_message = "Table '${each.key}' (${each.value.source}): replication requires both `role` and at least one entry in `destinations`."
    }
  }

  depends_on = [terraform_data.registry_validation]
}

# ---------------------------------------------------------------------------
# Table Policy
# ---------------------------------------------------------------------------

resource "aws_s3tables_table_policy" "this" {
  for_each = { for key, tbl in local.tables : key => tbl if tbl.policy != null }

  name             = aws_s3tables_table.this[each.key].name
  namespace        = aws_s3tables_table.this[each.key].namespace
  table_bucket_arn = aws_s3tables_table.this[each.key].table_bucket_arn
  resource_policy  = each.value.policy
}

# ---------------------------------------------------------------------------
# Table Replication
# ---------------------------------------------------------------------------

resource "aws_s3tables_table_replication" "this" {
  for_each = { for key, tbl in local.tables : key => tbl if tbl.replication != null }

  table_arn = aws_s3tables_table.this[each.key].arn
  role      = each.value.replication.role

  dynamic "rule" {
    for_each = each.value.replication.destinations

    content {
      destination {
        destination_table_bucket_arn = rule.value
      }
    }
  }
}
