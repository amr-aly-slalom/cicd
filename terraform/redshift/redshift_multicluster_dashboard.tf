# Redshift multi-cluster overview dashboard.
#
# A single account-wide "fleet" view of every Redshift cluster, side by side.
# Clusters are discovered dynamically via SEARCH() over the ClusterIdentifier
# dimension — nothing is hardcoded, no environment names, and any new cluster
# appears automatically on the next metric poll. One line per cluster on each
# widget (natural cluster-name labels, no manual labels).
#
# This dashboard is account-wide (not per-environment): the dev and test
# clusters live in the same account, so a single board shows them together.
#
# Aggregation follows the same standards as the per-cluster dashboard:
#   HealthStatus            Minimum  (catch any dip to 0)
#   CPU / Disk / IOPS       Maximum  (catch the worst moment / hottest cluster)
#   Connections             Maximum
#   QueryDuration           p95
#   UserQueriesFailed       Sum

# Discover Redshift clusters dynamically via the tagging API. Used only for the
# per-cluster failed-queries widget (which needs one SUM(SEARCH) per cluster,
# since CloudWatch SEARCH can't sum-per-cluster in a single expression). All
# other widgets discover clusters purely via SEARCH. Filter to EDP clusters by
# ARN prefix — no hardcoded cluster names.
data "aws_resourcegroupstaggingapi_resources" "redshift_clusters" {
  resource_type_filters = ["redshift:cluster"]
}

locals {
  rs_multi_region = data.aws_region.current.region

  # EDP cluster identifiers (last ":"-delimited ARN element), EDP-prefixed only.
  rs_clusters = [
    for r in data.aws_resourcegroupstaggingapi_resources.redshift_clusters.resource_tag_mapping_list :
    element(split(":", r.resource_arn), 6)
    if can(regex("^chedaws-edp", element(split(":", r.resource_arn), 6)))
  ]

  # Every SEARCH includes a "chedaws-edp" filter term so only EDP clusters are
  # shown (non-EDP clusters like test01 are excluded). New EDP clusters appear
  # automatically. To go account-wide, drop the "chedaws-edp" term.
}

resource "aws_cloudwatch_dashboard" "redshift_multicluster" {
  dashboard_name = "chedaws-edp-redshift-all-clusters"

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
          properties = { markdown = "# Redshift — All Clusters Overview  \n_Every EDP cluster (`chedaws-edp*`) in the account, discovered dynamically. One line per cluster._" }
        },
      ],
      # ── Availability ───────────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 1
          width      = 24
          height     = 1
          properties = { markdown = "## Availability" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Health Status per cluster (expect 1)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"HealthStatus\" chedaws-edp', 'Minimum', 300)", id = "h" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "healthy = 1", color = "#2ca02c" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 2
          width  = 12
          height = 6
          properties = {
            title  = "Database Connections per cluster (max)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"DatabaseConnections\" chedaws-edp', 'Maximum', 300)", id = "c" }]
            ]
          }
        },
      ],
      # ── Resource utilisation ─────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 8
          width      = 24
          height     = 1
          properties = { markdown = "## Resource Utilisation" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 9
          width  = 12
          height = 6
          properties = {
            title  = "CPU % per cluster (max)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"CPUUtilization\" chedaws-edp', 'Maximum', 300)", id = "cpu" }]
            ]
            annotations = { horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 9
          width  = 12
          height = 6
          properties = {
            title  = "Disk Used % per cluster (max)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"PercentageDiskSpaceUsed\" chedaws-edp', 'Maximum', 300)", id = "disk" }]
            ]
            annotations = { horizontal = [
              { value = 85, label = "85% warning", color = "#ff7f0e" },
              { value = 95, label = "95% critical", color = "#d62728" }
            ] }
          }
        },
      ],
      # ── Workload ──────────────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 15
          width      = 24
          height     = 1
          properties = { markdown = "## Workload" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 16
          width  = 12
          height = 6
          properties = {
            # QueryDuration is published per latency band (short/medium/long),
            # never at ClusterIdentifier alone — so search includes `latency`.
            # Result: one line per cluster x latency band.
            title  = "Query Duration p95 per cluster & latency band (us)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier,latency} MetricName=\"QueryDuration\" chedaws-edp', 'p95', 300)", id = "qd" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 16
          width  = 12
          height = 6
          properties = {
            # One line per cluster: SUM(SEARCH(... ClusterIdentifier="X")) totals
            # that cluster's failures across all QueryTypes. Clusters are
            # tag-discovered (local.rs_clusters) — no hardcoded names.
            title  = "User Queries Failed per cluster (sum, all query types)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [for i, cid in local.rs_clusters :
              [{ expression = "SUM(SEARCH('{AWS/Redshift,ClusterIdentifier,QueryType} MetricName=\"UserQueriesFailed\" ClusterIdentifier=\"${cid}\"', 'Sum', 300))", label = cid, id = "qf${i}" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "failures present", color = "#d62728" }] }
          }
        },
      ],
      # ── Throughput & Saturation ────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 22
          width      = 24
          height     = 1
          properties = { markdown = "## Throughput & Saturation" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 23
          width  = 12
          height = 6
          properties = {
            title  = "Queries Completed / sec per cluster & latency band (sum)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier,latency} MetricName=\"QueriesCompletedPerSecond\" chedaws-edp', 'Sum', 300)", id = "qc" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 23
          width  = 12
          height = 6
          properties = {
            # Overview altitude: one line per cluster showing the WORST WLM queue
            # wait across all its queues (MAX over the per-wlmid p99). Avoids the
            # cryptic "cluster + wlmid" series; per-queue detail is on the
            # per-cluster dashboard. Clusters tag-discovered — no hardcoded names.
            title  = "WLM Queue Wait p99 — worst queue per cluster (us) — queries waiting to run"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [for i, cid in local.rs_clusters :
              [{ expression = "MAX(SEARCH('{AWS/Redshift,ClusterIdentifier,wlmid} MetricName=\"WLMQueueWaitTime\" ClusterIdentifier=\"${cid}\"', 'p99', 300))", label = cid, id = "wlm${i}" }]
            ]
          }
        },
      ],
      # ── Storage I/O ────────────────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 29
          width      = 24
          height     = 1
          properties = { markdown = "## Storage I/O" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 30
          width  = 12
          height = 6
          properties = {
            title  = "Read / Write Latency p95 per cluster (s)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"ReadLatency\" chedaws-edp', 'p95', 300)", id = "rl" }],
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"WriteLatency\" chedaws-edp', 'p95', 300)", id = "wlat" }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 30
          width  = 12
          height = 6
          properties = {
            title  = "Read / Write IOPS per cluster (max)"
            view   = "timeSeries"
            region = local.rs_multi_region
            period = 300
            metrics = [
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"ReadIOPS\" chedaws-edp', 'Maximum', 300)", id = "riops" }],
              [{ expression = "SEARCH('{AWS/Redshift,ClusterIdentifier} MetricName=\"WriteIOPS\" chedaws-edp', 'Maximum', 300)", id = "wiops" }]
            ]
          }
        },
      ]
    )
  })
}

output "redshift_multicluster_dashboard_url" {
  description = "Redshift all-clusters overview dashboard URL"
  value       = "https://${local.rs_multi_region}.console.aws.amazon.com/cloudwatch/home?region=${local.rs_multi_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.redshift_multicluster.dashboard_name}"
}
