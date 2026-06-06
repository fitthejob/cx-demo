data "archive_file" "drift_detector" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/routing-drift-detector.zip"
}

resource "aws_iam_role" "routing_drift" {
  name                 = "${var.org_name}-routing-drift-${terraform.workspace}"
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

resource "aws_cloudwatch_log_group" "drift_detector" {
  name              = "/aws/lambda/${var.org_name}-routing-drift-detector-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy" "routing_drift" {
  name = "routing-drift"
  role = aws_iam_role.routing_drift.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DriftTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = [
          aws_dynamodb_table.routing_drift.arn,
          "${aws_dynamodb_table.routing_drift.arn}/index/${local.status_gsi_name}"
        ]
      },
      {
        Sid    = "ReadTerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.module_state_resolution.state_bucket}/${var.module_state_resolution.phone_numbers_state_key}",
          "arn:aws:s3:::${var.module_state_resolution.state_bucket}/env:/*/${var.module_state_resolution.phone_numbers_state_key}",
          "arn:aws:s3:::${var.module_state_resolution.state_bucket}/${var.module_state_resolution.contact_flow_state_key}",
          "arn:aws:s3:::${var.module_state_resolution.state_bucket}/env:/*/${var.module_state_resolution.contact_flow_state_key}"
        ]
      },
      {
        Sid    = "ConnectRead"
        Effect = "Allow"
        Action = [
          "connect:ListPhoneNumbersV2"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudTrailRead"
        Effect = "Allow"
        Action = [
          "cloudtrail:LookupEvents"
        ]
        Resource = "*"
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
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = local.metric_namespace
          }
        }
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.drift_detector.arn}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "drift_detector" {
  function_name    = "${var.org_name}-routing-drift-detector-${terraform.workspace}"
  description      = "PRD-19 detector for number-to-flow routing drift in Amazon Connect."
  runtime          = "python3.12"
  handler          = "drift_detector.handler"
  role             = aws_iam_role.routing_drift.arn
  filename         = data.archive_file.drift_detector.output_path
  source_code_hash = data.archive_file.drift_detector.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      DRIFT_TABLE                  = aws_dynamodb_table.routing_drift.name
      STATUS_GSI_NAME              = local.status_gsi_name
      MODULE_STATE_RESOLUTION_JSON = jsonencode(var.module_state_resolution)
      METRIC_NAMESPACE             = local.metric_namespace
      TF_WORKSPACE                 = terraform.workspace
      LOOKBACK_MINUTES             = tostring(var.lookback_minutes)
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_event_rule" "drift_schedule" {
  count = var.enable_schedule ? 1 : 0

  name                = "${var.org_name}-routing-drift-schedule-${terraform.workspace}"
  description         = "Optional 15-minute PRD-19 routing drift scan."
  schedule_expression = var.schedule_expression
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "drift_schedule" {
  count = var.enable_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.drift_schedule[0].name
  target_id = "routing-drift-detector"
  arn       = aws_lambda_function.drift_detector.arn
  input = jsonencode({
    operation = "SCAN_ALL"
  })
}

resource "aws_lambda_permission" "drift_schedule" {
  count = var.enable_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeRoutingDrift"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_detector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drift_schedule[0].arn
}
