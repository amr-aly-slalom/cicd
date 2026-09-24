# Discover EDP S3 buckets dynamically by tag (Application=EDP) — same tagging-API
# pattern as workgroups/Glue jobs. This avoids the aws_s3_buckets data source
# (provider-version dependent) and lets us split buckets by the Environment tag.
data "aws_resourcegroupstaggingapi_resources" "edp_buckets" {
  resource_type_filters = ["s3"]

  tag_filter {
    key    = "Application"
    values = ["EDP"]
  }
}

# Discover EDP Athena workgroups dynamically by tag (Application=EDP). Athena has
# no list data source, but workgroups are tagged, so the tagging API returns them.
data "aws_resourcegroupstaggingapi_resources" "edp_athena_workgroups" {
  resource_type_filters = ["athena:workgroup"]

  tag_filter {
    key    = "Application"
    values = ["EDP"]
  }
}

# Discover EDP Glue jobs dynamically by tag (Application=EDP). Glue CloudWatch
# metrics carry JobName+JobRunId, so a per-run SEARCH explodes the legend; we use
# the discovered job names to emit one aggregated line per job instead.
data "aws_resourcegroupstaggingapi_resources" "edp_glue_jobs" {
  resource_type_filters = ["glue:job"]

  tag_filter {
    key    = "Application"
    values = ["EDP"]
  }
}

locals {
  datalake_dashboard_region = data.aws_region.current.region

  # Build [{ name, env }] for each EDP S3 bucket from the tagging API. S3 ARNs are
  # arn:aws:s3:::<name>, so the name is the last ":"-delimited element. Exclude
  # S3 Tables buckets (they belong to the S3 Tables dashboard). New tagged buckets
  # appear automatically on the next apply — no list to maintain.
  edp_buckets = [
    for r in data.aws_resourcegroupstaggingapi_resources.edp_buckets.resource_tag_mapping_list : {
      name = element(split(":", r.resource_arn), 5)
      env  = lower(try(r.tags["Environment"], ""))
    }
    if !can(regex("s3tables|-tables", element(split(":", r.resource_arn), 5)))
  ]

  # Build [{ name, env }] for each EDP Athena workgroup from the tagging API:
  # workgroup name from the ARN, environment from the "Environment" tag (DEV/TEST).
  # Exclude *-tables-* workgroups (they belong to the S3 Tables dashboard).
  edp_athena_workgroups = [
    for r in data.aws_resourcegroupstaggingapi_resources.edp_athena_workgroups.resource_tag_mapping_list : {
      name = element(split("/", r.resource_arn), 1)
      env  = lower(try(r.tags["Environment"], ""))
    }
    if !can(regex("tables", element(split("/", r.resource_arn), 1)))
  ]

  # Build [{ name, env }] for each EDP Glue job: name from the ARN (path element
  # after "job/"), environment from the "Environment" tag (DEV/TEST). Tag-based
  # env split lets each env dashboard show only its own jobs.
  edp_glue_jobs = [
    for r in data.aws_resourcegroupstaggingapi_resources.edp_glue_jobs.resource_tag_mapping_list : {
      name = element(split("/", r.resource_arn), 1)
      env  = lower(try(r.tags["Environment"], ""))
    }
  ]

  datalake_env = lower(local.environment)

  # Per-env sets, built ONLY for the current deployment environment so a dev
  # apply creates just the dev dashboard (and test only test). Buckets, workgroups
  # and Glue jobs are all split by the Environment tag value (robust, tag-based).
  datalake_envs = {
    (local.datalake_env) = {
      buckets    = [for b in local.edp_buckets : b.name if b.env == local.datalake_env]
      workgroups = [for w in local.edp_athena_workgroups : w.name if w.env == local.datalake_env]
      glue_jobs  = [for j in local.edp_glue_jobs : j.name if j.env == local.datalake_env]
    }
  }
}

# ── Dashboard: Data Lake (S3 + Glue + Athena) — one per environment ───────────
resource "aws_cloudwatch_dashboard" "datalake" {
  for_each = local.datalake_envs

  dashboard_name = "chedaws-edp-${each.key}-datalake-s3-glue-athena"

  dashboard_body = jsonencode({
    widgets = concat(
      # ── Header ────────────────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 0
          width      = 24
          height     = 1
          properties = { markdown = "# Data Lake — S3 · Glue · Athena" }
        },
      ],
      # ── Glue: Job Execution & Duration (account-wide — see note above) ─────────
      [
        {
          type       = "text"
          x          = 0
          y          = 1
          width      = 24
          height     = 1
          properties = { markdown = "## Glue — Job Execution & Duration  \n_One line per job (summed across runs); jobs are tag-discovered and scoped to this env._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Job Elapsed Time (ms, per job)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            # One aggregated line per job: SUM collapses the per-run (JobRunId)
            # series so the legend shows job names, not individual runs.
            metrics = [for i, j in each.value.glue_jobs :
              [{ expression = "SUM(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.aggregate.elapsedTime\" JobName=\"${j}\"', 'Sum', 300))", label = j, id = "elp${i}" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Records Read (per job)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = [for i, j in each.value.glue_jobs :
              [{ expression = "SUM(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.aggregate.recordsRead\" JobName=\"${j}\"', 'Sum', 300))", label = j, id = "rec${i}" }]
            ]
          }
        },
      ],
      # ── Glue: Task Failures & Resource ─────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 8
          width      = 24
          height     = 1
          properties = { markdown = "## Glue — Task Failures & Resource" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 9
          width  = 8
          height = 6
          properties = {
            title  = "Failed / Killed Tasks (per job)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = concat(
              [for i, j in each.value.glue_jobs :
                [{ expression = "SUM(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.aggregate.numFailedTasks\" JobName=\"${j}\"', 'Sum', 300))", label = "FAILED ${j}", id = "fl${i}" }]
              ],
              [for i, j in each.value.glue_jobs :
                [{ expression = "SUM(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.aggregate.numKilledTasks\" JobName=\"${j}\"', 'Sum', 300))", label = "KILLED ${j}", id = "kl${i}" }]
              ]
            )
            annotations = { horizontal = [{ value = 1, label = "Failures present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 9
          width  = 8
          height = 6
          properties = {
            title  = "Driver JVM Heap Usage / CPU Load (max, per job)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            # Gauges: MAX collapses per-run series to the peak per job.
            metrics = concat(
              [for i, j in each.value.glue_jobs :
                [{ expression = "MAX(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.jvm.heap.usage\" JobName=\"${j}\"', 'Maximum', 300))", label = "heap ${j}", id = "hp${i}" }]
              ],
              [for i, j in each.value.glue_jobs :
                [{ expression = "MAX(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.system.cpuSystemLoad\" JobName=\"${j}\"', 'Maximum', 300))", label = "cpu ${j}", id = "cp${i}" }]
              ]
            )
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 9
          width  = 8
          height = 6
          properties = {
            title  = "S3 Bytes Read / Written (per job)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = concat(
              [for i, j in each.value.glue_jobs :
                [{ expression = "SUM(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.s3.filesystem.read_bytes\" JobName=\"${j}\"', 'Sum', 300))", label = "read ${j}", id = "rb${i}" }]
              ],
              [for i, j in each.value.glue_jobs :
                [{ expression = "SUM(SEARCH('{Glue,JobName,JobRunId,Type} MetricName=\"glue.driver.s3.filesystem.write_bytes\" JobName=\"${j}\"', 'Sum', 300))", label = "write ${j}", id = "wb${i}" }]
              ]
            )
          }
        },
        {
          # Categorized error counts from Glue log metric filters (namespace
          # Platform/Glue). Account-wide (filters count across the log group),
          # so identical on dev/test. Generic ERROR count omitted as noise.
          type   = "metric"
          x      = 0
          y      = 15
          width  = 24
          height = 6
          properties = {
            title  = "Glue Error Counts by Category (from logs) — empty until a matching error is logged"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            stat   = "Sum"
            period = 300
            metrics = [
              ["Platform/Glue", "GlueSchemaErrors", { label = "Schema errors" }],
              ["Platform/Glue", "GlueAccessDenied", { label = "Access denied" }],
              ["Platform/Glue", "GlueOutOfMemory", { label = "OOM" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "Errors present", color = "#d62728" }] }
          }
        },
      ],
      # ── Athena: Query Outcomes & Cost (env-filtered) ───────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 22
          width      = 24
          height     = 1
          properties = { markdown = "## Athena — Query Outcomes & Cost" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 23
          width  = 8
          height = 6
          properties = {
            # Failed vs succeeded query counts per workgroup (Glue/S3 workgroups
            # only; Tables excluded). One line per workgroup+state via SampleCount.
            title  = "Query Failures & Successes (per workgroup)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = concat(
              [for w in each.value.workgroups : [{ expression = "SUM(SEARCH('{AWS/Athena,WorkGroup,QueryState,QueryType} MetricName=\"TotalExecutionTime\" WorkGroup=\"${w}\" QueryState=\"FAILED\"', 'SampleCount', 300))", label = "FAILED ${w}" }]],
              [for w in each.value.workgroups : [{ expression = "SUM(SEARCH('{AWS/Athena,WorkGroup,QueryState,QueryType} MetricName=\"TotalExecutionTime\" WorkGroup=\"${w}\" QueryState=\"SUCCEEDED\"', 'SampleCount', 300))", label = "OK ${w}" }]]
            )
            annotations = { horizontal = [{ value = 1, label = "Failures present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 23
          width  = 8
          height = 6
          properties = {
            title  = "Data Scanned — ProcessedBytes (cost proxy, per workgroup)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = [for w in each.value.workgroups : [
              "AWS/Athena", "ProcessedBytes", "WorkGroup", w, { stat = "Sum", label = w }
            ]]
          }
        },
        {
          # AWS/Usage metrics are account-level (no workgroup/env dimension), so
          # this concurrency/submission view is identical on dev and test.
          type   = "metric"
          x      = 16
          y      = 23
          width  = 8
          height = 6
          properties = {
            title  = "Active Query Count (DML) & Query Submissions — account"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = [
              ["AWS/Usage", "ResourceCount", "Type", "Resource", "Resource", "ActiveQueryCount", "Service", "Athena", "Class", "DML", { stat = "Maximum", label = "Active DML queries" }],
              ["AWS/Usage", "CallCount", "Type", "API", "Resource", "StartQueryExecution", "Service", "Athena", "Class", "None", { stat = "Sum", label = "Query submissions" }]
            ]
          }
        },
      ],
      # ── S3: Storage (env-filtered by bucket name) ──────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 29
          width      = 24
          height     = 1
          properties = { markdown = "## S3 — Storage" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 30
          width  = 12
          height = 6
          properties = {
            title  = "Bucket Size Bytes (per bucket)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 86400
            metrics = [for b in each.value.buckets : [
              "AWS/S3", "BucketSizeBytes", "BucketName", b, "StorageType", "StandardStorage"
            ]]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 30
          width  = 12
          height = 6
          properties = {
            title  = "Number of Objects (per bucket)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 86400
            metrics = [for b in each.value.buckets : [
              "AWS/S3", "NumberOfObjects", "BucketName", b, "StorageType", "AllStorageTypes"
            ]]
          }
        },
      ],
      # ── S3: Requests & Errors (populates once request metrics are enabled) ─────
      [
        {
          type       = "text"
          x          = 0
          y          = 36
          width      = 24
          height     = 1
          properties = { markdown = "## S3 — Requests & Errors  \n_Populates once **request metrics** are enabled on the relevant buckets (opt-in per bucket)._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 37
          width  = 8
          height = 6
          properties = {
            title  = "Request Errors — 4xx / 5xx (per EDP bucket)"
            view   = "timeSeries"
            region = local.datalake_dashboard_region
            period = 300
            metrics = concat(
              [for b in each.value.buckets : [{ expression = "SEARCH('{AWS/S3,BucketName,FilterId} MetricName=\"4xxErrors\" BucketName=\"${b}\"', 'Sum', 300)", label = "4xx ${b}" }]],
              [for b in each.value.buckets : [{ expression = "SEARCH('{AWS/S3,BucketName,FilterId} MetricName=\"5xxErrors\" BucketName=\"${b}\"', 'Sum', 300)", label = "5xx ${b}" }]]
            )
            annotations = { horizontal = [{ value = 1, label = "Errors present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 37
          width  = 8
          height = 6
          properties = {
            title   = "Request Rate (per EDP bucket)"
            view    = "timeSeries"
            region  = local.datalake_dashboard_region
            period  = 300
            metrics = [for b in each.value.buckets : [{ expression = "SEARCH('{AWS/S3,BucketName,FilterId} MetricName=\"AllRequests\" BucketName=\"${b}\"', 'Sum', 300)", label = "Requests ${b}" }]]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 37
          width  = 8
          height = 6
          properties = {
            title   = "Request Latency p95 (ms, per EDP bucket)"
            view    = "timeSeries"
            region  = local.datalake_dashboard_region
            period  = 300
            metrics = [for b in each.value.buckets : [{ expression = "SEARCH('{AWS/S3,BucketName,FilterId} MetricName=\"TotalRequestLatency\" BucketName=\"${b}\"', 'p95', 300)", label = "Latency ${b}" }]]
          }
        },
      ]
    )
  })
}

output "datalake_dashboard_urls" {
  description = "CloudWatch Data Lake (S3 + Glue + Athena) dashboard URLs, per environment"
  value = {
    for env, dash in aws_cloudwatch_dashboard.datalake :
    env => "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards/dashboard/${dash.dashboard_name}"
  }
}
