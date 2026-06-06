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
  default = "PRD-19"
}

variable "module_state_resolution" {
  type = object({
    state_bucket            = string
    phone_numbers_state_key = string
    contact_flow_state_key  = string
    connect_instance_ids    = list(string)
  })
  description = "Resolved module-state contract derived from the deployment manifest / module catalog model."

  validation {
    condition = (
      length(trimspace(var.module_state_resolution.state_bucket)) > 0 &&
      length(trimspace(var.module_state_resolution.phone_numbers_state_key)) > 0 &&
      length(trimspace(var.module_state_resolution.contact_flow_state_key)) > 0 &&
      length(var.module_state_resolution.connect_instance_ids) > 0 &&
      alltrue([
        for instance_id in var.module_state_resolution.connect_instance_ids :
        length(trimspace(instance_id)) > 0
      ])
    )
    error_message = "module_state_resolution must include a state bucket, both state keys, and at least one non-empty Connect instance ID."
  }
}

variable "enable_schedule" {
  type        = bool
  default     = true
  description = "When true, create the optional 15-minute EventBridge schedule for continuous drift detection."
}

variable "schedule_expression" {
  type        = string
  default     = "rate(15 minutes)"
  description = "EventBridge schedule expression for routing drift scans."
}

variable "lookback_minutes" {
  type        = number
  default     = 30
  description = "CloudTrail lookback window for routing-mutation events."
}

variable "enable_drift_detected_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-19-01."
}

variable "enable_persistent_drift_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-19-02."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs."
}
