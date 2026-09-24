variable "bucket_arn" {
  description = "ARN of the pre-created S3 Table Bucket that namespaces and tables are created in. One table bucket per account per environment."
  type        = string
}

variable "environment" {
  description = "The target environment (dev, test, uat, prod)."
  type        = string
}

variable "config_dir" {
  description = "Path to the registry directory. Expected layout: <config_dir>/namespaces/<name>.yaml for namespace registrations, and <config_dir>/tables/<name>.yaml for table registrations. Both directories are flat - a table's namespace comes from its own metadata.namespace field, not from file location."
  type        = string
}

variable "enable_namespace_prefix" {
  description = "Whether to prepend 'edp_<environment>_' to namespace names. The table bucket is already per-environment, so this is usually unnecessary."
  type        = bool
  default     = true
}
