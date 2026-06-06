variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "aws_region" {
  type        = string
  description = "AWS region for all state backend resources."
  default     = "us-east-1"
}

variable "approved_regions" {
  type        = list(string)
  description = "List of AWS regions approved for resource deployment. Used in permission boundary and SCPs."
  default     = ["us-east-1"]
}

variable "state_bucket" {
  type        = string
  description = "S3 state bucket name from PRD-00. Injected at runtime via GitHub Actions secret."
}


variable "layer_id" {
  type    = string
  default = "L0"
}

variable "prd_id" {
  type    = string
  default = "PRD-02"
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
