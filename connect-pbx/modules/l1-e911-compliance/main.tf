provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Layer   = var.layer_id
      PRD     = var.prd_id
      Project = var.org_name
    }
  }
}

data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "bootstrap/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "connect_instance" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-connect-instance/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn         = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  bootstrap_kms_key_arn   = data.terraform_remote_state.bootstrap.outputs.bootstrap_kms_key_arn
  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  connect_instance_id     = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  metric_namespace        = "ConnectPBX/${terraform.workspace}"
  sync_status_gsi_name    = "sync-status-by-agent"
  phone_numbers_state_key = "l1-phone-numbers/terraform.tfstate"
  office_locations_json   = jsonencode(var.office_locations)
  artifact_bucket_enabled = length(trimspace(var.compliance_artifact_bucket_name)) > 0

  secret_arns = distinct(compact([var.e911_provider_secret_arn]))

  security_endpoint_configs = {
    for endpoint in var.security_alert_endpoints :
    replace(replace(replace(lower(endpoint), "@", "-at-"), ".", "-"), "+", "plus-") => {
      endpoint = endpoint
      protocol = can(regex("^\\+[1-9][0-9]{7,14}$", endpoint)) ? "sms" : "email"
    }
  }

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = var.layer_id
    PRD         = var.prd_id
  }
}

resource "aws_dynamodb_table" "location_registry" {
  name         = "${var.org_name}-e911-location-registry-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "agent_id"

  attribute {
    name = "agent_id"
    type = "S"
  }

  attribute {
    name = "sync_status_scope"
    type = "S"
  }

  global_secondary_index {
    name            = local.sync_status_gsi_name
    hash_key        = "sync_status_scope"
    range_key       = "agent_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.env_kms_key_arn
  }

  tags = local.common_tags
}

resource "aws_sns_topic" "security_alerts" {
  name              = "${var.org_name}-security-alerts-${terraform.workspace}"
  kms_master_key_id = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "security_alerts" {
  for_each = var.enable_security_alert_endpoint_subscriptions ? local.security_endpoint_configs : {}

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = each.value.protocol
  endpoint  = each.value.endpoint
}
