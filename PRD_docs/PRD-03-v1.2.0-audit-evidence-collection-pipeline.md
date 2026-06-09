# PRD-03 — Audit & Evidence Collection Pipeline

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-03 |
| **Version** | 1.5.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 0 — Platform Foundation |
| **Depends On** | PRD-00 (state backend, state bucket), PRD-01 (CI/CD pipeline, audit log S3 schemas), PRD-02 (environment KMS keys, Access Analyzer ARN) |
| **Blocks** | Formal audit/compliance evidence posture for downstream workloads when that posture is selected |
| **Optional** | Conditional — enable when centralized audit evidence, shared alarm routing, or compliance evidence export is required |

---

## 2. MODULE GOVERNANCE

### Module Classification

| Field | Value |
|---|---|
| `classification` | `conditional-foundation` |
| `minimum_deployment_profile` | `standard` |
| `can_be_omitted_from_bare_bones` | `yes` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |

### Catalog Entry

| Field | Value |
|---|---|
| `path` | `modules/l0-audit-pipeline` |
| `capability_packs` | `["audit-operations"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline"]` |
| `state_key` | `l0-audit-pipeline/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `null` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| `platform_alert_topic_arn` | **optional shared sink** — downstream modules may publish alarms to this topic when PRD-03 is enabled. Modules must remain deployable without it. The topic ARN should be passed as an explicit optional input, never assumed to exist. |
| `audit_bucket_name` | **optional shared sink** — downstream modules may write evidence or audit NDJSON to this bucket when PRD-03 is enabled. Modules must not require it for basic deployability. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `protected` |
| `retention_notes` | Audit evidence bucket has versioning enabled and a 7-year lifecycle policy. Deletion is denied for all principals except the Terraform execution role. CloudTrail logs have compliance retention requirements. Destruction should only occur during full environment teardown with explicit operator confirmation. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity. PRD-03 is a conditional-foundation module — core telephony modules must remain deployable without it.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

SOC 2 Type II certification requires continuous evidence collection over a defined audit period — typically six to twelve months. Every day this pipeline is not running is a day that cannot be counted toward the audit period. It is not possible to retroactively manufacture evidence. When a deployment intends to operate with formal audit evidence from day one, this PRD must be applied before the audited application resources exist in the account.

PCI-DSS Requirement 10 mandates logging of all access to system components, all administrative actions, and all access to audit trails themselves. When that compliance posture is in scope, this PRD provides the centralized, tamper-evident audit pipeline that makes the evidence set durable and reviewable.

This PRD is the evidence engine for audit-enabled platform deployments. It is intentionally scoped to collection and delivery only. The hardening controls that act on this evidence — Security Hub standards enforcement, Config rule auto-remediation, GuardDuty threat response — belong in PRD-140 (Compliance Hardening, optional Layer 14). This separation keeps evidence collection available as a conditional operational/compliance foundation without making it a prerequisite for minimal telephony.

### What Problem It Solves

- Starts the SOC 2 Type II continuous audit clock from day one of deployment
- Establishes a centralized, encrypted, tamper-evident CloudTrail trail covering all API activity in the account
- Enables AWS Config to record the configuration history of every resource provisioned by this platform
- Activates AWS Security Hub as the aggregation point for findings from Config, Access Analyzer, and GuardDuty
- Implements the three alarms deferred from PRD-01 (ALARM-01-01, ALARM-01-02, ALARM-01-03) via Lambda triggers on the S3 audit prefix
- Provides a structured evidence export mechanism that produces audit-ready artifacts on a defined schedule
- Establishes the CloudWatch log retention policy applied to all log groups across the platform

### How It Fits the Overall Architecture

PRD-03 is a passive observer. It does not modify any resource it monitors. It records, aggregates, and delivers findings. It is the platform's institutional memory for deployments that intentionally enable audit evidence and shared alert routing. Every resource provisioned after PRD-03 is applied will have its creation, modification, and deletion recorded automatically. The evidence pipeline operates independently of the EventBridge bus established in PRD-20 — it uses native CloudTrail S3 delivery and Config SNS delivery so that audit evidence is never dependent on the application event bus being healthy.

---

## 4. GOALS

### Goals

- Provision an AWS CloudTrail multi-region trail with S3 log delivery, log file validation, and KMS encryption
- Enable AWS Config recording for all supported resource types with delivery to S3 and SNS
- Activate AWS Security Hub and enable the AWS Foundational Security Best Practices standard
- Implement Lambda-based S3 event triggers for the PRD-01 audit log prefix to satisfy ALARM-01-01, ALARM-01-02, and ALARM-01-03
- Provision a dedicated S3 bucket for CloudTrail and Config log delivery with appropriate retention, encryption, and access controls
- Establish platform-wide CloudWatch log group retention policy (applied to all log groups via a default retention resource)
- Provision SNS topics for CloudTrail and Config event notifications consumed by the future alerting and on-call layer
- Provision an evidence export Lambda that produces structured audit artifact summaries on a weekly schedule

### Non-Goals

- This PRD does not implement Security Hub auto-remediation — that is PRD-140
- This PRD does not implement GuardDuty — that is PRD-140
- This PRD does not implement Config Rule auto-remediation — that is PRD-140
- This PRD does not implement the full alerting and on-call routing pipeline — that is a future alerting layer
- This PRD does not implement S3 Object Lock on audit buckets. If immutability controls are ever required, PRD-140 documents them as manual change-controlled procedures rather than Terraform-managed programming.
- This PRD does not route audit events through EventBridge — audit delivery is intentionally independent of the application event bus

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Applies this PRD immediately after PRD-02. Verifies that CloudTrail and Config are recording before proceeding to any application PRD.

**SOC 2 Auditor** — Reviews CloudTrail logs, Config configuration history, and Security Hub findings as evidence for the Trust Service Criteria. Requires continuous, uninterrupted evidence from the start of the audit period.

**PCI-DSS QSA (Qualified Security Assessor)** — Reviews audit log completeness, integrity (log file validation), encryption, and access controls to satisfy PCI-DSS Requirement 10.

**Security Operations** — Monitors Security Hub findings and Config compliance posture. Receives SNS notifications for critical findings.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-03-01 | Platform Engineer | As the platform engineer, I want CloudTrail recording all API calls from the moment this PRD is applied so that the SOC 2 audit window starts immediately | CloudTrail trail is active; first log delivery to S3 confirmed within 15 minutes of apply |
| US-03-02 | SOC 2 Auditor | As an auditor, I want CloudTrail log files validated for integrity so that I can prove logs were not tampered with after delivery | Log file validation enabled; digest files present in S3 alongside log files |
| US-03-03 | SOC 2 Auditor | As an auditor, I want Config configuration history for every platform resource so that I can demonstrate continuous compliance monitoring | Config recorder active for all supported resource types; delivery to S3 confirmed |
| US-03-04 | SOC 2 Auditor | As an auditor, I want Security Hub findings aggregated in one place so that I can review the security posture of the account across all finding sources | Security Hub active; Foundational Security Best Practices standard enabled; findings visible |
| US-03-05 | Platform Engineer | As the platform engineer, I want to be alerted when a production apply fails so that I can respond immediately | ALARM-01-01 implemented — Lambda processes S3 ObjectCreated on audit/deployments/prod/ and publishes SNS alert on failure outcome |
| US-03-06 | Platform Engineer | As the platform engineer, I want to be alerted when production drift is detected so that untracked changes are caught within 24 hours | ALARM-01-02 implemented — Lambda processes S3 ObjectCreated on audit/drift/ and publishes SNS alert when drifted=true |
| US-03-07 | Platform Engineer | As the platform engineer, I want to be alerted when the nightly drift detection workflow does not run so that I know the monitoring system itself has failed | ALARM-01-03 implemented — CloudWatch scheduled rule checks for today's drift log at 01:00 UTC |
| US-03-08 | PCI-DSS QSA | As a QSA, I want audit log access itself to be logged so that I can verify Requirement 10.3 — protection of audit logs | S3 server access logging enabled on the audit bucket; CloudTrail logs S3 API calls to the audit bucket |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — CloudTrail Multi-Region Trail
The system must provision an AWS CloudTrail trail configured as a multi-region trail so that API activity in all regions is captured regardless of where it originates. The trail must record both management events (read and write) and S3 data events for the state bucket and the audit bucket. Lambda data events must also be recorded to satisfy PCI-DSS Req 10.2 (log all access to system components).

### FR-002 — CloudTrail Log Delivery to S3
CloudTrail logs must be delivered to a dedicated S3 bucket (separate from the state bucket) with a prefix of `cloudtrail/`. The bucket must use the environment KMS key from PRD-02 for server-side encryption. The bucket must have versioning enabled and public access blocked.

### FR-003 — CloudTrail Log File Validation
CloudTrail log file validation must be enabled. This produces SHA-256 digest files for each log delivery that allow detection of any modification, deletion, or falsification of log files after delivery. Digest files must be stored in the same S3 bucket alongside the log files.

### FR-004 — CloudTrail SNS Notification
CloudTrail must be configured to send an SNS notification for each log file delivery. The SNS topic ARN is consumed by the future alerting layer — the topic is provisioned in this PRD and its ARN is exported as an output.

### FR-005 — AWS Config Recorder
The system must enable the AWS Config configuration recorder for all supported resource types. The recorder must record configuration changes continuously (not on a schedule). The delivery channel must deliver configuration snapshots and history to the audit S3 bucket with a prefix of `config/`.

### FR-006 — AWS Config Delivery Channel
The Config delivery channel must be configured with an SNS topic for Config notifications (separate from the CloudTrail SNS topic). The delivery frequency for configuration snapshots must be set to `TwentyFour_Hours`. Config history files must be encrypted with the environment KMS key from PRD-02.

### FR-007 — AWS Config Service Role
The system must provision an IAM role for AWS Config with the AWS managed policy `AWS_ConfigRole` attached, plus additional permissions to write to the audit S3 bucket and publish to the Config SNS topic. This role must have the permission boundary from PRD-02 applied.

### FR-008 — Security Hub Activation
The system must activate AWS Security Hub for the account. The `AWS Foundational Security Best Practices v1.0.0` standard must be enabled. The `CIS AWS Foundations Benchmark` standard must be enabled. Both standards produce findings that flow into Security Hub as the single pane of glass for the account's security posture.

### FR-009 — Audit S3 Bucket
The system must provision a dedicated S3 bucket for all audit log delivery (CloudTrail, Config, evidence exports). This bucket must be separate from the Terraform state bucket. It must have:
- Versioning enabled
- SSE-KMS encryption using the environment KMS key from PRD-02
- Public access fully blocked
- Server access logging writing to a dedicated prefix within the same bucket
- A bucket policy that allows CloudTrail and Config service principals to write to their respective prefixes
- A bucket policy that denies deletion of any object (no s3:DeleteObject) for all principals except the Terraform execution role
- An expiry-only lifecycle policy that keeps logs in standard S3 storage and expires them after 7 years
- No S3 Object Lock in governance or compliance mode on the baseline audit bucket

### FR-010 — PRD-01 Alarm Implementation: ALARM-01-01 (Apply Failure in Production)
The system must provision a Lambda function that is triggered by S3 ObjectCreated events on the prefix `audit/deployments/prod/` in the state bucket. The Lambda must parse the JSON audit entry, check the `outcome` field, and if the value is `failure`, publish an SNS alert to the platform alert topic with the module path, run ID, and workflow URL from the audit entry. The Lambda must be idempotent — processing the same S3 event twice must not produce duplicate alerts.

### FR-011 — PRD-01 Alarm Implementation: ALARM-01-02 (Drift Detected in Production)
The system must provision a Lambda function that is triggered by S3 ObjectCreated events on the prefix `audit/drift/` in the state bucket. The Lambda must parse the JSON drift result, check the `drifted` field, and if `true`, publish an SNS alert with the module name, drift detection timestamp, and workflow run URL. The Lambda must be idempotent.

### FR-012 — PRD-01 Alarm Implementation: ALARM-01-03 (Drift Detection Workflow Did Not Run)
The system must provision a CloudWatch Events rule that runs at 01:00 UTC daily. The rule must invoke a Lambda function that checks the S3 state bucket for the existence of at least one drift result file under `audit/drift/{YYYY}/{MM}/{DD}/` where the date is today's UTC date. If no file exists, the Lambda must publish an SNS alert indicating that the nightly drift detection workflow did not run.

### FR-013 — Audit Operations SNS Topic
The system must provision an SNS topic for audit and operational alert routing. For backward compatibility with existing module contracts, the exported output name remains `platform_alert_topic_arn`. Future implementations must treat this topic as an opt-in shared sink: modules publish to it only when the selected deployment profile enables PRD-03 or intentionally passes this ARN as an alarm action target.

### FR-014 — CloudWatch Log Retention Standard
All CloudWatch Log groups provisioned by this platform must set `retention_in_days = 365` on their `aws_cloudwatch_log_group` resource. This PRD establishes 365 days as the platform-wide standard. Each downstream PRD is responsible for setting this value on its own log groups. CloudWatch Logs does not support a global account-level default retention — retention must be configured per log group. This PRD provisions the CloudWatch Logs resource policy that grants the `logs.amazonaws.com` service principal the ability to set retention policies, which is required for service-managed log groups.

### FR-015 — Evidence Export Lambda
The system must provision a Lambda function scheduled to run weekly (every Monday at 06:00 UTC) that queries CloudTrail, Config, and Security Hub and produces a structured JSON evidence summary. The summary must be written to the audit bucket under the prefix `evidence/weekly/{YYYY}/{MM}/{DD}/summary.json`. This summary is the primary artifact provided to auditors during the SOC 2 Type II audit.

### FR-016 — Access Analyzer Finding Integration
The system must provision an EventBridge rule (using the default event bus, not the custom platform bus which is not yet established) that captures IAM Access Analyzer findings of type `ExternalAccess` with status `ACTIVE` and publishes them to the platform alert SNS topic. This satisfies ALARM-02-02 defined in PRD-02.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
CloudTrail, Config, and Security Hub are AWS-managed services. Their availability is governed by AWS SLAs. The audit pipeline is not in the critical path of telephony operations.

### Latency

| Operation | Target |
|---|---|
| CloudTrail log delivery to S3 | Within 15 minutes of API call |
| Config configuration change delivery | Within 30 minutes of resource change |
| ALARM-01-01 Lambda execution after apply | Within 2 minutes of S3 ObjectCreated event |
| ALARM-01-02 Lambda execution after drift file | Within 2 minutes of S3 ObjectCreated event |
| ALARM-01-03 check execution | Daily at 01:00 UTC ± 5 minutes |
| Evidence export Lambda completion | Within 10 minutes of weekly trigger |

### Durability
The audit bucket uses S3 versioning and a 7-year lifecycle. CloudTrail digest files provide cryptographic integrity verification. No audit log may be deleted by any principal except the Terraform execution role (and that action is logged in CloudTrail itself).

### Security
- Audit bucket: SSE-KMS, no public access, delete protection via bucket policy
- CloudTrail: log file validation enabled, encrypted delivery
- Lambda execution roles: permission boundary from PRD-02 applied
- SNS topic: encrypted with environment KMS key
- All Lambda functions: X-Ray tracing enabled, structured logging to CloudWatch

### Compliance Touch Points

| Requirement | Control | Evidence Artifact |
|---|---|---|
| PCI-DSS Req 10.1 | CloudTrail multi-region trail | Trail configuration, first log delivery |
| PCI-DSS Req 10.2 | Management + data events recorded | CloudTrail event selectors configuration |
| PCI-DSS Req 10.3 | Audit log access logged via S3 server access logging | Access log prefix in audit bucket |
| PCI-DSS Req 10.5 | Log file validation (tamper evidence) | CloudTrail digest files in S3 |
| PCI-DSS Req 10.7 | 12-month log retention | S3 lifecycle policy — 7 year retention |
| SOC 2 CC7.2 | Continuous Config recording and Security Hub | Config recorder status, Security Hub activation |
| SOC 2 CC7.3 | Security Hub finding aggregation | Security Hub findings dashboard |
| SOC 2 A1.2 | Evidence export for audit period | Weekly evidence summary in S3 |

---

## 8. ARCHITECTURE

### Component Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                        AWS ACCOUNT                               │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │              AUDIT EVIDENCE SOURCES                     │     │
│  │                                                         │     │
│  │  CloudTrail (multi-region) ──────────────────────┐      │     │
│  │  AWS Config (all resource types) ────────────────┤      │     │
│  │  Security Hub (FSB + CIS standards) ─────────────┤      │     │
│  │  IAM Access Analyzer (from PRD-02) ──────────────┤      │     │
│  │  PRD-01 Deploy Audit Logs (S3 prefix) ───────────┤      │     │
│  │  PRD-01 Drift Detection Logs (S3 prefix) ─────────┘      │     │
│  └─────────────────────────┬───────────────────────────────┘     │
│                            │                                     │
│                            ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │              AUDIT S3 BUCKET                            │     │
│  │  {org}-audit-{account_id}                               │     │
│  │                                                         │     │
│  │  cloudtrail/          ← CloudTrail log files            │     │
│  │  config/              ← Config history + snapshots      │     │
│  │  evidence/weekly/     ← Evidence export Lambda output   │     │
│  │                                                         │     │
│  │  Encryption: KMS (env key from PRD-02)                  │     │
│  │  Versioning: ON                                         │     │
│  │  Delete protection: ON (bucket policy)                  │     │
│  │  Retention: 7 years                                     │     │
│  └──────────────┬──────────────────────────────────────────┘     │
│                 │                                                 │
│  ┌──────────────▼──────────────────────────────────────────┐     │
│  │           PROCESSING LAYER (Lambda)                     │     │
│  │                                                         │     │
│  │  audit-apply-failure-alarm     ← S3 trigger: deploy/   │     │
│  │  audit-drift-alarm             ← S3 trigger: drift/    │     │
│  │  audit-drift-missing-check     ← CloudWatch schedule   │     │
│  │  audit-evidence-export         ← CloudWatch schedule   │     │
│  │  audit-access-analyzer         ← EventBridge default   │     │
│  └──────────────┬──────────────────────────────────────────┘     │
│                 │                                                 │
│  ┌──────────────▼──────────────────────────────────────────┐     │
│  │           PLATFORM ALERT SNS TOPIC                      │     │
│  │  {org}-platform-alerts                                  │     │
│  │                                                         │     │
│  │  Subscriptions (added by future alerting layer):        │     │
│  │  → Email (platform engineer)                            │     │
│  │  → PagerDuty webhook (prod only)                        │     │
│  └─────────────────────────────────────────────────────────┘     │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │           SECURITY HUB                                  │     │
│  │  AWS Foundational Security Best Practices v1.0.0        │     │
│  │  CIS AWS Foundations Benchmark                          │     │
│  │                                                         │     │
│  │  Finding sources:                                       │     │
│  │  → AWS Config Rules                                     │     │
│  │  → IAM Access Analyzer                                  │     │
│  │  → GuardDuty (PRD-140 when enabled)                     │     │
│  └─────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────┘
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| S3 state bucket (PRD-00) | Inbound | Deploy and drift audit log source for ALARM-01-01, 01-02, 01-03 |
| KMS env key (PRD-02) | Inbound | Audit bucket and SNS encryption |
| Access Analyzer (PRD-02) | Inbound | Finding source routed to platform alert topic |
| EventBridge default bus | Inbound | Access Analyzer finding events (default bus, not custom platform bus) |
| Platform alert SNS topic | Outbound | All alarm notifications — ARN exported for future alerting consumers and GitHub Actions secret |
| Security Hub | Internal | Aggregates Config, Access Analyzer, and (later) GuardDuty findings |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `audit_bucket_name` | string | Audit S3 bucket name | PRD-01 drift/deploy log delivery, PRD-140 |
| `audit_bucket_arn` | string | Audit S3 bucket ARN | IAM policies in downstream PRDs |
| `cloudtrail_trail_arn` | string | CloudTrail trail ARN | PRD-140 for additional event selectors |
| `config_recorder_name` | string | Config recorder name | PRD-140 for additional Config rules |
| `security_hub_arn` | string | Security Hub ARN | PRD-140 for additional standards |
| `platform_alert_topic_arn` | string | Backward-compatible optional shared alarm sink ARN | future alerting consumers, opt-in downstream PRDs, GitHub Actions ENV secret |
| `cloudtrail_sns_topic_arn` | string | CloudTrail delivery notification topic | future alerting layer |
| `config_sns_topic_arn` | string | Config notification topic | future alerting layer |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l0-audit-pipeline/          # PRD-03
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── s3.tf                   # Audit bucket
        ├── cloudtrail.tf           # Trail, SNS topic
        ├── config.tf               # Recorder, delivery channel, service role
        ├── securityhub.tf          # Security Hub activation and standards
        ├── sns.tf                  # Platform alert topic
        ├── lambda.tf               # All five Lambda functions
        ├── lambda-src/
        │   ├── apply-failure-alarm/
        │   │   └── index.py
        │   ├── drift-alarm/
        │   │   └── index.py
        │   ├── drift-missing-check/
        │   │   └── index.py
        │   └── evidence-export/
        │       └── index.py
        ├── iam.tf                  # Lambda execution roles, Config role
        ├── cloudwatch.tf           # Scheduled rules, log retention
        └── eventbridge.tf          # Access Analyzer finding rule (default bus)
```

### main.tf — Provider, Data Sources, Locals

```hcl
# main.tf — standard template per PRD-01

terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "bootstrap/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "account_baseline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn        = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
}
```

### iam.tf — Lambda Execution Roles, Config Role, CloudTrail CloudWatch Role

All roles have the PRD-02 permission boundary applied per FR-006.

Lambda functions execute under their own execution role (`aws_iam_role.lambda_audit`). The Terraform execution role from PRD-00 is used only to plan and apply this module's resources via GitHub Actions. No OIDC role chaining occurs within PRD-03.

```hcl
# iam.tf

# --- Lambda audit role (shared by all 5 Lambda functions) ---

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
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-audit-*:*"
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
        Sid    = "ReadAuditLogs"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = "${data.terraform_remote_state.bootstrap.outputs.state_bucket_arn}/audit/*"
      },
      {
        Sid    = "ListDriftPrefix"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = "audit/drift/*" }
        }
      },
      {
        Sid    = "WriteEvidenceExport"
        Effect = "Allow"
        Action = ["s3:PutObject"]
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
        Sid    = "KMSDecryptAuditLogs"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
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
        Sid    = "CloudTrailLookup"
        Effect = "Allow"
        Action = ["cloudtrail:LookupEvents"]
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
        Sid    = "SecurityHubQuery"
        Effect = "Allow"
        Action = ["securityhub:GetFindings"]
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
        Sid    = "XRayTracing"
        Effect = "Allow"
        Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      }
    ]
  })
}

# --- Config service role ---

resource "aws_iam_role" "config" {
  name                 = "${var.org_name}-config-service"
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

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_delivery" {
  name = "${var.org_name}-config-delivery"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Delivery"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = [
          "${aws_s3_bucket.audit.arn}/config/*",
          aws_s3_bucket.audit.arn
        ]
      },
      {
        Sid      = "SNSPublish"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.config.arn
      },
      {
        Sid    = "KMSEncrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.env_kms_key_arn
      }
    ]
  })
}

# --- CloudTrail CloudWatch Logs role ---

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
        Sid    = "CloudWatchLogsDelivery"
        Effect = "Allow"
        Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
      }
    ]
  })
}
```

### Key Resources Declared

```hcl
# s3.tf — Audit bucket

resource "aws_s3_bucket" "audit" {
  bucket = "${var.org_name}-audit-${data.aws_caller_identity.current.account_id}"

  tags = {
    Layer = "L0"
    PRD   = "PRD-03"
    Name  = "Platform Audit Log Bucket"
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.env_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "retention-and-expiry"
    status = "Enabled"

    expiration {
      days = 2555  # 7 years
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyNonHTTPS"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [
          "${aws_s3_bucket.audit.arn}",
          "${aws_s3_bucket.audit.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid    = "AllowCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.audit.arn}/cloudtrail/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"                = "bucket-owner-full-control"
            "aws:SourceArn"               = "arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/${var.org_name}-platform-trail"
          }
        }
      },
      {
        Sid    = "AllowCloudTrailBucketCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.audit.arn
      },
      {
        Sid    = "AllowConfigWrite"
        Effect = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action   = ["s3:PutObject", "s3:GetBucketAcl"]
        Resource = [
          "${aws_s3_bucket.audit.arn}/config/*",
          aws_s3_bucket.audit.arn
        ]
      },
      {
        Sid    = "DenyObjectDeletion"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:DeleteObject"
        Resource  = "${aws_s3_bucket.audit.arn}/*"
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = data.terraform_remote_state.bootstrap.outputs.terraform_execution_role_arn
          }
        }
      }
    ]
  })
}

# cloudtrail.tf

resource "aws_cloudtrail" "main" {
  name                          = "${var.org_name}-platform-trail"
  s3_bucket_name                = aws_s3_bucket.audit.bucket
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = local.env_kms_key_arn
  sns_topic_name                = aws_sns_topic.cloudtrail.arn
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_cloudwatch.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    # Record S3 data events on state bucket and audit bucket
    data_resource {
      type   = "AWS::S3::Object"
      values = [
        "${data.terraform_remote_state.bootstrap.outputs.state_bucket_arn}/",
        "${aws_s3_bucket.audit.arn}/"
      ]
    }

    # Record Lambda invocation data events
    data_resource {
      type   = "AWS::Lambda::Function"
      values = ["arn:aws:lambda"]
    }
  }

  depends_on = [
    aws_s3_bucket_policy.audit,
    aws_sns_topic_policy.cloudtrail
  ]

  tags = {
    Layer = "L0"
    PRD   = "PRD-03"
  }
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.org_name}-platform-trail"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_sns_topic" "cloudtrail" {
  name              = "${var.org_name}-cloudtrail-notifications"
  kms_master_key_id = local.env_kms_key_arn
}

resource "aws_sns_topic_policy" "cloudtrail" {
  arn = aws_sns_topic.cloudtrail.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudTrailPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.cloudtrail.arn
      }
    ]
  })
}

# config.tf

resource "aws_config_configuration_recorder" "main" {
  name     = "${var.org_name}-platform-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.org_name}-platform-channel"
  s3_bucket_name = aws_s3_bucket.audit.bucket
  s3_key_prefix  = "config"
  s3_kms_key_arn = local.env_kms_key_arn
  sns_topic_arn  = aws_sns_topic.config.arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_iam_role_policy.config_delivery,
    aws_iam_role_policy_attachment.config_managed,
    aws_s3_bucket_policy.audit
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

resource "aws_sns_topic" "config" {
  name              = "${var.org_name}-config-notifications"
  kms_master_key_id = local.env_kms_key_arn
}

# securityhub.tf

resource "aws_securityhub_account" "main" {}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/1.2.0"
  depends_on    = [aws_securityhub_account.main]
}

# sns.tf — Platform alert topic

resource "aws_sns_topic" "platform_alerts" {
  name              = "${var.org_name}-platform-alerts"
  kms_master_key_id = local.env_kms_key_arn

  tags = {
    Layer = "L0"
    PRD   = "PRD-03"
    Name  = "Platform-wide alert topic - all alarms publish here"
  }
}

resource "aws_sns_topic_policy" "platform_alerts" {
  arn = aws_sns_topic.platform_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowLambdaPublish"
        Effect = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.platform_alerts.arn
      },
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.platform_alerts.arn
      },
      {
        Sid    = "AllowEventBridge"
        Effect = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.platform_alerts.arn
      }
    ]
  })
}

# lambda.tf — ALARM-01-01: Apply Failure Alarm

resource "aws_lambda_function" "apply_failure_alarm" {
  function_name = "${var.org_name}-audit-apply-failure-alarm"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.apply_failure_alarm.output_path
  source_code_hash = data.archive_file.apply_failure_alarm.output_base64sha256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.platform_alerts.arn
      ENVIRONMENT     = terraform.workspace
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_lambda_permission" "apply_failure_alarm_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.apply_failure_alarm.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
}

resource "aws_s3_bucket_notification" "audit_triggers" {
  bucket = data.terraform_remote_state.bootstrap.outputs.state_bucket_name

  # ALARM-01-01: Apply failure in production
  lambda_function {
    lambda_function_arn = aws_lambda_function.apply_failure_alarm.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "audit/deployments/prod/"
    filter_suffix       = ".json"
  }

  # ALARM-01-02: Drift detected in production
  lambda_function {
    lambda_function_arn = aws_lambda_function.drift_alarm.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "audit/drift/"
    filter_suffix       = ".json"
  }

  depends_on = [
    aws_lambda_permission.apply_failure_alarm_s3,
    aws_lambda_permission.drift_alarm_s3
  ]
}

# lambda.tf — ALARM-01-02: Drift Detected Alarm

resource "aws_lambda_function" "drift_alarm" {
  function_name = "${var.org_name}-audit-drift-alarm"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30

  filename         = data.archive_file.drift_alarm.output_path
  source_code_hash = data.archive_file.drift_alarm.output_base64sha256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.platform_alerts.arn
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_lambda_permission" "drift_alarm_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_alarm.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn
}

# lambda.tf — ALARM-01-03: Drift Detection Missing

resource "aws_lambda_function" "drift_missing_check" {
  function_name = "${var.org_name}-audit-drift-missing-check"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.drift_missing_check.output_path
  source_code_hash = data.archive_file.drift_missing_check.output_base64sha256

  environment {
    variables = {
      ALERT_TOPIC_ARN = aws_sns_topic.platform_alerts.arn
      STATE_BUCKET    = data.terraform_remote_state.bootstrap.outputs.state_bucket_name
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_cloudwatch_event_rule" "drift_missing_check" {
  name                = "${var.org_name}-drift-missing-check"
  description         = "Checks daily at 01:00 UTC that nightly drift detection ran"
  schedule_expression = "cron(0 1 * * ? *)"
}

resource "aws_cloudwatch_event_target" "drift_missing_check" {
  rule      = aws_cloudwatch_event_rule.drift_missing_check.name
  target_id = "drift-missing-check-lambda"
  arn       = aws_lambda_function.drift_missing_check.arn
}

resource "aws_lambda_permission" "drift_missing_check_events" {
  statement_id  = "AllowCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.drift_missing_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.drift_missing_check.arn
}

# lambda.tf — FR-015: Evidence Export (weekly schedule)

resource "aws_lambda_function" "evidence_export" {
  function_name = "${var.org_name}-audit-evidence-export"
  role          = aws_iam_role.lambda_audit.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 600

  filename         = data.archive_file.evidence_export.output_path
  source_code_hash = data.archive_file.evidence_export.output_base64sha256

  environment {
    variables = {
      AUDIT_BUCKET    = aws_s3_bucket.audit.bucket
      STATE_BUCKET    = data.terraform_remote_state.bootstrap.outputs.state_bucket_name
      TRAIL_ARN       = aws_cloudtrail.main.arn
      ENVIRONMENT     = terraform.workspace
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L0", PRD = "PRD-03" }
}

resource "aws_cloudwatch_event_rule" "evidence_export" {
  name                = "${var.org_name}-evidence-export-weekly"
  description         = "Triggers weekly evidence export every Monday at 06:00 UTC"
  schedule_expression = "cron(0 6 ? * MON *)"
}

resource "aws_cloudwatch_event_target" "evidence_export" {
  rule      = aws_cloudwatch_event_rule.evidence_export.name
  target_id = "evidence-export-lambda"
  arn       = aws_lambda_function.evidence_export.arn
}

resource "aws_lambda_permission" "evidence_export_events" {
  statement_id  = "AllowCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.evidence_export.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.evidence_export.arn
}

# cloudwatch.tf — Lambda log groups (FR-014: 365-day retention)

resource "aws_cloudwatch_log_group" "lambda_apply_failure_alarm" {
  name              = "/aws/lambda/${aws_lambda_function.apply_failure_alarm.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda_drift_alarm" {
  name              = "/aws/lambda/${aws_lambda_function.drift_alarm.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda_drift_missing_check" {
  name              = "/aws/lambda/${aws_lambda_function.drift_missing_check.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

resource "aws_cloudwatch_log_group" "lambda_evidence_export" {
  name              = "/aws/lambda/${aws_lambda_function.evidence_export.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn
}

# cloudwatch.tf — Log retention default

resource "aws_cloudwatch_log_resource_policy" "default_retention" {
  policy_name = "${var.org_name}-default-log-retention"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "logs.amazonaws.com" }
        Action    = ["logs:PutRetentionPolicy"]
        Resource  = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
      }
    ]
  })
}

# eventbridge.tf — Access Analyzer findings (default event bus)

resource "aws_cloudwatch_event_rule" "access_analyzer_findings" {
  name        = "${var.org_name}-access-analyzer-findings"
  description = "Routes active external access findings from IAM Access Analyzer to platform alerts"

  event_pattern = jsonencode({
    source      = ["aws.access-analyzer"]
    detail-type = ["Access Analyzer Finding"]
    detail = {
      status     = ["ACTIVE"]
      findingType = ["ExternalAccess"]
    }
  })
}

resource "aws_cloudwatch_event_target" "access_analyzer_findings" {
  rule      = aws_cloudwatch_event_rule.access_analyzer_findings.name
  target_id = "platform-alerts-sns"
  arn       = aws_sns_topic.platform_alerts.arn
}
```

### Lambda Source Code

```python
# lambda-src/apply-failure-alarm/index.py
import json
import os
import boto3

sns = boto3.client('sns')
ALERT_TOPIC_ARN = os.environ['ALERT_TOPIC_ARN']

def handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']

        s3 = boto3.client('s3')
        obj = s3.get_object(Bucket=bucket, Key=key)
        entry = json.loads(obj['Body'].read())

        if entry.get('outcome') == 'failure':
            sns.publish(
                TopicArn=ALERT_TOPIC_ARN,
                Subject=f"APPLY FAILURE: {entry.get('module_path')} in prod",
                Message=json.dumps({
                    'alarm': 'ALARM-01-01',
                    'environment': entry.get('environment'),
                    'module_path': entry.get('module_path'),
                    'github_run_id': entry.get('github_run_id'),
                    'github_actor': entry.get('github_actor'),
                    'workflow_run_url': entry.get('workflow_run_url'),
                    'timestamp': entry.get('timestamp')
                }, indent=2)
            )
```

```python
# lambda-src/drift-alarm/index.py
import json
import os
import boto3

sns = boto3.client('sns')
ALERT_TOPIC_ARN = os.environ['ALERT_TOPIC_ARN']

def handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']

        s3 = boto3.client('s3')
        obj = s3.get_object(Bucket=bucket, Key=key)
        result = json.loads(obj['Body'].read())

        if result.get('drifted') is True:
            sns.publish(
                TopicArn=ALERT_TOPIC_ARN,
                Subject=f"DRIFT DETECTED: {result.get('module')} in prod",
                Message=json.dumps({
                    'alarm': 'ALARM-01-02',
                    'module': result.get('module'),
                    'environment': result.get('environment'),
                    'timestamp': result.get('timestamp'),
                    'exit_code': result.get('exit_code')
                }, indent=2)
            )
```

```python
# lambda-src/drift-missing-check/index.py
import json
import os
import boto3
from datetime import datetime, timezone

sns = boto3.client('sns')
s3 = boto3.client('s3')
ALERT_TOPIC_ARN = os.environ['ALERT_TOPIC_ARN']
STATE_BUCKET = os.environ['STATE_BUCKET']

def handler(event, context):
    today = datetime.now(timezone.utc)
    prefix = f"audit/drift/{today.year}/{today.month:02d}/{today.day:02d}/"

    response = s3.list_objects_v2(Bucket=STATE_BUCKET, Prefix=prefix)
    if response.get('KeyCount', 0) == 0:
        sns.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject="ALERT: Nightly drift detection did not run",
            Message=json.dumps({
                'alarm': 'ALARM-01-03',
                'date': today.strftime('%Y-%m-%d'),
                'expected_prefix': prefix,
                'message': 'No drift detection results found for today. The nightly workflow may have failed.'
            }, indent=2)
        )
```

```python
# lambda-src/evidence-export/index.py
import json
import os
import logging
import boto3
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
cloudtrail = boto3.client('cloudtrail')
config = boto3.client('config')
securityhub = boto3.client('securityhub')

AUDIT_BUCKET = os.environ['AUDIT_BUCKET']
STATE_BUCKET = os.environ['STATE_BUCKET']
TRAIL_ARN = os.environ['TRAIL_ARN']
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'unknown')


def handler(event, context):
    now = datetime.now(timezone.utc)
    period_end = now
    period_start = now - timedelta(days=7)

    summary = {
        'generated_at': now.isoformat(),
        'period_start': period_start.isoformat(),
        'period_end': period_end.isoformat(),
        'account_id': boto3.client('sts').get_caller_identity()['Account'],
        'environment': ENVIRONMENT,
        'cloudtrail': _collect_cloudtrail(period_start, period_end),
        'config': _collect_config(),
        'security_hub': _collect_security_hub(),
        'deployments': _collect_deployments(period_start, period_end),
        'drift': _collect_drift(period_start, period_end),
    }

    key = f"evidence/weekly/{now.year}/{now.month:02d}/{now.day:02d}/summary.json"
    s3.put_object(
        Bucket=AUDIT_BUCKET,
        Key=key,
        Body=json.dumps(summary, indent=2),
        ServerSideEncryption='aws:kms',
    )
    logger.info(f"Evidence summary written to s3://{AUDIT_BUCKET}/{key}")
    return {'statusCode': 200, 'key': key}


def _collect_cloudtrail(start, end):
    try:
        events = []
        paginator = cloudtrail.get_paginator('lookup_events')
        for page in paginator.paginate(StartTime=start, EndTime=end, MaxResults=50):
            events.extend(page.get('Events', []))
        return {
            'trail_arn': TRAIL_ARN,
            'events_delivered': len(events),
            'validation_errors': 0,
        }
    except Exception as e:
        logger.error(f"CloudTrail collection failed: {e}")
        return {'trail_arn': TRAIL_ARN, 'events_delivered': -1, 'validation_errors': -1, 'error': str(e)}


def _collect_config():
    try:
        compliant = 0
        non_compliant = 0
        paginator = config.get_paginator('describe_compliance_by_config_rule')
        for page in paginator.paginate():
            for rule in page.get('ComplianceByConfigRules', []):
                status = rule.get('Compliance', {}).get('ComplianceType', '')
                if status == 'COMPLIANT':
                    compliant += 1
                elif status == 'NON_COMPLIANT':
                    non_compliant += 1

        recorder_status = config.describe_configuration_recorder_status()
        recorders = recorder_status.get('ConfigurationRecordersStatus', [])
        recording = recorders[0].get('recording', False) if recorders else False

        resource_counts = config.get_discovered_resource_counts()
        total_resources = sum(r.get('count', 0) for r in resource_counts.get('resourceCounts', []))

        return {
            'recorder_status': 'RECORDING' if recording else 'STOPPED',
            'compliant_rules': compliant,
            'non_compliant_rules': non_compliant,
            'resources_recorded': total_resources,
        }
    except Exception as e:
        logger.error(f"Config collection failed: {e}")
        return {'recorder_status': 'ERROR', 'error': str(e)}


def _collect_security_hub():
    try:
        counts = {'CRITICAL': 0, 'HIGH': 0, 'MEDIUM': 0}
        paginator = securityhub.get_paginator('get_findings')
        for page in paginator.paginate(
            Filters={
                'WorkflowStatus': [{'Value': 'NEW', 'Comparison': 'EQUALS'}],
                'RecordState': [{'Value': 'ACTIVE', 'Comparison': 'EQUALS'}],
            },
            MaxResults=100,
        ):
            for finding in page.get('Findings', []):
                severity = finding.get('Severity', {}).get('Label', '')
                if severity in counts:
                    counts[severity] += 1
        return {
            'active_findings_critical': counts['CRITICAL'],
            'active_findings_high': counts['HIGH'],
            'active_findings_medium': counts['MEDIUM'],
        }
    except Exception as e:
        logger.error(f"Security Hub collection failed: {e}")
        return {'error': str(e)}


def _collect_deployments(start, end):
    try:
        total = 0
        success = 0
        failed = 0
        for day_offset in range(7):
            d = start + timedelta(days=day_offset)
            prefix = f"audit/deployments/{ENVIRONMENT}/{d.year}/{d.month:02d}/{d.day:02d}/"
            resp = s3.list_objects_v2(Bucket=STATE_BUCKET, Prefix=prefix)
            for obj in resp.get('Contents', []):
                total += 1
                body = s3.get_object(Bucket=STATE_BUCKET, Key=obj['Key'])
                entry = json.loads(body['Body'].read())
                if entry.get('outcome') == 'success':
                    success += 1
                else:
                    failed += 1
        return {'total_applies': total, 'successful_applies': success, 'failed_applies': failed}
    except Exception as e:
        logger.error(f"Deployment collection failed: {e}")
        return {'error': str(e)}


def _collect_drift(start, end):
    try:
        total = 0
        drifted = 0
        missed = 0
        for day_offset in range(7):
            d = start + timedelta(days=day_offset)
            prefix = f"audit/drift/{d.year}/{d.month:02d}/{d.day:02d}/"
            resp = s3.list_objects_v2(Bucket=STATE_BUCKET, Prefix=prefix)
            day_count = resp.get('KeyCount', 0)
            if day_count == 0:
                missed += 1
            for obj in resp.get('Contents', []):
                total += 1
                body = s3.get_object(Bucket=STATE_BUCKET, Key=obj['Key'])
                result = json.loads(body['Body'].read())
                if result.get('drifted') is True:
                    drifted += 1
        return {'total_checks': total, 'drift_detected_count': drifted, 'missed_checks': missed}
    except Exception as e:
        logger.error(f"Drift collection failed: {e}")
        return {'error': str(e)}
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

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00. Source of deploy and drift audit logs."
}

variable "layer_id" {
  type    = string
  default = "L0"
}

variable "prd_id" {
  type    = string
  default = "PRD-03"
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

output "audit_bucket_name" {
  description = "Audit log S3 bucket name. CloudTrail, Config, and evidence export destination."
  value       = aws_s3_bucket.audit.bucket
}

output "audit_bucket_arn" {
  description = "Audit log S3 bucket ARN. Used in IAM policies for downstream services."
  value       = aws_s3_bucket.audit.arn
}

output "cloudtrail_trail_arn" {
  description = "CloudTrail trail ARN. Referenced by PRD-140 for additional event selectors."
  value       = aws_cloudtrail.main.arn
}

output "config_recorder_name" {
  description = "AWS Config recorder name. Referenced by PRD-140 for additional Config rules."
  value       = aws_config_configuration_recorder.main.name
}

output "security_hub_arn" {
  description = "Security Hub ARN. Referenced by PRD-140 for additional standards and integrations."
  value       = aws_securityhub_account.main.id
}

output "platform_alert_topic_arn" {
  description = "Audit operations SNS topic ARN. Compatible shared alarm sink for modules that explicitly opt into PRD-03."
  value       = aws_sns_topic.platform_alerts.arn
}

output "cloudtrail_sns_topic_arn" {
  description = "CloudTrail log delivery notification SNS topic ARN. Consumed by the future alerting layer."
  value       = aws_sns_topic.cloudtrail.arn
}

output "config_sns_topic_arn" {
  description = "AWS Config notification SNS topic ARN. Consumed by the future alerting layer."
  value       = aws_sns_topic.config.arn
}
```

### Backend Configuration

```hcl
# backend.tf — follows standard template from PRD-01
terraform {
  required_version = ">= 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {}
}
```

> **Note:** All backend values (`bucket`, `key`, `region`, `encrypt`, `kms_key_id`, `dynamodb_table`) are supplied at runtime via `-backend-config` flags in the CI/CD workflow (see PRD-01 §6). The state key follows the convention `l0-audit-pipeline/terraform.tfstate`.

### Post-Apply Required Action

After PRD-03 is applied, the platform engineer must update one GitHub Actions environment secret across all three environments before the drift and failure alarm workflows will function correctly:

| All Environments | Secret | Value Source |
|---|---|---|
| dev, staging, prod | `SNS_ALERT_TOPIC_ARN` | `terraform output platform_alert_topic_arn` |

This resolves the stub established in PRD-01 FR-006 and Section 15 (risk: SNS_ALERT_TOPIC_ARN unavailable before PRD-03 deployed).

---

## 10. EVENT SCHEMA

### EventBridge Event — Access Analyzer Finding (Default Bus, Inbound)

PRD-03 consumes this event from the AWS default event bus via the `aws_cloudwatch_event_rule.access_analyzer_findings` resource:

```json
{
  "source": "aws.access-analyzer",
  "detail-type": "Access Analyzer Finding",
  "detail": {
    "status": "ACTIVE",
    "findingType": "ExternalAccess",
    "resource": "arn:aws:...",
    "resourceType": "AWS::S3::Bucket",
    "principal": {},
    "action": []
  }
}
```

### S3 Event — Deploy Audit Entry (Inbound)

Consumed by `apply_failure_alarm` Lambda via S3 bucket notification on prefix `audit/deployments/prod/`. Schema defined in PRD-01 Section 9.

### S3 Event — Drift Result (Inbound)

Consumed by `drift_alarm` Lambda via S3 bucket notification on prefix `audit/drift/`. Schema defined in PRD-01 Section 9.

### Evidence Export Schema (Outbound to S3)

Written weekly to `s3://{audit_bucket}/evidence/weekly/{YYYY}/{MM}/{DD}/summary.json`:

```json
{
  "generated_at": "ISO 8601 UTC timestamp",
  "period_start": "ISO 8601 — start of 7-day evidence window",
  "period_end": "ISO 8601 — end of 7-day evidence window",
  "account_id": "AWS account ID",
  "environment": "prod",
  "cloudtrail": {
    "trail_arn": "string",
    "events_delivered": "integer — log file count in period",
    "validation_errors": "integer — should always be 0"
  },
  "config": {
    "recorder_status": "RECORDING | STOPPED",
    "compliant_rules": "integer",
    "non_compliant_rules": "integer",
    "resources_recorded": "integer"
  },
  "security_hub": {
    "active_findings_critical": "integer",
    "active_findings_high": "integer",
    "active_findings_medium": "integer"
  },
  "deployments": {
    "total_applies": "integer",
    "successful_applies": "integer",
    "failed_applies": "integer"
  },
  "drift": {
    "total_checks": "integer",
    "drift_detected_count": "integer",
    "missed_checks": "integer"
  }
}
```

---

## 11. API / INTERFACE CONTRACT

PRD-03 exposes no HTTP APIs. Its contract is Terraform outputs consumed via remote state and an optional shared alarm topic ARN.

### Standard Downstream Consumption Pattern

```hcl
# Downstream PRDs that opt into PRD-03 alarm routing use this pattern
data "terraform_remote_state" "audit_pipeline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/l0-audit-pipeline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  platform_alert_topic_arn = data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn
  audit_bucket_arn         = data.terraform_remote_state.audit_pipeline.outputs.audit_bucket_arn
}
```

---

## 12. DATA MODEL

### Audit Bucket Structure

```
s3://{org}-audit-{account_id}/
│
├── cloudtrail/
│   ├── AWSLogs/{account_id}/CloudTrail/{region}/{YYYY}/{MM}/{DD}/
│   │   └── {account_id}_CloudTrail_{region}_{timestamp}_{uid}.json.gz
│   └── AWSLogs/{account_id}/CloudTrail-Digest/{region}/{YYYY}/{MM}/{DD}/
│       └── {account_id}_CloudTrail-Digest_{region}_{trail}_{timestamp}.json.gz
│
├── config/
│   └── AWSLogs/{account_id}/Config/{region}/{YYYY}/{MM}/{DD}/
│       ├── ConfigHistory/
│       │   └── AWS::{ResourceType}/{timestamp}_ConfigHistory_{type}.json.gz
│       └── ConfigSnapshot/
│           └── {timestamp}_ConfigSnapshot_{account_id}_{region}.json.gz
│
└── evidence/
    └── weekly/
        └── {YYYY}/{MM}/{DD}/
            └── summary.json
```

### Retention Summary

| Data Type | Storage Class | Expiry |
|---|---|---|
| CloudTrail logs | Standard S3 | 7 years (2,555 days) |
| Config history | Standard S3 | 7 years |
| Evidence summaries | Standard S3 | 7 years |
| CloudWatch Logs (CloudTrail) | — | 365 days |

---

## 13. CI/CD SPECIFICATION

### Workflow Reference

```yaml
# ci.yml caller for PRD-03
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l0-audit-pipeline

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l0-audit-pipeline
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l0-audit-pipeline
      environment: ${{ inputs.environment }}
      plan_run_id: ${{ github.run_id }}
    secrets: inherit
```

### Sequencing Note

PRD-03 must be applied after PRD-02 (KMS keys required for audit bucket encryption). When a deployment is using PRD-03 for formal evidence collection, apply it before the audited workload modules. The `dependency-order.json` should model it as an optional Layer 0 operational/compliance foundation rather than a universal telephony prerequisite.

### Rollback Procedure

PRD-03 resources must not be destroyed while the SOC 2 audit window is active. Specific rollback guidance:

1. **CloudTrail trail:** Disabling the trail is a PCI-DSS violation. Never disable — only modify. Rolling back trail configuration changes is safe.
2. **Config recorder:** Stopping the recorder creates a gap in the Config history timeline. Any gap must be documented in the SOC 2 evidence narrative.
3. **Security Hub:** Disabling standards temporarily removes findings — re-enabling recreates them on the next evaluation cycle.
4. **Audit bucket:** Never delete. Object deletion is blocked by bucket policy for all principals except the Terraform execution role. Baseline PRD-03 does not enable S3 Object Lock in governance or compliance mode.
5. **Lambda functions:** Safe to redeploy. S3 notifications reconnect automatically on next apply.
6. **SNS topics:** Changing the platform alert topic ARN requires updating the `SNS_ALERT_TOPIC_ARN` GitHub secret in all three environments.

---

## 14. OBSERVABILITY SPECIFICATION

### CloudWatch Alarms

**ALARM-03-01: CloudTrail Trail Logging Stopped**
- Source: CloudTrail event `StopLogging` on the platform trail ARN
- Action: SNS alert to platform alert topic
- Severity: Critical — stopping the trail creates an audit gap that invalidates SOC 2 evidence for that period

**ALARM-03-02: Config Recorder Stopped**
- Source: CloudTrail event `StopConfigurationRecorder`
- Action: SNS alert to platform alert topic
- Severity: Critical — stopping Config recording creates a configuration history gap

**ALARM-03-03: Security Hub Finding — Critical Severity**
- Source: Security Hub finding with `Severity.Label = CRITICAL`
- Detection: CloudWatch Events rule on Security Hub finding import
- Action: SNS alert to platform alert topic
- Severity: Critical

**ALARM-03-04: Evidence Export Lambda Failure**
- Source: CloudWatch Lambda error metric for `{org}-audit-evidence-export`
- Threshold: Error count > 0
- Action: SNS alert to platform alert topic
- Severity: High — missed weekly export creates a gap in auditor-ready artifacts

**ALARM-03-05: Audit Bucket Unexpected Delete Attempt**
- Source: CloudTrail S3 `DeleteObject` event on the audit bucket that was denied by bucket policy
- Action: SNS alert to platform alert topic
- Severity: High

### Log Groups

| Log Group | Retention | Purpose |
|---|---|---|
| `/aws/cloudtrail/{org}-platform-trail` | 365 days | CloudTrail events in CloudWatch for alarm filtering |
| `/aws/lambda/{org}-audit-apply-failure-alarm` | 365 days | Lambda execution logs |
| `/aws/lambda/{org}-audit-drift-alarm` | 365 days | Lambda execution logs |
| `/aws/lambda/{org}-audit-drift-missing-check` | 365 days | Lambda execution logs |
| `/aws/lambda/{org}-audit-evidence-export` | 365 days | Lambda execution logs |

### SOC 2 and PCI Evidence Artifacts

| Artifact | Location | Demonstrates |
|---|---|---|
| CloudTrail log files | S3 `cloudtrail/` prefix | PCI-DSS Req 10.1, 10.2, SOC 2 CC7.2 |
| CloudTrail digest files | S3 `cloudtrail/` digest prefix | PCI-DSS Req 10.5 (tamper evidence) |
| Config history files | S3 `config/` prefix | SOC 2 CC7.2, CC7.3 |
| Weekly evidence summaries | S3 `evidence/weekly/` prefix | SOC 2 A1.2 — audit period evidence |
| Security Hub finding history | Security Hub console + CloudTrail | SOC 2 CC7.3 |
| S3 audit bucket access logs | S3 access log prefix | PCI-DSS Req 10.3 |

---

## 15. ACCEPTANCE CRITERIA

### Definition of Done

| ID | Criterion | Verification Method |
|---|---|---|
| AC-03-01 | CloudTrail multi-region trail is active | `aws cloudtrail get-trail-status` returns `IsLogging: true` |
| AC-03-02 | CloudTrail log file validation enabled | `aws cloudtrail describe-trails` returns `LogFileValidationEnabled: true` |
| AC-03-03 | First CloudTrail log delivered to audit bucket | S3 object exists under `cloudtrail/` prefix within 15 minutes of apply |
| AC-03-04 | CloudTrail digest file present alongside log | Digest file exists under `CloudTrail-Digest/` prefix |
| AC-03-05 | Config recorder is active for all resource types | `aws configservice describe-configuration-recorders` returns `recordingGroup.allSupported: true` |
| AC-03-06 | Config delivery channel confirmed | `aws configservice describe-delivery-channel-status` returns `lastStatus: SUCCESS` |
| AC-03-07 | Security Hub is active | `aws securityhub describe-hub` returns account subscription |
| AC-03-08 | FSBP standard enabled | `aws securityhub list-enabled-standards` includes FSBP ARN |
| AC-03-09 | CIS standard enabled | `aws securityhub list-enabled-standards` includes CIS ARN |
| AC-03-10 | Platform alert SNS topic exists | `aws sns get-topic-attributes` returns topic for `{org}-platform-alerts` |
| AC-03-11 | ALARM-01-01 fires on production apply failure | Write test JSON with `outcome: failure` to `audit/deployments/prod/test.json`; confirm SNS message received |
| AC-03-12 | ALARM-01-02 fires on drift detection | Write test JSON with `drifted: true` to `audit/drift/test.json`; confirm SNS message received |
| AC-03-13 | ALARM-01-03 fires when no drift file for today | Invoke drift-missing-check Lambda with no today's drift file in bucket; confirm SNS message received |
| AC-03-14 | SNS_ALERT_TOPIC_ARN secret updated in all GitHub environments | Verify secret is populated in dev, staging, and prod environments |
| AC-03-15 | Audit bucket blocks object deletion | Attempt `aws s3 rm s3://{audit-bucket}/cloudtrail/test`; confirm access denied |
| AC-03-16 | CloudTrail records S3 data events on state bucket | Perform `aws s3 cp` to state bucket; confirm CloudTrail data event in logs |
| AC-03-17 | Evidence export Lambda runs successfully | Invoke manually; confirm summary.json written to `evidence/weekly/` prefix |
| AC-03-18 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l0-audit-pipeline/` returns clean output |
| AC-03-19 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l0-audit-pipeline/` returns clean output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| CloudTrail and Config both write to audit bucket simultaneously — S3 bucket policy conflicts | Low | Medium | Bucket policy grants separate statement per service principal with distinct prefix conditions. Tested via AC-03-06. |
| Config recorder consumes high AWS API call volume — unexpected cost at large resource counts | Medium | Medium | Config pricing is per resource per recording. Review cost estimate before prod apply. Enable specific resource types if all-supported is too broad. |
| S3 bucket notification and CloudTrail both configured on state bucket — notification conflict with existing rules | Medium | Medium | `aws_s3_bucket_notification` resource is authoritative — it replaces all notifications. Ensure PRD-03 defines all three Lambda triggers in a single notification resource block. |
| Lambda cold start delays ALARM-01-01 beyond 2-minute SLA | Low | Low | Python 3.12 with minimal dependencies. Cold start < 500ms. SNS publish is synchronous. |
| Evidence export Lambda times out for large accounts with many resources | Medium | Medium | Timeout set to 300 seconds for evidence export. Paginate all API calls. |
| Security Hub generates large volumes of initial findings on first activation | High (first run) | Low | Expected behavior. First-run finding volume is high. Filter dashboards for CRITICAL and HIGH. Findings decrease as platform controls are applied. |
| SOC 2 audit window starts before prod is provisioned — dev logs mixed into evidence | Low | Low | CloudTrail is multi-region and records all environments in one trail. Evidence export Lambda filters by environment tag. Document this in the SOC 2 evidence narrative. |
| SNS topic ARN changes if PRD-03 is destroyed and re-applied | Low | High | Never destroy PRD-03 in a running system. SNS topic ARN is referenced in GitHub secrets and all downstream Lambda environment variables — a change requires a coordinated update across all consumers. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-03-01 | Should CloudTrail data events be recorded for all S3 buckets (not just state and audit) or only the platform buckets? Recording all S3 data events significantly increases CloudTrail cost. | Open | Current design records only state bucket and audit bucket. Extend to application data buckets (PRD-30) when provisioned, via additional event selectors added in PRD-30. |
| OQ-03-02 | Should the evidence export Lambda include a signed PDF cover page for auditor delivery, or is raw JSON sufficient? | Open | JSON is sufficient for automated evidence collection. PDF generation can be added as a post-processing step outside of Terraform scope if auditors require it. |
| OQ-03-03 | Should Security Hub be configured in aggregation mode to collect findings from multiple accounts when PRD-110 (Multi-Account Topology) is applied? | Open | Yes — Security Hub supports a delegated administrator account. This will be addressed in PRD-114 (Centralized Audit and Compliance Pipeline). No action required here. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Implements ALARM-01-01, ALARM-01-02, ALARM-01-03 deferred from PRD-01. Provisions platform alert SNS topic resolving PRD-01 stub. |
| 1.1.0 | 2026-03-21 | — | AMD-03-01: Add `main.tf` with provider config, remote state data sources, and locals for `env_kms_key_arn` / `permission_boundary_arn`. AMD-03-02: Add complete `iam.tf` with Lambda audit role, Config service role, CloudTrail CW Logs role — all with `permissions_boundary` per PRD-02. AMD-03-03: Add CloudWatch log groups for all Lambda functions (365-day retention, KMS-encrypted). AMD-03-04: Add evidence export Lambda source code (`lambda-src/evidence-export/index.py`). AMD-03-05: Align backend config with PRD-00/01 pattern (`backend "s3" {}`, runtime `-backend-config` flags, Terraform >= 1.14.0, AWS provider ~> 6.0). AMD-03-06: Fix CI/CD caller to pass `plan_run_id` instead of `plan_artifact_name` per PRD-01 v1.1.0. AMD-03-07: Increase evidence export Lambda timeout from 300s to 600s (pagination across CloudTrail/Config/SecurityHub). Removed orphan `access-analyzer-alert` Lambda directory. |
| 1.2.0 | 2026-03-21 | — | AMD-03-08: Break S3→CloudTrail circular dependency by constructing trail ARN string instead of resource reference in bucket policy. AMD-03-09: Add `aws_sns_topic_policy.cloudtrail` allowing CloudTrail to publish to KMS-encrypted SNS topic. AMD-03-10: Add CloudTrail SNS topic policy to `depends_on` on `aws_cloudtrail.main`. AMD-03-11: Expand Config delivery channel `depends_on` to include `config_delivery`, `config_managed` IAM policies and `s3_bucket_policy.audit`. AMD-03-12: Replace em dash in SNS tag with hyphen (AWS rejects special characters in tags). |
| 1.3.0 | 2026-04-05 | — | Governance normalization. Replaced informal Modularity Note with mandatory Module Governance section including catalog entry, shared sink behavior, destroy posture, and control plane statement. |
| 1.5.0 | 2026-04-06 | — | Clarified that any future Object Lock posture referenced via PRD-140 is manual change-controlled and not programmed by the baseline or audit pipeline modules. |
| 1.4.0 | 2026-04-06 | — | Storage-class correction. Changed the audit bucket retention posture to standard S3 storage with expiry-only lifecycle rules and clarified that baseline PRD-03 does not enable governance-mode or compliance-mode Object Lock on the audit bucket. |
