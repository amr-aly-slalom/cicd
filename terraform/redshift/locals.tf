locals {
  environment  = terraform.workspace
  is_prod_like = contains(["uat", "prod"], local.environment)

  redshift_node_type                  = local.is_prod_like ? "rg.4xlarge" : "rg.xlarge"
  redshift_snapshot_retention         = local.is_prod_like ? 7 : 1
  redshift_skip_final_snapshot        = !local.is_prod_like
  redshift_connection_alarm_threshold = local.is_prod_like ? 900 : 450
  log_retention_days                  = local.is_prod_like ? 30 : 7

  # dev/test only - lets folks on the CHED VPN reach Redshift clusters directly.
  # See https://powercor.atlassian.net/wiki/spaces/NDP/pages/3299704853/Corporate+Firewall+Requests
  redshift_vpn_cidrs = !local.is_prod_like ? [
    "172.29.144.0/20",
    "172.30.144.0/20",
  ] : []

  redshift_alarm_defs = {
    cpu = {
      metric_name = "CPUUtilization"
      description = "CPUUtilization >= 85%"
      threshold   = 85
    }
    disk = {
      metric_name = "PercentageDiskSpaceUsed"
      description = "PercentageDiskSpaceUsed >= 80%"
      threshold   = 80
    }
    connections = {
      metric_name = "DatabaseConnections"
      description = "DatabaseConnections >= ${local.redshift_connection_alarm_threshold}"
      threshold   = local.redshift_connection_alarm_threshold
    }
  }
}
