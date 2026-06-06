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

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-17"
}

variable "cnam_policy" {
  type        = string
  default     = "company"
  description = "CNAM policy. company uses cnam_company_name, employee uses per-number cnam_name from PRD-11."

  validation {
    condition     = contains(["company", "employee"], var.cnam_policy)
    error_message = "cnam_policy must be company or employee."
  }
}

variable "cnam_company_name" {
  type        = string
  default     = ""
  description = "Company name for CNAM, max 15 characters."

  validation {
    condition     = length(var.cnam_company_name) <= 15
    error_message = "cnam_company_name must be 15 characters or fewer."
  }

  validation {
    condition     = var.cnam_policy != "company" || length(trimspace(var.cnam_company_name)) > 0
    error_message = "cnam_company_name is required when cnam_policy is company."
  }
}

variable "cnam_provider" {
  type        = string
  default     = "bandwidth"
  description = "CNAM provider identifier."

  validation {
    condition     = contains(["bandwidth", "neustar"], var.cnam_provider)
    error_message = "cnam_provider must be bandwidth or neustar."
  }
}

variable "cnam_provider_mode" {
  type        = string
  default     = "mock"
  description = "CNAM provider execution mode."

  validation {
    condition     = contains(["mock", "live"], var.cnam_provider_mode)
    error_message = "cnam_provider_mode must be mock or live."
  }
}

variable "cnam_provider_secret_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager ARN for live CNAM provider credentials."

  validation {
    condition     = var.cnam_provider_mode == "mock" || length(trimspace(var.cnam_provider_secret_arn)) > 0
    error_message = "cnam_provider_secret_arn is required when cnam_provider_mode is live."
  }
}

variable "reputation_staleness_days" {
  type        = number
  default     = 30
  description = "Maximum age of PRD-16 reputation current records for CNAM eligibility."
}

variable "submission_batch_size" {
  type        = number
  default     = 50
  description = "Maximum numbers submitted per CNAM batch."
}

variable "verification_propagation_hours" {
  type        = number
  default     = 72
  description = "Hours to wait after submission before drift verification checks."
}

variable "enable_weekly_verification_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional weekly EventBridge schedule for CNAM verification."
}

variable "verification_schedule_expression" {
  type        = string
  default     = "cron(0 7 ? * WED *)"
  description = "EventBridge schedule expression for weekly CNAM verification."
}

variable "enable_submission_failure_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-17-01."
}

variable "enable_drift_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-17-02."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs."
}

variable "bulk_import_bucket_name" {
  type        = string
  default     = ""
  description = "S3 bucket name for bulk CNAM CSV import. When non-empty, creates an S3 event trigger on cnam-import/*.csv objects."
}

variable "bulk_import_bucket_arn" {
  type        = string
  default     = ""
  description = "ARN of the S3 bucket for bulk CNAM CSV import. Required when bulk_import_bucket_name is set."
}
