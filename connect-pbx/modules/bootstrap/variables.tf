variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "aws_region" {
  type        = string
  description = "AWS region for all state backend resources."
  default     = "us-east-1"
}

variable "github_org" {
  type        = string
  description = "GitHub organization name for OIDC trust policy scoping."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name for OIDC trust policy scoping."
}

variable "allowed_branches" {
  type        = list(string)
  description = "GitHub branches permitted to assume the OIDC role."
  default     = ["main", "develop"]
}

variable "terraform_execution_role_boundary_arn" {
  type        = string
  description = "Optional permissions boundary ARN for the Terraform execution role."
  default = ""

}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. Authoritative definition - all modules inherit this structure."
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
