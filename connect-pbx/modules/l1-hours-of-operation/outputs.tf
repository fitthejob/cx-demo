output "hours_of_operation_ids" {
  description = "Map of schedule key to Hours of Operation ID. Consumed by PRD-13 and PRD-14."
  value = {
    for k, v in aws_connect_hours_of_operation.schedules :
    k => v.hours_of_operation_id
  }
}

output "hours_of_operation_arns" {
  description = "Map of schedule key to Hours of Operation ARN."
  value = {
    for k, v in aws_connect_hours_of_operation.schedules :
    k => v.arn
  }
}

output "holiday_closures_table_name" {
  description = "DynamoDB company-specific closure table name. Contact flow fallback check for same-day additions."
  value       = aws_dynamodb_table.holiday_closures.name
}

output "holiday_closures_table_arn" {
  description = "DynamoDB company-specific closure table ARN. Used in PRD-14 contact flow IAM."
  value       = aws_dynamodb_table.holiday_closures.arn
}

output "daily_closure_status_table_name" {
  description = "DynamoDB daily-status table name. Contact flow reads pre-computed closure status."
  value       = aws_dynamodb_table.daily_closure_status.name
}

output "daily_closure_status_table_arn" {
  description = "DynamoDB daily-status table ARN. Used in PRD-14 contact flow IAM."
  value       = aws_dynamodb_table.daily_closure_status.arn
}

output "emergency_closure_parameter_name" {
  description = "SSM parameter path for emergency closures. Contact flow checks this first."
  value       = aws_ssm_parameter.emergency_closure.name
}

output "emergency_closure_parameter_arn" {
  description = "SSM parameter ARN for emergency closures. Used in PRD-14 contact flow IAM."
  value       = aws_ssm_parameter.emergency_closure.arn
}
