variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "repo_name" {
  type        = string
  description = "Repository identifier used in repo-scoped resource names."
}

variable "aws_region" {
  type        = string
  description = "AWS region for all resources."
  default     = "us-east-1"
}

variable "identity_management_type" {
  type        = string
  description = "Connect instance identity management type. CONNECT_MANAGED by default. Change to SAML only when PRD-120 is applied."
  default     = "CONNECT_MANAGED"

  validation {
    condition     = contains(["CONNECT_MANAGED", "SAML", "EXISTING_DIRECTORY"], var.identity_management_type)
    error_message = "identity_management_type must be CONNECT_MANAGED, SAML, or EXISTING_DIRECTORY."
  }
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "enable_audit_integration" {
  type        = bool
  description = "Legacy compatibility switch. When true, PRD-10 may resolve shared sinks from l0-audit-pipeline if explicit inputs are not provided. Set false for bare-bones deployments."
  default     = false
}

variable "alarm_action_arns" {
  type        = list(string)
  description = "Optional explicit alarm action ARNs for Connect instance alarms. Set to [] to disable external alarm actions."
  default     = null
}

variable "placeholder_access_log_bucket_name" {
  type        = string
  description = "Optional explicit S3 access-log target for the placeholder recordings bucket. Set to null to disable access logging when audit integration is off."
  default     = null
}

variable "sso_integration_enabled" {
  type        = bool
  description = "Set to true when the PRD-120 SSO integration capability pack is enabled in the deployment manifest. Gates SAML and EXISTING_DIRECTORY identity management types."
  default     = false
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-10"
}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. Inherited from PRD-00 authoritative definition."
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
      crm_enabled        = false
      compliance_enabled = false
    }
  }
}
