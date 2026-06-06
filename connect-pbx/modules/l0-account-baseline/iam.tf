locals {
  project_bucket_arns = [
    "arn:aws:s3:::${var.state_bucket}",
    "arn:aws:s3:::${var.org_name}-*",
  ]

  project_object_arns = [
    "arn:aws:s3:::${var.state_bucket}/*",
    "arn:aws:s3:::${var.org_name}-*/*",
  ]

  project_dynamodb_arns = [
    "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.org_name}-*",
    "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.org_name}-*/index/*",
  ]

  project_topic_arns = [
    "arn:aws:sns:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.org_name}-*",
  ]

  project_event_bus_arns = compact(concat(
    ["arn:aws:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"],
    var.deployment_profile.shared_bus_arn != "" ? [var.deployment_profile.shared_bus_arn] : [],
  ))

  project_connect_manage_arns = [
    "arn:aws:connect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
    "arn:aws:connect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*/*",
    "arn:aws:connect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:phone-number/*",
  ]

  project_log_group_arns = [
    "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-*",
    "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-*:*",
    "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/cloudtrail/${var.org_name}-*",
    "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/cloudtrail/${var.org_name}-*:*",
  ]

  project_kms_key_arns = [
    "arn:aws:kms:${var.aws_region}:${data.aws_caller_identity.current.account_id}:key/*",
  ]

  project_ssm_parameter_arns = [
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.org_name}/*",
  ]

  project_secret_arns = [
    "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.org_name}*",
  ]

  project_ses_identity_arns = [
    "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/*",
  ]
}

resource "aws_iam_policy" "platform_boundary" {
  name        = "${var.org_name}-platform-boundary"
  description = "Permission boundary applied to all platform Lambda and service roles."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowProjectS3Objects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = local.project_object_arns
      },
      {
        Sid    = "AllowProjectS3Buckets"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketAcl",
        ]
        Resource = local.project_bucket_arns
      },
      {
        Sid    = "AllowProjectDynamoDB"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = local.project_dynamodb_arns
      },
      {
        Sid    = "AllowProjectEventBridge"
        Effect = "Allow"
        Action = [
          "events:PutEvents",
        ]
        Resource = local.project_event_bus_arns
      },
      {
        Sid    = "AllowProjectSNS"
        Effect = "Allow"
        Action = [
          "sns:Publish",
        ]
        Resource = local.project_topic_arns
      },
      {
        Sid    = "AllowConnectAssociations"
        Effect = "Allow"
        Action = [
          "connect:AssociatePhoneNumberContactFlow",
          "connect:DisassociatePhoneNumberContactFlow",
        ]
        Resource = local.project_connect_manage_arns
      },
      {
        Sid    = "AllowConnectReadOnlyListCalls"
        Effect = "Allow"
        Action = [
          "connect:ListPhoneNumbersV2",
          "connect:ListUsers",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowSESOutboundMail"
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail",
          "ses:SendTemplatedEmail",
        ]
        Resource = local.project_ses_identity_arns
      },
      {
        Sid    = "AllowProjectLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = local.project_log_group_arns
      },
      {
        Sid    = "AllowProjectKMSUsage"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = local.project_kms_key_arns
        Condition = {
          "ForAnyValue:StringLike" = {
            "kms:ResourceAliases" = "alias/${var.org_name}-*"
          }
        }
      },
      {
        Sid    = "AllowProjectSSMParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = local.project_ssm_parameter_arns
      },
      {
        Sid    = "AllowProjectSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
        ]
        Resource = local.project_secret_arns
      },
      {
        Sid    = "AllowCloudWatchMetricsForApprovedNamespaces"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "cloudwatch:namespace" = [
              "ConnectPBX/*",
              "${var.org_name}/*",
            ]
          }
        }
      },
      {
        Sid    = "AllowAuditReadOnlyQueries"
        Effect = "Allow"
        Action = [
          "cloudtrail:LookupEvents",
          "config:DescribeComplianceByConfigRule",
          "config:DescribeConfigurationRecorderStatus",
          "config:GetDiscoveredResourceCounts",
          "securityhub:GetFindings",
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowXRayTelemetry"
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
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
          "iam:DeleteUserPermissionsBoundary",
        ]
        Resource = "*"
      },
      {
        Sid    = "DenyKMSDeletion"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion",
          "kms:DeleteAlias",
          "kms:DisableKey",
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
          "s3:ListAllMyBuckets",
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
