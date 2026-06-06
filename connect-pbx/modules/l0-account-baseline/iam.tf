resource "aws_iam_policy" "platform_boundary" {
  name        = "${var.org_name}-platform-boundary"
  description = "Permission boundary applied to all platform Lambda and service roles."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPlatformServices"
        Effect = "Allow"
        Action = [
          "connect:*",
          "lambda:InvokeFunction",
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketAcl",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
                            "events:PutEvents",
                            "cloudtrail:LookupEvents",
                            "sns:Publish",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "transcribe:StartTranscriptionJob",
          "transcribe:GetTranscriptionJob",
          "lex:RecognizeText",
          "ses:SendEmail",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "secretsmanager:GetSecretValue"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyPrivilegeEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateUser",
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:AttachUserPolicy",
          "iam:PutRolePolicy",
          "iam:PutUserPolicy",
          "iam:CreatePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:PassRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:DeleteRolePermissionsBoundary",
          "iam:DeleteUserPermissionsBoundary"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyKMSDeletion"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion",
          "kms:DeleteAlias",
          "kms:DisableKey"
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyNonApprovedRegions"
        Effect = "Deny"
        NotAction = [
          "iam:*",
          "sts:*",
          "cloudwatch:PutMetricData",
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets"
        ]
        Resource = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = var.approved_regions
          }
        }
      }
    ]
  })
  tags = {
    Layer = "L0"
    PRD   = "PRD-02"
  }
}

resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "${var.org_name}-account-analyzer"
  type          = "ACCOUNT"

  tags = {
    Layer = "L0"
    PRD   = "PRD-02"
  }

}

resource "aws_iam_account_password_policy" "pci_compliant" {
  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
  hard_expiry                    = false
}
