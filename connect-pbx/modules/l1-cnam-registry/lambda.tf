data "archive_file" "cnam_provisioner" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/cnam-provisioner.zip"
}

data "archive_file" "cnam_verifier" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/cnam-verifier.zip"
}

resource "aws_iam_role" "cnam_registry" {
  name                 = "${var.org_name}-cnam-registry-${terraform.workspace}"
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

resource "aws_cloudwatch_log_group" "cnam_provisioner" {
  name              = "/aws/lambda/${var.org_name}-cnam-provisioner-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "cnam_verifier" {
  name              = "/aws/lambda/${var.org_name}-cnam-verifier-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy" "cnam_registry" {
  name = "cnam-registry"
  role = aws_iam_role.cnam_registry.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "CNAMInventoryTable"
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query"
          ]
          Resource = [
            aws_dynamodb_table.cnam_inventory.arn,
            "${aws_dynamodb_table.cnam_inventory.arn}/index/${local.status_gsi_name}"
          ]
        },
        {
          Sid      = "ReputationCurrentRead"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem"]
          Resource = local.reputation_table_arn
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
            "${aws_cloudwatch_log_group.cnam_provisioner.arn}:*",
            "${aws_cloudwatch_log_group.cnam_verifier.arn}:*"
          ]
        }
      ],
      length(local.secret_arns) > 0 ? [
        {
          Sid      = "SecretsManagerProviders"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.secret_arns
        }
      ] : [],
      var.bulk_import_bucket_name != "" ? [
        {
          Sid    = "BulkImportS3Read"
          Effect = "Allow"
          Action = ["s3:GetObject"]
          Resource = ["${var.bulk_import_bucket_arn}/cnam-import/*"]
        }
      ] : []
    )
  })
}

resource "aws_lambda_function" "cnam_provisioner" {
  function_name    = "${var.org_name}-cnam-provisioner-${terraform.workspace}"
  description      = "PRD-17 CNAM provisioner for desired record upserts, gated submission, and requeue."
  runtime          = "python3.12"
  handler          = "cnam_provisioner.handler"
  role             = aws_iam_role.cnam_registry.arn
  filename         = data.archive_file.cnam_provisioner.output_path
  source_code_hash = data.archive_file.cnam_provisioner.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                     = aws_dynamodb_table.cnam_inventory.name
      REPUTATION_TABLE_NAME          = local.reputation_table_name
      PHONE_NUMBERS_STATE_BUCKET     = var.state_bucket
      PHONE_NUMBERS_STATE_KEY        = local.phone_numbers_state_key
      TF_WORKSPACE                   = terraform.workspace
      METRIC_NAMESPACE               = local.metric_namespace
      CNAM_POLICY                    = var.cnam_policy
      CNAM_COMPANY_NAME              = var.cnam_company_name
      CNAM_PROVIDER                  = var.cnam_provider
      CNAM_PROVIDER_MODE             = var.cnam_provider_mode
      CNAM_PROVIDER_SECRET_ARN       = var.cnam_provider_secret_arn
      REPUTATION_STALENESS_DAYS      = tostring(var.reputation_staleness_days)
      SUBMISSION_BATCH_SIZE          = tostring(var.submission_batch_size)
      VERIFICATION_PROPAGATION_HOURS = tostring(var.verification_propagation_hours)
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "cnam_verifier" {
  function_name    = "${var.org_name}-cnam-verifier-${terraform.workspace}"
  description      = "PRD-17 CNAM verifier for on-demand and scheduled drift checks."
  runtime          = "python3.12"
  handler          = "cnam_verifier.handler"
  role             = aws_iam_role.cnam_registry.arn
  filename         = data.archive_file.cnam_verifier.output_path
  source_code_hash = data.archive_file.cnam_verifier.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                     = aws_dynamodb_table.cnam_inventory.name
      TF_WORKSPACE                   = terraform.workspace
      METRIC_NAMESPACE               = local.metric_namespace
      CNAM_PROVIDER                  = var.cnam_provider
      CNAM_PROVIDER_MODE             = var.cnam_provider_mode
      CNAM_PROVIDER_SECRET_ARN       = var.cnam_provider_secret_arn
      VERIFICATION_PROPAGATION_HOURS = tostring(var.verification_propagation_hours)
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_event_rule" "weekly_verification" {
  count = var.enable_weekly_verification_schedule ? 1 : 0

  name                = "${var.org_name}-cnam-weekly-verify-${terraform.workspace}"
  description         = "Optional weekly PRD-17 CNAM verification scan."
  schedule_expression = var.verification_schedule_expression
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "weekly_verification" {
  count = var.enable_weekly_verification_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.weekly_verification[0].name
  target_id = "cnam-verifier"
  arn       = aws_lambda_function.cnam_verifier.arn
  input = jsonencode({
    operation = "VERIFY_ACTIVE"
  })
}

resource "aws_lambda_permission" "weekly_verification" {
  count = var.enable_weekly_verification_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeCNAMVerification"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cnam_verifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_verification[0].arn
}

# --- Optional S3 bulk CSV import trigger for cnam_provisioner ---

resource "aws_lambda_permission" "bulk_csv_import" {
  count = var.bulk_import_bucket_name != "" ? 1 : 0

  statement_id  = "AllowExecutionFromS3BulkCSVImport"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cnam_provisioner.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.bulk_import_bucket_arn
}

resource "aws_s3_bucket_notification" "bulk_csv_import" {
  count  = var.bulk_import_bucket_name != "" ? 1 : 0
  bucket = var.bulk_import_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.cnam_provisioner.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "cnam-import/"
    filter_suffix       = ".csv"
  }

  depends_on = [aws_lambda_permission.bulk_csv_import]
}
