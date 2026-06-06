provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Layer   = "L1"
      PRD     = "PRD-12"
      Project = var.org_name
    }
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

data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  connect_instance_id = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  env_kms_key_arn     = data.terraform_remote_state.account_baseline.outputs.kms_key_arn

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-12"
  }
}

resource "aws_connect_hours_of_operation" "schedules" {
  for_each = var.hours_of_operation

  instance_id = local.connect_instance_id
  name        = "${var.org_name}-${each.value.name}"
  description = each.value.description
  time_zone   = each.value.time_zone

  dynamic "config" {
    for_each = each.value.config
    content {
      day = config.value.day
      start_time {
        hours   = config.value.start_hour
        minutes = config.value.start_minute
      }
      end_time {
        hours   = config.value.end_hour
        minutes = config.value.end_minute
      }
    }
  }

  tags = merge(local.common_tags, {
    Schedule = each.key
  })
}
