output "reputation_table_name" {
  description = "DynamoDB reputation table name."
  value       = aws_dynamodb_table.reputation.name
}

output "reputation_table_arn" {
  description = "DynamoDB reputation table ARN."
  value       = aws_dynamodb_table.reputation.arn
}

output "current_records_gsi_name" {
  description = "Sparse GSI exposing only CURRENT records."
  value       = local.current_records_gsi
}

output "reputation_operations_lambda_arn" {
  description = "ARN of the PRD-16 reputation operations Lambda."
  value       = aws_lambda_function.reputation_operations.arn
}

output "reputation_operations_lambda_name" {
  description = "Function name of the PRD-16 reputation operations Lambda."
  value       = aws_lambda_function.reputation_operations.function_name
}

output "stir_shaken_check_lambda_arn" {
  description = "ARN of the PRD-16 STIR/SHAKEN verification Lambda."
  value       = aws_lambda_function.stir_shaken.arn
}

output "stir_shaken_check_lambda_name" {
  description = "Function name of the PRD-16 STIR/SHAKEN verification Lambda."
  value       = aws_lambda_function.stir_shaken.function_name
}

output "high_spam_alarm_name" {
  description = "CloudWatch alarm name for high spam risk inventory."
  value       = var.enable_high_spam_alarm ? aws_cloudwatch_metric_alarm.high_spam_inventory[0].alarm_name : null
}

output "attestation_alarm_name" {
  description = "CloudWatch alarm name for degraded attestation."
  value       = var.enable_attestation_alarm ? aws_cloudwatch_metric_alarm.attestation_degraded[0].alarm_name : null
}
