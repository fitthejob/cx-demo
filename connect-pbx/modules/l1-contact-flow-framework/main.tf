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

data "terraform_remote_state" "connect_instance" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-connect-instance/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "hours_of_operation" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-hours-of-operation/terraform.tfstate"
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

data "terraform_remote_state" "audit_pipeline" {
  count     = var.enable_audit_integration && var.alarm_action_arns == null ? 1 : 0
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-audit-pipeline/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "queue_architecture" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-queue-architecture/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "phone_numbers" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-phone-numbers/terraform.tfstate"
    region = var.aws_region
  }
}
