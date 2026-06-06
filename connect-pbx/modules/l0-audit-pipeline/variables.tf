variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "S3 state bucket name from PRD-00. Injected at runtime via GitHub Actions secret."
}
