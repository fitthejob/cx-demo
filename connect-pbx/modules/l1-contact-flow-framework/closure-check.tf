# closure-check.tf — FR-010: Closure status check Lambda
#
# Lightweight Lambda invoked by the main inbound contact flow to check
# whether today is a closure (holiday, company closure, or emergency).
# Reads PRD-12's pre-computed daily_closure_status DynamoDB table and
# emergency_closure SSM parameter. Returns result as contact attributes.

data "archive_file" "closure_check" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/closure-check"
  output_path = "${path.module}/closure-check.zip"
}

# checkov:skip=CKV_AWS_116: Closure-check is invoked synchronously by contact flows, so a DLQ does not apply to the call-path request model.
# checkov:skip=CKV_AWS_115: Reserved concurrency is intentionally left unset because call volume limits should be tuned per implementation.
# checkov:skip=CKV_AWS_117: This Lambda only calls DynamoDB and SSM and intentionally stays outside a VPC to avoid extra latency in the inbound call path.
# checkov:skip=CKV_AWS_272: Code signing is not yet part of the local zip-based Lambda packaging baseline for this repo.
resource "aws_lambda_function" "closure_check" {
  function_name    = "${var.org_name}-closure-check-${terraform.workspace}"
  description      = "Reads PRD-12 daily closure status and emergency closure. Invoked per-call by main inbound contact flow."
  runtime          = "python3.12"
  handler          = "closure_check.handler"
  role             = aws_iam_role.closure_check.arn
  filename         = data.archive_file.closure_check.output_path
  source_code_hash = data.archive_file.closure_check.output_base64sha256
  timeout          = 10
  memory_size      = 128
  kms_key_arn      = local.env_kms_key_arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DAILY_STATUS_TABLE_NAME      = local.daily_closure_status_table_name
      EMERGENCY_CLOSURE_PARAM_NAME = local.emergency_closure_parameter_name
    }
  }

  tags = local.common_tags
}

resource "aws_connect_lambda_function_association" "closure_check" {
  function_arn = aws_lambda_function.closure_check.arn
  instance_id  = local.connect_instance_id
}

resource "aws_cloudwatch_log_group" "closure_check" {
  name              = "/aws/lambda/${aws_lambda_function.closure_check.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "closure_check" {
  name                 = "${var.org_name}-closure-check-${terraform.workspace}"
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

resource "aws_iam_role_policy" "closure_check" {
  name = "closure-check"
  role = aws_iam_role.closure_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = local.daily_closure_status_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.emergency_closure_parameter_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = local.env_kms_key_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.closure_check.arn}:*"
      }
    ]
  })
}
