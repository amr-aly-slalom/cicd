# Own KMS CMK, not the existing alias/chedaws-edp-ecr-<env> the MWAA
# namespace repos use (terraform/mwaa/data.tf as a data source - it's
# provisioned somewhere outside this repo entirely, nowhere any `resource`
# creates it). This stack must apply cleanly on an account where nothing
# else in this repo has ever been deployed, so it gets its own key via the
# shared module every other service here uses (terraform/kms.tf), rather
# than an implicit dependency on another stack's - or another repo's -
# prior apply.
module "kms" {
  source             = "../modules/kms"
  service_name       = "ci-image"
  service_principals = ["ecr.amazonaws.com"]
  environment        = local.environment
}

# ECR repo for the pre-built CI image (Terraform + this repo's provider
# cache + ty/trivy/tflint baked in - see docker/ci-image/Dockerfile). Not
# reusing the existing aws_ecr_repository.mwaa_namespace repos
# (terraform/mwaa/mwaa.tf): those are runtime images pulled by ECS Fargate
# task execution roles for MWAA namespaces, a different kind of consumer
# from a CI build-tooling image - a separate, purpose-specific repo keeps
# that distinction real instead of overloading an unrelated resource.
#
# One repo per environment/account, matching the mwaa_namespace pattern.
# Published and consumed by the SAME role in each account
# (chedaws-edp-ci-runner - see providers.tf), unlike mwaa_namespace's repos,
# which separate a Fargate pull principal from a CI push principal; here
# both the publish workflow and every tf-deploy.yaml container: job assume
# that one role, so a single principal covers both actions.
#trivy:ignore:AWS-0031 MUTABLE tags required; :latest is republished on every image update
resource "aws_ecr_repository" "ci_image" {
  #checkov:skip=CKV_AWS_51: MUTABLE tags required; :latest is republished on every image update
  name                 = "chedaws-edp-ci-image-${local.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = module.kms.key_arn
  }

  tags = {
    Name = "chedaws-edp-ci-image-${local.environment}"
  }
}

resource "aws_ecr_repository_policy" "ci_image" {
  repository = aws_ecr_repository.ci_image.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CIRunnerPushAndPull"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.aws_account_id}:role/chedaws-edp-ci-runner"
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
      },
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "ci_image" {
  repository = aws_ecr_repository.ci_image.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

output "ci_image_repository_url" {
  value = aws_ecr_repository.ci_image.repository_url
}
