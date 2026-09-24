# ── Credentials ───────────────────────────────────────────────────────────────

resource "random_password" "redshift" {
  length           = 32
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "redshift_password" {
  #checkov:skip=CKV2_AWS_57: Automatic rotation requires a custom Lambda rotation function which is out of scope for this feature; password lifecycle is managed by cluster replace
  name                    = "/chedaws-edp/${local.environment}/redshift/master-password"
  kms_key_id              = data.terraform_remote_state.core.outputs.redshift_kms_key_arn
  description             = "Redshift master password for chedaws-edp-${local.environment}"
  recovery_window_in_days = 7

  tags = {
    Name = "chedaws-edp-redshift-secret-${local.environment}"
  }
}

resource "aws_secretsmanager_secret_version" "redshift_password" {
  secret_id = aws_secretsmanager_secret.redshift_password.id
  secret_string = jsonencode({
    username = "edpadmin"
    password = random_password.redshift.result
  })
}

# ── Parameter Group ───────────────────────────────────────────────────────────

resource "aws_redshift_parameter_group" "this" {
  name        = "chedaws-edp-redshift-params-${local.environment}"
  family      = "redshift-2.0"
  description = "Parameter group for chedaws-edp-${local.environment} Redshift cluster"

  parameter {
    name  = "require_ssl"
    value = "true"
  }

  parameter {
    name  = "enable_case_sensitive_identifier"
    value = "true"
  }
}

# ── Subnet Group ──────────────────────────────────────────────────────────────

resource "aws_redshift_subnet_group" "this" {
  name        = "chedaws-edp-redshift-subnet-group-${local.environment}"
  subnet_ids  = data.aws_subnets.db.ids
  description = "Subnet group for chedaws-edp-${local.environment} Redshift cluster"

  tags = {
    Name = "chedaws-edp-redshift-subnet-group-${local.environment}"
  }
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "redshift" {
  name        = "chedaws-edp-redshift-sg-${local.environment}"
  description = "Security group for chedaws-edp-${local.environment} Redshift cluster"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    from_port   = 5439
    to_port     = 5439
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
    description = "Redshift access from VPC"
  }

  dynamic "ingress" {
    for_each = length(local.redshift_vpn_cidrs) > 0 ? [1] : []
    content {
      from_port   = 5439
      to_port     = 5439
      protocol    = "tcp"
      cidr_blocks = local.redshift_vpn_cidrs
      description = "Redshift access from on-prem VPN (dev/test only)"
    }
  }

  # Redshift reaches AWS APIs (S3, KMS, CloudWatch, Secrets Manager) and its
  # own package/extension mirrors via NAT, not a VPC endpoint; restrict
  # further only once VPC endpoints exist for these services.
  #trivy:ignore:AWS-0104
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name = "chedaws-edp-redshift-sg-${local.environment}"
  }
}

# ── CloudWatch Log Group ──────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "redshift" {
  name              = "/chedaws-edp/redshift/${local.environment}"
  retention_in_days = local.log_retention_days
  kms_key_id        = data.terraform_remote_state.core.outputs.cloudwatch_logs_kms_key_arn

  tags = {
    Name = "/chedaws-edp/redshift/${local.environment}"
  }
}

# ── Cluster & Logging ─────────────────────────────────────────────────────────

resource "aws_redshift_cluster" "this" {
  #checkov:skip=CKV_AWS_71: Audit logging is configured via aws_redshift_logging.this (separate resource, AWS provider v5+ recommended pattern)
  cluster_identifier                  = "chedaws-edp-${local.environment}"
  database_name                       = "edp"
  master_username                     = jsondecode(aws_secretsmanager_secret_version.redshift_password.secret_string)["username"]
  master_password                     = jsondecode(aws_secretsmanager_secret_version.redshift_password.secret_string)["password"]
  node_type                           = local.redshift_node_type
  number_of_nodes                     = 2
  cluster_type                        = "multi-node"
  cluster_subnet_group_name           = aws_redshift_subnet_group.this.name
  cluster_parameter_group_name        = aws_redshift_parameter_group.this.name
  vpc_security_group_ids              = [aws_security_group.redshift.id]
  kms_key_id                          = data.terraform_remote_state.core.outputs.redshift_kms_key_arn
  encrypted                           = true
  publicly_accessible                 = false
  skip_final_snapshot                 = local.redshift_skip_final_snapshot
  final_snapshot_identifier           = "chedaws-edp-${local.environment}-final-snapshot"
  automated_snapshot_retention_period = local.redshift_snapshot_retention
  enhanced_vpc_routing                = true
  port                                = 5439

  tags = {
    Name = "chedaws-edp-${local.environment}"
  }

  lifecycle {
    ignore_changes = [master_password]
  }
}

resource "aws_redshift_logging" "this" {
  cluster_identifier   = aws_redshift_cluster.this.id
  log_destination_type = "cloudwatch"
  log_exports          = ["connectionlog", "userlog", "useractivitylog"]

  # EnableLogging fails with InvalidClusterState while another change is
  # modifying the cluster. Wait for the IAM role association, which returns
  # once the cluster is available again.
  depends_on = [
    aws_cloudwatch_log_group.redshift,
    aws_redshift_cluster_iam_roles.this,
  ]
}

# ── CloudWatch Alarms ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "redshift" {
  for_each = local.redshift_alarm_defs

  alarm_name          = "chedaws-edp-redshift-${each.key}-${local.environment}"
  alarm_description   = "Redshift ${each.value.description} for cluster chedaws-edp-${local.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = each.value.metric_name
  namespace           = "AWS/Redshift"
  period              = 300
  statistic           = "Average"
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]
  ok_actions          = [data.terraform_remote_state.core.outputs.redshift_sns_topic_arn]

  dimensions = {
    ClusterIdentifier = aws_redshift_cluster.this.cluster_identifier
  }
}

# ── IAM Identity Centre Integration ───────────────────────────────────────────

resource "aws_iam_role" "redshift_idc_svc" {
  name        = "chedaws-edp-redshift-idc-svc-${local.environment}"
  description = "Service role for the chedaws-edp-${local.environment} Redshift IdC application; assumed by redshift.amazonaws.com for Trusted Identity Propagation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "redshift_idc_svc" {
  #checkov:skip=CKV_AWS_355:SSO actions do not support resource-level permissions; wildcard is required by AWS
  name = "redshift-idc-svc-policy"
  role = aws_iam_role.redshift_idc_svc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSODescribe"
        Effect = "Allow"
        Action = [
          "sso:DescribeRegisteredRegions",
          "sso:GetApplicationAuthenticationMethod",
          "sso:GetApplicationGrant",
          "sso:DescribeApplication",
          "sso:DescribeInstance"
        ]
        Resource = "*"
      },
      {
        Sid      = "RedshiftDescribe"
        Effect   = "Allow"
        Action   = ["redshift:DescribeClusters"]
        Resource = "arn:aws:redshift:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster:chedaws-edp-${local.environment}"
      }
    ]
  })
}

resource "aws_redshift_idc_application" "this" {
  idc_instance_arn              = var.idc_instance_arn
  idc_display_name              = "chedaws-edp-${local.environment}"
  redshift_idc_application_name = "chedaws-edp-${local.environment}"
  iam_role_arn                  = aws_iam_role.redshift_idc_svc.arn

  service_integration {
    redshift {
      connect {
        authorization = "Enabled"
      }
    }
  }
}

resource "aws_redshift_resource_policy" "zero_etl_inbound" {
  resource_arn = aws_redshift_cluster.this.cluster_namespace_arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AuthorizeZeroETLInboundIntegration"
        Effect = "Allow"
        Principal = {
          Service = "redshift.amazonaws.com"
        }
        Action = [
          "redshift:AuthorizeInboundIntegration"
        ]
        Resource = aws_redshift_cluster.this.cluster_namespace_arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_redshift_cluster_iam_roles" "this" {
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  iam_role_arns = concat(
    [aws_iam_role.redshift_idc_svc.arn],
    tolist(data.aws_iam_roles.redshift_load.arns)
  )

  lifecycle {
    ignore_changes = [iam_role_arns]
  }
}

# =========================================================
# Redshift DB Grants
# =========================================================
locals {
  databases = [
    "edp_core_dev", "edp_modelled_dev", "edp_platform_dev", "edp_raw_dev", "edp_sandbox_dev"
  ]
  roles = ["role_reader", "role_writer", "role_editor", "role_admin"]
  db_users = {
    oggadmin = { role = "role_writer" }
  }

  idc_group_role_assignments = {
    edp_dev_support_full = { group = "AWSIDC:ACL_AD_CHEDAWS_WL_NDP_DEV_SUPPORT_FULL", role = "role_writer" }
  }

  db_user_password_clauses = {
    for k, v in local.db_users :
    k => replace("PASSWORD '${random_password.db_user[k].result}'", "'", "''")
  }
}

# =========================================================
# Random passwords + Secrets Manager entries per db user
# =========================================================
resource "random_password" "db_user" {
  for_each = local.db_users

  length           = 8
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  special          = true
  override_special = "!#$"
}

resource "aws_secretsmanager_secret" "db_user" {
  for_each = local.db_users

  name                    = "/chedaws-edp/${local.environment}/redshift/${each.key}-credentials"
  kms_key_id              = data.terraform_remote_state.core.outputs.redshift_kms_key_arn
  description             = "Redshift password for db user ${each.key} in chedaws-edp-${local.environment}"
  recovery_window_in_days = 7

  tags = {
    Name = "chedaws-edp-redshift-${each.key}-secret-${local.environment}"
  }
}

resource "aws_secretsmanager_secret_version" "db_user" {
  for_each = local.db_users

  secret_id = aws_secretsmanager_secret.db_user[each.key].id
  secret_string = jsonencode({
    username = each.key
    password = random_password.db_user[each.key].result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# =========================================================
# Guard procedures
# =========================================================
resource "aws_redshiftdata_statement" "procedures" {
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = file("${path.module}/procedures.sql")

  lifecycle {
    ignore_changes = all # Comment out if you change procedures.sql
  }
}

# =========================================================
# Create databases via the guarded procedure
# =========================================================
resource "aws_redshiftdata_statement" "create_databases" {
  for_each           = toset(local.databases)
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "CALL sp_create_database_if_not_exists('${each.key}');"
  depends_on         = [aws_redshiftdata_statement.procedures]
}

# =========================================================
# Create roles via the guarded procedure
# =========================================================
resource "aws_redshiftdata_statement" "create_roles" {
  for_each           = toset(local.roles)
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "CALL sp_create_role_if_not_exists('${each.key}');"
  depends_on         = [aws_redshiftdata_statement.procedures]
}

# =========================================================
# Role hierarchy via the guarded procedure
# =========================================================
resource "aws_redshiftdata_statement" "role_hierarchy" {
  for_each = {
    reader_to_writer = { parent = "role_reader", child = "role_writer" }
    writer_to_editor = { parent = "role_writer", child = "role_editor" }
    editor_to_admin  = { parent = "role_editor", child = "role_admin" }
  }
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "CALL sp_grant_role_if_not_member('${each.value.parent}', '${each.value.child}');"
  depends_on         = [aws_redshiftdata_statement.create_roles]
}

# =========================================================
# Per-database scoped grants
# =========================================================
resource "aws_redshiftdata_statement" "grant_reader" {
  for_each           = toset(local.databases)
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = each.key
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "GRANT USAGE FOR SCHEMAS IN DATABASE ${each.key} TO ROLE role_reader; GRANT SELECT FOR TABLES IN DATABASE ${each.key} TO ROLE role_reader;"
  depends_on         = [aws_redshiftdata_statement.role_hierarchy, aws_redshiftdata_statement.create_databases]
}

resource "aws_redshiftdata_statement" "grant_writer" {
  for_each           = toset(local.databases)
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = each.key
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "GRANT SELECT, INSERT, UPDATE FOR TABLES IN DATABASE ${each.key} TO ROLE role_writer;"
  depends_on         = [aws_redshiftdata_statement.role_hierarchy, aws_redshiftdata_statement.create_databases]
}

resource "aws_redshiftdata_statement" "grant_editor" {
  for_each           = toset(local.databases)
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = each.key
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "GRANT DELETE, TRUNCATE FOR TABLES IN DATABASE ${each.key} TO ROLE role_editor;"
  depends_on         = [aws_redshiftdata_statement.role_hierarchy, aws_redshiftdata_statement.create_databases]
}

resource "aws_redshiftdata_statement" "grant_admin" {
  for_each           = toset(local.databases)
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = each.key
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "GRANT CREATE, ALTER, DROP FOR SCHEMAS IN DATABASE ${each.key} TO ROLE role_admin;"
  depends_on         = [aws_redshiftdata_statement.role_hierarchy, aws_redshiftdata_statement.create_databases]
}

# =========================================================
# Onboard the IDC group
# =========================================================
resource "aws_redshiftdata_statement" "onboard_idc_groups" {
  for_each           = local.idc_group_role_assignments
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "CALL sp_grant_role_if_not_member('${each.value.role}', '${each.value.group}');"
  depends_on         = [aws_redshiftdata_statement.grant_writer]
}

# =========================================================
# Create db users
# =========================================================
resource "aws_redshiftdata_statement" "create_users" {
  for_each           = local.db_users
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "CALL sp_create_user_if_not_exists('${each.key}', '${local.db_user_password_clauses[each.key]}');"
  depends_on         = [aws_redshiftdata_statement.procedures]

  lifecycle {
    ignore_changes = [sql]
  }
}

# =========================================================
# Assign each user to role
# =========================================================
resource "aws_redshiftdata_statement" "assign_user_role" {
  for_each           = local.db_users
  cluster_identifier = aws_redshift_cluster.this.cluster_identifier
  database           = "dev"
  db_user            = aws_redshift_cluster.this.master_username
  sql                = "CALL sp_grant_role_to_user_if_not_member('${each.value.role}', '${each.key}');"
  depends_on         = [aws_redshiftdata_statement.create_users, aws_redshiftdata_statement.role_hierarchy]
}
