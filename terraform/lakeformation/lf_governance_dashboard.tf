# Lake Formation Access Governance dashboard.
#
# Data source: the existing LF end-to-end verifier canary, which publishes
# success-flag metrics (1 = check passed, 0 = failed) in namespace
# ChedawsEDP/LFE2EVerifier, dimension Environment.
#
# Tracks whichever environment this root module is applied for, matching the
# verifier resources in lakeformation.tf (aws_lambda_function.lf_verifier,
# aws_cloudwatch_log_group.lf_verifier, etc.), which are built from
# local.environment and are not gated to a single environment. In practice
# this account is only ever applied with terraform.workspace = test, since
# Lake Formation is account-scoped (one LF setup per account, test was
# chosen for this account) and dev has no LF resources.
#
# How to read it (the core requirement: tell enforcement from misconfiguration
# from platform failure):
#   Authorised access is allowed  -> a principal that SHOULD have access does.
#                       Value should be 1. A drop to 0 = legitimate access
#                       wrongly blocked = MISCONFIGURATION.
#   Unauthorised access is blocked -> a principal that should NOT have access is
#                       blocked. Value should be 1. A drop to 0 = access wrongly
#                       allowed = ENFORCEMENT GAP (security issue).
#   Verifier Lambda errors / no data -> the canary itself failed to run =
#                       PLATFORM FAILURE (the checks above can't be trusted).
#
# Checks cover both access models (LF-Tag = TBAC, Resource Permission = RBAC)
# across both engines (Redshift, S3 Tables).
locals {
  # The verifier resources in lakeformation.tf are not env-gated - they're
  # built from local.environment like everything else, so this dashboard
  # tracks whichever environment is actually applied instead of assuming test.
  lf_env    = local.environment
  lf_region = data.aws_region.current.region
  lf_ns     = "ChedawsEDP/LFE2EVerifier"

  # verifier Lambda name (for the "did the canary run" health widget)
  lf_lambda_name = aws_lambda_function.lf_verifier.function_name

  # verifier log group (for the failure-reason Logs Insights widget)
  lf_log_group = aws_cloudwatch_log_group.lf_verifier.name
}

resource "aws_cloudwatch_dashboard" "lf_governance" {
  dashboard_name = "chedaws-edp-${local.lf_env}-lf-access-governance"

  dashboard_body = jsonencode({
    # The LF verifier canary runs once per day (~07:00 UTC), so these are DAILY
    # metrics. Force a wide default window so the daily datapoints are visible on
    # open — a short default range shows an empty graph even though data exists.
    start          = "-P14D"
    periodOverride = "inherit"

    widgets = concat(
      # ── Header / how-to-read ──────────────────────────────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 0
          width      = 24
          height     = 2
          properties = { markdown = "# Lake Formation — Access Governance\nA scheduled canary checks LF permissions daily (Lake Formation is deployed in **test** only). **Every line should sit at 1.**  A line dropping to 0 means:  **‘Authorised access is allowed’ → 0** = legitimate users wrongly blocked (misconfiguration).  **‘Unauthorised access is blocked’ → 0** = people wrongly getting in (security gap).  **Verifier health → errors / no data** = the canary itself failed (can't trust the checks until it recovers)." }
        },
      ],
      # ── Positive checks (should be 1; a drop = misconfiguration) ───────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 2
          width      = 24
          height     = 1
          properties = { markdown = "## Authorised access is allowed  \n_Users who SHOULD have access can get in. A drop to 0 = legitimate access is being **wrongly blocked** (misconfiguration)._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 3
          width  = 12
          height = 6
          properties = {
            title  = "Redshift — authorised access works (1 = allowed OK, drop = wrongly blocked)"
            view   = "timeSeries"
            region = local.lf_region
            stat   = "Minimum"
            period = 86400
            metrics = [
              [local.lf_ns, "RedshiftLfTagPositiveCheckSuccess", "Environment", local.lf_env, { label = "TBAC (LF-Tag)" }],
              [local.lf_ns, "RedshiftResourcePermissionPositiveCheckSuccess", "Environment", local.lf_env, { label = "RBAC (Resource)" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "pass = 1", color = "#2ca02c" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 3
          width  = 12
          height = 6
          properties = {
            title  = "S3 Tables — authorised access works (1 = allowed OK, drop = wrongly blocked)"
            view   = "timeSeries"
            region = local.lf_region
            stat   = "Minimum"
            period = 86400
            metrics = [
              [local.lf_ns, "S3TablesLfTagPositiveCheckSuccess", "Environment", local.lf_env, { label = "TBAC (LF-Tag)" }],
              [local.lf_ns, "S3TablesResourcePermissionPositiveCheckSuccess", "Environment", local.lf_env, { label = "RBAC (Resource)" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "pass = 1", color = "#2ca02c" }] }
          }
        },
      ],
      # ── Negative checks (should be 1; a drop = enforcement gap) ────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 9
          width      = 24
          height     = 1
          properties = { markdown = "## Unauthorised access is blocked  \n_Users who should NOT have access are stopped. A drop to 0 = access is being **wrongly allowed** (security gap)._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 10
          width  = 12
          height = 6
          properties = {
            title  = "Redshift — unauthorised access blocked (1 = correctly blocked, drop = wrongly allowed)"
            view   = "timeSeries"
            region = local.lf_region
            stat   = "Minimum"
            period = 86400
            metrics = [
              [local.lf_ns, "RedshiftLfTagNegativeCheckSuccess", "Environment", local.lf_env, { label = "TBAC (LF-Tag)" }],
              [local.lf_ns, "RedshiftResourcePermissionNegativeCheckSuccess", "Environment", local.lf_env, { label = "RBAC (Resource)" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "correctly blocked = 1", color = "#2ca02c" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 10
          width  = 12
          height = 6
          properties = {
            title  = "S3 Tables — unauthorised access blocked (1 = correctly blocked, drop = wrongly allowed)"
            view   = "timeSeries"
            region = local.lf_region
            stat   = "Minimum"
            period = 86400
            metrics = [
              [local.lf_ns, "S3TablesLfTagNegativeCheckSuccess", "Environment", local.lf_env, { label = "TBAC (LF-Tag)" }],
              [local.lf_ns, "S3TablesResourcePermissionNegativeCheckSuccess", "Environment", local.lf_env, { label = "RBAC (Resource)" }]
            ]
            annotations = { horizontal = [{ value = 1, label = "correctly blocked = 1", color = "#2ca02c" }] }
          }
        },
      ],
      # ── Verifier health (platform failure detection) ───────────────────────────
      [
        {
          type       = "text"
          x          = 0
          y          = 16
          width      = 24
          height     = 1
          properties = { markdown = "## Is the checker itself working?  \n_If the canary stops running or errors, the checks above are stale — don't trust a green board if this is red._" }
        },
        {
          type   = "metric"
          x      = 0
          y      = 17
          width  = 12
          height = 6
          properties = {
            title  = "Verifier ran without errors (canary health — expect 0 errors)"
            view   = "timeSeries"
            region = local.lf_region
            stat   = "Sum"
            period = 86400
            metrics = [
              ["AWS/Lambda", "Errors", "FunctionName", local.lf_lambda_name],
              ["AWS/Lambda", "Invocations", "FunctionName", local.lf_lambda_name]
            ]
            annotations = { horizontal = [{ value = 1, label = "errors present", color = "#d62728" }] }
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 17
          width  = 12
          height = 6
          properties = {
            title  = "Test data cleaned up after each run (1 = clean)"
            view   = "timeSeries"
            region = local.lf_region
            stat   = "Minimum"
            period = 86400
            metrics = [
              [local.lf_ns, "RedshiftCleanupSuccess", "Environment", local.lf_env],
              [local.lf_ns, "S3TablesCleanupSuccess", "Environment", local.lf_env]
            ]
            annotations = { horizontal = [{ value = 1, label = "clean = 1", color = "#2ca02c" }] }
          }
        },
      ],
      # ── Why did a check fail? (log detail — permission vs platform failure) ────
      [
        {
          type       = "text"
          x          = 0
          y          = 23
          width      = 24
          height     = 1
          properties = { markdown = "## Why did a check fail? — permission vs platform failure  \n_Pulled from the verifier's own run summary. Read the `detail`: **‘Insufficient Lake Formation permission’** = a real access/permissions issue; **‘timed out’ / ‘INTERNAL_ERROR’ / ‘Catalog … does not exist’** = a platform/setup issue (not a permissions failure)._" }
        },
        {
          type   = "log"
          x      = 0
          y      = 24
          width  = 24
          height = 8
          properties = {
            title  = "Latest verifier runs — status & failure reason (Redshift + S3 Tables)"
            region = local.lf_region
            query  = "SOURCE '${local.lf_log_group}' | fields @timestamp, redshift.status as redshift, redshift.detail as redshift_reason, s3tables.status as s3tables, s3tables.detail as s3tables_reason | filter ispresent(status) | sort @timestamp desc | limit 20"
            view   = "table"
          }
        },
      ]
    )
  })
}

output "lf_governance_dashboard_url" {
  description = "Lake Formation Access Governance dashboard URL"
  value       = "https://${local.lf_region}.console.aws.amazon.com/cloudwatch/home?region=${local.lf_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.lf_governance.dashboard_name}"
}
