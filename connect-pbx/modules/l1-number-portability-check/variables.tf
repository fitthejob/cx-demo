variable "org_name" {
  type        = string
  description = "Organization identifier."
}

variable "repo_name" {
  type        = string
  description = "Repository identifier accepted from shared global tfvars. Not consumed by this module."
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-15"
}

variable "lookup_provider" {
  type        = string
  default     = "mock"
  description = "Active lookup provider. v1 supports mock and bandwidth."

  validation {
    condition     = contains(["mock", "bandwidth"], var.lookup_provider)
    error_message = "lookup_provider must be one of: mock, bandwidth."
  }
}

variable "lookup_provider_secret_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager ARN for the active provider. Leave empty only when lookup_provider = mock."

  validation {
    condition     = var.lookup_provider == "mock" || length(trimspace(var.lookup_provider_secret_arn)) > 0
    error_message = "lookup_provider_secret_arn is required when lookup_provider is not mock."
  }
}

variable "check_expiry_days" {
  type        = number
  default     = 30
  description = "Number of days after which a portability check becomes stale for workflow gating."

  validation {
    condition     = var.check_expiry_days >= 1 && var.check_expiry_days <= 365
    error_message = "check_expiry_days must be between 1 and 365."
  }
}

variable "history_ttl_days" {
  type        = number
  default     = 365
  description = "Retention window for historical CHECK and OVERRIDE records."

  validation {
    condition     = var.history_ttl_days >= 30 && var.history_ttl_days <= 3650
    error_message = "history_ttl_days must be between 30 and 3650."
  }
}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. Not consumed by PRD-15 for behavior selection today, but declared for contract consistency."
  type = object({
    mode             = string
    instance_count   = number
    multi_az         = bool
    cross_region     = bool
    agent_capacity   = string
    account_topology = string
    hub_account_id   = string
    org_id           = string
    shared_bus_arn   = string
    optional_layers = object({
      sso_enabled        = bool
      crm_enabled        = bool
      compliance_enabled = bool
    })
  })
  default = {
    mode             = "single"
    instance_count   = 1
    multi_az         = false
    cross_region     = false
    agent_capacity   = "small"
    account_topology = "standalone"
    hub_account_id   = ""
    org_id           = ""
    shared_bus_arn   = ""
    optional_layers = {
      sso_enabled        = false
      crm_enabled        = false
      compliance_enabled = false
    }
  }
}
