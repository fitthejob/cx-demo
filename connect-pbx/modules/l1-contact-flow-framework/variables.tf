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
  description = "Legacy compatibility switch. When true, PRD-14 may resolve a shared alarm sink from l0-audit-pipeline if explicit alarm_action_arns are not provided."
  default     = false
}

variable "alarm_action_arns" {
  type        = list(string)
  description = "Optional explicit alarm action ARNs for PRD-14 alarms. Set to [] to disable external alarm actions."
  default     = null
}

variable "tts_voice_id" {
  type        = string
  description = "Amazon Polly voice ID for text-to-speech prompts. Supplied via environments/<env>/contact-flows.tfvars."
  default     = "Joanna"
}

variable "tts_language_code" {
  type        = string
  description = "Language code for TTS and speech recognition. Supplied via environments/<env>/contact-flows.tfvars."
  default     = "en-US"
}

variable "flow_prompts" {
  description = <<-EOT
    All customer-facing IVR prompt text. Edit to change what callers hear
    without modifying flow logic or JSON templates.

    IMPORTANT: default is empty map. The prompt inventory MUST be supplied via
    the environment-scoped tfvars (environments/<env>/contact-flows.tfvars).
    Running apply without prompts will fail — all prompt keys are required by
    the flow JSON templates.

    Required keys: greeting, main_menu, after_hours, callback_offer,
    queue_wait, overflow, error, goodbye, voicemail_unavailable.
  EOT

  type    = map(string)
  default = {}

  validation {
    condition = length(var.flow_prompts) == 0 || alltrue([
      for k in ["greeting", "main_menu", "after_hours", "callback_offer", "queue_wait", "overflow", "error", "goodbye", "voicemail_unavailable"] :
      contains(keys(var.flow_prompts), k)
    ])
    error_message = "flow_prompts must contain all required keys: greeting, main_menu, after_hours, callback_offer, queue_wait, overflow, error, goodbye, voicemail_unavailable."
  }
}

variable "number_flow_associations" {
  description = <<-EOT
    Map of phone number key (from PRD-11) to contact flow key. Each key must
    match a provisioned phone number in PRD-11. Each value must match a flow
    key in this module's contact_flow_id_map (currently: main-inbound,
    error-handler).

    IMPORTANT: default is empty map. The association inventory MUST be supplied
    via the environment-scoped tfvars (environments/<env>/contact-flows.tfvars).
    Running apply without associations provisions zero phone number → flow
    associations.
  EOT

  type    = map(string)
  default = {}

  validation {
    condition = alltrue([
      for _, flow_key in var.number_flow_associations :
      contains(["main-inbound", "error-handler", "queue-transfer"], flow_key)
    ])
    error_message = "number_flow_associations values must be one of: main-inbound, error-handler, queue-transfer."
  }
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-14"
}

variable "python_executable" {
  type        = string
  description = "Python interpreter used by local-exec helpers. Defaults to 'python' for manual runs; repo runners override with a resolved interpreter path for cross-platform execution."
  default     = "python"
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-14. It exists for
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
  description = "Platform-wide deployment profile. Not consumed by PRD-14 — declared for contract consistency. See PRD-00 for authoritative schema."
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
