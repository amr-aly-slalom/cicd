variable "service_name" {
  description = "Service name used in alias and description, e.g. redshift"
  type        = string
}

variable "service_principals" {
  description = "One or more AWS service principals granted KMS actions, e.g. [\"redshift.amazonaws.com\"]"
  type        = set(string)

  validation {
    condition     = length(var.service_principals) > 0
    error_message = "At least one service principal must be provided."
  }
}

variable "publisher_principals" {
  description = "AWS service principals that publish to resources encrypted with this key (e.g. CloudWatch alarms to an SNS topic). Granted only kms:GenerateDataKey* and kms:Decrypt, limited to this account."
  type        = set(string)
  default     = []
}

variable "environment" {
  description = "Terraform workspace name, embedded in alias suffix"
  type        = string
}
