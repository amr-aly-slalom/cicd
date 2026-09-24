# The CMKs and alerts topic this
# stack uses are owned by the core state - read them here instead of
# re-declaring them, which would collide with core's copies.
data "terraform_remote_state" "core" {
  backend = "s3"
  config = {
    bucket = "chedaws-prod-terraform-state-file"
    key    = "chedaws-data-platform/chedaws-tf-edp-infra/terraform-state-2026-06/terraform.tfstate"
    region = "ap-southeast-2"
  }
  workspace = local.environment
}
