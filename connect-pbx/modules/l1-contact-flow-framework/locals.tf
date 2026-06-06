locals {
  connect_instance_id              = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  connect_instance_arn             = data.terraform_remote_state.connect_instance.outputs.connect_instance_arn
  hours_of_operation_ids           = data.terraform_remote_state.hours_of_operation.outputs.hours_of_operation_ids
  daily_closure_status_table_name  = data.terraform_remote_state.hours_of_operation.outputs.daily_closure_status_table_name
  daily_closure_status_table_arn   = data.terraform_remote_state.hours_of_operation.outputs.daily_closure_status_table_arn
  emergency_closure_parameter_name = data.terraform_remote_state.hours_of_operation.outputs.emergency_closure_parameter_name
  emergency_closure_parameter_arn  = data.terraform_remote_state.hours_of_operation.outputs.emergency_closure_parameter_arn
  queue_ids                        = data.terraform_remote_state.queue_architecture.outputs.queue_ids
  queue_arns                       = data.terraform_remote_state.queue_architecture.outputs.queue_arns
  queue_config                     = data.terraform_remote_state.queue_architecture.outputs.queue_config
  system_queue_id                  = data.terraform_remote_state.queue_architecture.outputs.system_queue_id
  phone_number_ids                 = data.terraform_remote_state.phone_numbers.outputs.phone_number_ids
  phone_number_inventory           = data.terraform_remote_state.phone_numbers.outputs.phone_number_inventory
  env_kms_key_arn                  = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn          = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  alarm_action_arns = var.alarm_action_arns != null ? var.alarm_action_arns : (
    compact([try(data.terraform_remote_state.audit_pipeline[0].outputs.platform_alert_topic_arn, null)])
  )
  contact_flow_log_group_name = data.terraform_remote_state.connect_instance.outputs.contact_flow_log_group_name

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-14"
  }

  contact_flow_id_map = {
    "main-inbound"   = aws_connect_contact_flow.main_inbound.contact_flow_id
    "after-hours"    = aws_connect_contact_flow.after_hours.contact_flow_id
    "error-handler"  = aws_connect_contact_flow.error_handler.contact_flow_id
    "queue-transfer" = aws_connect_contact_flow.queue_transfer.contact_flow_id
  }

  contact_flow_arn_map = {
    "main-inbound"   = aws_connect_contact_flow.main_inbound.arn
    "after-hours"    = aws_connect_contact_flow.after_hours.arn
    "error-handler"  = aws_connect_contact_flow.error_handler.arn
    "queue-transfer" = aws_connect_contact_flow.queue_transfer.arn
  }
}
