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

variable "phone_numbers" {
  description = <<-EOT
    Phone number inventory map. Each key is a human-readable identifier (e.g. main-inbound,
    sales, support). Modify this map in the environment folder
    (for example environments/dev/phone-numbers.tfvars) to add or remove numbers —
    no module code changes required.

    By default, digits are NOT specified here. AWS assigns the next available number from
    its telephony pool for the given country_code, type, and optional prefix. The actual
    E.164 number is available after apply in the phone_number_inventory output.

    If existing_phone_number is provided, PRD-11 first checks whether that exact E.164
    number is already claimed to the target Connect instance. If it exists, the module
    reuses it and exports its existing ID/ARN instead of claiming a new number. If it is
    not found and claim_if_missing is true, PRD-11 falls back to the normal claim path.
    This fallback claims a number using the country/type/prefix inputs and does NOT
    guarantee the same exact E.164 number.

    prefix: Optional area code hint in E.164 prefix format (e.g. "+1212" for NYC, "+1415"
    for San Francisco). AWS will attempt to claim a number matching this prefix. If no
    inventory is available, the apply fails — try a different prefix or set null to accept
    any available number. Prefix availability is not guaranteed.

    IMPORTANT: default is empty map. The phone number inventory MUST be supplied via
    the centralized environment folder, e.g. environments/dev/phone-numbers.tfvars.
    Running apply without the tfvars file provisions zero numbers (safe). Running
    apply with the tfvars file provisions exactly the numbers listed. Each claimed
    number accrues charges immediately.
  EOT

  type = map(object({
    description           = string
    type                  = string               # DID or TOLL_FREE
    country_code          = string               # ISO 3166-1 alpha-2 e.g. US, GB, CA, AU
    prefix                = optional(string)     # E.164 prefix e.g. "+1212". null = any available.
    existing_phone_number = optional(string)     # Exact E.164 number to reuse if already claimed to the instance.
    claim_if_missing      = optional(bool, true) # Fall back to the normal claim path when existing_phone_number is absent from the instance.
    purpose               = string               # e.g. main-inbound, sales, support, billing
    cost_center           = string               # Business unit for cost allocation
    cnam_name             = optional(string)     # Optional per-number employee CNAM label for PRD-17.
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      contains(["DID", "TOLL_FREE"], v.type)
    ])
    error_message = "Each phone_numbers entry type must be DID or TOLL_FREE."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      v.prefix == null || can(regex("^\\+[0-9]{1,6}$", v.prefix))
    ])
    error_message = "Each prefix must be null or an E.164 prefix string e.g. \"+1212\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      try(v.existing_phone_number, null) == null || can(regex("^\\+[1-9][0-9]{1,14}$", v.existing_phone_number))
    ])
    error_message = "Each existing_phone_number must be null or a full E.164 string e.g. \"+14155551234\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      length(trimspace(v.purpose)) > 0 && length(trimspace(v.cost_center)) > 0
    ])
    error_message = "Each phone_numbers entry must have non-empty purpose and cost_center."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) || length(k) == 1
    ])
    error_message = "Each phone_numbers map key must be lowercase alphanumeric with hyphens only (e.g. main-inbound, sales)."
  }
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-11. It exists for
# forward compatibility with the platform deployment profile contract
# (authoritative definition in PRD-00 bootstrap module). Every module
# declares this variable with the same schema and defaults so that:
#   - All modules accept the same deployment_profile from tfvars
#   - Modules that need conditional behavior (e.g. l0-account-baseline
#     uses .cross_region for KMS, l1-connect-instance uses
#     .optional_layers.sso_enabled for identity management) can reference
#     specific fields without changing their variable signature
#   - When the platform scales beyond single-instance (instance_count > 1),
#     PRD-11 may use .instance_count to scope phone numbers per instance
#
# Do not remove — this is intentional contract consistency, not dead code.
# -----------------------------------------------------------------------
variable "deployment_profile" {
  description = "Platform-wide deployment profile. Not consumed by PRD-11 — declared for contract consistency. See PRD-00 for authoritative schema."
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
