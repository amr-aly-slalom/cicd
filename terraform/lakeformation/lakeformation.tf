locals {
  # Base / S3 Tables locals
  s3tables_wildcard_arn = "arn:aws:s3tables:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:bucket/*"
  account_id            = data.aws_caller_identity.current.account_id
  s3tables_enabled      = local.environment != "dev"
  # Redshift locals
  namespace_id = one(regex(
    "namespace:([0-9a-fA-F-]+)$",
    data.aws_redshift_cluster.this.cluster_namespace_arn
  ))
  datashare_arn = format(
    "arn:aws:redshift:%s:%s:datashare:%s/ds_internal_namespace",
    var.aws_region, local.account_id, local.namespace_id
  )
  glue_catalog_arn = "arn:aws:glue:${var.aws_region}:${local.account_id}:catalog"

  # Permissions and YAML file parsing locals
  _lakeformation_dir = "${path.root}/../../lakeformation"
  _all_lakeformation_files = {
    for f in fileset(local._lakeformation_dir, "**/*.yaml") :
    f => yamldecode(file("${local._lakeformation_dir}/${f}"))
  }
  _known_kinds = ["LFTagSet", "DatabaseAccess", "TableAccess", "AccessGrant", "TagAssignments"]
  _unknown_kind_files = {
    for f, v in local._all_lakeformation_files : f => v.kind
    if !contains(local._known_kinds, try(v.kind, null))
  }

  # LFTagSet locals
  _lf_tag_set_files = {
    for f, v in local._all_lakeformation_files : f => v
    if v.kind == "LFTagSet"
  }
  _lf_tags_raw = flatten([
    for f, v in local._lf_tag_set_files :
    try(v.spec.tags, [])
  ])
  lf_tag_definitions = {
    for t in local._lf_tags_raw :
    t.key => t.values
    if !contains(keys(t), "environments") || contains(t.environments, local.environment)
  }

  s3tables_catalog_name             = "s3tablescatalog"
  redshift_catalog_name             = aws_glue_catalog.redshift_federated_catalog.name
  s3tables_catalog_exists           = local.s3tables_enabled ? true : tobool(data.external.s3tables_catalog_check[0].result.exists)
  lf_verifier_access_tag_key_exists = local.s3tables_enabled ? true : tobool(data.external.lf_verifier_access_tag_check[0].result.exists)

  # DatabaseAccess / TableAccess locals
  _database_table_access_files = {
    for f, v in local._all_lakeformation_files : f => v
    if contains(["DatabaseAccess", "TableAccess"], v.kind)
  }
  _database_table_access_files_for_env = {
    for k, v in local._database_table_access_files : k => v
    if v.metadata.environments == local.environment
  }
  _database_table_access_resolved = {
    for k, v in local._database_table_access_files_for_env : k => merge(v, {
      _service    = split(".", v.apiVersion)[0]
      _catalog_id = split(".", v.apiVersion)[0] == "redshift" ? "${local.account_id}:${local.redshift_catalog_name}/${v.metadata.catalogName}" : "${local.account_id}:${local.s3tables_catalog_name}/${v.metadata.catalogName}"
    })
  }
  database_table_access_grants = flatten([
    for k, v in local._database_table_access_resolved : concat(
      [
        for g in try(v.spec.groups, []) : {
          key           = "${k}__group__${g.name}"
          principal     = local.group_principal_arns[g.name]
          permissions   = g.grants
          kind          = v.kind
          database_name = v.metadata.databaseName
          table_name    = try(v.metadata.tableName, null)
          catalog_id    = v._catalog_id
        }
      ],
      [
        for r in try(v.spec.iamRoles, []) : {
          key           = "${k}__role__${r.arn}"
          principal     = r.arn
          permissions   = r.grants
          kind          = v.kind
          database_name = v.metadata.databaseName
          table_name    = try(v.metadata.tableName, null)
          catalog_id    = v._catalog_id
        }
      ]
    )
  ])
  _database_table_access_group_names = flatten([
    for k, v in local._database_table_access_files_for_env : [
      for g in try(v.spec.groups, []) : g.name
    ]
  ])

  # AccessGrant locals
  _access_grant_files = {
    for f, v in local._all_lakeformation_files : f => v
    if v.kind == "AccessGrant"
  }
  _access_grant_files_for_env = {
    for k, v in local._access_grant_files : k => v
    if v.metadata.environments == local.environment
  }
  _access_grant_principal_arns = {
    for k, v in local._access_grant_files_for_env :
    k => (
      can(regex("^arn:aws:iam::", v.metadata.principal))
      ? v.metadata.principal
      : local.group_principal_arns[v.metadata.principal]
    )
  }
  access_grants = flatten([
    for k, v in local._access_grant_files_for_env : concat(
      try(v.spec.database, null) != null ? [{
        key           = "${k}__database"
        principal     = local._access_grant_principal_arns[k]
        permissions   = v.spec.database.grants
        resource_type = "DATABASE"
        expressions   = v.spec.tags
      }] : [],
      try(v.spec.table, null) != null ? [{
        key           = "${k}__table"
        principal     = local._access_grant_principal_arns[k]
        permissions   = v.spec.table.grants
        resource_type = "TABLE"
        expressions   = v.spec.tags
      }] : []
    )
  ])
  _access_grant_group_names = [
    for k, v in local._access_grant_files_for_env : v.metadata.principal
    if !can(regex("^arn:aws:iam::", v.metadata.principal))
  ]
  referenced_group_names = distinct(concat(
    local._database_table_access_group_names,
    local._access_grant_group_names,
  ))

  # TagAssignments locals
  _tag_assignment_files = {
    for f, v in local._all_lakeformation_files : f => v
    if v.kind == "TagAssignments"
  }
  _tag_assignment_files_for_env = {
    for k, v in local._tag_assignment_files : k => v
    if v.metadata.environments == local.environment
  }
  _tag_assignment_resolved = {
    for k, v in local._tag_assignment_files_for_env : k => merge(v, {
      _catalog_id = v.metadata.service == "redshift" ? "${local.account_id}:${local.redshift_catalog_name}/${v.metadata.catalogName}" : "${local.account_id}:${local.s3tables_catalog_name}/${v.metadata.catalogName}"
    })
  }
  tag_assignments = {
    for k, v in local._tag_assignment_resolved : k => {
      catalog_id    = v._catalog_id
      database_name = v.metadata.databaseName
      table_name    = try(v.metadata.tableName, null)
      is_table      = try(v.metadata.tableName, null) != null
      tags          = v.spec.tags
    }
  }

  # Grants / Identity Center locals
  idc_index         = index(data.aws_ssoadmin_instances.main.arns, var.idc_instance_arn)
  identity_store_id = data.aws_ssoadmin_instances.main.identity_store_ids[local.idc_index]
  group_principal_arns = {
    for name, g in data.aws_identitystore_group.referenced :
    name => "arn:aws:identitystore:::group/${g.group_id}"
  }
}

data "external" "s3tables_catalog_check" {
  count = local.s3tables_enabled ? 0 : 1

  program = ["bash", "-c", <<-EOT
    if aws glue get-catalog --catalog-id "${local.account_id}:${local.s3tables_catalog_name}" >/dev/null 2>&1; then
      echo '{"exists": "true"}'
    else
      echo '{"exists": "false"}'
    fi
  EOT
  ]
}

data "external" "lf_verifier_access_tag_check" {
  count = local.s3tables_enabled ? 0 : 1

  program = ["bash", "-c", <<-EOT
    if aws lakeformation get-lf-tag --catalog-id "${local.account_id}" --tag-key "${local.lf_verifier_access_tag_key}" >/dev/null 2>&1; then
      echo '{"exists": "true"}'
    else
      echo '{"exists": "false"}'
    fi
  EOT
  ]
}

# ── IAM Identity Centre Integration ───────────────────────────────────────────
resource "aws_lakeformation_identity_center_configuration" "integration" {
  count        = contains(local.distinct_account_envs, local.environment) ? 1 : 0
  instance_arn = var.idc_instance_arn

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

# ── S3 Tables Resources ──────────────────────────────────────────────────────
resource "aws_iam_role" "lf_data_access" {
  count = local.s3tables_enabled ? 1 : 0

  name = "LakeFormationDataAccessRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LakeFormationDataAccessPolicy"
      Effect    = "Allow"
      Principal = { Service = "lakeformation.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:SetContext", "sts:SetSourceIdentity"]
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "s3tables_access" {
  #checkov:skip=CKV_AWS_355: "Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions"
  #checkov:skip=CKV_AWS_290: "Ensure IAM policies does not allow write access without constraints"
  count = local.s3tables_enabled ? 1 : 0

  name = "S3TablesLakeFormationAccess"
  role = aws_iam_role.lf_data_access[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "LakeFormationPermissionsForS3ListTableBucket"
        Effect   = "Allow"
        Action   = ["s3tables:ListTableBuckets"]
        Resource = ["*"]
      },
      {
        Sid    = "LakeFormationDataAccessPermissionsForS3TableBucket"
        Effect = "Allow"
        Action = [
          "s3tables:CreateTableBucket",
          "s3tables:GetTableBucket",
          "s3tables:CreateNamespace",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:DeleteNamespace",
          "s3tables:DeleteTableBucket",
          "s3tables:CreateTable",
          "s3tables:DeleteTable",
          "s3tables:GetTable",
          "s3tables:ListTables",
          "s3tables:RenameTable",
          "s3tables:UpdateTableMetadataLocation",
          "s3tables:GetTableMetadataLocation",
          "s3tables:GetTableData",
          "s3tables:PutTableData",
        ]
        Resource = [local.s3tables_wildcard_arn]
      },
      {
        Sid    = "LakeFormationDataAccessKMS"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })
}

data "aws_lakeformation_data_lake_settings" "current" {}

# The role Terraform runs as (the provider's assumed role, not its STS session).
data "aws_iam_session_context" "deployer" {
  arn = data.aws_caller_identity.current.arn
}

# Everything below that needs Lake Formation admin rights (LF-Tags, grants,
# resource registration, federated catalogs) must depend on this resource, so
# the deployer is an admin before those calls are made.
resource "aws_lakeformation_data_lake_settings" "this" {

  read_only_admins = ["arn:aws:iam::${local.account_id}:role/aws-service-role/redshift.amazonaws.com/AWSServiceRoleForRedshift"]
  admins = distinct(concat(
    tolist(data.aws_lakeformation_data_lake_settings.current.admins),
    [data.aws_iam_session_context.deployer.issuer_arn],
    local.s3tables_enabled ? [aws_iam_role.lf_data_access[0].arn] : [],
  ))
}

resource "aws_lakeformation_resource" "s3tables_registration" {
  count = local.s3tables_enabled ? 1 : 0

  arn                    = local.s3tables_wildcard_arn
  role_arn               = aws_iam_role.lf_data_access[0].arn
  with_federation        = true
  with_privileged_access = true

  depends_on = [aws_iam_role_policy.s3tables_access, aws_lakeformation_data_lake_settings.this]
}

resource "aws_glue_catalog" "s3tables_federated_catalog" {
  count = local.s3tables_enabled ? 1 : 0

  name = "s3tablescatalog"

  federated_catalog {
    connection_name = "aws:s3tables"
    identifier      = local.s3tables_wildcard_arn
  }
  depends_on = [aws_lakeformation_resource.s3tables_registration]
}

####################################################################################################
#  Redshift
####################################################################################################

data "aws_redshift_cluster" "this" {
  cluster_identifier = data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier
  depends_on         = [aws_redshift_namespace_registration.this]
}

resource "aws_iam_role" "redshift_data_transfer" {
  name = "redshift-data-transfer-role-${local.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = ["redshift.amazonaws.com", "glue.amazonaws.com"]
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "redshift_data_transfer" {
  #checkov:skip=CKV_AWS_355: "Ensure no IAM policies documents allow "*" as a statement's resource for restrictable actions"
  #checkov:skip=CKV_AWS_290: "Ensure IAM policies does not allow write access without constraints"
  name = "DataTransferRolePolicy"
  role = aws_iam_role.redshift_data_transfer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "glue-enable-datalake-access"
    Statement = [{
      Sid    = "DataTransferRolePolicy"
      Effect = "Allow"
      Action = [
        "glue:GetCatalog",
        "glue:GetDatabase",
        "glue:GetTable",
        "glue:GetTables",
        "glue:GetPartitions",
        "kms:GenerateDataKey",
        "kms:Decrypt",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_redshift_namespace_registration" "this" {
  consumer_identifier            = format("DataCatalog/%s", local.account_id)
  namespace_type                 = "provisioned"
  provisioned_cluster_identifier = data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier
  depends_on                     = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_redshift_data_share_consumer_association" "this" {
  data_share_arn = local.datashare_arn
  consumer_arn   = local.glue_catalog_arn

  depends_on = [aws_redshift_namespace_registration.this, aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_resource" "datashare" {
  arn                     = local.datashare_arn
  use_service_linked_role = false

  depends_on = [aws_redshift_data_share_consumer_association.this, aws_lakeformation_data_lake_settings.this]
}

resource "aws_glue_catalog" "redshift_federated_catalog" {
  name        = "redshift_managed_lake_${local.environment}"
  description = "Redshift federated catalog"

  federated_catalog {
    connection_name = "aws:redshift"
    identifier      = local.datashare_arn
  }

  catalog_properties {
    data_lake_access_properties {
      data_lake_access   = true
      data_transfer_role = aws_iam_role.redshift_data_transfer.arn
    }
  }

  depends_on = [
    aws_lakeformation_resource.datashare,
    aws_iam_role_policy.redshift_data_transfer,
    aws_lakeformation_data_lake_settings.this
  ]
}

#################################################################
#  Permissions
#################################################################

resource "terraform_data" "lakeformation_known_kinds_check" {
  lifecycle {
    precondition {
      condition     = length(local._unknown_kind_files) == 0
      error_message = "Unrecognized kind in lakeformation/*.yaml file(s): ${jsonencode(local._unknown_kind_files)}. Known kinds: ${join(", ", local._known_kinds)}."
    }
  }
}

# ── Existence checks ─────────────────────────────────────────────────────────

data "aws_glue_catalog_table" "database_table_access_check" {
  for_each = {
    for k, v in local._database_table_access_resolved : k => v
    if v.kind == "TableAccess"
  }

  catalog_id    = each.value._catalog_id
  database_name = each.value.metadata.databaseName
  name          = each.value.metadata.tableName
}

resource "aws_lakeformation_permissions" "database_table_access" {
  for_each = { for g in local.database_table_access_grants : g.key => g }

  principal   = each.value.principal
  permissions = each.value.permissions

  depends_on = [
    aws_lakeformation_resource.s3tables_registration,
    aws_glue_catalog.s3tables_federated_catalog,
    aws_lakeformation_resource.datashare,
    aws_glue_catalog.redshift_federated_catalog,
    aws_lakeformation_identity_center_configuration.integration,
  ]

  dynamic "database" {
    for_each = each.value.kind == "DatabaseAccess" ? [1] : []
    content {
      name       = each.value.database_name
      catalog_id = each.value.catalog_id
    }
  }

  dynamic "table" {
    for_each = each.value.kind == "TableAccess" ? [1] : []
    content {
      database_name = each.value.database_name
      name          = each.value.table_name
      catalog_id    = each.value.catalog_id
    }
  }

  lifecycle {
    precondition {
      condition     = contains(["DatabaseAccess", "TableAccess"], each.value.kind)
      error_message = "database_table_access grant '${each.key}' has kind '${each.value.kind}', but only DatabaseAccess or TableAccess are supported."
    }
  }
}

resource "aws_lakeformation_permissions" "access_grants" {
  for_each = { for g in local.access_grants : g.key => g }

  principal   = each.value.principal
  permissions = each.value.permissions

  depends_on = [
    aws_lakeformation_lf_tag.this,
    aws_lakeformation_resource.s3tables_registration,
    aws_glue_catalog.s3tables_federated_catalog,
    aws_lakeformation_resource.datashare,
    aws_glue_catalog.redshift_federated_catalog,
    aws_lakeformation_identity_center_configuration.integration,
  ]

  lf_tag_policy {
    resource_type = each.value.resource_type
    catalog_id    = local.account_id

    dynamic "expression" {
      for_each = each.value.expressions
      content {
        key    = expression.value.key
        values = expression.value.values
      }
    }
  }

  # lifecycle {
  #   precondition {
  #     condition = alltrue([
  #       for exp in each.value.expressions : contains(keys(local.lf_tag_definitions), exp.key)
  #     ])
  #     error_message = "AccessGrant '${each.key}' references LF-Tag key(s) not defined in lakeformation/lf_tags/*.yaml. Defined keys: ${join(", ", keys(local.lf_tag_definitions))}."
  #   }

  #   precondition {
  #     condition = alltrue([
  #       for exp in each.value.expressions : alltrue([
  #         for v in exp.values : contains(try(local.lf_tag_definitions[exp.key], []), v)
  #       ])
  #     ])
  #     error_message = "AccessGrant '${each.key}' references LF-Tag value(s) not defined for their key in lakeformation/lf_tags/*.yaml."
  #   }
  # }
}

resource "aws_lakeformation_resource_lf_tags" "tag_assignments" {
  for_each = local.tag_assignments

  depends_on = [
    aws_lakeformation_lf_tag.this,
    aws_lakeformation_resource.s3tables_registration,
    aws_glue_catalog.s3tables_federated_catalog,
    aws_lakeformation_resource.datashare,
    aws_glue_catalog.redshift_federated_catalog,
  ]

  dynamic "database" {
    for_each = each.value.is_table ? [] : [1]
    content {
      name       = each.value.database_name
      catalog_id = each.value.catalog_id
    }
  }

  dynamic "table" {
    for_each = each.value.is_table ? [1] : []
    content {
      name          = each.value.table_name
      database_name = each.value.database_name
      catalog_id    = each.value.catalog_id
    }
  }

  dynamic "lf_tag" {
    for_each = each.value.tags
    content {
      key   = lf_tag.value.key
      value = lf_tag.value.value
    }
  }

  # lifecycle {
  #   precondition {
  #     condition = alltrue([
  #       for t in each.value.tags : contains(keys(local.lf_tag_definitions), t.key)
  #     ])
  #     error_message = "TagAssignments '${each.key}' references LF-Tag key(s) not defined in lakeformation/lf_tags/*.yaml. Defined keys: ${join(", ", keys(local.lf_tag_definitions))}."
  #   }

  #   precondition {
  #     condition = alltrue([
  #       for t in each.value.tags : contains(try(local.lf_tag_definitions[t.key], []), t.value)
  #     ])
  #     error_message = "TagAssignments '${each.key}' references an LF-Tag value not defined for its key in lakeformation/lf_tags/*.yaml."
  #   }
  # }
}

# ── Lake Formation LF-Tags Definitions & Permissions ────────────────────────
resource "aws_lakeformation_lf_tag" "this" {
  for_each = local.s3tables_enabled ? local.lf_tag_definitions : {}

  key        = each.key
  values     = each.value
  catalog_id = local.account_id

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

data "aws_identitystore_group" "referenced" {
  for_each = toset(local.referenced_group_names)

  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "DisplayName"
      attribute_value = each.value
    }
  }
}

#################################################################
# Governance LF-Tags
#################################################################

locals {
  baseline_governance_tags = {
    Organisation = {
      description      = "Business entity that owns the data"
      governance_owner = "Data Governance Team"
      values = [
        "CitiPower",
        "Powercor",
        "UnitedEnergy",
        "CHED",
        "Shared",
      ]
    }
    Domain = {
      description      = "Business data domain"
      governance_owner = "Domain Data Owner"
      values = [
        "Network",
        "Customer",
        "Asset",
        "Operations",
        "Finance",
        "Reference",
      ]
    }
    Layer = {
      description      = "Medallion lifecycle layer"
      governance_owner = "Platform Engineering"
      values = [
        "Landing",
        "Raw",
        "Conformed",
        "Modelled",
      ]
    }
    Sensitivity = {
      description      = "CHED Information Classification"
      governance_owner = "Data Governance Team"
      values = [
        "Public",
        "Internal",
        "Restricted",
        "HighlyRestricted",
        "PersonalInformation",
      ]
    }
    PII = {
      description      = "Contains Personally Identifiable Information"
      governance_owner = "Privacy Officer"
      values = [
        "True",
        "False",
      ]
    }
    SourceSystem = {
      description      = "Originating source system"
      governance_owner = "Source System Owner"
      values = [
        "NAP",
        "SNAP",
        "SAP",
        "GIS-GSA",
        "AvedaPI-SCADA",
        "SIQ",
        "UIQ",
        "DMS-OMS-ADMS",
        "EDNAR",
        "NARS",
        "MSATS",
        "CIS-OV",
        "MTS",
        "IEE",
        "Salesforce",
        "BOM",
        "WeatherCo",
        "External",
        "Unknown",
      ]
    }
    DataSubjectType = {
      description      = "Type of data subject"
      governance_owner = "Privacy Officer / Data Governance"
      values = [
        "Customer",
        "Employee",
        "ThirdParty",
        "NotApplicable",
      ]
    }
    RetentionClass = {
      description      = "Data retention obligation class"
      governance_owner = "Legal / Compliance"
      values = [
        "Transient",
        "MediumTerm",
        "LongTerm",
        "Regulatory",
        "Indefinite",
      ]
    }
    Environment = {
      description      = "Deployment environment"
      governance_owner = "EDP Platform Team"
      values = [
        "Dev",
        "Test",
        "UAT",
        "Prod",
      ]
    }
  }
}

resource "aws_lakeformation_lf_tag" "baseline_governance_tags" {
  for_each = local.s3tables_enabled ? local.baseline_governance_tags : {}

  key        = each.key
  values     = each.value.values
  catalog_id = local.account_id

  depends_on = [aws_lakeformation_data_lake_settings.this]
}


####################################################################################################
#  Lake Formation Permissions E2E Verifier
####################################################################################################


locals {
  lf_verifier_s3tables_namespace    = "lf_permissions_verifier"
  lf_verifier_s3tables_table_name   = "lf_permissions_verifier_probe"
  lf_verifier_redshift_schema_name  = "public"
  lf_verifier_redshift_table_name   = "lf_permissions_verifier_probe"
  lf_verifier_log_retention         = local.is_prod_like ? 30 : 7
  lf_verifier_athena_results_bucket = module.lf_verifier_athena_results_s3.s3_bucket_id
  lf_verifier_redshift_db_name      = "dev"
  lf_verifier_s3tables_catalog_id   = "${local.account_id}:${local.s3tables_catalog_name}/${element(split("/", data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn), 1)}"
  lf_verifier_redshift_catalog_id   = "${local.account_id}:${aws_glue_catalog.redshift_federated_catalog.name}/${local.lf_verifier_redshift_db_name}"
}

resource "aws_iam_role" "lf_verifier_setup" {
  name        = "chedaws-edp-lf-e2e-verifier-setup-${local.environment}"
  description = "Broad-rights role used only to create/seed/clean up the Lake Formation permissions verifier's probe table. Never used for the actual access-boundary assertions."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lf_verifier_lambda_execution.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}


resource "aws_iam_role" "lf_verifier_target_resource_permission" {
  name        = "chedaws-edp-lf-e2e-verifier-target-resource-permission-${local.environment}"
  description = "Deliberately limited (SELECT + DESCRIBE only, granted via a named Data Catalog resource grant) role. The Lake Formation permissions verifier Lambda assumes this role to confirm the named-resource permission mechanism grants access as expected and denies non-granted operations."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lf_verifier_lambda_execution.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role" "lf_verifier_target_lf_tag" {
  name        = "chedaws-edp-lf-e2e-verifier-target-lf-tag-${local.environment}"
  description = "Deliberately limited (SELECT + DESCRIBE only, granted via an LF-Tag expression) role. The Lake Formation permissions verifier Lambda assumes this role to confirm the LF-Tag permission mechanism grants access as expected and denies non-granted operations."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lf_verifier_lambda_execution.arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_s3tables_namespace" "lf_verifier" {
  namespace        = local.lf_verifier_s3tables_namespace
  table_bucket_arn = data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn
}

# ── Dedicated LF-Tag (tag-based mechanism under test) ───────────────────────
locals {
  lf_verifier_access_tag_key = "LFPermissionsVerifierAccess"
}

resource "aws_lakeformation_lf_tag" "lf_verifier_access" {
  count = local.s3tables_enabled ? 1 : 0

  key        = local.lf_verifier_access_tag_key
  values     = ["Granted"]
  catalog_id = local.account_id

  depends_on = [aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_resource_lf_tags" "lf_verifier_access_s3tables_database" {
  count = local.s3tables_catalog_exists ? 1 : 0

  database {
    name       = local.lf_verifier_s3tables_namespace
    catalog_id = local.lf_verifier_s3tables_catalog_id
  }

  lf_tag {
    key   = local.lf_verifier_access_tag_key
    value = "Granted"
  }

  depends_on = [aws_s3tables_namespace.lf_verifier, aws_lakeformation_lf_tag.lf_verifier_access, aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_resource_lf_tags" "lf_verifier_access_redshift_database" {
  count = local.lf_verifier_access_tag_key_exists ? 1 : 0

  database {
    name       = local.lf_verifier_redshift_schema_name
    catalog_id = local.lf_verifier_redshift_catalog_id
  }

  lf_tag {
    key   = local.lf_verifier_access_tag_key
    value = "Granted"
  }
}

resource "aws_lakeformation_permissions" "lf_verifier_setup_s3tables_database" {
  count = local.s3tables_catalog_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_setup.arn
  permissions = ["CREATE_TABLE", "DESCRIBE"]

  database {
    name       = local.lf_verifier_s3tables_namespace
    catalog_id = local.lf_verifier_s3tables_catalog_id
  }

  depends_on = [aws_s3tables_namespace.lf_verifier, aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_permissions" "lf_verifier_setup_s3tables_table" {
  count = local.s3tables_catalog_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_setup.arn
  permissions = ["ALTER", "DROP", "DESCRIBE", "SELECT", "INSERT", "DELETE"]

  table {
    database_name = local.lf_verifier_s3tables_namespace
    catalog_id    = local.lf_verifier_s3tables_catalog_id
    wildcard      = true
  }

  depends_on = [aws_s3tables_namespace.lf_verifier, aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_permissions" "lf_verifier_target_resource_permission_s3tables" {
  count = local.s3tables_catalog_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_target_resource_permission.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = local.lf_verifier_s3tables_namespace
    catalog_id    = local.lf_verifier_s3tables_catalog_id
    wildcard      = true
  }

  depends_on = [aws_s3tables_namespace.lf_verifier, aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_permissions" "lf_verifier_target_lf_tag_s3tables" {
  count = local.s3tables_catalog_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_target_lf_tag.arn
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"
    catalog_id    = local.account_id

    expression {
      key    = local.lf_verifier_access_tag_key
      values = ["Granted"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.lf_verifier_access_s3tables_database]
}

resource "aws_lakeformation_permissions" "lf_verifier_target_lf_tag_s3tables_database" {
  count = local.s3tables_catalog_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_target_lf_tag.arn
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"
    catalog_id    = local.account_id

    expression {
      key    = local.lf_verifier_access_tag_key
      values = ["Granted"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.lf_verifier_access_s3tables_database]
}

# ── CATALOG-level visibility for the LF-Tag role (second half of the fix) ──

resource "aws_lakeformation_permissions" "lf_verifier_target_lf_tag_s3tables_catalog_visibility" {
  count = local.s3tables_catalog_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_target_lf_tag.arn
  permissions = ["DESCRIBE"]

  database {
    name       = local.lf_verifier_s3tables_namespace
    catalog_id = local.lf_verifier_s3tables_catalog_id
  }

  depends_on = [aws_s3tables_namespace.lf_verifier, aws_lakeformation_data_lake_settings.this]
}

resource "aws_lakeformation_permissions" "lf_verifier_setup_redshift" {
  principal   = aws_iam_role.lf_verifier_setup.arn
  permissions = ["DESCRIBE", "SELECT", "INSERT", "DELETE"]

  table {
    database_name = local.lf_verifier_redshift_schema_name
    catalog_id    = local.lf_verifier_redshift_catalog_id
    wildcard      = true
  }
}

resource "aws_lakeformation_permissions" "lf_verifier_target_resource_permission_redshift" {
  principal   = aws_iam_role.lf_verifier_target_resource_permission.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = local.lf_verifier_redshift_schema_name
    catalog_id    = local.lf_verifier_redshift_catalog_id
    wildcard      = true
  }
}

resource "aws_lakeformation_permissions" "lf_verifier_target_lf_tag_redshift" {
  count = local.lf_verifier_access_tag_key_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_target_lf_tag.arn
  permissions = ["SELECT", "DESCRIBE"]

  lf_tag_policy {
    resource_type = "TABLE"
    catalog_id    = local.account_id

    expression {
      key    = local.lf_verifier_access_tag_key
      values = ["Granted"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.lf_verifier_access_redshift_database]
}

resource "aws_lakeformation_permissions" "lf_verifier_target_lf_tag_redshift_database" {
  count = local.lf_verifier_access_tag_key_exists ? 1 : 0

  principal   = aws_iam_role.lf_verifier_target_lf_tag.arn
  permissions = ["DESCRIBE"]

  lf_tag_policy {
    resource_type = "DATABASE"
    catalog_id    = local.account_id

    expression {
      key    = local.lf_verifier_access_tag_key
      values = ["Granted"]
    }
  }

  depends_on = [aws_lakeformation_resource_lf_tags.lf_verifier_access_redshift_database]
}

resource "aws_lakeformation_permissions" "lf_verifier_target_lf_tag_redshift_catalog_visibility" {
  principal   = aws_iam_role.lf_verifier_target_lf_tag.arn
  permissions = ["DESCRIBE"]

  database {
    name       = local.lf_verifier_redshift_schema_name
    catalog_id = local.lf_verifier_redshift_catalog_id
  }
}

resource "aws_iam_role_policy" "lf_verifier_setup" {
  #checkov:skip=CKV_AWS_290: Athena/Glue/Redshift Data API actions on this role's own probe resources require wildcard-shaped ARNs (query execution IDs, statement IDs, partitions); scope is limited to this verifier's own dedicated workgroup/database/table
  #checkov:skip=CKV_AWS_355: See above
  name = "lf-e2e-verifier-setup-policy"
  role = aws_iam_role.lf_verifier_setup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
        ]
        Resource = "*"
      },
      {
        Sid    = "AthenaResultsAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.lf_verifier_athena_results_bucket}",
          "arn:aws:s3:::${local.lf_verifier_athena_results_bucket}/*",
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueRead"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:CreateTable",
          "glue:UpdateTable",
        ]
        Resource = "*"
      },
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Sid    = "S3TablesMetadataAccess"
        Effect = "Allow"
        Action = [
          "s3tables:GetTableBucket",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:GetTable",
          "s3tables:ListTables",
          "s3tables:CreateTable",
          "s3tables:UpdateTableMetadataLocation",
          "s3tables:GetTableMetadataLocation",
          "s3tables:GetTableData",
          "s3tables:PutTableData",
        ]
        Resource = [
          data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn,
          "${data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn}/*",
        ]
      },
      {
        Sid    = "RedshiftDataApiSetup"
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:DescribeStatement",
          "redshift-data:GetStatementResult",
          "redshift-data:CancelStatement",
          "redshift:GetClusterCredentialsWithIAM",
          "redshift-serverless:GetCredentials",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "lf_verifier_target_resource_permission" {
  #checkov:skip=CKV_AWS_290: Same rationale as lf_verifier_setup above
  #checkov:skip=CKV_AWS_355: Same rationale as lf_verifier_setup above
  name = "lf-e2e-verifier-target-resource-permission-policy"
  role = aws_iam_role.lf_verifier_target_resource_permission.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
        ]
        Resource = "*"
      },
      {
        Sid    = "AthenaResultsAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.lf_verifier_athena_results_bucket}",
          "arn:aws:s3:::${local.lf_verifier_athena_results_bucket}/*",
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueRead"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:UpdateTable",
        ]
        Resource = "*"
      },
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Sid    = "S3TablesMetadataAccess"
        Effect = "Allow"
        Action = [
          "s3tables:GetTableBucket",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:GetTable",
          "s3tables:ListTables",
          "s3tables:GetTableMetadataLocation",
          "s3tables:GetTableData",
        ]
        Resource = [
          data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn,
          "${data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn}/*",
        ]
      },
      {
        Sid    = "RedshiftDataApiTarget"
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:DescribeStatement",
          "redshift-data:GetStatementResult",
          "redshift:GetClusterCredentialsWithIAM",
          "redshift-serverless:GetCredentials",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "lf_verifier_target_lf_tag" {
  #checkov:skip=CKV_AWS_290: Same rationale as lf_verifier_setup above
  #checkov:skip=CKV_AWS_355: Same rationale as lf_verifier_setup above
  name = "lf-e2e-verifier-target-lf-tag-policy"
  role = aws_iam_role.lf_verifier_target_lf_tag.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQueryExecution"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
        ]
        Resource = "*"
      },
      {
        Sid    = "AthenaResultsAccess"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${local.lf_verifier_athena_results_bucket}",
          "arn:aws:s3:::${local.lf_verifier_athena_results_bucket}/*",
        ]
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
      {
        Sid    = "GlueRead"
        Effect = "Allow"
        Action = [
          "glue:GetCatalog",
          "glue:GetDatabase",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
          "glue:UpdateTable",
        ]
        Resource = "*"
      },
      {
        Sid      = "LakeFormationDataAccess"
        Effect   = "Allow"
        Action   = ["lakeformation:GetDataAccess"]
        Resource = "*"
      },
      {
        Sid    = "S3TablesMetadataAccess"
        Effect = "Allow"
        Action = [
          "s3tables:GetTableBucket",
          "s3tables:GetNamespace",
          "s3tables:ListNamespaces",
          "s3tables:GetTable",
          "s3tables:ListTables",
          "s3tables:GetTableMetadataLocation",
          "s3tables:GetTableData",
        ]
        Resource = [
          data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn,
          "${data.terraform_remote_state.s3tables.outputs.s3tables_table_bucket_arn}/*",
        ]
      },
      {
        Sid    = "RedshiftDataApiTarget"
        Effect = "Allow"
        Action = [
          "redshift-data:ExecuteStatement",
          "redshift-data:DescribeStatement",
          "redshift-data:GetStatementResult",
          "redshift:GetClusterCredentialsWithIAM",
          "redshift-serverless:GetCredentials",
        ]
        Resource = "*"
      },
    ]
  })
}

data "aws_iam_policy_document" "lf_verifier_athena_results" {
  statement {
    sid     = "DenyWrongEncryptionAlgorithm"
    effect  = "Deny"
    actions = ["s3:PutObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["_S3_BUCKET_ARN_/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms", "AES256"]
    }
  }
}

module "lf_verifier_athena_results_s3" {
  #checkov:skip=CKV_AWS_18: "Ensure the S3 bucket has access logging enabled"
  #checkov:skip=CKV_AWS_144: "Ensure that S3 bucket has cross-region replication enabled"
  #checkov:skip=CKV_TF_1: registry source with pinned version is the correct alternative to a git commit hash
  #checkov:skip=CKV_AWS_145: "Ensure that S3 buckets are encrypted with KMS by default"
  #checkov:skip=CKV_AWS_21: "Ensure all data stored in the S3 bucket have versioning enabled"
  #checkov:skip=CKV_AWS_300: "Ensure S3 lifecycle configuration sets period for aborting failed uploads"
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.14.1"

  bucket = "chedaws-edp-lf-e2e-verifier-athena-results-${local.environment}"

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn
      }
      bucket_key_enabled = true
    }
  }

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle_rule = [
    {
      id      = "expire-query-results"
      enabled = true

      abort_incomplete_multipart_upload = {
        days_after_initiation = 7
      }

      expiration = {
        days = 7
      }

      noncurrent_version_expiration = {
        noncurrent_days = 7
      }
    }
  ]

  attach_policy = true
  policy        = data.aws_iam_policy_document.lf_verifier_athena_results.json

  tags = {
    Name = "chedaws-edp-lf-e2e-verifier-athena-results-${local.environment}"
  }
}

#trivy:ignore:AWS-0006 Ensure that Athena Workgroup is encrypted
resource "aws_athena_workgroup" "lf_verifier" {
  #checkov:skip=CKV_AWS_159: "Ensure that Athena Workgroup is encrypted"
  name = "chedaws-edp-lf-e2e-verifier-${local.environment}"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${local.lf_verifier_athena_results_bucket}/athena-query-results/lf-e2e-verifier/"
    }
  }

  tags = {
    Name = "chedaws-edp-lf-e2e-verifier-${local.environment}"
  }
}

resource "aws_iam_role" "lf_verifier_lambda_execution" {
  name        = "chedaws-edp-lf-e2e-verifier-lambda-${local.environment}"
  description = "Lambda execution role for the Lake Formation permissions verifier - assumes the setup role and both target roles (lf_verifier_target_resource_permission, lf_verifier_target_lf_tag) via sts:AssumeRole and manages probe table lifecycle"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "lf_verifier_lambda_execution" {
  name = "lf-e2e-verifier-lambda-execution-policy"
  role = aws_iam_role.lf_verifier_lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AssumeVerifierRoles"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          aws_iam_role.lf_verifier_setup.arn,
          aws_iam_role.lf_verifier_target_resource_permission.arn,
          aws_iam_role.lf_verifier_target_lf_tag.arn,
        ]
      },
      {
        Sid      = "EmitMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
      },
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:*:*:log-group:/chedaws-edp/lf-e2e-verifier/${local.environment}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "lf_verifier" {
  name              = "/chedaws-edp/lf-e2e-verifier/${local.environment}"
  retention_in_days = local.lf_verifier_log_retention
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "chedaws-edp-lf-e2e-verifier-logs-${local.environment}"
  }
}

resource "terraform_data" "build_lf_verifier_zip" {
  triggers_replace = [
    filemd5("${path.root}/../../lambda/lakeformation-permissions-verifier/handler.py"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      (cd ${path.root}/../../lambda/lakeformation-permissions-verifier && zip -j handler.zip handler.py)
    EOT
  }
}

resource "aws_s3_object" "lf_verifier_lambda" {
  depends_on             = [terraform_data.build_lf_verifier_zip]
  bucket                 = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  key                    = "e2e/lf-e2e-verifier/handler.zip"
  source                 = "${path.root}/../../lambda/lakeformation-permissions-verifier/handler.zip"
  source_hash            = filemd5("${path.root}/../../lambda/lakeformation-permissions-verifier/handler.py")
  server_side_encryption = "aws:kms"
  kms_key_id             = data.terraform_remote_state.core.outputs.platform_s3_kms_key_arn

  # source is only where the zip is built locally; the object's content is
  # tracked by source_hash, a hash of the files the zip is built from. Ignoring
  # source keeps a change to that local path (e.g. this module moving
  # directory) from re-uploading a zip this checkout never built.
  lifecycle {
    ignore_changes = [source]
  }
}

#trivy:ignore:AWS-0066 X-Ray tracing not required for scheduled synthetic verifier
resource "aws_lambda_function" "lf_verifier" {
  #checkov:skip=CKV_AWS_117: Glue/Athena/STS APIs are public; VPC not required for this scheduled synthetic verifier
  #checkov:skip=CKV_AWS_173: Lambda env vars contain non-secret config; KMS envelope encryption not required
  #checkov:skip=CKV_AWS_50: X-Ray tracing not required for scheduled synthetic verifier
  #checkov:skip=CKV_AWS_272: Code-signing not used in this project
  #checkov:skip=CKV_AWS_116: Scheduled synthetic verifier; DLQ not applicable
  function_name                  = "chedaws-edp-lf-e2e-verifier-${local.environment}"
  role                           = aws_iam_role.lf_verifier_lambda_execution.arn
  handler                        = "handler.lambda_handler"
  runtime                        = "python3.12"
  timeout                        = local.is_prod_like ? 300 : 240
  memory_size                    = local.is_prod_like ? 512 : 256
  reserved_concurrent_executions = 2

  s3_bucket         = data.terraform_remote_state.core.outputs.platform_s3_bucket_name
  s3_key            = aws_s3_object.lf_verifier_lambda.key
  s3_object_version = aws_s3_object.lf_verifier_lambda.version_id

  environment {
    variables = {
      ENVIRONMENT                         = local.environment
      METRICS_NAMESPACE                   = "ChedawsEDP/LFE2EVerifier"
      SETUP_ROLE_ARN                      = aws_iam_role.lf_verifier_setup.arn
      TARGET_ROLE_ARN_RESOURCE_PERMISSION = aws_iam_role.lf_verifier_target_resource_permission.arn
      TARGET_ROLE_ARN_LF_TAG              = aws_iam_role.lf_verifier_target_lf_tag.arn
      ATHENA_WORKGROUP                    = aws_athena_workgroup.lf_verifier.name
      ATHENA_QUERY_TIMEOUT_SECONDS        = tostring(local.is_prod_like ? 90 : 30)
      S3TABLES_CATALOG_ID                 = local.lf_verifier_s3tables_catalog_id
      S3TABLES_DATABASE_NAME              = local.lf_verifier_s3tables_namespace
      S3TABLES_TABLE_NAME                 = local.lf_verifier_s3tables_table_name
      S3TABLES_REGION                     = var.aws_region
      REDSHIFT_CATALOG_ID                 = local.lf_verifier_redshift_catalog_id
      REDSHIFT_DATABASE_NAME              = local.lf_verifier_redshift_schema_name
      REDSHIFT_TABLE_NAME                 = local.lf_verifier_redshift_table_name
      REDSHIFT_REGION                     = var.aws_region
      REDSHIFT_CLUSTER_IDENTIFIER         = data.terraform_remote_state.redshift.outputs.redshift_cluster_identifier
      REDSHIFT_DB_NAME                    = local.lf_verifier_redshift_db_name
    }
  }

  logging_config {
    log_group  = aws_cloudwatch_log_group.lf_verifier.name
    log_format = "Text"
  }

  depends_on = [
    aws_cloudwatch_log_group.lf_verifier,
    aws_athena_workgroup.lf_verifier,
    aws_s3tables_namespace.lf_verifier,
    aws_lakeformation_permissions.lf_verifier_setup_s3tables_database,
    aws_lakeformation_permissions.lf_verifier_setup_s3tables_table,
    aws_lakeformation_permissions.lf_verifier_setup_redshift,
    aws_lakeformation_permissions.lf_verifier_target_resource_permission_s3tables,
    aws_lakeformation_permissions.lf_verifier_target_resource_permission_redshift,
    aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables,
    aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables_database,
    aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables_catalog_visibility,
    aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift,
    aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift_database,
    aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift_catalog_visibility,
    aws_lakeformation_resource_lf_tags.lf_verifier_access_s3tables_database,
    aws_lakeformation_resource_lf_tags.lf_verifier_access_redshift_database,
  ]

  tags = {
    Name = "chedaws-edp-lf-e2e-verifier-${local.environment}"
  }
}

resource "aws_cloudwatch_event_rule" "lf_verifier_schedule" {
  name                = "chedaws-edp-lf-e2e-verifier-schedule-${local.environment}"
  description         = "Triggers Lake Formation permissions verifier Lambda daily at 07:00 UTC in ${local.environment}"
  schedule_expression = "cron(0 7 * * ? *)"
  state               = "ENABLED"

  tags = {
    Name = "chedaws-edp-lf-e2e-verifier-schedule-${local.environment}"
  }
}

resource "aws_cloudwatch_event_target" "lf_verifier" {
  rule      = aws_cloudwatch_event_rule.lf_verifier_schedule.name
  target_id = "LFPermissionsVerifierLambda"
  arn       = aws_lambda_function.lf_verifier.arn
}

resource "aws_lambda_permission" "lf_verifier_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lf_verifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.lf_verifier_schedule.arn
}

# ── CloudWatch Alarms ────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "lf_e2e_s3tables_resource_permission_positive_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-s3tables-resource-permission-positive-failure-${local.environment}"
  alarm_description = "The S3 Tables verifier's named-resource-permission target role could NOT perform a granted (SELECT/DESCRIBE) operation in the last 24 hours in ${local.environment}. This means the named Data Catalog resource grant (aws_lakeformation_permissions.lf_verifier_target_resource_permission_s3tables) is broken or missing. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "S3TablesResourcePermissionPositiveCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-s3tables-resource-permission-positive-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_s3tables_resource_permission_negative_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-s3tables-resource-permission-negative-failure-${local.environment}"
  alarm_description = "The S3 Tables verifier's named-resource-permission target role was able to perform a NON-granted operation (INSERT) in the last 24 hours in ${local.environment}. This is an over-permission / security boundary failure - investigate immediately. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "S3TablesResourcePermissionNegativeCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-s3tables-resource-permission-negative-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_s3tables_lf_tag_positive_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-s3tables-lf-tag-positive-failure-${local.environment}"
  alarm_description = "The S3 Tables verifier's LF-Tag target role could NOT perform a granted (SELECT/DESCRIBE) operation in the last 24 hours in ${local.environment}. This means the LF-Tag-based grant (aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables, LFPermissionsVerifierAccess=Granted) is broken or missing. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "S3TablesLfTagPositiveCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-s3tables-lf-tag-positive-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_s3tables_lf_tag_negative_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-s3tables-lf-tag-negative-failure-${local.environment}"
  alarm_description = "The S3 Tables verifier's LF-Tag target role was able to perform a NON-granted operation (INSERT) in the last 24 hours in ${local.environment}. This is an over-permission / security boundary failure on the LF-Tag mechanism - investigate immediately. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "S3TablesLfTagNegativeCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-s3tables-lf-tag-negative-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_redshift_resource_permission_positive_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-redshift-resource-permission-positive-failure-${local.environment}"
  alarm_description = "The Redshift verifier's named-resource-permission target role could NOT perform a granted (SELECT/DESCRIBE) operation in the last 24 hours in ${local.environment}. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "RedshiftResourcePermissionPositiveCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-redshift-resource-permission-positive-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_redshift_resource_permission_negative_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-redshift-resource-permission-negative-failure-${local.environment}"
  alarm_description = "The Redshift verifier's named-resource-permission target role was able to perform a NON-granted operation (INSERT) in the last 24 hours in ${local.environment}. This is an over-permission / security boundary failure - investigate immediately. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "RedshiftResourcePermissionNegativeCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-redshift-resource-permission-negative-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_redshift_lf_tag_positive_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-redshift-lf-tag-positive-failure-${local.environment}"
  alarm_description = "The Redshift verifier's LF-Tag target role could NOT perform a granted (SELECT/DESCRIBE) operation in the last 24 hours in ${local.environment}. This means the LF-Tag-based grant (aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift, LFPermissionsVerifierAccess=Granted) is broken or missing. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "RedshiftLfTagPositiveCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-redshift-lf-tag-positive-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_redshift_lf_tag_negative_failure" {
  alarm_name        = "chedaws-edp-lf-e2e-redshift-lf-tag-negative-failure-${local.environment}"
  alarm_description = "The Redshift verifier's LF-Tag target role was able to perform a NON-granted operation (INSERT) in the last 24 hours in ${local.environment}. This is an over-permission / security boundary failure on the LF-Tag mechanism - investigate immediately. Check CloudWatch Logs at /chedaws-edp/lf-e2e-verifier/${local.environment}."

  namespace   = "ChedawsEDP/LFE2EVerifier"
  metric_name = "RedshiftLfTagNegativeCheckSuccess"

  dimensions = {
    Environment = local.environment
  }

  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-redshift-lf-tag-negative-failure-${local.environment}"
  }
}

resource "aws_cloudwatch_metric_alarm" "lf_e2e_lambda_errors" {
  alarm_name        = "chedaws-edp-lf-e2e-lambda-errors-${local.environment}"
  alarm_description = "Lake Formation permissions verifier Lambda invocation errors in ${local.environment}. Check /chedaws-edp/lf-e2e-verifier/${local.environment} for details."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"

  dimensions = {
    FunctionName = aws_lambda_function.lf_verifier.function_name
  }

  statistic           = "Sum"
  period              = 86400
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  alarm_actions = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  tags = {
    Name = "chedaws-edp-lf-e2e-lambda-errors-${local.environment}"
  }
}
