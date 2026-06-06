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

locals {
  connect_instance_id    = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  hours_of_operation_ids = data.terraform_remote_state.hours_of_operation.outputs.hours_of_operation_ids
  env_kms_key_arn        = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  alarm_action_arns = var.alarm_action_arns != null ? var.alarm_action_arns : (
    compact([try(data.terraform_remote_state.audit_pipeline[0].outputs.platform_alert_topic_arn, null)])
  )

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-13"
  }
}

resource "aws_connect_queue" "queues" {
  for_each = local.enabled_queues

  instance_id           = local.connect_instance_id
  name                  = "${var.org_name}-${each.value.name}"
  description           = each.value.description
  hours_of_operation_id = local.hours_of_operation_ids[each.value.hours_of_operation_key]
  max_contacts          = each.value.max_contacts > 0 ? each.value.max_contacts : null

  tags = merge(local.common_tags, {
    QueueKey        = each.key
    RoutingStrategy = each.value.routing_strategy
    OverflowAction  = each.value.overflow_action
    MaxWaitMinutes  = tostring(each.value.max_wait_minutes)
    CostCenter      = each.value.cost_center
    Priority        = tostring(each.value.priority)
  })
}

resource "aws_connect_routing_profile" "profiles" {
  for_each = var.routing_profiles

  instance_id               = local.connect_instance_id
  name                      = "${var.org_name}-${each.value.name}"
  description               = each.value.description
  default_outbound_queue_id = aws_connect_queue.queues[each.value.default_outbound_queue_key].queue_id

  dynamic "media_concurrencies" {
    for_each = each.value.media_concurrencies
    content {
      channel     = media_concurrencies.value.channel
      concurrency = media_concurrencies.value.concurrency
    }
  }

  dynamic "queue_configs" {
    for_each = each.value.queue_configs
    content {
      channel  = queue_configs.value.channel
      delay    = queue_configs.value.delay_seconds
      priority = queue_configs.value.priority
      queue_id = aws_connect_queue.queues[queue_configs.value.queue_key].queue_id
    }
  }

  tags = merge(local.common_tags, {
    ProfileKey = each.key
  })
}
