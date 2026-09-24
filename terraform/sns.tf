resource "aws_sns_topic" "alerts" {
  name              = "chedaws-edp-alerts-${local.environment}"
  kms_master_key_id = module.kms["sns"].key_arn
  display_name      = "EDP Alerts – ${upper(local.environment)}"
}
