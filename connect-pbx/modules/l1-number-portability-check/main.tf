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

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "audit_pipeline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-audit-pipeline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn          = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn  = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  platform_alert_topic_arn = data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = var.layer_id
    PRD         = var.prd_id
  }
}

resource "aws_dynamodb_table" "portability_audit" {
  name         = "${var.org_name}-number-portability-audit-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phone_number"
  range_key    = "record_type"

  attribute {
    name = "phone_number"
    type = "S"
  }

  attribute {
    name = "record_type"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.env_kms_key_arn
  }

  ttl {
    attribute_name = "expires_epoch"
    enabled        = true
  }

  tags = local.common_tags
}
