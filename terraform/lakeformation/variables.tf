variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "ap-southeast-2"
}

variable "idc_instance_arn" {
  description = "ARN of the central IAM Identity Centre instance"
  type        = string
  default     = "arn:aws:sso:::instance/ssoins-82599788fabf9a65"
}
