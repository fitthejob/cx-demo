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
      }
    ]
  })
}

resource "aws_iam_role_policy" "terraform_execution_dynamo_db" {
  name = "${var.org_name}-terraform-execution-dynamo-db"
  role = aws_iam_role.terraform_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable",
        ]
        Resource = aws_dynamodb_table.tfstate_lock.arn
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
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = "arn:aws:kms:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key/*"
        Condition = {
          StringLike = {
            "kms:ResourceAliases" = "alias/${var.org_name}-tfstate-*"
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
          "iam:CreateRole",
          "iam:UpdateRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:TagRole",
          "iam:PassRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.org_name}-*"
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

