output "cnam_inventory_table_name" {
  description = "CNAM inventory DynamoDB table name."
  value       = aws_dynamodb_table.cnam_inventory.name
}

output "cnam_inventory_table_arn" {
  description = "CNAM inventory DynamoDB table ARN."
  value       = aws_dynamodb_table.cnam_inventory.arn
}

output "cnam_status_gsi_name" {
  description = "Sparse GSI exposing inventory records by submission status."
  value       = local.status_gsi_name
}

output "cnam_provisioner_lambda_arn" {
  description = "CNAM provisioner Lambda ARN."
  value       = aws_lambda_function.cnam_provisioner.arn
}

output "cnam_provisioner_lambda_name" {
  description = "CNAM provisioner Lambda function name."
  value       = aws_lambda_function.cnam_provisioner.function_name
}

output "cnam_verifier_lambda_arn" {
  description = "CNAM verifier Lambda ARN."
  value       = aws_lambda_function.cnam_verifier.arn
}

output "cnam_verifier_lambda_name" {
  description = "CNAM verifier Lambda function name."
  value       = aws_lambda_function.cnam_verifier.function_name
}

output "submission_failure_alarm_name" {
  description = "CloudWatch alarm name for submission failures."
  value       = var.enable_submission_failure_alarm ? aws_cloudwatch_metric_alarm.submission_failure[0].alarm_name : null
}

output "drift_alarm_name" {
  description = "CloudWatch alarm name for CNAM drift."
  value       = var.enable_drift_alarm ? aws_cloudwatch_metric_alarm.drift_detected[0].alarm_name : null
}
