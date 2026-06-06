data "archive_file" "apply_failure_alarm" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/apply-failure-alarm"
  output_path = "${path.module}/.build/apply-failure-alarm.zip"
}

data "archive_file" "drift_alarm" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/drift-alarm"
  output_path = "${path.module}/.build/drift-alarm.zip"
}

data "archive_file" "drift_missing_check" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/drift-missing-check"
  output_path = "${path.module}/.build/drift-missing-check.zip"
}

data "archive_file" "evidence_export" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/evidence-export"
  output_path = "${path.module}/.build/evidence-export.zip"
}

resource "aws_lambda_function" "apply_failure_alarm" {
  function_name = "${var.org_name}-audit-apply-failure-alarm"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.apply_failure_alarm.output_path
  source_code_hash = data.archive_file.apply_failure_alarm.output_base64sha256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.platform_alerts.arn
      ENVIRONMENT     = terraform.workspace
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_lambda_permission" "apply_failure_alarm_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.apply_failure_alarm.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
}

resource "aws_s3_bucket_notification" "audit_triggers" {
  bucket = data.terraform_remote_state.bootstrap.outputs.state_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.apply_failure_alarm.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "audit/deployments/prod/"
    filter_suffix       = ".json"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.drift_alarm.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "audit/drift/"
    filter_suffix       = ".json"
  }

  depends_on = [
    aws_lambda_permission.apply_failure_alarm_s3,
    aws_lambda_permission.drift_alarm_s3
  ]
}

resource "aws_lambda_function" "drift_alarm" {
  function_name = "${var.org_name}-audit-drift-alarm"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.drift_alarm.output_path
  source_code_hash = data.archive_file.drift_alarm.output_base64sha256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.platform_alerts.arn
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_lambda_permission" "drift_alarm_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_alarm.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
}

resource "aws_lambda_function" "drift_missing_check" {
  function_name = "${var.org_name}-audit-drift-missing-check"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.drift_missing_check.output_path
  source_code_hash = data.archive_file.drift_missing_check.output_base64sha256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.platform_alerts.arn
      STATE_BUCKET    = data.terraform_remote_state.bootstrap.outputs.state_bucket_name
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_cloudwatch_event_rule" "drift_missing_check" {
  name                = "${var.org_name}-drift-missing-check"
  description         = "Checks daily at 01:00 UTC that nightly drift detection ran"
  schedule_expression = "cron(0 1 * * ? *)"
}

resource "aws_cloudwatch_event_target" "drift_missing_check" {
  rule      = aws_cloudwatch_event_rule.drift_missing_check.name
  target_id = "drift-missing-check-lambda"
  arn       = aws_lambda_function.drift_missing_check.arn
}

resource "aws_lambda_permission" "drift_missing_check_events" {
  statement_id  = "AllowCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_missing_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drift_missing_check.arn
}

resource "aws_lambda_function" "evidence_export" {
  function_name = "${var.org_name}-audit-evidence-export"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 600

  filename         = data.archive_file.evidence_export.output_path
  source_code_hash = data.archive_file.evidence_export.output_base64sha256

  environment {
    variables = {
      AUDIT_BUCKET = aws_s3_bucket.audit.bucket
      STATE_BUCKET = data.terraform_remote_state.bootstrap.outputs.state_bucket_name
      TRAIL_ARN    = aws_cloudtrail.main.arn
      ENVIRONMENT  = terraform.workspace
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_cloudwatch_event_rule" "evidence_export" {
  name                = "${var.org_name}-evidence-export-weekly"
  description         = "Triggers weekly evidence export every Monday at 06:00 UTC"
  schedule_expression = "cron(0 6 ? * MON *)"
}

resource "aws_cloudwatch_event_target" "evidence_export" {
  rule      = aws_cloudwatch_event_rule.evidence_export.name
  target_id = "evidence-export-lambda"
  arn       = aws_lambda_function.evidence_export.arn
}

resource "aws_lambda_permission" "evidence_export_events" {
  statement_id  = "AllowCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.evidence_export.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.evidence_export.arn
}
