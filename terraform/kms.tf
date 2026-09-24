module "kms" {
  for_each = local.kms_services

  source               = "./modules/kms"
  service_name         = each.key
  service_principals   = each.value.service_principals
  publisher_principals = try(each.value.publisher_principals, [])
  environment          = local.environment
}
