locals {
  scps_enabled = var.deployment_profile.account_topology != "standalone"
}

resource "aws_organizations_policy" "deny_non_approved_regions" {
  count = local.scps_enabled ? 1 : 0

  name        = "${var.org_name}-deny-non-approved-regions"
  description = "Denies all API calls to regions not in the approved list"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonApprovedRegion"
        Effect = "Deny"
        NotAction = [
          "iam:*",
          "sts:*",
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets",
          "support:*",
          "trustedadvisor:*"
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
}

resource "aws_organizations_policy" "deny_cloudtrail_disable" {
  count       = local.scps_enabled ? 1 : 0
  name        = "${var.org_name}-deny-cloudtrail-disable"
  description = "Prevents disabling or deleting CloudTrail trails"
  type = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyCloudTrailDisable"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging",
          "cloudtrail:DeleteTrail",
          "cloudtrail:UpdateTrail"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy" "deny_kms_key_deletion" {
  count = local.scps_enabled ? 1 : 0

  name        = "${var.org_name}-deny-kms-key-deletion"
  description = "Prevents deletion of platform KMS keys"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyKMSKeyDeletion"
        Effect   = "Deny"
        Action   = ["kms:ScheduleKeyDeletion"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Project" = var.org_name
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy" "deny_root_usage" {
  count = local.scps_enabled ? 1 : 0

  name        = "${var.org_name}-deny-root-usage"
  description = "Denies all actions by the root account"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyRootUsage"
        Effect   = "Deny"
        NotAction = [
          "sts:GetSessionToken",
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ListMFADevices",
          "iam:ResyncMFADevice"
        ]
        Resource = "*"
        Condition = {
            StringLike = {
                "aws:PrincipalArn" = "arn:aws:iam::*:root"
            }
        }
      }
    ]
  })
}

resource "aws_organizations_policy" "require_mfa" {
  count = local.scps_enabled ? 1 : 0

  name        = "${var.org_name}-scp-require-mfa"
  description = "Denies all actions except IAM self-service MFA when MFA is not present"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyAllExceptMFASelfService"
        Effect = "Deny"
        NotAction = [
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ListMFADevices",
          "sts:GetSessionToken"
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      }
    ]
  })
}
