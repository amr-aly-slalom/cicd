terraform {
  required_version = ">= 1.10.0" # backend use_lockfile
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }

    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket       = "chedaws-prod-terraform-state-file"
    key          = "chedaws-data-platform/chedaws-tf-edp-infra/terraform-state-2026-06/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
  assume_role {
    role_arn = {
      dev  = "arn:aws:iam::381491832813:role/chedaws-edp-ci-runner",
      test = "arn:aws:iam::381491832813:role/chedaws-edp-ci-runner",
      uat  = "arn:aws:iam::339712719726:role/chedaws-edp-ci-runner",
      prod = "arn:aws:iam::637423180765:role/chedaws-edp-ci-runner"
    }[local.environment]
    session_name = "INFRA_BUILD"
    # uat/prod ci-runner roles allow 1h sessions; the provider refreshes credentials during longer applies.
    duration = contains(["uat", "prod"], local.environment) ? "1h" : "2h"
  }
  default_tags {
    tags = {
      "Environment"      = upper(local.environment)
      "Application"      = "EDP"
      "Entity"           = "VPN_UE"
      "ManagedBy"        = "Terraform"
      "Project"          = "P12107"
      "Team"             = "Data Platform"
      "ApplicationOwner" = "MMaleki@powercor.com.au"
      "BusinessUnit"     = "Technology and Security"
      "GitRepo"          = "chedaws-data-platform/chedaws-tf-edp-infra"
    }
  }
}

provider "random" {}
