resource "aws_cloudwatch_log_group" "lambda_apply_failure_alarm" {
  name              = "/aws/lambda/${aws_lambda_function.apply_failure_alarm.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda_drift_alarm" {
  name              = "/aws/lambda/${aws_lambda_function.drift_alarm.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda_drift_missing_check" {
  name              = "/aws/lambda/${aws_lambda_function.drift_missing_check.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda_evidence_export" {
  name              = "/aws/lambda/${aws_lambda_function.evidence_export.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_resource_policy" "default_retention" {
  policy_name = "${var.org_name}-default-log-retention"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "logs.amazonaws.com" }
        Action    = ["logs:PutRetentionPolicy"]
        Resource  = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
      }
    ]
  })
}
