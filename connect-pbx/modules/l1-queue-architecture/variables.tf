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

variable "enable_audit_integration" {
  type        = bool
  description = "Legacy compatibility switch. When true, PRD-13 may resolve a shared alarm sink from l0-audit-pipeline if explicit alarm_action_arns are not provided."
  default     = false
}

variable "alarm_action_arns" {
  type        = list(string)
  description = "Optional explicit alarm action ARNs for queue alarms. Set to [] to disable external alarm actions."
  default     = null
}

variable "queues" {
  description = <<-EOT
    Queue inventory. Add, remove, or customize queues here. Set enabled=false
    to deactivate without deleting the entry.

    IMPORTANT: default is empty map. The queue inventory MUST be supplied via
    the centralized environment folder, e.g. environments/dev/queues.tfvars.
    Running apply without queues provisions zero queue resources. Standard queue
    templates are provided in the tfvars files, not in the variable default.
  EOT

  type = map(object({
    enabled                = bool
    name                   = string
    description            = string
    hours_of_operation_key = string
    routing_strategy       = string # LONGEST_IDLE | LEAST_OCCUPIED | ROUND_ROBIN
    max_contacts           = number # 0 = unlimited
    max_wait_minutes       = number # Used by PRD-14 contact flow overflow logic
    overflow_action        = string # VOICEMAIL | CALLBACK | DISCONNECT
    cost_center            = string
    priority               = number # 1 = highest
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.queues :
      contains(["LONGEST_IDLE", "LEAST_OCCUPIED", "ROUND_ROBIN"], v.routing_strategy)
    ])
    error_message = "Each queue routing_strategy must be LONGEST_IDLE, LEAST_OCCUPIED, or ROUND_ROBIN."
  }

  validation {
    condition = alltrue([
      for k, v in var.queues :
      contains(["VOICEMAIL", "CALLBACK", "DISCONNECT"], v.overflow_action)
    ])
    error_message = "Each queue overflow_action must be VOICEMAIL, CALLBACK, or DISCONNECT."
  }

  validation {
    condition = alltrue([
      for k, v in var.queues :
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) || length(k) == 1
    ])
    error_message = "Each queue map key must be lowercase alphanumeric with hyphens only."
  }
}

variable "routing_profiles" {
  description = <<-EOT
    Routing profile inventory. Each profile defines which queues an agent serves
    and in what priority order.

    IMPORTANT: default is empty map. The routing profile inventory MUST be
    supplied via the centralized environment folder, e.g.
    environments/dev/queues.tfvars. Running apply without routing profiles
    provisions zero routing profile resources.

    The tiered model:
      Priority 1 (primary):   Agent's home queue, delay 0s
      Priority 2 (secondary): Overflow queue, delay 120s (configurable)
      Priority 3 (tertiary):  General fallback, delay 300s (configurable)
  EOT

  type = map(object({
    name                       = string
    description                = string
    default_outbound_queue_key = string
    media_concurrencies = list(object({
      channel     = string # VOICE | CHAT | TASK
      concurrency = number # max simultaneous contacts per channel
    }))
    queue_configs = list(object({
      queue_key     = string # Must match a key in var.queues
      channel       = string # VOICE | CHAT | TASK
      priority      = number # 1 = highest
      delay_seconds = number # seconds before queue is offered to this profile
    }))
  }))

  default = {}
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-13"
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-13. It exists for
# forward compatibility with the platform deployment profile contract
# (authoritative definition in PRD-00 bootstrap module). Every module
# declares this variable with the same schema and defaults so that:
#   - All modules accept the same deployment_profile from tfvars
#   - Modules that need conditional behavior can reference specific fields
#     without changing their variable signature
#
# Do not remove — this is intentional contract consistency, not dead code.
# -----------------------------------------------------------------------
variable "deployment_profile" {
  description = "Platform-wide deployment profile. Not consumed by PRD-13 — declared for contract consistency. See PRD-00 for authoritative schema."
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
