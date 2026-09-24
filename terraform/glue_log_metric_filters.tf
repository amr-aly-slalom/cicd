# =============================================================================
# Glue log metric filters — turn error-log patterns into CloudWatch metrics
variable "glue_error_log_group" {
  description = "CloudWatch log group holding Glue job error logs"
  type        = string
  default     = "/aws-glue/jobs/error"
}

# Namespace: a fixed naming convention (not a resource/AWS-created value). Kept
# as a local so it stays consistent — the datalake dashboard's error-category
# widget references "Platform/Glue" directly, so changing this must be matched
# in that widget.
locals {
  glue_metric_namespace = "Platform/Glue"
}

# ── Generic ERROR count ───────────────────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "glue_errors" {
  name           = "glue-job-errors"
  log_group_name = var.glue_error_log_group
  pattern        = "ERROR"

  metric_transformation {
    name          = "GlueJobErrors"
    namespace     = local.glue_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ── Schema-related errors (Spark AnalysisException, unresolved columns) ────────
resource "aws_cloudwatch_log_metric_filter" "glue_schema_errors" {
  name           = "glue-schema-errors"
  log_group_name = var.glue_error_log_group
  pattern        = "AnalysisException"

  metric_transformation {
    name          = "GlueSchemaErrors"
    namespace     = local.glue_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ── S3 / data-access denials ──────────────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "glue_access_denied" {
  name           = "glue-access-denied"
  log_group_name = var.glue_error_log_group
  pattern        = "AccessDenied"

  metric_transformation {
    name          = "GlueAccessDenied"
    namespace     = local.glue_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ── Out-of-memory failures ────────────────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "glue_oom" {
  name           = "glue-out-of-memory"
  log_group_name = var.glue_error_log_group
  pattern        = "OutOfMemoryError"

  metric_transformation {
    name          = "GlueOutOfMemory"
    namespace     = local.glue_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
