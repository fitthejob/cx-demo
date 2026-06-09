# PRD-02 — AWS Account Baseline (IAM, KMS, SCPs)

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-02 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-03-16 |
| **Layer** | 0 — Platform Foundation |
| **Depends On** | PRD-00 (state backend, bootstrap KMS key, Terraform execution role), PRD-01 (CI/CD pipeline) |
| **Blocks** | PRD-03 and all subsequent PRDs — every module requires environment KMS key ARN from this PRD's outputs |
| **Optional** | No |

---

## 2. MODULE GOVERNANCE

### Module Classification

| Field | Value |
|---|---|
| `classification` | `core-required` |
| `minimum_deployment_profile` | `bare-bones` |
| `can_be_omitted_from_bare_bones` | `no` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |

### Catalog Entry

| Field | Value |
|---|---|
| `path` | `modules/l0-account-baseline` |
| `capability_packs` | `["core-telephony"]` |
| `dependencies` | `["modules/bootstrap"]` |
| `state_key` | `l0-account-baseline/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `null` |
| `supports_destroy` | `false` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 audit pipeline | Not consumed. PRD-02 outputs (KMS key, permission boundary) are consumed *by* PRD-03, but PRD-02 does not depend on PRD-03. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `protected` |
| `retention_notes` | KMS keys require a 30-day pending-deletion window. Deleting PRD-02 resources blocks all downstream modules that reference the environment KMS key or permission boundary ARN. Destruction should only occur during full environment teardown. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Every AWS resource provisioned by this platform requires three foundational elements before it can exist securely: a KMS key scoped to its environment for encryption at rest, an IAM permission model that enforces least privilege, and guardrails that prevent the account from drifting into insecure configurations. Without these elements in place first, downstream resources are provisioned with default encryption (AWS-managed keys), overly broad IAM roles, and no account-level policy enforcement.

PRD-02 establishes these three pillars as a prerequisite for every other module. It is the account's security posture baseline. Nothing that requires encryption, IAM, or policy controls can be safely provisioned until this PRD is applied.

### What Problem It Solves

- Provisions per-environment KMS customer-managed keys (dev, staging, prod) that satisfy the key isolation decision from PRD-00 and are consumed as `ENV_KMS_KEY_ARN` by every downstream module's backend configuration and resource encryption
- Establishes the IAM foundation: permission boundaries, service-linked roles for Amazon Connect and Lambda, and the cross-service trust policies required by the platform
- Establishes account-level IAM password policy and access analyzer to detect overly permissive resource policies
- Documents and defines Service Control Policy (SCP) intent as version-controlled HCL, with enforcement deferred to PRD-110 when a dedicated org-management Terraform role is provisioned with the required management account permissions
- Provides a clean, auditable account baseline that SOC 2 and PCI auditors can reference as the starting posture of the environment

### How It Fits the Overall Architecture

PRD-02 sits at the base of every other module's dependency chain. Its primary output — the per-environment KMS key ARN — is consumed by the Terraform backend configuration of every subsequent PRD and by every resource that requires encryption at rest. Its IAM permission boundaries are applied to every Lambda execution role and every service role provisioned by downstream PRDs.

### SCP Scope Note

Service Control Policies are AWS Organizations features and the organization structure is already in place. However, SCPs must be created and attached via the management account, which requires an IAM role with `organizations:CreatePolicy` and `organizations:AttachPolicy` permissions scoped to the management account. The Terraform execution role provisioned by PRD-00 operates within the workload account (dev or prod) and does not hold those management account permissions. SCP creation and attachment are therefore deferred to PRD-110, which provisions a dedicated org-management Terraform role in the management account. The SCP HCL definitions are version-controlled here and ready to apply the moment PRD-110 activates them — they are not being designed later.

---

## 4. GOALS

### Goals

- Provision three per-environment KMS customer-managed keys: dev, staging, prod
- Provision KMS key aliases following the platform naming convention
- Enable automatic annual KMS key rotation on all keys
- Establish IAM permission boundaries for Lambda execution roles and service roles
- Provision AWS IAM Access Analyzer for the account to detect publicly accessible or cross-account exposed resources
- Configure the account-level IAM password policy to meet PCI-DSS and SOC 2 requirements
- Define SCPs as version-controlled HCL resources ready for activation in PRD-110
- Provision the IAM service-linked role for Amazon Connect if not already present
- Export per-environment KMS key ARNs as Terraform outputs consumed by all downstream PRDs

### Non-Goals

- This PRD does not provision application-specific IAM roles — those are defined in each service's PRD
- This PRD does not attach SCPs to the organization — attachment requires the org-management role provisioned in PRD-110
- This PRD does not configure VPCs or networking — there is no VPC requirement for the serverless Connect architecture
- This PRD does not configure CloudTrail or AWS Config — those are PRD-03
- This PRD does not provision the Connect instance itself — that is PRD-10

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Applies this PRD as the second step after PRD-00 bootstrap. Consumes the KMS key ARN outputs to configure GitHub Actions environment secrets before any other PRD is applied.

**Security Engineer / Auditor** — Reviews the KMS key policies, IAM permission boundaries, and SCP definitions as evidence of access control and encryption controls for PCI-DSS and SOC 2 assessments.

**Downstream Module Author** — Every subsequent PRD references `data "terraform_remote_state" "account_baseline"` to retrieve the environment KMS key ARN. This PRD's outputs are the most widely consumed in the platform.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-02-01 | Platform Engineer | As the platform engineer, I want per-environment KMS keys available immediately after this PRD is applied so that I can populate GitHub Actions secrets and unblock all downstream PRDs | Three KMS key ARNs available as Terraform outputs after apply |
| US-02-02 | Platform Engineer | As the platform engineer, I want IAM permission boundaries defined so that no downstream Lambda or service role can ever escalate beyond the boundary | Permission boundary ARN available as output; all downstream execution roles reference it |
| US-02-03 | Security Auditor | As an auditor, I want evidence that all encryption keys are customer-managed with annual rotation so that I can satisfy PCI-DSS Req 3.6 and SOC 2 CC6.7 | KMS key rotation status returns true for all three keys |
| US-02-04 | Security Auditor | As an auditor, I want IAM Access Analyzer enabled so that any resource made publicly accessible is immediately flagged | Access Analyzer active, findings visible in AWS console and CloudTrail |
| US-02-05 | Security Auditor | As an auditor, I want the account password policy to meet PCI-DSS complexity requirements so that human IAM users are protected | `aws iam get-account-password-policy` returns compliant configuration |
| US-02-06 | Platform Engineer | As the platform engineer, I want SCP definitions version-controlled in HCL now so that when the org-management role is provisioned in PRD-110 the policies are immediately available without additional design work | SCP resource blocks exist in module, guarded by `var.deployment_profile.account_topology != "standalone"` condition |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Per-Environment KMS Key Provisioning
The system must provision three AWS KMS customer-managed keys, one per environment: dev, staging, and prod. Each key must be a symmetric encryption key (SYMMETRIC_DEFAULT) suitable for use with S3, DynamoDB, Lambda environment variables, CloudWatch Logs, and SNS. Keys must be provisioned in the same AWS region as all other platform resources.

### FR-002 — KMS Key Aliases
Each KMS key must have an alias following the naming convention `alias/{org_name}-{environment}`. The alias is the stable reference used in all downstream resource configurations. Key IDs rotate on deletion and recreation; aliases provide a stable pointer.

### FR-003 — KMS Key Rotation
All three environment KMS keys must have automatic annual rotation enabled at creation time. Rotation must not be disableable without a Terraform change that goes through the full PR review and approval pipeline.

### FR-004 — KMS Key Deletion Window
All three environment KMS keys must have a deletion window of 30 days minimum. This is longer than the 14-day bootstrap key window in PRD-00 because these keys encrypt application data — longer recovery windows are justified.

### FR-005 — KMS Key Policy
Each environment KMS key must have an explicit key policy granting:
- Root account full access (prevents key lockout)
- Terraform execution role (PRD-00) decrypt, generate data key, and describe access
- AWS service principals for Connect, Lambda, S3, DynamoDB, CloudWatch Logs, and SNS the ability to use the key for their respective encryption operations
- No wildcard principal grants on any action

### FR-006 — IAM Permission Boundary
The system must provision one IAM managed policy to serve as a permission boundary for all Lambda execution roles and service roles provisioned by downstream PRDs. The boundary must:
- Allow a defined set of platform service actions (Connect, Lambda, S3, DynamoDB, EventBridge, SNS, SQS, Transcribe, Lex, SES, CloudWatch Logs, X-Ray, KMS, SSM, Secrets Manager) on all resources — scoping is enforced by individual execution role policies, not the boundary
- Allow CloudWatch Logs write access for Lambda logging
- Allow X-Ray write access for tracing
- Deny any action that would create IAM entities, modify IAM policies, or escalate privileges
- Deny any action that would modify KMS key policies or schedule KMS key deletion
- Deny any action outside the permitted AWS regions

### FR-007 — IAM Access Analyzer
The system must enable AWS IAM Access Analyzer for the account with analyzer type `ACCOUNT`. The analyzer must be configured to generate findings for any resource that is publicly accessible or accessible by principals outside the account. Findings must be visible in the AWS console and recorded in CloudTrail.

### FR-008 — IAM Account Password Policy
The system must configure the account-level IAM password policy with the following settings to meet PCI-DSS Req 8.3 and SOC 2 CC6.1:
- Minimum password length: 14 characters
- Require uppercase letters: true
- Require lowercase letters: true
- Require numbers: true
- Require symbols: true
- Allow users to change password: true
- Maximum password age: 90 days
- Password reuse prevention: 24 previous passwords
- Hard expiry: false (account lockout on expiry disabled — prevents lockout without admin intervention)

### FR-009 — Connect Service-Linked Role
The system must ensure the IAM service-linked role for Amazon Connect (`AWSServiceRoleForAmazonConnect`) exists in the account. This role is required by the Connect instance provisioned in PRD-10. If the role already exists (created by a prior manual Connect interaction), the Terraform resource must use `create_before_destroy = false` and handle the pre-existing role gracefully.

### FR-010 — SCP Definition (Deferred Enforcement)
The system must define the following SCPs as HCL `aws_organizations_policy` resource blocks within the module, guarded by the condition `var.deployment_profile.account_topology != "standalone"`. When the deployment profile is `standalone` (default), these resources are not created. When the org-management Terraform role is provisioned in PRD-110 and `account_topology` is updated to `spoke` or `hub`, the SCPs are created and attached:

- **SCP-DENY-NON-APPROVED-REGIONS**: Denies all API calls to AWS regions outside the approved list defined in `var.approved_regions`
- **SCP-REQUIRE-MFA**: Denies all console actions by IAM users who have not authenticated with MFA
- **SCP-DENY-ROOT-USAGE**: Denies all actions by the root account except specific emergency break-glass actions
- **SCP-DENY-KMS-KEY-DELETION**: Denies `kms:ScheduleKeyDeletion` on keys tagged as platform keys
- **SCP-DENY-CLOUDTRAIL-DISABLE**: Denies `cloudtrail:StopLogging`, `cloudtrail:DeleteTrail`, and `cloudtrail:UpdateTrail` across the organization

### FR-011 — Resource Tagging Enforcement (Advisory)
The system must provision an AWS Config Rule (defined here, enforced in PRD-03) that checks all resources for the required platform tags: `Project`, `Layer`, `PRD`, `Environment`, and `ManagedBy`. Resources missing required tags must generate a Config finding. Tag enforcement is advisory in dev, blocking in prod.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
KMS is a regional AWS managed service with 99.99% availability. IAM is a global service. Neither requires HA configuration at this layer.

### Security

| Control | Requirement |
|---|---|
| KMS key access | Restricted to Terraform execution role and approved AWS service principals only |
| Key rotation | Automatic annual rotation on all three environment keys |
| Permission boundary | Applied to all downstream execution roles — prevents privilege escalation |
| Access Analyzer | Continuous monitoring for publicly exposed resources |
| Password policy | PCI-DSS Req 8.3 compliant |
| Root account | MFA required (manual control, documented in runbook) |

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 3.6 | KMS CMK with annual rotation | `aws kms get-key-rotation-status` output |
| PCI-DSS Req 7.1 | IAM permission boundary limits access to minimum necessary | Permission boundary policy document |
| PCI-DSS Req 8.3 | IAM password policy complexity | `aws iam get-account-password-policy` output |
| PCI-DSS Req 10.3 | Access Analyzer findings recorded in CloudTrail | CloudTrail event history |
| SOC 2 CC6.1 | Least privilege via permission boundaries | IAM policy document, boundary attachment |
| SOC 2 CC6.3 | Access Analyzer for external exposure detection | Access Analyzer findings |
| SOC 2 CC6.7 | CMK encryption with rotation | KMS key configuration |

### Scale
This module provisions account-level resources that do not scale with call volume or agent count. There is no capacity planning concern at this layer.

---

## 8. ARCHITECTURE

### Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS ACCOUNT                              │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   KMS LAYER                              │   │
│  │                                                          │   │
│  │  ┌─────────────┐  ┌───────────────┐  ┌───────────────┐  │   │
│  │  │  KMS Key    │  │   KMS Key     │  │   KMS Key     │  │   │
│  │  │  dev        │  │   staging     │  │   prod        │  │   │
│  │  │             │  │               │  │               │  │   │
│  │  │ Rotation:ON │  │  Rotation:ON  │  │  Rotation:ON  │  │   │
│  │  │ Window:30d  │  │  Window:30d   │  │  Window:30d   │  │   │
│  │  └──────┬──────┘  └──────┬────────┘  └──────┬────────┘  │   │
│  │         │                │                   │           │   │
│  │  alias/{org}-dev  alias/{org}-staging  alias/{org}-prod  │   │
│  └─────────┼────────────────┼───────────────────┼───────────┘   │
│            │                │                   │               │
│            ▼                ▼                   ▼               │
│     Consumed by all downstream PRD modules                      │
│     via ENV_KMS_KEY_ARN GitHub secret                           │
│     and terraform_remote_state.account_baseline output          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   IAM LAYER                              │   │
│  │                                                          │   │
│  │  Permission Boundary Policy                              │   │
│  │  {org}-platform-boundary                                 │   │
│  │  Applied to all Lambda + service roles in downstream PRDs│   │
│  │                                                          │   │
│  │  Service-Linked Role: AWSServiceRoleForAmazonConnect     │   │
│  │                                                          │   │
│  │  IAM Access Analyzer (ACCOUNT type)                      │   │
│  │                                                          │   │
│  │  Account Password Policy (PCI-DSS compliant)             │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │           SCP DEFINITIONS (deferred enforcement)         │   │
│  │                                                          │   │
│  │  Defined in HCL, not created when topology = standalone  │   │
│  │  Activated by changing deployment_profile.account_topology│  │
│  │  to spoke or hub in PRD-110                              │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Integration Points

PRD-02 has no EventBridge integration. It produces no events and consumes no events. Its outputs are consumed exclusively via Terraform remote state by all downstream PRDs.

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `kms_key_arn` | string | KMS key ARN for the current workspace environment | All PRDs — backend config + resource encryption |
| `kms_key_alias` | string | KMS key alias for the current workspace environment | Resource configurations preferring alias reference |
| `permission_boundary_arn` | string | IAM permission boundary managed policy ARN | Every Lambda execution role in PRD-40 onward |
| `access_analyzer_arn` | string | IAM Access Analyzer ARN | PRD-03 for finding aggregation |
| `connect_service_linked_role_arn` | string | Connect service-linked role ARN | PRD-10 Connect instance configuration |

> **Per-workspace outputs:** This module is applied once per environment workspace (`dev`, `staging`, `prod`). `kms_key_arn` and `kms_key_alias` return the key for the active workspace only — there is no single apply that provisions all three keys.

### Environment Key Resolution Pattern

Downstream PRDs resolve the current workspace's KMS key directly — no lookup map required since the module only exposes the key for the active workspace:

```hcl
# Standard pattern used in all downstream PRDs
data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/modules/l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
}
```

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l0-account-baseline/        # PRD-02
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── kms.tf                  # Per-environment KMS keys and aliases
        ├── iam.tf                  # Permission boundary, Access Analyzer, password policy
        ├── iam-connect.tf          # Connect service-linked role
        └── scps.tf                 # SCP definitions (conditionally created)
```

### Backend Configuration

This module uses partial backend configuration — `main.tf` contains `backend "s3" {}` permanently. Backend values are never hardcoded in the repository.

**Local init (after bootstrap):**

```bash
cd connect-pbx/modules/l0-account-baseline
terraform init -backend-config=../bootstrap/backend-<profile>.hcl \
               -backend-config="key=dev/modules/l0-account-baseline/terraform.tfstate"
terraform workspace select dev
terraform plan -var-file="../../environments/dev.tfvars"
```

The `backend-<profile>.hcl` file is generated by `bootstrap.sh` and lives in `modules/bootstrap/`. It supplies the bucket name, KMS key ARN, lock table name, and region — values shared by all modules. Only the `key` (state path) differs per module and is overridden inline.

**CI/CD:** The `-backend-config` flags are injected automatically by the GitHub Actions workflows via GitHub Actions secrets. See `DEPLOY-00-bootstrapping-guide.md` for the full backend configuration pattern.

### Key Resources Declared

```hcl
# kms.tf

resource "aws_kms_key" "env" {
  for_each = toset([terraform.workspace])

  description             = "Platform encryption key — ${each.key} environment"
  key_usage               = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = var.deployment_profile.cross_region

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "TerraformExecutionAccess"
        Effect = "Allow"
        Principal = {
          AWS = data.terraform_remote_state.bootstrap.outputs.terraform_execution_role_arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:ReEncrypt*",
          "kms:CreateGrant"
        ]
        Resource = "*"
      },
      {
        Sid    = "AWSServiceAccess"
        Effect = "Allow"
        Principal = {
          Service = [
            "config.amazonaws.com",
            "connect.amazonaws.com",
            "lambda.amazonaws.com",
            "s3.amazonaws.com",
            "dynamodb.amazonaws.com",
            "sns.amazonaws.com",
            "sqs.amazonaws.com",
            "events.amazonaws.com",
            "transcribe.amazonaws.com",
            "lex.amazonaws.com"
          ]
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "CloudTrailAccess"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  })

  tags = {
    Environment = each.key
    Layer       = "L0"
    PRD         = "PRD-02"
  }
}

resource "aws_kms_alias" "env" {
  for_each = toset([terraform.workspace])

  name          = "alias/${var.org_name}-${each.key}"
  target_key_id = aws_kms_key.env[each.key].key_id
}

# iam.tf

resource "aws_iam_policy" "platform_boundary" {
  name        = "${var.org_name}-platform-boundary"
  description = "Permission boundary applied to all platform Lambda and service roles. Prevents privilege escalation."

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
          "sns:Publish",
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "transcribe:StartTranscriptionJob",
          "transcribe:GetTranscriptionJob",
          "lex:RecognizeText",
          "ses:SendEmail",
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
        Sid    = "DenyKMSKeyDeletion"
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

# iam-connect.tf

resource "aws_iam_service_linked_role" "connect" {
  aws_service_name = "connect.amazonaws.com"
  description      = "Service-linked role for Amazon Connect"

  lifecycle {
    ignore_changes        = [aws_service_name]
    create_before_destroy = false
  }
}

# scps.tf — SCP definitions, conditionally created

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
        Sid    = "DenyNonApprovedRegions"
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
  count = local.scps_enabled ? 1 : 0

  name        = "${var.org_name}-deny-cloudtrail-disable"
  description = "Prevents disabling or deleting CloudTrail trails"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyCloudTrailDisable"
        Effect   = "Deny"
        Action   = [
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
            "aws:ResourceTag/Project" = "connect-pbx"
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
        Action   = "*"
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
```

### Variables

```hcl
# variables.tf

variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "aws_region" {
  type        = string
  description = "Primary AWS deployment region."
  default     = "us-east-1"
}

variable "approved_regions" {
  type        = list(string)
  description = "List of AWS regions approved for resource deployment. Used in permission boundary and SCPs."
  default     = ["us-east-1"]
}

variable "state_bucket" {
  type        = string
  description = "S3 state bucket name from PRD-00. Injected at runtime via GitHub Actions secret."
}

variable "terraform_execution_role_arn" {
  type        = string
  description = "Terraform execution role ARN from PRD-00. Injected at runtime via GitHub Actions secret."
}

variable "layer_id" {
  type    = string
  default = "L0"
}

variable "prd_id" {
  type    = string
  default = "PRD-02"
}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. Inherited from PRD-00 authoritative definition."
  type = object({
    mode             = string
    instance_count   = number
    multi_az         = bool
    cross_region     = bool
    agent_capacity   = string
    account_topology = string
    hub_account_id   = string
    org_id           = string
    shared_bus_arn   = string
    optional_layers = object({
      sso_enabled        = bool
      crm_enabled        = bool
      compliance_enabled = bool
    })
  })
  default = {
    mode             = "single"
    instance_count   = 1
    multi_az         = false
    cross_region     = false
    agent_capacity   = "small"
    account_topology = "standalone"
    hub_account_id   = ""
    org_id           = ""
    shared_bus_arn   = ""
    optional_layers = {
      sso_enabled        = false
      crm_enabled        = false
      compliance_enabled = false
    }
  }
}
```

### Outputs

```hcl
# outputs.tf

output "kms_key_arn_dev" {
  description = "KMS key ARN for dev environment. Used in all dev workspace resource encryption and backend config."
  value       = aws_kms_key.env["dev"].arn
}

output "kms_key_arn_staging" {
  description = "KMS key ARN for staging environment."
  value       = aws_kms_key.env["staging"].arn
}

output "kms_key_arn_prod" {
  description = "KMS key ARN for prod environment."
  value       = aws_kms_key.env["prod"].arn
  sensitive   = true
}

output "kms_key_alias_dev" {
  description = "KMS key alias for dev environment."
  value       = aws_kms_alias.env["dev"].name
}

output "kms_key_alias_staging" {
  description = "KMS key alias for staging environment."
  value       = aws_kms_alias.env["staging"].name
}

output "kms_key_alias_prod" {
  description = "KMS key alias for prod environment."
  value       = aws_kms_alias.env["prod"].name
}

output "permission_boundary_arn" {
  description = "IAM permission boundary managed policy ARN. Applied to all Lambda execution roles and service roles in downstream PRDs."
  value       = aws_iam_policy.platform_boundary.arn
}

output "access_analyzer_arn" {
  description = "IAM Access Analyzer ARN. Referenced by PRD-03 for finding aggregation."
  value       = aws_accessanalyzer_analyzer.account.arn
}

output "connect_service_linked_role_arn" {
  description = "Amazon Connect service-linked role ARN. Referenced by PRD-10."
  value       = aws_iam_service_linked_role.connect.arn
}
```

### Backend Configuration

```hcl
# backend.tf — follows standard template from PRD-01
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = ""
    key            = "dev/l0-account-baseline/terraform.tfstate"
    region         = ""
    encrypt        = true
    kms_key_id     = ""
    dynamodb_table = ""
  }
}
```

### Environment Toggle Behavior

| Profile Setting | Behavior |
|---|---|
| `account_topology = "standalone"` (default) | SCP resources are not created. KMS keys, IAM boundary, Access Analyzer all created normally. |
| `account_topology = "spoke"` or `"hub"` | SCP resources are created and ready for attachment in PRD-110. |
| `deployment_profile.cross_region = true` | KMS keys are created as multi-region keys to support PRD-122 (Multi-Region Failover). |

### Post-Apply Required Action

After PRD-02 is applied, the platform engineer must update three GitHub Actions environment secrets before any other PRD can be applied:

| Environment | Secret | Value Source |
|---|---|---|
| dev | `ENV_KMS_KEY_ARN` | `terraform output kms_key_arn_dev` |
| staging | `ENV_KMS_KEY_ARN` | `terraform output kms_key_arn_staging` |
| prod | `ENV_KMS_KEY_ARN` | `terraform output kms_key_arn_prod` |

This is the critical sequencing gate between PRD-02 and all subsequent PRDs. It is documented in the acceptance criteria (AC-02-12).

---

## 10. EVENT SCHEMA

**PRD-02 produces no EventBridge events and consumes no EventBridge events.**

IAM Access Analyzer findings are recorded in CloudTrail and surfaced in the AWS console. They are not routed through EventBridge in this PRD — EventBridge integration for Access Analyzer findings is established in PRD-03.

---

## 11. API / INTERFACE CONTRACT

PRD-02 exposes no HTTP APIs. Its contract is exclusively Terraform outputs consumed via remote state.

### Standard Downstream Consumption Pattern

All downstream PRDs that need the environment KMS key use this pattern:

```hcl
# Standard remote state reference for PRD-03 through PRD-142
data "terraform_remote_state" "account_baseline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  # Resolves correct KMS key for the current workspace automatically
  env_kms_key_arn = {
    dev     = data.terraform_remote_state.account_baseline.outputs.kms_key_arn_dev
    staging = data.terraform_remote_state.account_baseline.outputs.kms_key_arn_staging
    prod    = data.terraform_remote_state.account_baseline.outputs.kms_key_arn_prod
  }[terraform.workspace]

  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
}
```

---

## 12. DATA MODEL

PRD-02 provisions no application data stores. Its data model is exclusively the Terraform state file.

### State File Location

```
s3://{org}-tfstate-{account_id}/
└── {workspace}/
    └── l0-account-baseline/
        └── terraform.tfstate
```

Note: This module is applied once and its state file exists in all three workspaces (dev, staging, prod) because it is applied per-environment. However, the KMS keys provisioned are not environment-specific resources — they are account-level resources shared across the account. The workspace distinction here is used for state organization only. The three KMS keys (dev, staging, prod) are all created in a single apply regardless of which workspace is active.

### KMS Key Inventory

| Key Alias | Environment | Rotation | Deletion Window | Multi-Region |
|---|---|---|---|---|
| `alias/{org}-dev` | dev | Annual | 30 days | `cross_region` toggle |
| `alias/{org}-staging` | staging | Annual | 30 days | `cross_region` toggle |
| `alias/{org}-prod` | prod | Annual | 30 days | `cross_region` toggle |

### Retention

KMS keys must not be deleted while any resource encrypted with them exists. The 30-day deletion window provides a recovery period. The `deny-kms-key-deletion` SCP (when active) provides an organizational guardrail. ALARM-02-01 (below) provides monitoring.

---

## 13. CI/CD SPECIFICATION

### Workflow Reference

```yaml
# ci.yml caller for PRD-02 — follows standard pattern from PRD-01
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l0-account-baseline

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l0-account-baseline
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l0-account-baseline
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules/l0-account-baseline-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Apply Sequencing Note

PRD-02 must be applied before any other PRD except PRD-00 and PRD-01. The dependency order in `modules/dependency-order.json` must place `modules/l0-account-baseline` as the first entry in Layer 0 after bootstrap.

### Post-Apply Manual Step

After PRD-02 apply completes, the platform engineer must manually update the `ENV_KMS_KEY_ARN` GitHub Actions environment secret for dev, staging, and prod before the pipeline can safely apply any subsequent PRD. This step cannot be automated because the KMS key ARNs are outputs of this apply and the GitHub Environments API requires authenticated access outside the Terraform execution role's scope.

### Rollback Procedure

PRD-02 resources must not be destroyed while any downstream resource exists. Rollback of KMS key changes must be approached with extreme caution:

1. KMS key policy changes can be rolled back by re-applying the previous Terraform plan
2. KMS key aliases can be re-pointed without destroying the key
3. KMS keys themselves must never be destroyed while downstream resources are encrypted with them
4. IAM boundary changes take effect immediately — rolling back a boundary change requires re-applying the previous policy version
5. Access Analyzer and password policy changes are non-destructive and can be freely rolled back

---

## 14. OBSERVABILITY SPECIFICATION

### CloudWatch Alarms

**ALARM-02-01: KMS Environment Key Pending Deletion**
- Source: CloudTrail event filter on `ScheduleKeyDeletion` for any of the three environment KMS key ARNs
- Action: SNS alert to platform engineer
- Severity: Critical — loss of an environment key makes all resources encrypted with it permanently unreadable

**ALARM-02-02: IAM Access Analyzer Finding — High Severity**
- Source: CloudTrail event `CreateFinding` from IAM Access Analyzer with `findingType = "ExternalAccess"`
- Action: SNS alert to platform engineer
- Severity: High — indicates a resource has been made publicly accessible or cross-account accessible unexpectedly

**ALARM-02-03: Root Account Login Detected**
- Source: CloudTrail event filter on `ConsoleLogin` with `userIdentity.type = Root`
- Action: SNS alert to platform engineer
- Severity: Critical — root account usage outside of documented break-glass scenarios indicates a security incident

### Log Retention

| Log | Location | Retention |
|---|---|---|
| KMS API events | CloudTrail (PRD-03) | Per PRD-03 policy |
| IAM Access Analyzer findings | AWS console + CloudTrail | Findings persist until archived |
| Password policy changes | CloudTrail (PRD-03) | Per PRD-03 policy |

### SOC 2 and PCI Evidence Artifacts

| Artifact | Demonstrates |
|---|---|
| `aws kms get-key-rotation-status` output for all three keys | PCI-DSS Req 3.6, SOC 2 CC6.7 |
| KMS key policy documents | PCI-DSS Req 7.1, SOC 2 CC6.1 |
| IAM permission boundary policy document | SOC 2 CC6.1 |
| `aws iam get-account-password-policy` output | PCI-DSS Req 8.3 |
| Access Analyzer finding history | SOC 2 CC6.3 |
| CloudTrail events for root account login | SOC 2 CC6.1, PCI-DSS Req 10.2 |

---

## 15. ACCEPTANCE CRITERIA

### Definition of Done

| ID | Criterion | Verification Method |
|---|---|---|
| AC-02-01 | Three KMS keys exist with correct aliases | `aws kms list-aliases` returns `alias/{org}-dev`, `alias/{org}-staging`, `alias/{org}-prod` |
| AC-02-02 | All three keys have rotation enabled | `aws kms get-key-rotation-status --key-id {arn}` returns `true` for each key |
| AC-02-03 | All three keys have 30-day deletion window | `aws kms describe-key` returns `PendingWindowInDays: 30` for each key |
| AC-02-04 | KMS key policy denies wildcard principal on any action | Key policy document reviewed — no `Principal: *` statements |
| AC-02-05 | Permission boundary policy exists | `aws iam get-policy` returns policy for `{org}-platform-boundary` |
| AC-02-06 | Permission boundary denies IAM privilege escalation | Attempt to create IAM role using boundary-constrained role — confirm denial |
| AC-02-07 | Permission boundary denies actions in non-approved regions | Attempt resource creation in non-approved region using boundary-constrained role — confirm denial |
| AC-02-08 | IAM Access Analyzer is active | `aws accessanalyzer list-analyzers` returns active analyzer of type `ACCOUNT` |
| AC-02-09 | Account password policy is PCI-DSS compliant | `aws iam get-account-password-policy` returns all required settings |
| AC-02-10 | Connect service-linked role exists | `aws iam get-role --role-name AWSServiceRoleForAmazonConnect` succeeds |
| AC-02-11 | SCP resources not created when topology is standalone | `terraform state list` contains no `aws_organizations_policy` resources when `account_topology = standalone` |
| AC-02-12 | GitHub Actions environment secrets updated with KMS key ARNs | All three environments have `ENV_KMS_KEY_ARN` set; PRD-03 plan runs successfully using the key |
| AC-02-13 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l0-account-baseline/` returns clean output |
| AC-02-14 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l0-account-baseline/` returns clean output |
| AC-02-15 | Multi-region KMS keys created when cross_region is true | Set `cross_region = true` in profile; confirm `aws kms describe-key` returns `MultiRegion: true` |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| KMS key deleted before downstream resources are migrated | Low | Critical | 30-day deletion window; ALARM-02-01; SCP deny when org is active (PRD-110) |
| Connect service-linked role already exists from manual account activity | Medium | Low | `lifecycle { ignore_changes = [aws_service_name] }` handles pre-existing role gracefully |
| Permission boundary too restrictive — blocks legitimate service action | Medium | High | Boundary tested against all downstream PRD service requirements before finalizing. Add actions iteratively. |
| Permission boundary too permissive — does not prevent escalation | Low | Critical | Boundary includes explicit deny on all IAM write actions. Tested via AC-02-06. |
| GitHub secret update step forgotten after PRD-02 apply | High early phases | High | AC-02-12 is a blocking acceptance criterion. PRD-03 plan will fail visibly if the secret is not updated. |
| KMS key alias naming collision if org_name contains special characters | Low | Medium | `org_name` variable validated by Terraform to contain only alphanumeric characters and hyphens. |
| Access Analyzer findings not actioned — alert fatigue | Medium | Medium | ALARM-02-02 routes to SNS. Findings reviewed weekly as part of the platform security operational cadence. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-02-01 | Should the three environment KMS keys be provisioned in a single workspace apply (current design) or in separate per-environment applies? Single apply is simpler. Per-environment applies provide stricter isolation but require the module to be applied three times. | Open | Current design provisions all three keys in one apply for simplicity. If stricter isolation is required, this can be refactored before PRD-02 is first applied. |
| OQ-02-02 | Should the permission boundary be environment-specific (three boundaries) or a single shared boundary across environments? | Open | Current design uses a single shared boundary for simplicity. Environment-specific boundaries would allow different permissions in dev vs prod. Recommend shared boundary initially; revisit at PRD-120. |
| OQ-02-03 | What is the complete list of approved AWS regions? Currently defaulting to us-east-1 only. | Open | Platform engineer to supply. Affects permission boundary deny and SCP deny-non-approved-regions. Required before prod apply. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release |
| 1.1.0 | 2026-03-21 | — | AMD-02-01: Add `CloudTrailAccess` KMS key policy statement — CloudTrail requires `aws:SourceAccount` condition, not `kms:CallerAccount`. AMD-02-02: Add `CloudWatchLogsAccess` KMS key policy statement with `kms:EncryptionContext:aws:logs:arn` condition — CloudWatch Logs requires region-scoped service principal and encryption context grant. AMD-02-03: Add `config.amazonaws.com` to `AWSServiceAccess` KMS statement — required by PRD-03 Config recorder. AMD-02-04: Remove `logs.amazonaws.com` from `AWSServiceAccess` — superseded by dedicated `CloudWatchLogsAccess` statement. AMD-02-05: Add `s3:GetBucketAcl` to permission boundary — required by Config delivery channel to verify S3 bucket access. |
| 1.2.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section with catalog entry, destroy posture, and control plane statement. |
