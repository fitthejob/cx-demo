data "archive_file" "e911_bundle" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/e911-compliance.zip"
}

resource "aws_iam_role" "e911_compliance" {
  name                 = "${var.org_name}-e911-compliance-${terraform.workspace}"
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

resource "aws_cloudwatch_log_group" "emergency_notification" {
  name              = "/aws/lambda/${var.org_name}-emergency-notification-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "e911_registration" {
  name              = "/aws/lambda/${var.org_name}-e911-registration-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "e911_provider_sync" {
  name              = "/aws/lambda/${var.org_name}-e911-provider-sync-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "e911_compliance_audit" {
  name              = "/aws/lambda/${var.org_name}-e911-compliance-audit-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role_policy" "e911_compliance" {
  name = "e911-compliance"
  role = aws_iam_role.e911_compliance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "LocationRegistryTable"
          Effect = "Allow"
          Action = [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            "dynamodb:Scan"
          ]
          Resource = [
            aws_dynamodb_table.location_registry.arn,
            "${aws_dynamodb_table.location_registry.arn}/index/${local.sync_status_gsi_name}"
          ]
        },
        {
          Sid      = "SecurityAlertsTopic"
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = aws_sns_topic.security_alerts.arn
        },
        {
          Sid      = "ConnectUsersRead"
          Effect   = "Allow"
          Action   = ["connect:ListUsers"]
          Resource = "*"
        },
        {
          Sid    = "PhoneNumbersStateRead"
          Effect = "Allow"
          Action = ["s3:GetObject"]
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
          Resource = [
            "${aws_cloudwatch_log_group.emergency_notification.arn}:*",
            "${aws_cloudwatch_log_group.e911_registration.arn}:*",
            "${aws_cloudwatch_log_group.e911_provider_sync.arn}:*",
            "${aws_cloudwatch_log_group.e911_compliance_audit.arn}:*"
          ]
        }
      ],
      local.artifact_bucket_enabled ? [
        {
          Sid      = "ComplianceArtifactWrite"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = ["arn:aws:s3:::${var.compliance_artifact_bucket_name}/e911/*"]
        }
      ] : [],
      length(local.secret_arns) > 0 ? [
        {
          Sid      = "ProviderSecrets"
          Effect   = "Allow"
          Action   = ["secretsmanager:GetSecretValue"]
          Resource = local.secret_arns
        }
      ] : [],
      var.registration_email_delivery_mode == "live" ? [
        {
          Sid      = "RegistrationEmail"
          Effect   = "Allow"
          Action   = ["ses:SendEmail", "ses:SendRawEmail", "ses:SendTemplatedEmail"]
          Resource = "*"
        }
      ] : []
    )
  })
}

resource "aws_lambda_function" "emergency_notification" {
  function_name    = "${var.org_name}-emergency-notification-${terraform.workspace}"
  description      = "PRD-18 emergency notification service contract."
  runtime          = "python3.12"
  handler          = "emergency_notification.handler"
  role             = aws_iam_role.e911_compliance.arn
  filename         = data.archive_file.e911_bundle.output_path
  source_code_hash = data.archive_file.e911_bundle.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                        = aws_dynamodb_table.location_registry.name
      SECURITY_ALERTS_TOPIC_ARN         = aws_sns_topic.security_alerts.arn
      METRIC_NAMESPACE                  = local.metric_namespace
      NOTIFICATION_DELIVERY_MODE        = var.notification_delivery_mode
      ALLOW_LIVE_EXTERNAL_NOTIFICATIONS = tostring(var.allow_live_external_notifications)
      TF_WORKSPACE                      = terraform.workspace
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "e911_registration" {
  function_name    = "${var.org_name}-e911-registration-${terraform.workspace}"
  description      = "PRD-18 guarded registration workflow for office and remote worker location records."
  runtime          = "python3.12"
  handler          = "e911_registration.handler"
  role             = aws_iam_role.e911_compliance.arn
  filename         = data.archive_file.e911_bundle.output_path
  source_code_hash = data.archive_file.e911_bundle.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                          = aws_dynamodb_table.location_registry.name
      METRIC_NAMESPACE                    = local.metric_namespace
      REGISTRATION_EMAIL_DELIVERY_MODE    = var.registration_email_delivery_mode
      ALLOW_LIVE_EXTERNAL_NOTIFICATIONS   = tostring(var.allow_live_external_notifications)
      REMOTE_REGISTRATION_SENDER_EMAIL    = var.remote_registration_sender_email
      SES_TEMPLATE_NAME                   = aws_ses_template.remote_worker_registration.name
      LOCATION_VERIFICATION_INTERVAL_DAYS = tostring(var.location_verification_interval_days)
      OFFICE_LOCATIONS_JSON               = local.office_locations_json
      TF_WORKSPACE                        = terraform.workspace
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "e911_provider_sync" {
  function_name    = "${var.org_name}-e911-provider-sync-${terraform.workspace}"
  description      = "PRD-18 provider sync workflow with explicit safe-mode guardrails."
  runtime          = "python3.12"
  handler          = "e911_provider_sync.handler"
  role             = aws_iam_role.e911_compliance.arn
  filename         = data.archive_file.e911_bundle.output_path
  source_code_hash = data.archive_file.e911_bundle.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                 = aws_dynamodb_table.location_registry.name
      SYNC_STATUS_GSI_NAME       = local.sync_status_gsi_name
      PHONE_NUMBERS_STATE_BUCKET = var.state_bucket
      PHONE_NUMBERS_STATE_KEY    = local.phone_numbers_state_key
      METRIC_NAMESPACE           = local.metric_namespace
      E911_PROVIDER              = var.e911_provider
      E911_PROVIDER_MODE         = var.e911_provider_mode
      E911_PROVIDER_SECRET_ARN   = var.e911_provider_secret_arn
      ALLOW_LIVE_PROVIDER_SYNC   = tostring(var.allow_live_provider_sync)
      ELIN_ASSIGNMENT_MODE       = var.elin_assignment_mode
      TF_WORKSPACE               = terraform.workspace
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_function" "e911_compliance_audit" {
  function_name    = "${var.org_name}-e911-compliance-audit-${terraform.workspace}"
  description      = "PRD-18 compliance audit for E911 location coverage and staleness."
  runtime          = "python3.12"
  handler          = "e911_compliance_audit.handler"
  role             = aws_iam_role.e911_compliance.arn
  filename         = data.archive_file.e911_bundle.output_path
  source_code_hash = data.archive_file.e911_bundle.output_base64sha256
  timeout          = 120
  memory_size      = 256

  environment {
    variables = {
      TABLE_NAME                          = aws_dynamodb_table.location_registry.name
      CONNECT_INSTANCE_ID                 = local.connect_instance_id
      LOCATION_VERIFICATION_INTERVAL_DAYS = tostring(var.location_verification_interval_days)
      COMPLIANCE_ARTIFACT_BUCKET           = var.compliance_artifact_bucket_name
      METRIC_NAMESPACE                    = local.metric_namespace
      TF_WORKSPACE                        = terraform.workspace
    }
  }

  tags = local.common_tags
}

# NOTE: SES identity/domain verification must be configured separately.
# This template is referenced by the e911_registration Lambda when
# registration_email_delivery_mode = "live".
resource "aws_ses_template" "remote_worker_registration" {
  name    = "${var.org_name}-e911-remote-worker-registration-${terraform.workspace}"
  subject = "Action Required: Confirm Your E911 Dispatchable Location"

  html = <<-HTML
    <!DOCTYPE html>
    <html>
    <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>E911 Location Confirmation Required</h2>
      <p>Hello {{employee_name}},</p>
      <p>As a remote worker, you are required to confirm your dispatchable location for E911 compliance.</p>
      <p>Please confirm your address by clicking the link below before <strong>{{deadline_date}}</strong>:</p>
      <p><a href="{{confirmation_url}}" style="display:inline-block;padding:12px 24px;background:#0073bb;color:#fff;text-decoration:none;border-radius:4px;">Confirm My Location</a></p>
      <p>If the button does not work, copy and paste this URL into your browser:</p>
      <p>{{confirmation_url}}</p>
      <p>If you have questions, contact your administrator.</p>
    </body>
    </html>
  HTML

  text = <<-TEXT
    E911 Location Confirmation Required

    Hello {{employee_name}},

    As a remote worker, you are required to confirm your dispatchable location
    for E911 compliance.

    Please confirm your address by visiting the following link before
    {{deadline_date}}:

    {{confirmation_url}}

    If you have questions, contact your administrator.
  TEXT
}

resource "aws_cloudwatch_event_rule" "provider_sync_schedule" {
  count = var.enable_daily_provider_sync_schedule ? 1 : 0

  name                = "${var.org_name}-e911-provider-sync-${terraform.workspace}"
  description         = "Optional daily PRD-18 provider sync."
  schedule_expression = var.provider_sync_schedule_expression
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "provider_sync_schedule" {
  count = var.enable_daily_provider_sync_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.provider_sync_schedule[0].name
  target_id = "e911-provider-sync"
  arn       = aws_lambda_function.e911_provider_sync.arn
  input = jsonencode({
    operation         = "SYNC_PENDING"
    request_id        = "schedule-sync-pending"
    operator_identity = "eventbridge-schedule"
  })
}

resource "aws_lambda_permission" "provider_sync_schedule" {
  count = var.enable_daily_provider_sync_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeE911ProviderSync"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.e911_provider_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.provider_sync_schedule[0].arn
}

resource "aws_cloudwatch_event_rule" "compliance_audit_schedule" {
  count = var.enable_daily_compliance_audit_schedule ? 1 : 0

  name                = "${var.org_name}-e911-compliance-audit-${terraform.workspace}"
  description         = "Optional daily PRD-18 compliance audit."
  schedule_expression = var.compliance_audit_schedule_expression
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "compliance_audit_schedule" {
  count = var.enable_daily_compliance_audit_schedule ? 1 : 0

  rule      = aws_cloudwatch_event_rule.compliance_audit_schedule[0].name
  target_id = "e911-compliance-audit"
  arn       = aws_lambda_function.e911_compliance_audit.arn
  input = jsonencode({
    request_id        = "schedule-compliance-audit"
    operator_identity = "eventbridge-schedule"
  })
}

resource "aws_lambda_permission" "compliance_audit_schedule" {
  count = var.enable_daily_compliance_audit_schedule ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridgeE911ComplianceAudit"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.e911_compliance_audit.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.compliance_audit_schedule[0].arn
}
