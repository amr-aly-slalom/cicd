# module.kms["s3"|"cloudwatch_logs"|"ecr"] and aws_sns_topic.alerts are owned
# by the core state and shared with the other stacks - read their ARNs here
# instead of re-declaring the resources, which would collide with the core
# state's copies.
data "terraform_remote_state" "core" {
  backend = "s3"
  config = {
    bucket = "chedaws-prod-terraform-state-file"
    key    = "chedaws-data-platform/chedaws-tf-edp-infra/terraform-state-2026-06/terraform.tfstate"
    region = "ap-southeast-2"
  }
  workspace = local.environment
}

# The Redshift cluster, its master secret and endpoint are owned by the
# redshift state (terraform/redshift/) - read them from there.
data "terraform_remote_state" "redshift" {
  backend = "s3"
  config = {
    bucket = "chedaws-prod-terraform-state-file"
    key    = "chedaws-data-platform/chedaws-tf-edp-infra/terraform-state-2026-06/redshift/terraform.tfstate"
    region = "ap-southeast-2"
  }
  workspace = local.environment
}
