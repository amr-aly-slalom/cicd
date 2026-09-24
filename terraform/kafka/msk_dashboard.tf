locals {
  msk_cluster_name = aws_msk_cluster.this.cluster_name
  msk_region       = data.aws_region.current.region
  msk_brokers      = [for i in range(1, aws_msk_cluster.this.number_of_broker_nodes + 1) : tostring(i)]
}

# ── Dashboard: MSK Cluster (health + per-broker resources + consumer lag) ──────
resource "aws_cloudwatch_dashboard" "msk_cluster" {
  dashboard_name = "chedaws-edp-${local.environment}-msk-cluster"

  dashboard_body = jsonencode({
    widgets = concat(
      # ── Cluster Health ────────────────────────────────────────────────────────
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
          width  = 6
          height = 6
          properties = {
            # ActiveControllerCount is reported per broker as 0 (not controller)
            # or 1 (controller). Use MAXIMUM: healthy = a controller exists (max
            # is 1); a drop to 0 means NO controller anywhere. Minimum would
            # always read 0 because the non-controller brokers report 0.
            title  = "Active Controller (expect 1)"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Kafka", "ActiveControllerCount", "Cluster Name", local.msk_cluster_name]
            ]
            annotations = { horizontal = [{ value = 1, label = "1 controller expected", color = "#2ca02c" }] }
          }
        },
        {
          type   = "metric"
          x      = 6
          y      = 1
          width  = 6
          height = 6
          properties = {
            title  = "Offline Partitions (expect 0)"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Maximum"
            period = 60
            metrics = [
              ["AWS/Kafka", "OfflinePartitionsCount", "Cluster Name", local.msk_cluster_name]
            ]
            annotations = { horizontal = [{ value = 1, label = "Offline present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 1
          width  = 6
          height = 6
          properties = {
            # Per-broker metric (dims Cluster Name + Broker ID); one line per
            # broker so a single struggling broker is visible.
            title       = "Under-Replicated Partitions (expect 0)"
            view        = "timeSeries"
            region      = local.msk_region
            stat        = "Maximum"
            period      = 60
            metrics     = [for b in local.msk_brokers : ["AWS/Kafka", "UnderReplicatedPartitions", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [{ value = 1, label = "Under-replicated present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 18
          y      = 1
          width  = 6
          height = 6
          properties = {
            # Per-broker metric (dims Cluster Name + Broker ID); one line per broker.
            title       = "Under-Min-ISR Partitions (expect 0)"
            view        = "timeSeries"
            region      = local.msk_region
            stat        = "Maximum"
            period      = 60
            metrics     = [for b in local.msk_brokers : ["AWS/Kafka", "UnderMinIsrPartitionCount", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [{ value = 1, label = "Below min ISR", color = "#d62728" }] }
          }
        },
      ],
      # ── Per-Broker CPU & Memory (Maximum — hottest broker) ─────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 7
          width      = 24
          height     = 1
          properties = { markdown = "## Per-Broker CPU & Memory" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 8
          width  = 12
          height = 6
          properties = {
            title  = "Broker CPU %"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Maximum"
            period = 60
            metrics = concat(
              [for b in local.msk_brokers : ["AWS/Kafka", "CpuUser", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "CpuUser b${b}" }]],
              [for b in local.msk_brokers : ["AWS/Kafka", "CpuSystem", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "CpuSystem b${b}" }]]
            )
            annotations = { horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 8
          width  = 12
          height = 6
          properties = {
            title       = "Broker Memory %"
            view        = "timeSeries"
            region      = local.msk_region
            stat        = "Maximum"
            period      = 60
            metrics     = [for b in local.msk_brokers : ["AWS/Kafka", "MemoryUsed", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [{ value = 80, label = "80% warning", color = "#ff7f0e" }] }
          }
        },
      ],
      # ── Per-Broker Disk (Maximum) ──────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 14
          width      = 24
          height     = 1
          properties = { markdown = "## Per-Broker Disk" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 15
          width  = 12
          height = 6
          properties = {
            title   = "Data Log Disk % (broker down at full)"
            view    = "timeSeries"
            region  = local.msk_region
            stat    = "Maximum"
            period  = 60
            metrics = [for b in local.msk_brokers : ["AWS/Kafka", "KafkaDataLogsDiskUsed", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [
              { value = 85, label = "85% warning", color = "#ff7f0e" },
              { value = 95, label = "95% critical", color = "#d62728" }
            ] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 15
          width  = 12
          height = 6
          properties = {
            title       = "Root Disk %"
            view        = "timeSeries"
            region      = local.msk_region
            stat        = "Maximum"
            period      = 60
            metrics     = [for b in local.msk_brokers : ["AWS/Kafka", "RootDiskUsed", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [{ value = 85, label = "85% warning", color = "#ff7f0e" }] }
          }
        },
      ],
      # ── Per-Broker Thread Saturation (Minimum idle — busiest moment) ───────────
      [
        {
          type       = "text"
          x          = 0
          y          = 21
          width      = 24
          height     = 1
          properties = { markdown = "## Per-Broker Thread Saturation  \n_Idle % — **Minimum** catches the busiest moment (low idle = saturated)._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 22
          width  = 12
          height = 6
          properties = {
            title       = "Network Thread Idle % (low = saturated)"
            view        = "timeSeries"
            region      = local.msk_region
            stat        = "Minimum"
            period      = 60
            metrics     = [for b in local.msk_brokers : ["AWS/Kafka", "NetworkProcessorAvgIdlePercent", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [{ value = 30, label = "30% idle — saturated", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 22
          width  = 12
          height = 6
          properties = {
            title       = "Request Handler Idle % (low = saturated)"
            view        = "timeSeries"
            region      = local.msk_region
            stat        = "Minimum"
            period      = 60
            metrics     = [for b in local.msk_brokers : ["AWS/Kafka", "RequestHandlerAvgIdlePercent", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
            annotations = { horizontal = [{ value = 30, label = "30% idle — saturated", color = "#d62728" }] }
          }
        },
      ],
      # ── Per-Broker Request Latency (Mean — AWS publishes only *Mean) ───────────
      [
        {
          type       = "text"
          x          = 0
          y          = 28
          width      = 24
          height     = 1
          properties = { markdown = "## Per-Broker Request Latency  \n_AWS publishes only the pre-computed `*Mean` metrics for these (no p95/p99 exists)._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 29
          width  = 12
          height = 6
          properties = {
            title   = "Write Latency (ms)"
            view    = "timeSeries"
            region  = local.msk_region
            stat    = "Average"
            period  = 60
            metrics = [for b in local.msk_brokers : ["AWS/Kafka", "ProduceTotalTimeMsMean", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 29
          width  = 12
          height = 6
          properties = {
            title   = "Read Latency (ms)"
            view    = "timeSeries"
            region  = local.msk_region
            stat    = "Average"
            period  = 60
            metrics = [for b in local.msk_brokers : ["AWS/Kafka", "FetchConsumerTotalTimeMsMean", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "b${b}" }]]
          }
        },
      ],
      # ── Per-Broker Performance (throttling, latency phases, conversions) ───────
      [
        {
          type       = "text"
          x          = 0
          y          = 35
          width      = 24
          height     = 1
          properties = { markdown = "## Per-Broker Performance  \n_Where latency comes from and whether requests are being throttled or slowed by format conversions._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 36
          width  = 12
          height = 6
          properties = {
            title  = "Throttling (>0 = clients throttled)"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Maximum"
            period = 60
            metrics = concat(
              [for b in local.msk_brokers : ["AWS/Kafka", "ProduceThrottleQueueSize", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "produce b${b}" }]],
              [for b in local.msk_brokers : ["AWS/Kafka", "FetchThrottleQueueSize", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "fetch b${b}" }]],
              [for b in local.msk_brokers : ["AWS/Kafka", "RequestThrottleQueueSize", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "request b${b}" }]]
            )
            annotations = { horizontal = [{ value = 1, label = "Throttling active", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 36
          width  = 12
          height = 6
          properties = {
            title  = "Write Latency — Local vs Queue (ms)"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Average"
            period = 60
            metrics = concat(
              [for b in local.msk_brokers : ["AWS/Kafka", "ProduceLocalTimeMsMean", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "local b${b}" }]],
              [for b in local.msk_brokers : ["AWS/Kafka", "ProduceRequestQueueTimeMsMean", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "queue b${b}" }]]
            )
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 42
          width  = 12
          height = 6
          properties = {
            title  = "Read Latency — Local vs Queue (ms)"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Average"
            period = 60
            metrics = concat(
              [for b in local.msk_brokers : ["AWS/Kafka", "FetchConsumerLocalTimeMsMean", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "local b${b}" }]],
              [for b in local.msk_brokers : ["AWS/Kafka", "FetchConsumerRequestQueueTimeMsMean", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "queue b${b}" }]]
            )
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 42
          width  = 12
          height = 6
          properties = {
            title  = "Message Conversions/sec (expect 0)"
            view   = "timeSeries"
            region = local.msk_region
            stat   = "Sum"
            period = 60
            metrics = concat(
              [for b in local.msk_brokers : ["AWS/Kafka", "ProduceMessageConversionsPerSec", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "produce b${b}" }]],
              [for b in local.msk_brokers : ["AWS/Kafka", "FetchMessageConversionsPerSec", "Cluster Name", local.msk_cluster_name, "Broker ID", b, { label = "fetch b${b}" }]]
            )
          }
        },
      ],
      # ── Consumer Lag (mandatory near-real-time pipeline signal) ────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 48
          width      = 24
          height     = 1
          properties = { markdown = "## Consumer Lag  \n_Observable + alertable. SEARCH across all consumer groups/topics for this cluster._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 49
          width  = 12
          height = 6
          properties = {
            title  = "Consumer Lag — seconds behind (p99)"
            view   = "timeSeries"
            region = local.msk_region
            period = 60
            metrics = [
              [{ expression = "SEARCH('{AWS/Kafka,\"Consumer Group\",\"Cluster Name\",Topic} MetricName=\"EstimatedMaxTimeLag\" \"Cluster Name\"=\"${local.msk_cluster_name}\"', 'p99', 60)", id = "lag_time" }]
            ]
            annotations = { horizontal = [{ value = 300, label = "5 min behind", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 49
          width  = 12
          height = 6
          properties = {
            title  = "Consumer Lag — messages behind (max)"
            view   = "timeSeries"
            region = local.msk_region
            period = 60
            metrics = [
              [{ expression = "SEARCH('{AWS/Kafka,\"Consumer Group\",\"Cluster Name\",Topic} MetricName=\"MaxOffsetLag\" \"Cluster Name\"=\"${local.msk_cluster_name}\"', 'Maximum', 60)", id = "lag_offset" }]
            ]
          }
        },
      ]
    )
  })
}

# ── Dashboard: MSK Topics (per-topic throughput — Sum) ─────────────────────────
# MessagesInPerSec / BytesInPerSec / BytesOutPerSec are the only genuinely
# topic-scoped metrics (they carry a Topic dimension). SEARCH auto-discovers
# topics so no hardcoded topic list is needed.
resource "aws_cloudwatch_dashboard" "msk_topics" {
  dashboard_name = "chedaws-edp-${local.environment}-msk-topics"

  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text"
        x          = 0
        y          = 0
        width      = 24
        height     = 1
        properties = { markdown = "## Per-Topic Throughput  \n_Sum = true total throughput. SEARCH auto-discovers topics on this cluster._" }
      },
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Messages In / sec"
          view   = "timeSeries"
          region = local.msk_region
          period = 60
          metrics = [
            [{ expression = "SEARCH('{AWS/Kafka,\"Cluster Name\",\"Broker ID\",Topic} MetricName=\"MessagesInPerSec\" \"Cluster Name\"=\"${local.msk_cluster_name}\"', 'Sum', 60)", id = "min" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Bytes In / sec"
          view   = "timeSeries"
          region = local.msk_region
          period = 60
          metrics = [
            [{ expression = "SEARCH('{AWS/Kafka,\"Cluster Name\",\"Broker ID\",Topic} MetricName=\"BytesInPerSec\" \"Cluster Name\"=\"${local.msk_cluster_name}\"', 'Sum', 60)", id = "bin" }]
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
          title  = "Bytes Out / sec"
          view   = "timeSeries"
          region = local.msk_region
          period = 60
          metrics = [
            [{ expression = "SEARCH('{AWS/Kafka,\"Cluster Name\",\"Broker ID\",Topic} MetricName=\"BytesOutPerSec\" \"Cluster Name\"=\"${local.msk_cluster_name}\"', 'Sum', 60)", id = "bout" }]
          ]
        }
      },
    ]
  })
}


output "msk_cluster_dashboard_url" {
  description = "CloudWatch cluster dashboard URL"
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.msk_cluster.dashboard_name}"
}

output "msk_topics_dashboard_url" {
  description = "CloudWatch topics dashboard URL"
  value       = "https://${data.aws_region.current.region}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.region}#dashboards:name=${aws_cloudwatch_dashboard.msk_topics.dashboard_name}"
}
