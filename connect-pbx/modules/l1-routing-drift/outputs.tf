output "routing_drift_table_name" {
  description = "Routing drift DynamoDB table name."
  value       = aws_dynamodb_table.routing_drift.name
}

output "routing_drift_table_arn" {
  description = "Routing drift DynamoDB table ARN."
  value       = aws_dynamodb_table.routing_drift.arn
}

output "routing_drift_status_gsi_name" {
  description = "Sparse GSI exposing drift records by record status."
  value       = local.status_gsi_name
}

output "routing_drift_detector_lambda_arn" {
  description = "Routing drift detector Lambda ARN."
  value       = aws_lambda_function.drift_detector.arn
}

output "routing_drift_detector_lambda_name" {
  description = "Routing drift detector Lambda function name."
  value       = aws_lambda_function.drift_detector.function_name
}

output "drift_detected_alarm_name" {
  description = "CloudWatch alarm name for ALARM-19-01."
  value       = var.enable_drift_detected_alarm ? aws_cloudwatch_metric_alarm.drift_detected[0].alarm_name : null
}

output "persistent_drift_alarm_name" {
  description = "CloudWatch alarm name for ALARM-19-02."
  value       = var.enable_persistent_drift_alarm ? aws_cloudwatch_metric_alarm.persistent_drift[0].alarm_name : null
}
