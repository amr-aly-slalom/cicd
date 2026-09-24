# ------------------------------------------------------------------------------
# LOCAL VARIABLES & SAFETY RULES
# ------------------------------------------------------------------------------
locals {
  is_oracle    = length(regexall("oracle", var.engine)) > 0
  is_sqlserver = length(regexall("sqlserver", var.engine)) > 0

  # --- JDBC Connection String Logic --------------------------------------
  jdbc_prefix = (
    local.is_oracle ? "jdbc:oracle:thin:@" :
    local.is_sqlserver ? "jdbc:sqlserver://" :
    var.engine == "postgres" ? "jdbc:postgresql://" :
    var.engine == "mysql" ? "jdbc:mysql://" :
    var.engine == "mariadb" ? "jdbc:mariadb://" :
    "jdbc:${var.engine}://"
  )

  jdbc_url = (
    local.is_oracle ? "${local.jdbc_prefix}${aws_db_instance.this.endpoint}:${aws_db_instance.this.port}:${var.database_name}" :
    local.is_sqlserver ? "${local.jdbc_prefix}${aws_db_instance.this.endpoint}:${aws_db_instance.this.port};databaseName=${var.database_name}" :
    "${local.jdbc_prefix}${aws_db_instance.this.endpoint}:${aws_db_instance.this.port}/${var.database_name}"
  )

  is_replica                  = var.replicate_source_db != null
  use_managed_master_password = var.use_managed_master_password && !local.is_replica
  managed_master_password_arg = local.use_managed_master_password ? true : null

  username = local.is_replica ? null : var.master_username
  password = (
    local.is_replica ? null :
    local.use_managed_master_password ? null :
    var.generate_random_password ? random_password.this[0].result :
    var.master_password
  )
  db_name            = local.is_replica ? null : var.database_name
  allocated_storage  = local.is_replica ? null : var.allocated_storage
  storage_throughput = (var.storage_type == "gp3" && var.iops != null) ? var.storage_throughput : null
}

# ------------------------------------------------------------------------------
# PASSWORDS & CREDENTIALS
# ------------------------------------------------------------------------------
resource "random_password" "this" {
  count = (
    var.generate_random_password &&
    !var.use_managed_master_password &&
    !local.is_replica
  ) ? 1 : 0

  length           = 16
  special          = true
  override_special = "!#$%^*()_+=[]{}<>?:;.,~-"
}

# ------------------------------------------------------------------------------
# NETWORKING & GROUPS
# ------------------------------------------------------------------------------
resource "aws_db_subnet_group" "this" {
  count = var.subnet_group_name == "" && !local.is_replica ? 1 : 0

  name       = "${var.db_identifier}-db-subnet-group"
  subnet_ids = var.database_subnet_ids

  tags = merge({
    Name = "${var.db_identifier}-db-subnet-group"
    },
    var.tags
  )
}

# ------------------------------------------------------------------------------
# DB Parameter Group
# ------------------------------------------------------------------------------
resource "aws_db_parameter_group" "this" {
  name = "${var.db_identifier}-parameter-group"
  # family      = var.family
  family      = data.aws_rds_engine_version.db.parameter_group_family
  description = "Parameter group for ${var.db_identifier} (${var.engine})"
  dynamic "parameter" {
    for_each = var.db_parameters
    content {
      name         = parameter.value.name
      value        = parameter.value.value
      apply_method = try(parameter.value.apply_method, "immediate")
    }
  }

  tags = merge({
    Name = "${var.db_identifier}-params"
    },
    var.tags
  )

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# DB Option Group
# ------------------------------------------------------------------------------
resource "aws_db_option_group" "this" {
  count = length(var.option_group_options) > 0 ? 1 : 0

  name                     = "${var.db_identifier}-option-group"
  engine_name              = var.engine
  major_engine_version     = var.major_engine_version
  option_group_description = "Option group for ${var.db_identifier} (${var.engine})"

  dynamic "option" {
    for_each = var.option_group_options
    content {
      option_name                    = option.value.option_name
      port                           = try(option.value.port, null)
      version                        = try(option.value.version, null)
      db_security_group_memberships  = try(option.value.db_security_group_memberships, [])
      vpc_security_group_memberships = try(option.value.vpc_security_group_memberships, [])

      dynamic "option_settings" {
        for_each = try(option.value.option_settings, [])
        content {
          name  = option_settings.value.name
          value = option_settings.value.value
        }
      }
    }
  }

  tags = merge({
    Name = "${var.db_identifier}-option-group"
    },
    var.tags
  )
}

# ------------------------------------------------------------------------------
# IAM ROLES (Monitoring & Integrations)
# ------------------------------------------------------------------------------

# 1. Enhanced Monitoring Role
resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name = "${var.db_identifier}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge({
    Name = "${var.db_identifier}-rds-monitoring-role"
    },
    var.tags
  )
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_iam_role" "integration_roles" {
  for_each = var.integration_policies

  name = "${var.db_identifier}-${each.key}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
      }
    ]
  })

  tags = merge({
    Name = "${var.db_identifier}-${each.key}-role"
    },
    var.tags
  )
}

resource "aws_iam_policy" "integration_policies" {
  for_each = var.integration_policies

  name   = "${var.db_identifier}-${each.key}-policy"
  policy = each.value.policy_json

  tags = merge({
    Name = "${var.db_identifier}-${each.key}-policy"
    },
    var.tags
  )
}

resource "aws_iam_role_policy_attachment" "integration_attachments" {
  for_each = var.integration_policies

  role       = aws_iam_role.integration_roles[each.key].name
  policy_arn = aws_iam_policy.integration_policies[each.key].arn
}

resource "aws_db_instance_role_association" "integrations" {
  for_each = var.integration_policies

  db_instance_identifier = aws_db_instance.this.identifier
  role_arn               = aws_iam_role.integration_roles[each.key].arn
  feature_name           = each.value.feature_name
}

# ------------------------------------------------------------------------------
# RDS DATABASE INSTANCE
# ------------------------------------------------------------------------------
resource "aws_db_instance" "this" {
  #checkov:skip=CKV_AWS_354: Ensure RDS Performance Insights are encrypted using KMS CMKs
  #checkov:skip=CKV_AWS_353: Ensure that RDS instances have performance insights enabled
  #checkov:skip=CKV_AWS_157: Multi-AZ not enabled in any environment for this instance - accepted single-AZ cost tradeoff, not an oversight
  identifier          = var.db_identifier
  snapshot_identifier = var.snapshot_name

  # Core Engine
  engine         = var.engine
  engine_version = data.aws_rds_engine_version.db.version
  license_model  = var.license_model
  port           = var.port
  instance_class = var.db_instance_class

  # Auth / Identification (Dynamic via rules)
  replicate_source_db         = var.replicate_source_db
  username                    = local.username
  password                    = local.password
  manage_master_user_password = local.managed_master_password_arg
  db_name                     = local.db_name

  # Engine-Specific Attributes (Defaults to null in variables)
  timezone                            = var.timezone
  character_set_name                  = var.character_set_name
  nchar_character_set_name            = var.nchar_character_set_name
  iam_database_authentication_enabled = var.iam_database_authentication_enabled
  domain                              = var.domain
  domain_iam_role_name                = var.domain_iam_role_name
  ca_cert_identifier                  = var.ca_cert_identifier

  # Storage Options
  allocated_storage     = local.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  iops                  = var.iops
  storage_throughput    = local.storage_throughput
  storage_encrypted     = var.enable_encryption
  kms_key_id            = var.enable_encryption ? var.rds_kms_key_arn : null

  # Networking
  db_subnet_group_name   = var.subnet_group_name != "" ? var.subnet_group_name : try(aws_db_subnet_group.this[0].name, null)
  vpc_security_group_ids = concat(var.security_group_ids, var.create_security_group ? [aws_security_group.this[0].id] : [])
  publicly_accessible    = var.publicly_accessible
  network_type           = var.network_type
  multi_az               = var.multi_az_enabled

  # Groups
  parameter_group_name = aws_db_parameter_group.this.name
  option_group_name    = try(aws_db_option_group.this[0].name, null)

  # Backup & Maintenance
  backup_retention_period    = var.backup_retention_period
  backup_window              = var.backup_window
  maintenance_window         = var.maintenance_window
  copy_tags_to_snapshot      = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  final_snapshot_identifier  = var.skip_final_snapshot ? null : "${var.db_identifier}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  apply_immediately          = var.apply_immediately
  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  delete_automated_backups   = var.delete_automated_backups

  # Monitoring & Logs
  monitoring_interval             = var.monitoring_interval
  monitoring_role_arn             = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports
  database_insights_mode          = var.database_insights_mode

  # Performance Insights
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.secretsmanager_kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? var.performance_insights_retention_period : null

  tags = merge({
    Name = var.db_identifier
    },
    var.tags
  )

  lifecycle {
    ignore_changes = [
      engine_version,
      password,
      snapshot_identifier,
      final_snapshot_identifier
    ]
  }
}

# ------------------------------------------------------------------------------
# SECRETS MANAGER
# ------------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_credentials" {
  count = var.create_secrets_manager_secret && !local.is_replica && !local.use_managed_master_password ? 1 : 0

  name                    = "${var.db_identifier}-db-credentials"
  description             = "${title(var.engine)} RDS credentials for ${var.db_identifier}"
  kms_key_id              = var.secretsmanager_kms_key_arn
  recovery_window_in_days = var.secrets_recovery_window

  tags = merge({
    Name = "${var.db_identifier}-db-credentials"
    },
    var.tags
  )
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  count = var.create_secrets_manager_secret && !local.is_replica && !local.use_managed_master_password ? 1 : 0

  secret_id = aws_secretsmanager_secret.db_credentials[0].id

  secret_string = jsonencode({
    username               = local.username
    password               = local.password
    host                   = aws_db_instance.this.endpoint
    port                   = aws_db_instance.this.port
    dbname                 = local.db_name
    db_instance_identifier = aws_db_instance.this.identifier
    connection_string      = local.jdbc_url
  })
}

# ------------------------------------------------------------------------------
# CLOUDWATCH LOG GROUPS
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "db_logs" {
  #checkov:skip=CKV_AWS_338: Ensure CloudWatch log groups retains logs for at least 1 year
  for_each = toset(var.enabled_cloudwatch_logs_exports)

  name              = "${var.cloudwatch_log_group_prefix}/${var.db_identifier}/${each.value}"
  retention_in_days = var.cloudwatch_logs_retention_days
  kms_key_id        = var.logs_kms_key_arn

  tags = merge({
    Name = "${var.db_identifier}-${each.value}-logs"
    },
    var.tags
  )
}

# ------------------------------------------------------------------------------
# SECURITY GROUP
# ------------------------------------------------------------------------------
resource "aws_security_group" "this" {
  count = var.create_security_group ? 1 : 0

  name        = var.security_group_name != "" ? var.security_group_name : "${var.db_identifier}-sg"
  description = var.security_group_description
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.security_group_ingress_rules
    content {
      description = ingress.value.description
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
      self        = ingress.value.self
    }
  }

  dynamic "egress" {
    for_each = var.security_group_egress_rules
    content {
      description = egress.value.description
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
      self        = egress.value.self
    }
  }

  tags = merge({
    Name = var.security_group_name != "" ? var.security_group_name : "${var.db_identifier}-sg"
    },
    var.tags
  )

  lifecycle {
    create_before_destroy = true
  }
}
