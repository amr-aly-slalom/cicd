module "sap_ecc_oracle_rds" {
  source = "../modules/rds"
  count  = contains(local.rds_environments, local.environment) ? 1 : 0

  db_identifier        = "chedaws-edp-sap-ecc-${local.environment}"
  engine               = "oracle-se2"
  major_engine_version = "19"
  port                 = 1521
  db_instance_class    = "db.m5.xlarge"
  database_name        = "ORCL"

  generate_random_password      = true
  create_secrets_manager_secret = true
  master_username               = "edp_admin"

  storage_type          = "gp3"
  allocated_storage     = 4000
  iops                  = 12000
  max_allocated_storage = 10000
  storage_throughput    = 500
  multi_az_enabled      = false
  deletion_protection   = local.is_prod_like ? true : false

  license_model            = "bring-your-own-license"
  character_set_name       = "AL32UTF8"
  nchar_character_set_name = "AL16UTF16"

  database_subnet_ids = data.aws_subnets.db.ids
  enable_encryption   = true
  rds_kms_key_arn     = data.aws_kms_alias.rds.target_key_arn

  create_security_group      = true
  vpc_id                     = data.aws_vpc.this.id
  security_group_name        = "chedaws-edp-sap-ecc-sg-${local.environment}"
  security_group_description = "Security group for chedaws-edp-sap-ecc-${local.environment} rds"
  security_group_ingress_rules = [
    {
      from_port   = 1521
      to_port     = 1521
      protocol    = "tcp"
      cidr_blocks = [for s in data.aws_subnet.db : s.cidr_block]
      description = "rds access from DB-tier subnet"
    },
    {
      from_port   = 1521
      to_port     = 1521
      protocol    = "tcp"
      cidr_blocks = ["10.31.68.0/24"]
      description = "rds access from on premise"
    },
    {
      from_port   = 1521
      to_port     = 1521
      protocol    = "tcp"
      cidr_blocks = ["172.29.144.0/20", "172.30.144.0/20"]
      description = "rds access from vpn"
    }
  ]

  db_parameters = [
    { name = "processes", value = "500", apply_method = "pending-reboot" },
    { name = "open_cursors", value = "1000", apply_method = "immediate" }
  ]

  option_group_options = [
    { option_name = "TIMEZONE_FILE_AUTOUPGRADE" },
    {
      option_name     = "Timezone"
      option_settings = [{ name = "TIME_ZONE", value = "UTC" }]
    }
  ]

  monitoring_interval             = 60
  enabled_cloudwatch_logs_exports = ["alert"]
}
