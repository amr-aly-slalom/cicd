locals {
  redshift_dashboard_cluster = aws_redshift_cluster.this.cluster_identifier
  redshift_dashboard_region  = data.aws_region.current.region

  # Node IDs for per-node widgets. Verified against the cluster: Redshift emits
  # "Leader" plus compute nodes "Compute-0 .. Compute-(N-1)". number_of_nodes is
  # the compute-node count, so compute indices are 0..number_of_nodes-1.
  redshift_compute_nodes = [for i in range(0, aws_redshift_cluster.this.number_of_nodes) : "Compute-${i}"]
  redshift_node_ids      = concat(["Leader"], local.redshift_compute_nodes)
}

# ── Dashboard: Redshift Cluster Metrics ───────────────────────────────────────
# Aggregation standards (averages are avoided — they mask spikes and node issues):
#   p95  -> latency / duration
#   Max  -> CPU, disk, IOPS, connections
#   Sum  -> query throughput and counts (incl. failures)
#   p99  -> WLM queue wait (saturation)
# Status flags (HealthStatus, MaintenanceMode) use Min/Max intentionally.
resource "aws_cloudwatch_dashboard" "redshift" {
  dashboard_name = "${local.redshift_dashboard_cluster}-redshift-cluster"

  dashboard_body = jsonencode({
    widgets = concat(
      # ── Cluster Health ──────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 0
          width      = 24
          height     = 1
          properties = { markdown = "## Cluster Health" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 1
          width  = 8
          height = 6
          properties = {
            title  = "Health Status"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Minimum"
            period = 60
            metrics = [
              ["AWS/Redshift", "HealthStatus", "ClusterIdentifier", local.redshift_dashboard_cluster]
            ]
            annotations = {
              horizontal = [{ value = 1, label = "Healthy", color = "#2ca02c" }]
            }
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 1
          width  = 8
          height = 6
          properties = {
            title  = "Maintenance Mode"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Redshift", "MaintenanceMode", "ClusterIdentifier", local.redshift_dashboard_cluster]
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 1
          width  = 8
          height = 6
          properties = {
            title  = "Database Connections (max)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Redshift", "DatabaseConnections", "ClusterIdentifier", local.redshift_dashboard_cluster]
            ]
          }
        },
      ],
      # ── CPU & Disk (cluster) ──────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 7
          width      = 24
          height     = 1
          properties = { markdown = "## CPU & Disk (cluster)" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "CPU Utilization % (max)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Redshift", "CPUUtilization", "ClusterIdentifier", local.redshift_dashboard_cluster]
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
            title  = "Disk Space Used % (max)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Redshift", "PercentageDiskSpaceUsed", "ClusterIdentifier", local.redshift_dashboard_cluster]
            ]
            annotations = {
              horizontal = [
                { value = 85, label = "85% warning", color = "#ff7f0e" },
                { value = 95, label = "95% critical", color = "#d62728" }
              ]
            }
          }
        },
      ],
      # ── Per-Node CPU & Disk ────────────────────────────────────────────────────
      # Node-level view so a single-node spike/failure is not hidden by the
      # cluster aggregate. Uses the NodeID dimension.
      [
        {
          type       = "text"
          x          = 0
          y          = 14
          width      = 24
          height     = 1
          properties = { markdown = "## Per-Node CPU & Disk" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 15
          width  = 12
          height = 6
          properties = {
            title  = "CPU Utilization % (max, per node)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [for n in local.redshift_node_ids : [
              "AWS/Redshift", "CPUUtilization", "ClusterIdentifier", local.redshift_dashboard_cluster, "NodeID", n
            ]]
            annotations = {
              horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }]
            }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 15
          width  = 12
          height = 6
          properties = {
            title  = "Disk Space Used % (max, per node)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [for n in local.redshift_node_ids : [
              "AWS/Redshift", "PercentageDiskSpaceUsed", "ClusterIdentifier", local.redshift_dashboard_cluster, "NodeID", n
            ]]
            annotations = {
              horizontal = [
                { value = 85, label = "85% warning", color = "#ff7f0e" },
                { value = 95, label = "95% critical", color = "#d62728" }
              ]
            }
          }
        },
      ],
      # ── Workload / Query Performance ──────────────────────────────────────────
      # Throughput as Sum; duration as p95 to expose spikes. Failed queries
      # tracked separately so errors don't skew throughput/latency reads.
      [
        {
          type       = "text"
          x          = 0
          y          = 21
          width      = 24
          height     = 1
          properties = { markdown = "## Workload / Query Performance" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 22
          width  = 8
          height = 6
          properties = {
            title  = "Queries Completed / sec (sum, by latency)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Sum"
            period = 60
            metrics = [
              ["AWS/Redshift", "QueriesCompletedPerSecond", "ClusterIdentifier", local.redshift_dashboard_cluster, "latency", "short"],
              ["AWS/Redshift", "QueriesCompletedPerSecond", "ClusterIdentifier", local.redshift_dashboard_cluster, "latency", "medium"],
              ["AWS/Redshift", "QueriesCompletedPerSecond", "ClusterIdentifier", local.redshift_dashboard_cluster, "latency", "long"]
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 22
          width  = 8
          height = 6
          properties = {
            title  = "Query Duration p95 (us, by latency)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "p95"
            period = 60
            metrics = [
              ["AWS/Redshift", "QueryDuration", "ClusterIdentifier", local.redshift_dashboard_cluster, "latency", "short"],
              ["AWS/Redshift", "QueryDuration", "ClusterIdentifier", local.redshift_dashboard_cluster, "latency", "medium"],
              ["AWS/Redshift", "QueryDuration", "ClusterIdentifier", local.redshift_dashboard_cluster, "latency", "long"]
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 22
          width  = 8
          height = 6
          properties = {
            # UserQueriesFailed is dimensioned by QueryType (COPY/SELECT/INSERT/...)
            # with no cluster-only rollup, so SEARCH+SUM totals across all types.
            title  = "User Queries Failed (sum, all query types)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            period = 60
            metrics = [
              [{ expression = "SUM(SEARCH('{AWS/Redshift,ClusterIdentifier,QueryType} MetricName=\"UserQueriesFailed\" ClusterIdentifier=\"${local.redshift_dashboard_cluster}\"', 'Sum', 60))", label = "Queries Failed", id = "qf" }]
            ]
            annotations = {
              horizontal = [{ value = 1, label = "Failures present", color = "#d62728" }]
            }
          }
        },
      ],
      # ── WLM Saturation ──────────────────────────────────────────────────────
      # WLM queue wait as p99 — the signal that queries are queuing rather than
      # executing. Queue length and running queries give concurrency/queue depth.
      [
        {
          type       = "text"
          x          = 0
          y          = 28
          width      = 24
          height     = 1
          properties = { markdown = "## WLM Saturation & Concurrency" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 29
          width  = 8
          height = 6
          properties = {
            # WLMQueueWaitTime by QueryPriority (readable: Normal/High/Critical/…)
            # rather than numeric wlmid. SEARCH surfaces p99 per priority class.
            title  = "WLM Queue Wait Time p99 (us, per query priority)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            period = 60
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier,QueryPriority} MetricName=\"WLMQueueWaitTime\" ClusterIdentifier=\"${local.redshift_dashboard_cluster}\"', 'p99', 60)", id = "wlm" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 29
          width  = 8
          height = 6
          properties = {
            # WLMQueueLength is dimensioned by QueueName (not wlmid): "Default
            # queue", "Short query queue", "Service class for super user".
            title  = "WLM Queue Length (queued queries, per WLM queue)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            period = 60
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier,QueueName} MetricName=\"WLMQueueLength\" ClusterIdentifier=\"${local.redshift_dashboard_cluster}\"', 'Maximum', 60)", id = "wql" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 16
          y      = 29
          width  = 8
          height = 6
          properties = {
            # WLMRunningQueries is dimensioned by QueueName (not wlmid).
            title  = "WLM Running Queries (concurrency, per WLM queue)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            period = 60
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier,QueueName} MetricName=\"WLMRunningQueries\" ClusterIdentifier=\"${local.redshift_dashboard_cluster}\"', 'Maximum', 60)", id = "wrq" }]
            ]
          }
        },
      ],
      # ── I/O ─────────────────────────────────────────────────────────────────
      # Latency as p95; throughput/IOPS as Max.
      [
        {
          type       = "text"
          x          = 0
          y          = 35
          width      = 24
          height     = 1
          properties = { markdown = "## I/O" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 36
          width  = 12
          height = 6
          properties = {
            title  = "Read / Write Latency p95 (s)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "p95"
            period = 60
            metrics = [
              ["AWS/Redshift", "ReadLatency", "ClusterIdentifier", local.redshift_dashboard_cluster],
              ["AWS/Redshift", "WriteLatency", "ClusterIdentifier", local.redshift_dashboard_cluster]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 36
          width  = 12
          height = 6
          properties = {
            title  = "Read / Write IOPS (max)"
            view   = "timeSeries"
            region = local.redshift_dashboard_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Redshift", "ReadIOPS", "ClusterIdentifier", local.redshift_dashboard_cluster],
              ["AWS/Redshift", "WriteIOPS", "ClusterIdentifier", local.redshift_dashboard_cluster]
            ]
          }
        },
      ]
    )
  })
}

output "redshift_dashboard_url" {
  description = "CloudWatch Redshift dashboard URL"
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.redshift.dashboard_name}"
}
