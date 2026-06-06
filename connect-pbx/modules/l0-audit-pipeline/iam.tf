################################################################################
# AWS Config – custom service role (replaces service-linked role for PRD-02
# permission-boundary compliance)
################################################################################

resource "aws_iam_role" "config_service" {
  name                 = "${var.org_name}-config-service-role-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = { Layer = "L0", PRD = "PRD-02" }
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_delivery" {
  name = "${var.org_name}-config-delivery"
  role = aws_iam_role.config_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Delivery"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl"
        ]
        Resource = [
          "${aws_s3_bucket.audit.arn}",
          "${aws_s3_bucket.audit.arn}/config/*"
        ]
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.config.arn
      },
      {
        Sid    = "KMSForDelivery"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = local.env_kms_key_arn
      }
    ]
  })
}

################################################################################
# Lambda audit execution role
################################################################################

resource "aws_iam_role" "lambda_audit" {
  name                 = "${var.org_name}-audit-lambda-execution"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_iam_role_policy" "lambda_audit_logs" {
  name = "${var.org_name}-audit-lambda-logs"
  role = aws_iam_role.lambda_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-audit-*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_audit_s3" {
  name = "${var.org_name}-audit-lambda-s3"
  role = aws_iam_role.lambda_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadAuditLogs"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${data.terraform_remote_state.bootstrap.outputs.state_bucket_arn}/audit/*"
      },
      {
        Sid      = "ListDriftPrefix"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = "audit/drift/*" }
        }
      },
      {
        Sid      = "WriteEvidenceExport"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.audit.arn}/evidence/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_audit_sns" {
  name = "${var.org_name}-audit-lambda-sns"
  role = aws_iam_role.lambda_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.platform_alerts.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_audit_kms" {
  name = "${var.org_name}-audit-lambda-kms"
  role = aws_iam_role.lambda_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "KMSDecryptAuditLogs"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = local.env_kms_key_arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_audit_evidence_queries" {
  name = "${var.org_name}-audit-lambda-evidence-queries"
  role = aws_iam_role.lambda_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudTrailLookup"
        Effect   = "Allow"
        Action   = ["cloudtrail:LookupEvents"]
        Resource = "*"
      },
      {
        Sid    = "ConfigQuery"
        Effect = "Allow"
        Action = [
          "config:DescribeComplianceByConfigRule",
          "config:DescribeConfigurationRecorderStatus",
          "config:GetDiscoveredResourceCounts"
        ]
        Resource = "*"
      },
      {
        Sid      = "SecurityHubQuery"
        Effect   = "Allow"
        Action   = ["securityhub:GetFindings"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_audit_xray" {
  name = "${var.org_name}-audit-lambda-xray"
  role = aws_iam_role.lambda_audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name                 = "${var.org_name}-cloudtrail-cloudwatch"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name = "${var.org_name}-cloudtrail-cloudwatch"
  role = aws_iam_role.cloudtrail_cloudwatch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudWatchLogsDelivery"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}
