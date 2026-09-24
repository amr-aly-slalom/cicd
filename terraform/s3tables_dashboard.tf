# Discover S3 Tables Athena workgroups by tag; keep only the *-tables-* ones.
data "aws_resourcegroupstaggingapi_resources" "edp_tables_workgroups" {
  resource_type_filters = ["athena:workgroup"]

  tag_filter {
    key    = "Application"
    values = ["EDP"]
  }
}

locals {
  s3tables_dashboard_region = data.aws_region.current.region

  # env -> tables Athena workgroup names (Environment tag; only *-tables-*).
  s3tables_workgroups = [
    for r in data.aws_resourcegroupstaggingapi_resources.edp_tables_workgroups.resource_tag_mapping_list : {
      name = element(split("/", r.resource_arn), 1)
      env  = lower(try(r.tags["Environment"], ""))
    }
    if can(regex("tables", element(split("/", r.resource_arn), 1)))
  ]

  s3tables_env = lower(local.environment)

  # Built ONLY for the current deployment environment so a dev apply creates just
  # the dev dashboard (and test only test).
  s3tables_envs = {
    (local.s3tables_env) = {
      # Named, not discovered by tag: core deploys before the s3tables stack, so
      # on a new environment discovery finds nothing and PutDashboard rejects
      # the empty dimension value. Must match terraform/s3tables/s3tables.tf.
      table_bucket = "chedaws-edp-table-bucket-${local.s3tables_env}"
      workgroups   = distinct([for w in local.s3tables_workgroups : w.name if w.env == local.s3tables_env])
    }
  }
}

# ── Dashboard: S3 Tables — one per environment ────────────────────────────────
# S3 Tables storage + compaction (AWS/S3/Tables), a table-size anomaly band, and
# Athena query metrics scoped to that env's *-tables-* workgroups. Widgets use
# SEARCH() so all tables under the env's table bucket appear automatically.
resource "aws_cloudwatch_dashboard" "s3tables" {
  for_each = local.s3tables_envs

  dashboard_name = "chedaws-edp-${each.key}-s3tables"

  dashboard_body = jsonencode({
    # S3 Tables storage/compaction metrics are emitted once per day (period
    # 86400). Force a wide default window and honour each widget's own period so
    # the daily datapoints are visible on open (the default short range shows
    # nothing for daily metrics).
    start          = "-P14D"
    periodOverride = "inherit"

    widgets = concat(
      # ── S3 Tables: Storage ────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 0
          width      = 24
          height     = 1
          properties = { markdown = "## S3 Tables — Storage" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 1
          width  = 12
          height = 6
          properties = {
            title  = "Table Size Bytes (per table)"
            view   = "timeSeries"
            region = local.s3tables_dashboard_region
            period = 86400
            metrics = [
              [{ expression = "SEARCH('{AWS/S3/Tables,TableBucketName,TableName,StorageType,Namespace} MetricName=\"TableSizeBytes\" TableBucketName=\"${each.value.table_bucket}\"', 'Maximum', 86400)", id = "ts" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 1
          width  = 12
          height = 6
          properties = {
            title  = "Table Number of Objects (per table)"
            view   = "timeSeries"
            region = local.s3tables_dashboard_region
            period = 86400
            metrics = [
              [{ expression = "SEARCH('{AWS/S3/Tables,TableBucketName,TableName,StorageType,Namespace} MetricName=\"TableNumberOfObjects\" TableBucketName=\"${each.value.table_bucket}\"', 'Maximum', 86400)", id = "tno" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 7
          width  = 12
          height = 6
          properties = {
            title  = "Table Bucket Size Bytes"
            view   = "timeSeries"
            region = local.s3tables_dashboard_region
            period = 86400
            metrics = [
              [{ expression = "SEARCH('{AWS/S3/Tables,TableBucketName,TableName,StorageType,Namespace} MetricName=\"TableBucketSizeBytes\" TableBucketName=\"${each.value.table_bucket}\"', 'Maximum', 86400)", id = "tbs" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 7
          width  = 12
          height = 6
          properties = {
            title  = "Table Bucket Number of Objects"
            view   = "timeSeries"
            region = local.s3tables_dashboard_region
            period = 86400
            metrics = [
              [{ expression = "SEARCH('{AWS/S3/Tables,TableBucketName,TableName,StorageType,Namespace} MetricName=\"TableBucketNumberOfObjects\" TableBucketName=\"${each.value.table_bucket}\"', 'Maximum', 86400)", id = "tbno" }]
            ]
          }
        },
      ],
      # ── S3 Tables: Growth Anomaly ──────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 13
          width      = 24
          height     = 1
          properties = { markdown = "## S3 Tables — Growth Anomaly" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 14
          width  = 24
          height = 6
          properties = {
            title  = "Table Bucket Size Bytes with anomaly band"
            view   = "timeSeries"
            region = local.s3tables_dashboard_region
            period = 86400
            # ANOMALY_DETECTION_BAND needs a SINGLE, DIRECT metric (it cannot wrap
            # a SEARCH/metric-math expression). S3 Tables publishes a pre-aggregated
            # bucket total at TableName=ALL, Namespace=ALL, StorageType=
            # TablesStandardStorage — we reference that metric directly (id "sz")
            # and band it.
            metrics = [
              ["AWS/S3/Tables", "TableBucketSizeBytes", "TableBucketName", each.value.table_bucket, "TableName", "ALL", "StorageType", "TablesStandardStorage", "Namespace", "ALL", { id = "sz", stat = "Maximum", label = "Bucket size" }],
              [{ expression = "ANOMALY_DETECTION_BAND(sz, 2)", label = "Expected range", id = "ad" }]
            ]
          }
        },
      ],
      # ── S3 Tables: Maintenance (Compaction) ───────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 20
          width      = 24
          height     = 1
          properties = { markdown = "## S3 Tables — Maintenance (Compaction)" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 21
          width  = 24
          height = 6
          properties = {
            title  = "Compaction Bytes & Objects Processed (binpack)"
            view   = "timeSeries"
            region = local.s3tables_dashboard_region
            period = 86400
            metrics = [
              [{ expression = "SEARCH('{AWS/S3/Tables,TableBucketName,TableName,MaintenanceActivityType,Namespace} MetricName=\"CompactionBytesProcessed_binpack\" TableBucketName=\"${each.value.table_bucket}\"', 'Sum', 86400)", id = "cb" }],
              [{ expression = "SEARCH('{AWS/S3/Tables,TableBucketName,TableName,MaintenanceActivityType,Namespace} MetricName=\"CompactionObjectsCount_binpack\" TableBucketName=\"${each.value.table_bucket}\"', 'Sum', 86400)", id = "co" }]
            ]
          }
        },
      ]
    )
  })
}

output "s3tables_dashboard_urls" {
  description = "CloudWatch S3 Tables dashboard URLs, per environment"
  value = {
    for env, dash in aws_cloudwatch_dashboard.s3tables :
    env => "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards/dashboard/${dash.dashboard_name}"
  }
}
