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
  phone_numbers_state_key = "l1-phone-numbers/terraform.tfstate"
  current_records_gsi     = "current-by-scope"

  all_secret_arns = distinct(compact(concat(
    values(var.reputation_api_secrets),
    [var.attestation_provider_secret_arn]
  )))

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = var.layer_id
    PRD         = var.prd_id
  }
}

resource "aws_dynamodb_table" "reputation" {
  name         = "${var.org_name}-number-reputation-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phone_number"
  range_key    = "check_date"

  attribute {
    name = "phone_number"
    type = "S"
  }

  attribute {
    name = "check_date"
    type = "S"
  }

  attribute {
    name = "record_scope"
    type = "S"
  }

  global_secondary_index {
    name            = local.current_records_gsi
    hash_key        = "record_scope"
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
    attribute_name = "expires_epoch"
    enabled        = true
  }

  tags = local.common_tags
}
