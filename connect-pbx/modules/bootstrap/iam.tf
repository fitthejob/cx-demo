#--------------------
# OIDC Provider
#--------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    PRD = "PRD-00"
  }
}

#--------------------
# GitHub Actions OIDC Role
#--------------------

resource "aws_iam_role" "github_actions_oidc" {
  name                 = "${var.org_name}-github-actions-oidc"
  max_session_duration = 14400

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDCTrust"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = concat(
              [
                for branch in var.allowed_branches :
                "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${branch}"
              ],
              [
                for environment in var.allowed_environments :
                "repo:${var.github_org}/${var.github_repo}:environment:${environment}"
              ]
            )
          }
        }
      }
    ]
  })

  tags = {
    PRD  = "PRD-00"
    Role = "OIDC"
  }
}

resource "aws_iam_role_policy" "github_actions_oidc" {
  name = "${var.org_name}-github-actions-oidc"
  role = aws_iam_role.github_actions_oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AssumeExecutionRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.terraform_execution.arn
      }
    ]
  })
}

#--------------------
# Terraform Execution Role
#--------------------

resource "aws_iam_role" "terraform_execution" {
  name                 = "${var.org_name}-terraform-execution-role"
  max_session_duration = 14400

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowOIDCRoleChaining"
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.github_actions_oidc.arn
        }
      },
      {
        Sid    = "AllowGitHubActionsOIDCDirectly"
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = concat(
              [
                for branch in var.allowed_branches :
                "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${branch}"
              ],
              [
                for environment in var.allowed_environments :
                "repo:${var.github_org}/${var.github_repo}:environment:${environment}"
              ]
            )
          }
        }
      }
    ]
  })

  tags = {
    PRD   = "PRD-00"
    Role  = "Execution"
    Scope = "bootstrap"
  }
}

resource "aws_iam_role_policy" "terraform_execution_s3" {
  name = "${var.org_name}-terraform-execution-s3"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = "arn:aws:s3:::${var.org_name}-tfstate-*/*"
      },
      {
        Sid    = "StateBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning",
        ]
        Resource = "arn:aws:s3:::${var.org_name}-tfstate-*"
      },
      {
        Sid    = "ConnectRecordingsPlaceholderRead"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetBucketTagging",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetLifecycleConfiguration",
          "s3:GetEncryptionConfiguration",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketPolicy",
          "s3:GetBucketLogging",
        ]
        Resource = "arn:aws:s3:::${var.org_name}-connect-recordings-placeholder-${data.aws_caller_identity.current.account_id}"
      },
      {
        Sid    = "ConnectRecordingsPlaceholderManage"
        Effect = "Allow"
        Action = [
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:PutBucketTagging",
          "s3:PutEncryptionConfiguration",
          "s3:PutLifecycleConfiguration",
          "s3:PutBucketVersioning",
          "s3:PutBucketPublicAccessBlock",
          "s3:DeleteBucketPolicy",
        ]
        Resource = "arn:aws:s3:::${var.org_name}-connect-recordings-placeholder-${data.aws_caller_identity.current.account_id}"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_connect_read" {
  name = "${var.org_name}-terraform-execution-connect-read"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConnectInstanceRead"
        Effect = "Allow"
        Action = [
          "connect:DescribeInstance",
          "connect:DescribeInstanceAttribute",
          "connect:ListLambdaFunctions",
        ]
        Resource = "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"
      },
      {
        Sid    = "ConnectHoursRead"
        Effect = "Allow"
        Action = [
          "connect:DescribeHoursOfOperation",
        ]
        Resource = "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*/operating-hours/*"
      },
      {
        Sid    = "ConnectQueueRead"
        Effect = "Allow"
        Action = [
          "connect:DescribeQueue",
          "connect:DescribeRoutingProfile",
          "connect:ListRoutingProfileQueues",
          "connect:ListQueueQuickConnects",
        ]
        Resource = [
          "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*/queue/*",
          "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*/routing-profile/*",
        ]
      },
      {
        Sid    = "ConnectContactFlowRead"
        Effect = "Allow"
        Action = [
          "connect:DescribeContactFlow",
        ]
        Resource = "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*/contact-flow/*"
      },
      {
        Sid    = "ConnectSecurityProfileRead"
        Effect = "Allow"
        Action = [
          "connect:DescribeSecurityProfile",
          "connect:ListSecurityProfilePermissions",
        ]
        Resource = "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*/security-profile/*"
      },
      {
        Sid    = "ConnectInstanceStorageConfigRead"
        Effect = "Allow"
        Action = [
          "connect:DescribeInstanceStorageConfig",
        ]
        Resource = "arn:aws:connect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_runtime_read" {
  name = "${var.org_name}-terraform-execution-runtime-read"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchAlarmRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "LogsRead"
        Effect = "Allow"
        Action = [
          "logs:DescribeMetricFilters",
          "logs:DescribeLogGroups",
          "logs:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid    = "DynamoDBProjectTableRead"
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:ListTagsOfResource",
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.org_name}-*"
      },
      {
        Sid    = "DynamoDBProjectTableManage"
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateContinuousBackups",
        ]
        Resource = "arn:aws:dynamodb:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:table/${var.org_name}-*"
      },
      {
        Sid    = "EventBridgeProjectRuleRead"
        Effect = "Allow"
        Action = [
          "events:DescribeRule",
          "events:ListTagsForResource",
          "events:ListTargetsByRule",
        ]
        Resource = "arn:aws:events:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:rule/${var.org_name}-*"
      },
      {
        Sid    = "LambdaProjectFunctionRead"
        Effect = "Allow"
        Action = [
          "lambda:GetEventSourceMapping",
          "lambda:GetFunction",
          "lambda:GetFunctionCodeSigningConfig",
          "lambda:GetPolicy",
          "lambda:ListTags",
          "lambda:ListVersionsByFunction",
        ]
        Resource = [
          "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.org_name}-*",
          "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:event-source-mapping:*",
        ]
      },
      {
        Sid    = "LambdaProjectFunctionManage"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
        ]
        Resource = "arn:aws:lambda:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:function:${var.org_name}-*"
      },
      {
        Sid    = "SSMProjectParameterRead"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:DescribeParameters",
          "ssm:ListTagsForResource",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_kms" {
  name = "${var.org_name}-terraform-execution-kms"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSStateAccess"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "arn:aws:kms:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          "ForAnyValue:StringLike" = {
            "kms:ResourceAliases" = "alias/${var.org_name}-*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_iam" {
  name = "${var.org_name}-terraform-execution-iam"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "IAMRoleManagement"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListRoleTags",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePermissionsBoundary",
          "iam:DeleteRolePermissionsBoundary",
          "iam:TagRole",
          "iam:UntagRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-*"
      },
      {
        Sid    = "IAMPassRoleToLambda"
        Effect = "Allow"
        Action = [
          "iam:PassRole",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-audit-lambda-execution",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-cnam-registry-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-closure-check-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-phone-flow-assoc-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-e911-compliance-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-holiday-check-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-number-portability-check-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-routing-drift-*",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-number-reputation-*",
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "lambda.amazonaws.com"
          }
        }
      },
      {
        Sid    = "IAMPassRoleToConfig"
        Effect = "Allow"
        Action = [
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-config-service-role-*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "config.amazonaws.com"
          }
        }
      },
      {
        Sid    = "IAMPassRoleToCloudTrail"
        Effect = "Allow"
        Action = [
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-cloudtrail-cloudwatch"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "cloudtrail.amazonaws.com"
          }
        }
      },
      {
        Sid    = "IAMPolicyManagement"
        Effect = "Allow"
        Action = [
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.org_name}-*"
      },
      {
        Sid    = "IAMAccountPasswordPolicyManagement"
        Effect = "Allow"
        Action = [
          "iam:GetAccountPasswordPolicy",
          "iam:UpdateAccountPasswordPolicy",
          "iam:DeleteAccountPasswordPolicy",
        ]
        Resource = "*"
      },
      {
        Sid    = "ConnectServiceLinkedRoleRead"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/connect.amazonaws.com/AWSServiceRoleForAmazonConnect"
      },
      {
        Sid    = "ConnectServiceLinkedRoleCreate"
        Effect = "Allow"
        Action = [
          "iam:CreateServiceLinkedRole",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "connect.amazonaws.com"
          }
        }
      },
      {
        Sid    = "OIDCProviderManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_access_analyzer" {
  name = "${var.org_name}-terraform-execution-access-analyzer"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AccessAnalyzerManagement"
        Effect = "Allow"
        Action = [
          "access-analyzer:CreateAnalyzer",
          "access-analyzer:DeleteAnalyzer",
          "access-analyzer:GetAnalyzer",
          "access-analyzer:ListTagsForResource",
          "access-analyzer:TagResource",
          "access-analyzer:UntagResource",
          "access-analyzer:UpdateAnalyzer",
        ]
        Resource = "arn:aws:access-analyzer:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:analyzer/${var.org_name}-*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_kms_admin" {
  name = "${var.org_name}-terraform-execution-kms-admin"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ProjectKMSManagement"
        Effect = "Allow"
        Action = [
          "kms:CreateAlias",
          "kms:CreateKey",
          "kms:DeleteAlias",
          "kms:DescribeKey",
          "kms:EnableKeyRotation",
          "kms:GetKeyPolicy",
          "kms:GetKeyRotationStatus",
          "kms:ListAliases",
          "kms:ListResourceTags",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
          "kms:CancelKeyDeletion",
          "kms:TagResource",
          "kms:UntagResource",
          "kms:UpdateAlias",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_organizations" {
  name = "${var.org_name}-terraform-execution-organizations"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OrganizationsPolicyManagement"
        Effect = "Allow"
        Action = [
          "organizations:CreatePolicy",
          "organizations:DeletePolicy",
          "organizations:DescribeOrganization",
          "organizations:DescribePolicy",
          "organizations:ListPolicies",
          "organizations:ListRoots",
          "organizations:ListTagsForResource",
          "organizations:TagResource",
          "organizations:UntagResource",
          "organizations:UpdatePolicy",
        ]
        Resource = "*"
      }
    ]
  })
}

