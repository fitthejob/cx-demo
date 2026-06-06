output "main_inbound_flow_id" {
  description = "Main inbound contact flow ID. Consumed by downstream integrations."
  value       = aws_connect_contact_flow.main_inbound.contact_flow_id
}

output "main_inbound_flow_arn" {
  description = "Main inbound contact flow ARN."
  value       = aws_connect_contact_flow.main_inbound.arn
}

output "after_hours_flow_id" {
  description = "After-hours contact flow ID."
  value       = aws_connect_contact_flow.after_hours.contact_flow_id
}

output "error_handler_flow_id" {
  description = "Error handler contact flow ID."
  value       = aws_connect_contact_flow.error_handler.contact_flow_id
}

output "queue_transfer_flow_id" {
  description = "Queue-transfer contact flow ID."
  value       = aws_connect_contact_flow.queue_transfer.contact_flow_id
}

output "closure_check_lambda_arn" {
  description = "Closure-check Lambda ARN."
  value       = aws_lambda_function.closure_check.arn
}

output "ivr_no_input_alarm_name" {
  description = "CloudWatch alarm name for the IVR no-input spike alarm."
  value       = aws_cloudwatch_metric_alarm.ivr_no_input_spike.alarm_name
}

output "contact_flow_ids" {
  description = "Map of PRD-14 contact flow identifiers."
  value = {
    "main-inbound"   = aws_connect_contact_flow.main_inbound.contact_flow_id
    "after-hours"    = aws_connect_contact_flow.after_hours.contact_flow_id
    "error-handler"  = aws_connect_contact_flow.error_handler.contact_flow_id
    "queue-transfer" = aws_connect_contact_flow.queue_transfer.contact_flow_id
  }
}

output "expected_number_flow_routes" {
  description = "Authoritative expected phone number to contact flow route map for downstream reconciliation such as PRD-19."
  value = {
    for number_key, flow_key in var.number_flow_associations :
    local.phone_number_inventory[number_key].phone_number => {
      phone_number_id   = local.phone_number_ids[number_key]
      contact_flow_key  = flow_key
      expected_flow_id  = local.contact_flow_id_map[flow_key]
      expected_flow_arn = local.contact_flow_arn_map[flow_key]
    }
  }
}
