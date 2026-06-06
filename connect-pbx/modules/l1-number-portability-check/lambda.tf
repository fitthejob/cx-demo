data "archive_file" "portability_check" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/portability-check.zip"
}

resource "aws_iam_role" "portability_check" {
  name                 = "${var.org_name}-number-portability-check-${terraform.workspace}"
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

resource "aws_cloudwatch_log_group" "portability_check" {
  name              = "/aws/lambda/${var.org_name}-number-portability-check-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy" "portability_check" {
  name = "number-portability-check"
  role = aws_iam_role.portability_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBPortabilityAudit"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.portability_audit.arn
      },
      {
        Sid      = "SecretsManagerProvider"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.lookup_provider_secret_arn != "" ? var.lookup_provider_secret_arn : "*"
      },
      {
        Sid      = "KMS"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = local.env_kms_key_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.portability_check.arn}:*"
      }
    ]
  })
}

resource "aws_lambda_function" "portability_check" {
  function_name    = "${var.org_name}-number-portability-check-${terraform.workspace}"
  description      = "Checks portability eligibility for DIDs and toll-free numbers and stores CURRENT plus history records."
  runtime          = "python3.12"
  handler          = "portability_check.handler"
  role             = aws_iam_role.portability_check.arn
  filename         = data.archive_file.portability_check.output_path
  source_code_hash = data.archive_file.portability_check.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                 = aws_dynamodb_table.portability_audit.name
      LOOKUP_PROVIDER            = var.lookup_provider
      LOOKUP_PROVIDER_SECRET_ARN = var.lookup_provider_secret_arn
      CHECK_EXPIRY_DAYS          = tostring(var.check_expiry_days)
      HISTORY_TTL_DAYS           = tostring(var.history_ttl_days)
    }
  }

  tags = local.common_tags
}
