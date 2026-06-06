output "location_registry_table_name" {
  description = "E911 location registry DynamoDB table name."
  value       = aws_dynamodb_table.location_registry.name
}

output "location_registry_table_arn" {
  description = "E911 location registry DynamoDB table ARN."
  value       = aws_dynamodb_table.location_registry.arn
}

output "location_registry_sync_status_gsi_name" {
  description = "GSI exposing records by provider sync status."
  value       = local.sync_status_gsi_name
}

output "security_alerts_topic_arn" {
  description = "SNS topic ARN for emergency notifications."
  value       = aws_sns_topic.security_alerts.arn
}

output "emergency_notification_lambda_arn" {
  description = "Emergency notification Lambda ARN."
  value       = aws_lambda_function.emergency_notification.arn
}

output "emergency_notification_lambda_name" {
  description = "Emergency notification Lambda name."
  value       = aws_lambda_function.emergency_notification.function_name
}

output "e911_registration_lambda_arn" {
  description = "E911 registration Lambda ARN."
  value       = aws_lambda_function.e911_registration.arn
}

output "e911_registration_lambda_name" {
  description = "E911 registration Lambda name."
  value       = aws_lambda_function.e911_registration.function_name
}

output "e911_provider_sync_lambda_arn" {
  description = "E911 provider sync Lambda ARN."
  value       = aws_lambda_function.e911_provider_sync.arn
}

output "e911_provider_sync_lambda_name" {
  description = "E911 provider sync Lambda name."
  value       = aws_lambda_function.e911_provider_sync.function_name
}

output "e911_compliance_audit_lambda_arn" {
  description = "E911 compliance audit Lambda ARN."
  value       = aws_lambda_function.e911_compliance_audit.arn
}

output "e911_compliance_audit_lambda_name" {
  description = "E911 compliance audit Lambda name."
  value       = aws_lambda_function.e911_compliance_audit.function_name
}

output "no_record_alarm_name" {
  description = "CloudWatch alarm name for agents without E911 records."
  value       = var.enable_no_record_alarm ? aws_cloudwatch_metric_alarm.no_record[0].alarm_name : null
}

output "provider_sync_failure_alarm_name" {
  description = "CloudWatch alarm name for E911 provider sync failures."
  value       = var.enable_sync_failure_alarm ? aws_cloudwatch_metric_alarm.provider_sync_failure[0].alarm_name : null
}

output "notification_error_alarm_name" {
  description = "CloudWatch alarm name for emergency notification Lambda errors."
  value       = var.enable_notification_error_alarm ? aws_cloudwatch_metric_alarm.notification_error[0].alarm_name : null
}
