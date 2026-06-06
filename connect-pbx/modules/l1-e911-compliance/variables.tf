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
  default = "PRD-18"
}

variable "e911_provider" {
  type        = string
  default     = "bandwidth"
  description = "Configured E911 service provider identifier."

  validation {
    condition     = contains(["intrado", "bandwidth", "911inform", "redsky"], var.e911_provider)
    error_message = "e911_provider must be intrado, bandwidth, 911inform, or redsky."
  }
}

variable "e911_provider_mode" {
  type        = string
  default     = "mock"
  description = "Provider execution mode for E911 synchronization."

  validation {
    condition     = contains(["mock", "live"], var.e911_provider_mode)
    error_message = "e911_provider_mode must be mock or live."
  }

  validation {
    condition     = var.e911_provider_mode != "live" || var.allow_live_provider_sync
    error_message = "allow_live_provider_sync must be true when e911_provider_mode is live."
  }
}

variable "e911_provider_secret_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager ARN containing live E911 provider credentials."

  validation {
    condition     = var.e911_provider_mode != "live" || length(trimspace(var.e911_provider_secret_arn)) > 0
    error_message = "e911_provider_secret_arn is required when e911_provider_mode is live."
  }
}

variable "allow_live_provider_sync" {
  type        = bool
  default     = false
  description = "Explicit safety gate that must be true before live provider synchronization can be enabled."
}

variable "notification_delivery_mode" {
  type        = string
  default     = "mock"
  description = "Emergency notification delivery mode."

  validation {
    condition     = contains(["mock", "live"], var.notification_delivery_mode)
    error_message = "notification_delivery_mode must be mock or live."
  }

  validation {
    condition     = var.notification_delivery_mode != "live" || var.allow_live_external_notifications
    error_message = "allow_live_external_notifications must be true when notification_delivery_mode is live."
  }
}

variable "registration_email_delivery_mode" {
  type        = string
  default     = "mock"
  description = "Remote worker registration email delivery mode."

  validation {
    condition     = contains(["mock", "live"], var.registration_email_delivery_mode)
    error_message = "registration_email_delivery_mode must be mock or live."
  }

  validation {
    condition     = var.registration_email_delivery_mode != "live" || var.allow_live_external_notifications
    error_message = "allow_live_external_notifications must be true when registration_email_delivery_mode is live."
  }
}

variable "allow_live_external_notifications" {
  type        = bool
  default     = false
  description = "Explicit safety gate that must be true before live external notification or email delivery can be enabled."
}

variable "remote_registration_sender_email" {
  type        = string
  default     = ""
  description = "SES sender identity used for live remote-worker registration emails."

  validation {
    condition     = var.registration_email_delivery_mode != "live" || length(trimspace(var.remote_registration_sender_email)) > 0
    error_message = "remote_registration_sender_email is required when registration_email_delivery_mode is live."
  }
}

variable "security_alert_endpoints" {
  type        = list(string)
  default     = []
  description = "List of security alert endpoints. Supports email and SMS (E.164) when subscriptions are enabled."
}

variable "enable_security_alert_endpoint_subscriptions" {
  type        = bool
  default     = false
  description = "When true, create SNS subscriptions for security_alert_endpoints."

  validation {
    condition     = !var.enable_security_alert_endpoint_subscriptions || var.allow_live_external_notifications
    error_message = "allow_live_external_notifications must be true before SNS endpoint subscriptions can be created."
  }
}

variable "location_verification_interval_days" {
  type        = number
  default     = 90
  description = "Number of days after which a location record must be re-verified."

  validation {
    condition     = var.location_verification_interval_days >= 30 && var.location_verification_interval_days <= 365
    error_message = "location_verification_interval_days must be between 30 and 365."
  }
}

variable "office_locations" {
  description = "Static office location records available for operator upsert and future sync workflows."
  type = map(object({
    street_address = string
    city           = string
    state          = string
    zip            = string
    building       = optional(string)
    floor          = string
    room           = optional(string)
    phone_number   = string
  }))
  default = {}
}

variable "elin_assignment_mode" {
  type        = string
  default     = "mock"
  description = "ELIN assignment strategy. inventory uses PRD-11 phone numbers with purpose=e911-elin."

  validation {
    condition     = contains(["mock", "inventory"], var.elin_assignment_mode)
    error_message = "elin_assignment_mode must be mock or inventory."
  }
}

variable "enable_daily_provider_sync_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional daily provider-sync schedule."
}

variable "provider_sync_schedule_expression" {
  type        = string
  default     = "cron(0 3 ? * * *)"
  description = "EventBridge schedule expression for the daily provider sync."
}

variable "enable_daily_compliance_audit_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional daily compliance-audit schedule."
}

variable "compliance_audit_schedule_expression" {
  type        = string
  default     = "cron(0 4 ? * * *)"
  description = "EventBridge schedule expression for the daily compliance audit."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs."
}

variable "compliance_artifact_bucket_name" {
  type        = string
  default     = ""
  description = "Optional S3 bucket for E911 compliance evidence artifacts. When empty, artifact export is skipped."
}

variable "enable_no_record_alarm" {
  type        = bool
  default     = true
  description = "When true, create the no-record compliance alarm."
}

variable "enable_sync_failure_alarm" {
  type        = bool
  default     = true
  description = "When true, create the provider-sync failure alarm."
}

variable "enable_notification_error_alarm" {
  type        = bool
  default     = true
  description = "When true, create the emergency-notification error alarm."
}
