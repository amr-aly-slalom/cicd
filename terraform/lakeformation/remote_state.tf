# The CMKs, alerts topic and platform bucket this
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

# The S3 Tables bucket is owned by the s3tables state (terraform/s3tables/) -
# read it from there.
data "terraform_remote_state" "s3tables" {
  backend = "s3"
  config = {
    bucket = "chedaws-prod-terraform-state-file"
    key    = "chedaws-data-platform/chedaws-tf-edp-infra/terraform-state-2026-06/s3tables/terraform.tfstate"
    region = "ap-southeast-2"
  }
  workspace = local.environment
}
