terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {}
}

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
  count     = var.enable_audit_integration && (var.alarm_action_arns == null || var.placeholder_access_log_bucket_name == null) ? 1 : 0
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-audit-pipeline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn = data.terraform_remote_state.account_baseline.outputs.kms_key_arn

  alarm_action_arns = var.alarm_action_arns != null ? var.alarm_action_arns : (
    compact([try(data.terraform_remote_state.audit_pipeline[0].outputs.platform_alert_topic_arn, null)])
  )

  placeholder_access_log_bucket_name = var.placeholder_access_log_bucket_name != null ? var.placeholder_access_log_bucket_name : (
    try(data.terraform_remote_state.audit_pipeline[0].outputs.audit_bucket_name, null)
  )
}
