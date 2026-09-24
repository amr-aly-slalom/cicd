# ------------------------------------------------------------------------------
# CORE IDENTITY
# ------------------------------------------------------------------------------
variable "db_identifier" {
  description = "Unique identifier used as the base name for the DB instance and all related resources (subnet group, parameter group, IAM roles, etc.)."
  type        = string
}

variable "tags" {
  description = "A map of tags to apply to all resources created by this module."
  type        = map(string)
  default     = {}
}

# ------------------------------------------------------------------------------
# ENGINE
# ------------------------------------------------------------------------------
variable "engine" {
  description = "The database engine to use (e.g. \"mysql\", \"postgres\", \"mariadb\", \"oracle-ee\", \"oracle-se2\", \"sqlserver-ee\", \"sqlserver-se\", \"sqlserver-ex\", \"sqlserver-web\", \"custom-oracle-ee\"). Aurora engines are not supported by this module."
  type        = string
}

variable "engine_version" {
  description = "The engine version to use. Ignored on subsequent applies (see lifecycle.ignore_changes) to avoid forced replacements on minor version drift."
  type        = string
  default     = null
}

variable "family" {
  description = "The DB parameter group family (e.g. \"mysql8.0\", \"postgres16\", \"oracle-ee-19\"). Must match the engine/engine_version combination."
  type        = string
  default     = null
}

variable "major_engine_version" {
  description = "The major engine version, required only when option_group_options is non-empty (used for the DB option group)."
  type        = string
  default     = null
}

variable "license_model" {
  description = "License model for the DB instance (e.g. \"license-included\", \"bring-your-own-license\", \"general-public-license\"). Required for Oracle/SQL Server; leave null for engines that don't use it."
  type        = string
  default     = null
}

# ------------------------------------------------------------------------------
# INSTANCE SIZING
# ------------------------------------------------------------------------------
variable "db_instance_class" {
  description = "The instance class/type for the DB instance (e.g. \"db.t3.medium\", \"db.r6g.large\")."
  type        = string
}

variable "port" {
  description = "The port the DB instance will listen on."
  type        = number
}

variable "multi_az_enabled" {
  description = "Whether to enable Multi-AZ deployment for high availability."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# DATABASE / SNAPSHOT
# ------------------------------------------------------------------------------
variable "database_name" {
  description = "The name of the initial database to create. Ignored (forced to null) when replicate_source_db is set."
  type        = string
  default     = null
}

variable "snapshot_name" {
  description = "The snapshot identifier to restore the DB instance from. Leave null to create a fresh instance."
  type        = string
  default     = null
}

variable "replicate_source_db" {
  description = "The identifier or ARN of the source DB instance/cluster to create a read replica from. When set, username/password/db_name/allocated_storage are forced to null."
  type        = string
  default     = null
}

variable "source_region" {
  description = "The source region for a cross-region read replica. Required when replicate_source_db references an instance in a different AWS region."
  type        = string
  default     = "ap-southeast-2"
}

# ------------------------------------------------------------------------------
# CREDENTIALS
# ------------------------------------------------------------------------------
variable "master_username" {
  description = "Master username for the DB instance. Ignored for read replicas."
  type        = string
  default     = null
}

variable "master_password" {
  description = "Master password for the DB instance. Used only when generate_random_password and use_managed_master_password are both false."
  type        = string
  default     = null
  sensitive   = true
}

variable "generate_random_password" {
  description = "Whether to auto-generate a random master password via the random_password resource. Mutually exclusive with use_managed_master_password."
  type        = bool
  default     = false
}

variable "use_managed_master_password" {
  description = "Whether to let RDS manage the master password automatically via AWS Secrets Manager (manage_master_user_password). Mutually exclusive with generate_random_password."
  type        = bool
  default     = false
}

variable "iam_database_authentication_enabled" {
  description = "Whether to enable IAM database authentication (supported on MySQL, PostgreSQL, MariaDB)."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# ENGINE-SPECIFIC ATTRIBUTES (Oracle / SQL Server only)
# ------------------------------------------------------------------------------
variable "timezone" {
  description = "The instance time zone. Only valid for Oracle and SQL Server engines."
  type        = string
  default     = null
}

variable "character_set_name" {
  description = "The character set name to use for the DB instance. Only valid for Oracle and SQL Server engines."
  type        = string
  default     = null
}

variable "nchar_character_set_name" {
  description = "The national character set for storing NCHAR/NVARCHAR2 data. Only valid for Oracle engines."
  type        = string
  default     = null
}

variable "domain" {
  description = "The ID of the Directory Service Active Directory domain to join (SQL Server, Oracle, PostgreSQL, MySQL where supported)."
  type        = string
  default     = null
}

variable "domain_iam_role_name" {
  description = "The name of the IAM role to use when making API calls to the Directory Service, required if domain is set."
  type        = string
  default     = null
}

variable "ca_cert_identifier" {
  description = "The identifier of the CA certificate for the DB instance."
  type        = string
  default     = null
}

# ------------------------------------------------------------------------------
# STORAGE
# ------------------------------------------------------------------------------
variable "allocated_storage" {
  description = "The allocated storage size in GiB. Ignored (forced to null) when replicate_source_db is set."
  type        = number
  default     = null
}

variable "max_allocated_storage" {
  description = "The upper limit (GiB) for RDS storage autoscaling. Set to 0 or null to disable autoscaling."
  type        = number
  default     = null
}

variable "storage_type" {
  description = "The storage type: \"standard\", \"gp2\", \"gp3\", \"io1\", or \"io2\"."
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "The provisioned IOPS. Only valid when storage_type is gp3, io1, or io2 (enforced via precondition in main.tf)."
  type        = number
  default     = null
}

variable "storage_throughput" {
  description = "The storage throughput (MiBps). Only applied when storage_type is gp3 and iops is set; ignored otherwise."
  type        = number
  default     = null
}

variable "enable_encryption" {
  description = "Whether to enable storage encryption at rest."
  type        = bool
  default     = true
}

variable "rds_kms_key_arn" {
  description = "KMS key ARN used to encrypt storage. Only applied when enable_encryption is true; when null, the default AWS-managed RDS key is used."
  type        = string
  default     = null
}

# ------------------------------------------------------------------------------
# NETWORKING
# ------------------------------------------------------------------------------
variable "subnet_group_name" {
  description = "Name of an existing DB subnet group to use. If left as an empty string, the module creates its own subnet group from database_subnet_ids."
  type        = string
  default     = ""
}

variable "database_subnet_ids" {
  description = "List of subnet IDs to use for the module-created DB subnet group. Required when subnet_group_name is not set."
  type        = list(string)
  default     = []
}

variable "security_group_ids" {
  description = "List of VPC security group IDs to associate with the DB instance."
  type        = list(string)
  default     = []
}

variable "publicly_accessible" {
  description = "Whether the DB instance should have a publicly resolvable DNS name / public IP. Defaults to false for safety."
  type        = bool
  default     = false
}

variable "network_type" {
  description = "The network type of the DB instance: \"IPV4\" or \"DUAL\"."
  type        = string
  default     = "IPV4"

  validation {
    condition     = contains(["IPV4", "DUAL"], var.network_type)
    error_message = "network_type must be either \"IPV4\" or \"DUAL\"."
  }
}

# ------------------------------------------------------------------------------
# PARAMETER / OPTION GROUPS
# ------------------------------------------------------------------------------
variable "db_parameters" {
  description = "List of DB parameter group parameters. Each item: { name = string, value = string, apply_method = optional(string, \"immediate\") }."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}

variable "option_group_options" {
  description = "List of DB option group options. Each item follows the aws_db_option_group \"option\" block shape, e.g. { option_name = string, port = optional(number), version = optional(string), db_security_group_memberships = optional(list(string)), vpc_security_group_memberships = optional(list(string)), option_settings = optional(list(object({ name = string, value = string }))) }."
  type        = any
  default     = []
}

# ------------------------------------------------------------------------------
# BACKUP & MAINTENANCE
# ------------------------------------------------------------------------------
variable "backup_retention_period" {
  description = "The number of days to retain automated backups. Set to 0 to disable automated backups."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "The daily time range (UTC) during which automated backups are created, e.g. \"03:00-04:00\"."
  type        = string
  default     = null
}

variable "maintenance_window" {
  description = "The weekly time range (UTC) during which system maintenance can occur, e.g. \"sun:04:30-sun:05:30\"."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Whether to enable deletion protection on the DB instance."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Whether to skip taking a final snapshot when the DB instance is destroyed. When false, a timestamped final snapshot is created."
  type        = bool
  default     = false
}

variable "apply_immediately" {
  description = "Whether modifications are applied immediately, or during the next maintenance window."
  type        = bool
  default     = false
}

variable "auto_minor_version_upgrade" {
  description = "Whether minor engine version upgrades are applied automatically during the maintenance window."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# MONITORING & PERFORMANCE INSIGHTS
# ------------------------------------------------------------------------------
variable "monitoring_interval" {
  description = "Interval, in seconds, between points when Enhanced Monitoring metrics are collected. Set to 0 to disable Enhanced Monitoring. Valid values: 0, 1, 5, 10, 15, 30, 60."
  type        = number
  default     = 0
}

variable "database_insights_mode" {
  description = "The mode of Database Insights to enable: \"standard\" or \"advanced\". \"advanced\" requires performance_insights_enabled = true."
  type        = string
  default     = "standard"
}

variable "performance_insights_enabled" {
  description = "Whether to enable Performance Insights on the DB instance."
  type        = bool
  default     = false
}

variable "performance_insights_kms_key_id" {
  description = "The KMS key ARN used to encrypt Performance Insights data. Only applied when performance_insights_enabled is true; when null, the default AWS-managed key is used."
  type        = string
  default     = null
}

variable "performance_insights_retention_period" {
  description = "The retention period (days) for Performance Insights data. Valid values: 7, or a multiple of 31 up to 731 (for the long-term retention tiers)."
  type        = number
  default     = 7
}

# ------------------------------------------------------------------------------
# CLOUDWATCH LOGS
# ------------------------------------------------------------------------------
variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to CloudWatch Logs. Valid values depend on engine (e.g. [\"audit\", \"error\", \"general\", \"slowquery\"] for MySQL; [\"postgresql\", \"upgrade\"] for PostgreSQL; [\"alert\", \"audit\", \"listener\", \"trace\"] for Oracle; [\"agent\", \"error\"] for SQL Server)."
  type        = list(string)
  default     = []
}

variable "cloudwatch_log_group_prefix" {
  description = "Prefix used when naming the module-created CloudWatch log groups. Should generally be left as \"/aws/rds/instance\" to match what RDS creates natively and avoid orphaned duplicate log groups."
  type        = string
  default     = "/aws/rds/instance"
}

variable "cloudwatch_logs_retention_days" {
  description = "Number of days to retain exported CloudWatch logs. Set to 0 for indefinite retention."
  type        = number
  default     = 30
}

variable "logs_kms_key_arn" {
  description = "KMS key ARN used to encrypt CloudWatch log groups. Leave null to use the default (unencrypted or account default) behavior."
  type        = string
  default     = null
}

# ------------------------------------------------------------------------------
# SECRETS MANAGER (module-managed credentials secret)
# ------------------------------------------------------------------------------
variable "create_secrets_manager_secret" {
  description = "Whether to create a Secrets Manager secret containing the DB credentials and connection info. Ignored when use_managed_master_password is true (RDS creates its own secret in that case)."
  type        = bool
  default     = false
}

variable "secretsmanager_kms_key_arn" {
  description = "KMS key ARN used to encrypt the module-managed Secrets Manager secret. Leave null to use the default aws/secretsmanager key."
  type        = string
  default     = null
}

variable "secrets_recovery_window" {
  description = "Number of days AWS Secrets Manager waits before permanently deleting the secret after it's scheduled for deletion. Set to 0 for immediate deletion."
  type        = number
  default     = 7
}

# ------------------------------------------------------------------------------
# IAM INTEGRATIONS (S3 import/export, EFS, etc.)
# ------------------------------------------------------------------------------
variable "integration_policies" {
  description = "Map of integration name to config for engine-specific IAM role associations (e.g. S3 import/export for Oracle/SQL Server, S3 export for Postgres/MySQL). Each value: { policy_json = string, feature_name = string }. feature_name must match a valid aws_db_instance_role_association feature (e.g. \"S3_INTEGRATION\", \"s3Import\", \"s3Export\")."
  type = map(object({
    policy_json  = string
    feature_name = string
  }))
  default = {}
}

variable "delete_automated_backups" {
  description = "(Optional) Specifies whether to remove automated backups immediately after the DB instance is deleted"
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Security Group
# ------------------------------------------------------------------------------
variable "create_security_group" {
  type        = bool
  default     = false
  description = "Whether to create a security group and attach it to the DB instance."
}

variable "vpc_id" {
  type        = string
  default     = null
  description = "VPC ID for the security group. Required if create_security_group = true."
}

variable "security_group_name" {
  type        = string
  default     = ""
  description = "Name for the created security group. Defaults to '<db_identifier>-sg'."
}

variable "security_group_description" {
  type        = string
  default     = "Managed security group"
  description = "Description for the created security group."
}

variable "security_group_ingress_rules" {
  description = "List of ingress rules for the created security group. Fully generic — not tied to RDS."
  type = list(object({
    description = optional(string, null)
    from_port   = number
    to_port     = number
    protocol    = optional(string, "tcp")
    cidr_blocks = optional(list(string), null)
    self        = optional(bool, null)
  }))
  default = []
}

variable "security_group_egress_rules" {
  description = "List of egress rules for the created security group. Defaults to allow-all outbound."
  type = list(object({
    description = optional(string, null)
    from_port   = number
    to_port     = number
    protocol    = optional(string, "-1")
    cidr_blocks = optional(list(string), null)
    self        = optional(bool, null)
  }))
  default = [
    {
      description = "Allow all outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}
