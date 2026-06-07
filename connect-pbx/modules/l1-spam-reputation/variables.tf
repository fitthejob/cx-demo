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
  default = "PRD-16"
}

variable "spam_threshold_risk" {
  type        = number
  default     = 30
  description = "Spam score at or above which a number is labeled RISK."

  validation {
    condition     = var.spam_threshold_risk >= 0 && var.spam_threshold_risk <= 100
    error_message = "spam_threshold_risk must be between 0 and 100."
  }
}

variable "spam_threshold_spam" {
  type        = number
  default     = 70
  description = "Spam score at or above which a number is labeled SPAM."

  validation {
    condition     = var.spam_threshold_spam >= 0 && var.spam_threshold_spam <= 100 && var.spam_threshold_spam >= var.spam_threshold_risk
    error_message = "spam_threshold_spam must be between 0 and 100 and greater than or equal to spam_threshold_risk."
  }
}

variable "reputation_provider_mode" {
  type        = string
  default     = "mock"
  description = "Provider execution mode for PRD-16 reputation checks."

  validation {
    condition     = contains(["mock", "live"], var.reputation_provider_mode)
    error_message = "reputation_provider_mode must be mock or live."
  }
}

variable "reputation_providers" {
  type        = list(string)
  default     = ["hiya", "first_orion"]
  description = "Ordered list of reputation providers to query."

  validation {
    condition = alltrue([
      for provider in var.reputation_providers :
      contains(["hiya", "first_orion", "tns"], provider)
    ])
    error_message = "reputation_providers entries must be hiya, first_orion, or tns."
  }
}

variable "reputation_api_secrets" {
  type        = map(string)
  default     = {}
  description = "Map of provider name to Secrets Manager secret ARN."

  validation {
    condition = var.reputation_provider_mode == "mock" || alltrue([
      for provider in var.reputation_providers :
      contains(keys(var.reputation_api_secrets), provider) && length(trimspace(var.reputation_api_secrets[provider])) > 0
    ])
    error_message = "reputation_api_secrets must include a non-empty ARN for every configured provider when reputation_provider_mode is live."
  }
}

variable "attestation_provider_mode" {
  type        = string
  default     = "mock"
  description = "Provider execution mode for STIR/SHAKEN verification."

  validation {
    condition     = contains(["mock", "live"], var.attestation_provider_mode)
    error_message = "attestation_provider_mode must be mock or live."
  }
}

variable "attestation_provider_secret_arn" {
  type        = string
  default     = ""
  description = "Optional Secrets Manager ARN for a live STIR/SHAKEN verification provider."

  validation {
    condition     = var.attestation_provider_mode == "mock" || length(trimspace(var.attestation_provider_secret_arn)) > 0
    error_message = "attestation_provider_secret_arn is required when attestation_provider_mode is live."
  }
}

variable "reputation_staleness_days" {
  type        = number
  default     = 30
  description = "Days after which the current reputation record is considered stale for assignment gating."

  validation {
    condition     = var.reputation_staleness_days >= 1 && var.reputation_staleness_days <= 365
    error_message = "reputation_staleness_days must be between 1 and 365."
  }
}

variable "history_ttl_days" {
  type        = number
  default     = 365
  description = "Retention window for immutable history records."

  validation {
    condition     = var.history_ttl_days >= 30 && var.history_ttl_days <= 3650
    error_message = "history_ttl_days must be between 30 and 3650."
  }
}

variable "batch_size" {
  type        = number
  default     = 50
  description = "Maximum numbers processed per reputation batch."

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 100
    error_message = "batch_size must be between 1 and 100."
  }
}

variable "batch_delay_ms" {
  type        = number
  default     = 100
  description = "Delay in milliseconds between reputation batches."

  validation {
    condition     = var.batch_delay_ms >= 0 && var.batch_delay_ms <= 5000
    error_message = "batch_delay_ms must be between 0 and 5000."
  }
}

variable "enable_weekly_reputation_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional weekly reputation inventory scan schedule."
}

variable "reputation_schedule_expression" {
  type        = string
  default     = "cron(0 13 ? * MON *)"
  description = "EventBridge schedule expression for the weekly reputation scan."
}

variable "enable_weekly_attestation_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional weekly STIR/SHAKEN verification schedule."
}

variable "attestation_schedule_expression" {
  type        = string
  default     = "cron(0 14 ? * MON *)"
  description = "EventBridge schedule expression for the weekly attestation scan."
}

variable "enable_high_spam_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-16-01."
}

variable "enable_attestation_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-16-02."
}

variable "alarm_on_risk_label" {
  type        = bool
  default     = false
  description = "When true, RISK labels also count toward the high-spam metric."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs."
}
