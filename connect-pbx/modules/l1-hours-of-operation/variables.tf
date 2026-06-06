variable "org_name" {
  type        = string
  description = "Organization identifier."
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "hours_of_operation" {
  description = <<-EOT
    Hours of operation schedule inventory. Each key is a human-readable identifier
    (e.g. standard-business, extended, twenty-four-seven).

    IMPORTANT: default is empty map. The schedule inventory MUST be supplied via
    the centralized environment folder, e.g. environments/dev/hours.tfvars.
    Running apply without schedules provisions zero hours of operation resources.
    Standard schedule templates are provided in the tfvars files, not in the variable default.

    Three standard templates are recommended:
      standard-business: Mon-Fri 08:00-18:00 local time
      extended:          Mon-Sat 07:00-21:00 local time
      twenty-four-seven: All days 00:00-23:59
  EOT

  type = map(object({
    name        = string
    description = string
    time_zone   = string
    config = list(object({
      day          = string
      start_hour   = number
      start_minute = number
      end_hour     = number
      end_minute   = number
    }))
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.hours_of_operation :
      alltrue([
        for c in v.config :
        contains([
          "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY",
          "FRIDAY", "SATURDAY", "SUNDAY"
        ], c.day)
      ])
    ])
    error_message = "Each config entry day must be a valid AWS Connect day name."
  }

  validation {
    condition = alltrue([
      for k, v in var.hours_of_operation :
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) || length(k) == 1
    ])
    error_message = "Each hours_of_operation map key must be lowercase alphanumeric with hyphens only."
  }
}

variable "holiday_closures" {
  description = <<-EOT
    Company-specific closure dates. US federal holidays are computed dynamically
    by the daily Lambda and do NOT belong in this variable.

    Use this for company-specific closures only:
      - Company shutdown days (e.g., Dec 26, Dec 31)
      - Office move or maintenance days
      - Industry-specific holidays not covered by US federal holidays

    Default is empty list. Most deployments will have zero or very few entries.
    Dates are absolute (ISO 8601) — each entry applies to a specific calendar date.
  EOT

  type = list(object({
    date          = string       # ISO 8601 date, e.g. "2026-12-25"
    name          = string       # Holiday name, e.g. "Christmas Day"
    schedule_keys = list(string) # Schedule keys this applies to, or ["ALL"]
  }))

  default = []

  validation {
    condition = alltrue([
      for h in var.holiday_closures :
      can(regex("^\\d{4}-\\d{2}-\\d{2}$", h.date))
    ])
    error_message = "Each holiday_closures date must be ISO 8601 format (YYYY-MM-DD)."
  }
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-12. It exists for
# forward compatibility with the platform deployment profile contract
# (authoritative definition in PRD-00 bootstrap module). Every module
# declares this variable with the same schema and defaults so that:
#   - All modules accept the same deployment_profile from tfvars
#   - Modules that need conditional behavior can reference specific fields
#     without changing their variable signature
#
# Do not remove — this is intentional contract consistency, not dead code.
# -----------------------------------------------------------------------
variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs (e.g. SNS topic ARNs)."
}

variable "default_timezone" {
  type        = string
  default     = "America/New_York"
  description = "IANA timezone for the holiday check Lambda and EventBridge schedule comment. Used as the Lambda TIME_ZONE env var."

  validation {
    condition     = can(regex("^[A-Za-z_]+/[A-Za-z_]+(/[A-Za-z_]+)?$", var.default_timezone))
    error_message = "default_timezone must be a valid IANA timezone identifier (e.g. America/New_York, America/Chicago)."
  }
}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. Not consumed by PRD-12 — declared for contract consistency. See PRD-00 for authoritative schema."
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
