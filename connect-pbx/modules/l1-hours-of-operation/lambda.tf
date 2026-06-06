data "archive_file" "holiday_check" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/holiday_check.zip"
}

resource "aws_lambda_function" "holiday_check" {
  function_name    = "${var.org_name}-holiday-check-${terraform.workspace}"
  runtime          = "python3.12"
  handler          = "holiday_check.handler"
  role             = aws_iam_role.holiday_check.arn
  filename         = data.archive_file.holiday_check.output_path
  source_code_hash = data.archive_file.holiday_check.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      CLOSURES_TABLE_NAME        = aws_dynamodb_table.holiday_closures.name
      DAILY_STATUS_TABLE_NAME    = aws_dynamodb_table.daily_closure_status.name
      TIME_ZONE                  = var.default_timezone
      METRIC_NAMESPACE           = "${var.org_name}/HolidayCheck"
      EMERGENCY_CLOSURE_SSM_PARAM = aws_ssm_parameter.emergency_closure.name
      ENVIRONMENT                = terraform.workspace
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "holiday_check" {
  name              = "/aws/lambda/${aws_lambda_function.holiday_check.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "holiday_check" {
  name = "${var.org_name}-holiday-check-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "holiday_check" {
  name = "holiday-check-policy"
  role = aws_iam_role.holiday_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.holiday_closures.arn,
          aws_dynamodb_table.daily_closure_status.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:DescribeStream", "dynamodb:ListStreams"]
        Resource = "${aws_dynamodb_table.holiday_closures.arn}/stream/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.holiday_check.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.env_kms_key_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.emergency_closure.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "${var.org_name}/HolidayCheck"
          }
        }
      }
    ]
  })
}

# Daily midnight schedule
resource "aws_cloudwatch_event_rule" "daily_holiday_check" {
  name                = "${var.org_name}-daily-holiday-check-${terraform.workspace}"
  description         = "Triggers holiday check Lambda daily at midnight ET to pre-compute closure status"
  schedule_expression = "cron(0 5 * * ? *)" # 05:00 UTC ≈ midnight ET; Lambda uses var.default_timezone for date logic

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "daily_holiday_check" {
  rule = aws_cloudwatch_event_rule.daily_holiday_check.name
  arn  = aws_lambda_function.holiday_check.arn
}

resource "aws_lambda_permission" "daily_holiday_check" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.holiday_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_holiday_check.arn
}

# DynamoDB Streams trigger — re-compute on company closure table writes
resource "aws_lambda_event_source_mapping" "holiday_closures_stream" {
  event_source_arn  = aws_dynamodb_table.holiday_closures.stream_arn
  function_name     = aws_lambda_function.holiday_check.arn
  starting_position = "LATEST"
  batch_size        = 1
}
