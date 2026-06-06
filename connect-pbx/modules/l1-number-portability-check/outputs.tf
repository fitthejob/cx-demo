output "portability_check_lambda_arn" {
  description = "ARN of the PRD-15 portability check Lambda."
  value       = aws_lambda_function.portability_check.arn
}

output "portability_check_lambda_name" {
  description = "Lambda function name for CLI invocation."
  value       = aws_lambda_function.portability_check.function_name
}

output "portability_audit_table_name" {
  description = "DynamoDB portability audit table name."
  value       = aws_dynamodb_table.portability_audit.name
}

output "portability_audit_table_arn" {
  description = "DynamoDB portability audit table ARN."
  value       = aws_dynamodb_table.portability_audit.arn
}

output "check_expiry_days" {
  description = "Configured portability freshness window in days."
  value       = var.check_expiry_days
}

output "portability_check_alarm_name" {
  description = "CloudWatch alarm name for Lambda error spikes."
  value       = aws_cloudwatch_metric_alarm.portability_lambda_errors.alarm_name
}
