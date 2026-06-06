data "archive_file" "reputation_operations" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/reputation-operations.zip"
}

data "archive_file" "stir_shaken" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/stir-shaken-check.zip"
}

resource "aws_iam_role" "number_reputation" {
  name                 = "${var.org_name}-number-reputation-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "reputation_operations" {
  name              = "/aws/lambda/${var.org_name}-spam-reputation-check-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "stir_shaken" {
  name              = "/aws/lambda/${var.org_name}-stir-shaken-check-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy" "number_reputation" {
  name = "number-reputation"
  role = aws_iam_role.number_reputation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "DynamoDBReputationTable"
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:Query",
            "dynamodb:UpdateItem"
          ]
          Resource = [
            aws_dynamodb_table.reputation.arn,
            "${aws_dynamodb_table.reputation.arn}/index/${local.current_records_gsi}"
          ]
        },
        {
          Sid    = "PhoneNumbersStateRead"
          Effect = "Allow"
          Action = [
            "s3:GetObject"
          ]
          Resource = [
            "arn:aws:s3:::${var.state_bucket}/${local.phone_numbers_state_key}",
            "arn:aws:s3:::${var.state_bucket}/env:/*/${local.phone_numbers_state_key}"
          ]
        },
        {
          Sid    = "KMS"
          Effect = "Allow"
          Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
          Resource = distinct([
            local.env_kms_key_arn,
            local.bootstrap_kms_key_arn
          ])
        },
        {
          Sid      = "CloudWatchMetrics"
          Effect   = "Allow"
          Action   = ["cloudwatch:PutMetricData"]
          Resource = "*"
        },
        {
          Sid    = "CloudWatchLogs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogStream",
            "logs:PutLogEvents"
          ]
          Resource = [
            "${aws_cloudwatch_log_group.reputation_operations.arn}:*",
            "${aws_cloudwatch_log_group.stir_shaken.arn}:*"
          ]
        }
      ],
      length(local.all_secret_arns) > 0 ? [
        {
          Sid      = "SecretsManagerProviders"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.all_secret_arns
        }
      ] : []
    )
  })
}

resource "aws_lambda_function" "reputation_operations" {
  function_name    = "${var.org_name}-spam-reputation-check-${terraform.workspace}"
  description      = "PRD-16 reputation operations Lambda for inventory scans, assignment eligibility, and remediation state."
  runtime          = "python3.12"
  handler          = "reputation_check.handler"
  role             = aws_iam_role.number_reputation.arn
  filename         = data.archive_file.reputation_operations.output_path
  source_code_hash = data.archive_file.reputation_operations.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                 = aws_dynamodb_table.reputation.name
      HISTORY_TTL_DAYS           = tostring(var.history_ttl_days)
      REPUTATION_STALENESS_DAYS  = tostring(var.reputation_staleness_days)
      SPAM_THRESHOLD_RISK        = tostring(var.spam_threshold_risk)
      SPAM_THRESHOLD_SPAM        = tostring(var.spam_threshold_spam)
      REPUTATION_PROVIDER_MODE   = var.reputation_provider_mode
      REPUTATION_PROVIDERS       = jsonencode(var.reputation_providers)
      REPUTATION_API_SECRETS     = jsonencode(var.reputation_api_secrets)
      PHONE_NUMBERS_STATE_BUCKET = var.state_bucket
      PHONE_NUMBERS_STATE_KEY    = local.phone_numbers_state_key
      TF_WORKSPACE               = terraform.workspace
      METRIC_NAMESPACE           = local.metric_namespace
      BATCH_SIZE                 = tostring(var.batch_size)
      BATCH_DELAY_MS             = tostring(var.batch_delay_ms)
      ALARM_ON_RISK_LABEL        = tostring(var.alarm_on_risk_label)
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "stir_shaken" {
  function_name    = "${var.org_name}-stir-shaken-check-${terraform.workspace}"
  description      = "PRD-16 STIR/SHAKEN verification Lambda for on-demand and scheduled attestation refresh."
  runtime          = "python3.12"
  handler          = "stir_shaken_check.handler"
  role             = aws_iam_role.number_reputation.arn
  filename         = data.archive_file.stir_shaken.output_path
  source_code_hash = data.archive_file.stir_shaken.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                      = aws_dynamodb_table.reputation.name
      ATTESTATION_PROVIDER_MODE       = var.attestation_provider_mode
      ATTESTATION_PROVIDER_SECRET_ARN = var.attestation_provider_secret_arn
      PHONE_NUMBERS_STATE_BUCKET      = var.state_bucket
      PHONE_NUMBERS_STATE_KEY         = local.phone_numbers_state_key
      TF_WORKSPACE                    = terraform.workspace
      METRIC_NAMESPACE                = local.metric_namespace
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_event_rule" "weekly_reputation_scan" {
  count = var.enable_weekly_reputation_schedule ? 1 : 0

  name                = "${var.org_name}-spam-reputation-weekly-${terraform.workspace}"
  description         = "Optional weekly PRD-16 reputation inventory scan."
  schedule_expression = var.reputation_schedule_expression
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "weekly_reputation_scan" {
  count = var.enable_weekly_reputation_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.weekly_reputation_scan[0].name
  target_id = "reputation-operations"
  arn       = aws_lambda_function.reputation_operations.arn
  input = jsonencode({
    operation = "CHECK_INVENTORY"
  })
}

resource "aws_lambda_permission" "weekly_reputation_scan" {
  count = var.enable_weekly_reputation_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeReputation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reputation_operations.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_reputation_scan[0].arn
}

resource "aws_cloudwatch_event_rule" "weekly_attestation_scan" {
  count = var.enable_weekly_attestation_schedule ? 1 : 0

  name                = "${var.org_name}-stir-shaken-weekly-${terraform.workspace}"
  description         = "Optional weekly PRD-16 STIR/SHAKEN inventory scan."
  schedule_expression = var.attestation_schedule_expression
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "weekly_attestation_scan" {
  count = var.enable_weekly_attestation_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.weekly_attestation_scan[0].name
  target_id = "stir-shaken-check"
  arn       = aws_lambda_function.stir_shaken.arn
  input = jsonencode({
    operation = "CHECK_INVENTORY"
  })
}

resource "aws_lambda_permission" "weekly_attestation_scan" {
  count = var.enable_weekly_attestation_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeAttestation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stir_shaken.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_attestation_scan[0].arn
}
