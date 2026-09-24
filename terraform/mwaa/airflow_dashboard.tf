locals {
  mwaa_environment      = aws_mwaa_environment.airflow.name
  mwaa_dashboard_region = data.aws_region.current.region
}

# ── Dashboard: Airflow (MWAA) Environment Metrics ─────────────────────────────
resource "aws_cloudwatch_dashboard" "airflow" {
  dashboard_name = "${local.mwaa_environment}-airflow"

  dashboard_body = jsonencode({
    widgets = concat(
      # ── Scheduler Health ────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 0
          width      = 24
          height     = 1
          properties = { markdown = "## Scheduler Health" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 1
          width  = 12
          height = 6
          properties = {
            title  = "Scheduler Heartbeat"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Sum"
            period = 60
            metrics = [
              ["AmazonMWAA", "SchedulerHeartbeat", "Function", "Scheduler", "Environment", local.mwaa_environment]
            ]
            annotations = {
              horizontal = [{ value = 1, label = "Heartbeat expected", color = "#2ca02c" }]
            }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 1
          width  = 12
          height = 6
          properties = {
            title  = "Scheduler CPU / Memory %"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/MWAA", "CPUUtilization", "Cluster", "Scheduler", "Environment", local.mwaa_environment],
              ["AWS/MWAA", "MemoryUtilization", "Cluster", "Scheduler", "Environment", local.mwaa_environment]
            ]
            annotations = {
              horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }]
            }
          }
        },
      ],
      # ── Workers ─────────────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 7
          width      = 24
          height     = 1
          properties = { markdown = "## Workers" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "Base Worker CPU / Memory %"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/MWAA", "CPUUtilization", "Cluster", "BaseWorker", "Environment", local.mwaa_environment],
              ["AWS/MWAA", "MemoryUtilization", "Cluster", "BaseWorker", "Environment", local.mwaa_environment]
            ]
            annotations = {
              horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }]
            }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "Additional (autoscaled) Worker CPU / Memory %"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/MWAA", "CPUUtilization", "Cluster", "AdditionalWorker", "Environment", local.mwaa_environment],
              ["AWS/MWAA", "MemoryUtilization", "Cluster", "AdditionalWorker", "Environment", local.mwaa_environment]
            ]
            annotations = {
              horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }]
            }
          }
        },
      ],
      # ── Task Queue & Throughput ───────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 14
          width      = 24
          height     = 1
          properties = { markdown = "## Task Queue & Throughput" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 15
          width  = 8
          height = 6
          properties = {
            title  = "Tasks Queued vs Running"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AmazonMWAA", "QueuedTasks", "Function", "Executor", "Environment", local.mwaa_environment],
              ["AmazonMWAA", "RunningTasks", "Function", "Executor", "Environment", local.mwaa_environment]
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 15
          width  = 8
          height = 6
          properties = {
            title  = "Tasks Executable (ready to run)"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AmazonMWAA", "TasksExecutable", "Function", "Scheduler", "Environment", local.mwaa_environment]
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 15
          width  = 8
          height = 6
          properties = {
            title  = "DAG Runs Running"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AmazonMWAA", "DagRunsRunning", "Function", "Scheduler", "Environment", local.mwaa_environment]
            ]
          }
        },
      ],
      # ── Web Server ──────────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 21
          width      = 24
          height     = 1
          properties = { markdown = "## Web Server" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 22
          width  = 24
          height = 6
          properties = {
            title  = "Web Server CPU / Memory %"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/MWAA", "CPUUtilization", "Cluster", "WebServer", "Environment", local.mwaa_environment],
              ["AWS/MWAA", "MemoryUtilization", "Cluster", "WebServer", "Environment", local.mwaa_environment]
            ]
            annotations = {
              horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }]
            }
          }
        },
      ],
      # ── DAG & Task Execution ──────────────────────────────────────────────────
      # AmazonMWAA namespace. Task totals are only published at DAG=All (env-wide
      # aggregate); DAG run durations carry a real DAG dimension (per-DAG).
      [
        {
          type       = "text"
          x          = 0
          y          = 28
          width      = 24
          height     = 1
          properties = { markdown = "## DAG & Task Execution  \n_Task success/failure counts are environment-wide totals (`DAG=All`); task duration and DAG run durations are per task / per DAG._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 29
          width  = 12
          height = 6
          properties = {
            title  = "Task Successes vs Failures (environment total)"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            period = 300
            metrics = [
              ["AmazonMWAA", "TaskInstanceSuccesses", "Task", "All", "Environment", local.mwaa_environment, "DAG", "All", { stat = "Sum", label = "Successes" }],
              ["AmazonMWAA", "TaskInstanceFailures", "Task", "All", "Environment", local.mwaa_environment, "DAG", "All", { stat = "Sum", label = "Failures" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "Failures present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 29
          width  = 12
          height = 6
          properties = {
            # TaskInstanceDuration is published per task/DAG only (no All/All
            # aggregate), so SEARCH across tasks — one p95 line per task.
            title  = "Task Instance Duration p95 (ms, per task)"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AmazonMWAA,DAG,Environment,Task} MetricName=\"TaskInstanceDuration\" Environment=\"${local.mwaa_environment}\"', 'p95', 300)", id = "tid" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 35
          width  = 12
          height = 6
          properties = {
            title  = "DAG Run Duration — Success p95 (ms, by DAG)"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AmazonMWAA,DAG,Environment} MetricName=\"DAGDurationSuccess\" Environment=\"${local.mwaa_environment}\"', 'p95', 300)", id = "ds1" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 35
          width  = 12
          height = 6
          properties = {
            title  = "DAG Run Duration — Failed p95 (ms, by DAG)"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AmazonMWAA,DAG,Environment} MetricName=\"DAGDurationFailed\" Environment=\"${local.mwaa_environment}\"', 'p95', 300)", id = "df1" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 41
          width  = 12
          height = 6
          properties = {
            title  = "DAG Import Errors & Parse Time"
            view   = "timeSeries"
            region = local.mwaa_dashboard_region
            stat   = "Sum"
            period = 300
            metrics = [
              ["AmazonMWAA", "ImportErrors", "Function", "DAG Processing", "Environment", local.mwaa_environment],
              ["AmazonMWAA", "TotalParseTime", "Function", "DAG Processing", "Environment", local.mwaa_environment, { stat = "Average" }]
            ]
            annotations = {
              horizontal = [{ value = 1, label = "Import errors present", color = "#d62728" }]
            }
          }
        },
      ]
    )
  })
}

output "airflow_dashboard_url" {
  description = "CloudWatch Airflow (MWAA) dashboard URL"
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.airflow.dashboard_name}"
}
