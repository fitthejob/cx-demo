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

locals {
  env_kms_key_arn         = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  bootstrap_kms_key_arn   = data.terraform_remote_state.bootstrap.outputs.bootstrap_kms_key_arn
  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  metric_namespace        = "ConnectPBX/${terraform.workspace}"
  status_gsi_name         = "status-by-scope"

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = var.layer_id
    PRD         = var.prd_id
  }
}

resource "aws_dynamodb_table" "routing_drift" {
  name         = "${var.org_name}-routing-drift-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phone_number"
  range_key    = "drift_type"

  attribute {
    name = "phone_number"
    type = "S"
  }

  attribute {
    name = "drift_type"
    type = "S"
  }

  attribute {
    name = "status_scope"
    type = "S"
  }

  global_secondary_index {
    name            = local.status_gsi_name
    hash_key        = "status_scope"
    range_key       = "phone_number"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.env_kms_key_arn
  }

  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  tags = local.common_tags
}
