# PRD-10 — Amazon Connect Instance & Configuration

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-10 |
| **Version** | 1.3.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-03-30 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-00 (state backend), PRD-01 (CI/CD), PRD-02 (KMS keys, Connect service-linked role, permission boundary), PRD-03 (audit pipeline, platform alert SNS topic) |
| **Blocks** | PRD-11, PRD-12, PRD-13, PRD-14, PRD-10a, PRD-50 through PRD-54, PRD-70 through PRD-73 |
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
| `path` | `modules/l1-connect-instance` |
| `capability_packs` | `["core-telephony"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline"]` |
| `state_key` | `l1-connect-instance/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `null` |
| `supports_destroy` | `false` |
| `supports_operator_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 platform alert topic | **optional input** — alarms publish to the platform alert topic only when `alarm_action_arns` is supplied. PRD-03 is not required for Connect instance provisioning. |
| PRD-03 audit bucket | **optional input** — audit logging targets are wired only when `audit_bucket_logging_target` is supplied. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `conditional` |
| `retention_notes` | Connect instance is retained by default. Terraform keeps `prevent_destroy` enabled unless an explicitly approved operator destroy run passes the temporary lifecycle override. Instance alias and identity management type remain immutable after creation, so this path should be used only for deliberate environment teardown or rebuild. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity. SSO/SAML identity management is activated by the PRD-120 capability pack in the deployment manifest, not by `deployment_profile.optional_layers.sso_enabled`.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

The Amazon Connect instance is the PBX core. Every telephony capability in this platform — inbound routing, outbound calling, IVR flows, agent workspaces, voicemail, and AI auto-attendant — exists as a configuration or integration on top of the Connect instance. Without the instance, there is no phone system.

This PRD provisions the Connect instance itself and its foundational configuration: identity management type, inbound and outbound call enablement, and the administrative security profile. It intentionally stops at the instance boundary. Data streaming to Kinesis is deferred to PRD-20 (EventBridge layer) — the stream has no consumer until that PRD is built, and Connect retains CTRs natively for 24 months. Storage associations (S3 for call recordings), contact flows, queues, hours of operation, and phone numbers are each provisioned by their own PRDs. This separation ensures each concern is independently deployable and testable.

### What Problem It Solves

- Provisions the Amazon Connect instance that replaces the on-premises and cloud PBX systems being consolidated
- Establishes the identity management model — native Connect identity management (`CONNECT_MANAGED`) by default, with a clean toggle to SAML federation when PRD-120 (AD/SSO Integration) is activated
- Enables both inbound and outbound calling at the instance level
- Provisions the administrative security profile used by the platform engineer during initial configuration
- Exports the Connect instance ID and ARN as the foundational outputs referenced by every subsequent telephony PRD

### How It Fits the Overall Architecture

The Connect instance sits at the base of Layer 1. Every other telephony PRD (PRD-11 through PRD-14, PRD-10a, PRD-50 through PRD-54) depends on the instance ID and ARN exported by this PRD. Contact flows are added in PRD-14, queues in PRD-13, phone numbers in PRD-11, and the production customer-audio storage cutover is owned by PRD-10a. The instance is intentionally provisioned without these dependencies so it can be applied and verified independently before the rest of Layer 1 is built on top of it.

### Identity Management Note

The Connect instance is provisioned with `CONNECT_MANAGED` identity management by default. This means user accounts are created and managed natively within the Connect console. When PRD-120 (SAML Identity Provider Configuration) is applied as part of optional Layer 12, the identity management type cannot be changed on an existing instance — a new instance must be created and all configuration migrated. This is a deliberate AWS limitation and is the primary reason PRD-120 must be planned before initial provisioning if SSO is a near-term requirement. The `identity_management_type` variable makes this decision explicit and auditable.

---

## 4. GOALS

### Goals

- Provision the Amazon Connect instance with the correct identity management type, inbound calling, and outbound calling configuration
- Configure the instance alias following the platform naming convention
- Provision the administrative security profile for initial platform configuration
- Export the instance ID and instance ARN as outputs consumed by all downstream telephony PRDs

### Non-Goals

- This PRD does not provision phone numbers — that is PRD-11
- This PRD does not configure hours of operation — that is PRD-12
- This PRD does not configure queues or routing profiles — that is PRD-13
- This PRD does not configure contact flows — that is PRD-14
- This PRD does not own the long-term S3 storage association for call recordings beyond the temporary placeholder — the canonical cutover is defined in PRD-10a
- This PRD does not configure Amazon Lex bot associations — that is PRD-72
- This PRD does not configure agent users or the agent hierarchy — that is PRD-50
- This PRD does not configure the Contact Control Panel — that is PRD-51
- This PRD does not configure SAML or SSO federation — that is PRD-120
- This PRD does not provision Kinesis Data Streams or CTR streaming — that is deferred to PRD-20 (EventBridge layer). Connect retains CTRs natively for 24 months; the Kinesis stream is only needed when PRD-20 is ready to consume it

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Applies this PRD as the first step in Layer 1. Verifies the instance is reachable via the Connect console URL before proceeding to PRD-11.

**Connect Administrator** — The operational persona who manages day-to-day Connect configuration. Initially the same person as the platform engineer. Uses the administrative security profile provisioned here to access the Connect console.

**SOC 2 Auditor** — Reviews the instance configuration for access control (security profiles), identity management settings, and data streaming configuration as evidence of system component controls.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-10-01 | Platform Engineer | As the platform engineer, I want the Connect instance provisioned via Terraform so that it is version-controlled, reproducible, and auditable | Instance exists, is active, and state file confirms Terraform management |
| US-10-02 | Platform Engineer | As the platform engineer, I want to access the Connect admin console immediately after apply so that I can verify the instance and begin testing | Instance URL accessible at `https://{alias}.my.connect.aws` |
| US-10-03 | Platform Engineer | As the platform engineer, I want the identity management type to be an explicit Terraform variable so that the SSO migration path is documented and planned | `identity_management_type` variable present with `CONNECT_MANAGED` default and clear documentation |
| US-10-04 | Connect Administrator | As the Connect administrator, I want an administrative security profile available so that I can access all Connect configuration during initial setup | Admin security profile exists in the Connect instance |
| US-10-05 | Platform Engineer | As the platform engineer, I want the Connect instance to be ready for Kinesis CTR streaming when PRD-20 is applied, without requiring instance recreation | Instance supports adding `aws_connect_instance_storage_config` for CTR streaming post-provisioning |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Connect Instance Provisioning
The system must provision a single Amazon Connect instance per deployment. The instance alias must follow the convention `{org_name}-{environment}`. The instance must be configured with inbound calls enabled and outbound calls enabled. Early media (ringback tone before answer) must be enabled. Auto-resolve best voices must be enabled to allow Connect to select the best available text-to-speech voice. Contact lens for speech analytics must be enabled at the instance level to allow per-queue configuration later. The Connect instance must keep a Terraform lifecycle guard enabled by default to prevent accidental deletion — the instance alias and identity management type are immutable after creation, and all downstream resources (phone numbers, queues, flows, agent assignments) are lost on instance deletion. A temporary operator-approved override may lift that guard only for a deliberate destroy run.

### FR-002 — Identity Management Type
The instance must be provisioned with an `identity_management_type` variable that accepts `CONNECT_MANAGED`, `SAML`, or `EXISTING_DIRECTORY`. The default must be `CONNECT_MANAGED`. When set to `SAML`, this variable signals that PRD-120 must be applied before the instance is provisioned — not after. A Terraform validation block must enforce that `SAML` and `EXISTING_DIRECTORY` values are only permitted when the PRD-120 SSO integration capability pack is enabled in the deployment manifest. The `identity_management_type` variable value is set in environment tfvars and validated at plan time; it is not gated by `deployment_profile`.

### FR-003 — Data Streaming (Deferred to PRD-20)
Kinesis Data Stream provisioning and the `aws_connect_instance_storage_config` for `CONTACT_TRACE_RECORDS` are deferred to PRD-20 (EventBridge layer). Connect retains CTRs natively for 24 months in its internal storage, queryable via the Connect API and console historical metrics. The Kinesis stream and storage association can be added to an existing Connect instance at any time without recreation — there is no technical reason to provision it before a consumer exists. This deferral eliminates ~$10.95/month idle cost per account (1 PROVISIONED shard).

### FR-004 — Administrative Security Profile
The system must provision a Connect security profile named `Platform-Admin` with all permissions enabled. This profile is used exclusively by the platform engineer during initial setup and integration testing. A second security profile named `Agent-Default` must be provisioned with standard agent permissions — this is the baseline profile assigned to agents provisioned in PRD-50.

### FR-005 — Connect Instance Storage Configuration Placeholder
The Connect instance requires at least one storage configuration to be fully functional. Since PRD-10a (Voicemail Solution) may not yet be applied, this PRD must provision a minimal placeholder S3 bucket for call recordings to satisfy the Connect instance dependency. This bucket is superseded by the production customer-audio architecture defined in PRD-10a. The placeholder bucket must follow the naming convention `{org_name}-connect-recordings-placeholder-{account_id}` and is tagged with `Superseded-By = PRD-10a` to make its temporary nature explicit. The placeholder bucket must enforce TLS-only access via a bucket policy that denies `s3:*` when `aws:SecureTransport = false`, consistent with all other S3 buckets in the platform. If PRD-03 is enabled, server access logging may write to the audit bucket. If PRD-03 is not enabled, the placeholder bucket remains deployable without that log-target dependency.

### FR-006 — CloudWatch Metrics Integration
The system must associate the Connect instance with CloudWatch to enable instance-level metrics. Connect publishes metrics to CloudWatch automatically when the instance is active. This PRD must provision the CloudWatch log group for Connect contact flow logs with a retention period of 365 days and encryption using the environment KMS key.

### FR-007 — Instance ID and ARN Export
The Connect instance ID and instance ARN must be exported as Terraform outputs. These outputs are the most widely consumed values in the entire platform — every downstream telephony PRD (PRD-11 through PRD-14, PRD-10a, PRD-50 through PRD-54, PRD-70 through PRD-73) references the instance ID.

### FR-008 — Identity Management Cross-Validation
A Terraform validation must enforce that `identity_management_type` values of `SAML` or `EXISTING_DIRECTORY` are only permitted when the PRD-120 SSO integration capability pack is enabled in the deployment manifest. The `identity_management_type` variable value is set in environment tfvars and validated at plan time; it is not gated by `deployment_profile`. The validation must be implemented as a `precondition` block on the Connect instance resource using `var.sso_integration_enabled`.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
Amazon Connect is a managed AWS service with a 99.99% availability SLA. The Connect instance spans multiple AWS Availability Zones automatically — no HA configuration is required at the instance level. Regional failover is addressed in PRD-122.

### Scale

| Deployment Profile | Agent Capacity | Connect Instance Limit |
|---|---|---|
| Default (small) | small | 500 queues, 500 routing profiles |
| Medium | medium | 500 queues, 500 routing profiles |
| Large | large | Service limit increase required above 500 agents |
| Enterprise | enterprise | Multiple instance strategy — PRD-121 |

Connect default service limits relevant to this platform:
- Concurrent active calls: 10 (default) — request limit increase to 500+ before prod
- Phone numbers per instance: 10 (default) — request limit increase per PRD-11 requirements
- Users per instance: 500 (default) — request limit increase for 100-500 agent deployments

### Security
- Connect instance traffic: encrypted in transit by AWS-managed TLS
- Call recordings: encrypted at rest in S3 using environment KMS key (placeholder bucket in this PRD, production implementation in PRD-10a)
- Contact trace records: retained natively by Connect for 24 months; Kinesis streaming added by PRD-20 when needed
- CloudWatch logs: encrypted using environment KMS key
- Administrative access: restricted to `Platform-Admin` security profile

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 2.2 | Connect instance configured to minimum required services only | Instance configuration — no unnecessary features enabled |
| PCI-DSS Req 8.1 | Administrative security profile with unique access | Security profile provisioned via Terraform; assigned to named users only |
| SOC 2 CC6.1 | Access to telephony system controlled via security profiles | Security profile configuration document |
| SOC 2 CC6.6 | Data in transit encrypted | Connect managed TLS — AWS responsibility |
| SOC 2 CC6.7 | Contact trace records encrypted at rest | Connect native CTR storage (AWS-managed encryption); Kinesis encryption added by PRD-20 |

---

## 8. ARCHITECTURE

### Component Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                    LAYER 1 — TELEPHONY CORE                      │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              AMAZON CONNECT INSTANCE                       │  │
│  │              {org_name}-{environment}                      │  │
│  │                                                            │  │
│  │  Identity Management: CONNECT_MANAGED (default)            │  │
│  │  Inbound Calls:       Enabled                             │  │
│  │  Outbound Calls:      Enabled                             │  │
│  │  Early Media:         Enabled                             │  │
│  │  Contact Lens:        Enabled                             │  │
│  │                                                            │  │
│  │  Security Profiles:                                        │  │
│  │  ├── Platform-Admin  (all permissions)                     │  │
│  │  └── Agent-Default   (standard agent permissions)         │  │
│  │                                                            │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │  Storage Associations                               │  │  │
│  │  │  CALL_RECORDINGS → Placeholder S3 (→ PRD-10a)       │  │  │
│  │  │  CTR streaming   → Deferred to PRD-20               │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └──────────────────────────────────────┬────────────────────┘  │
│                                         │                        │
│                              ┌──────────▼──────────┐             │
│                              │  CloudWatch Logs     │             │
│                              │  Contact Flow Logs   │             │
│                              │  365 day retention   │             │
│                              │  KMS encrypted       │             │
│                              └─────────────────────┘             │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

Downstream PRDs referencing instance_id and instance_arn:
PRD-11 (Phone Numbers) ──────────────────────────────────────────►
PRD-12 (Hours of Operation) ─────────────────────────────────────►
PRD-13 (Queue Architecture) ─────────────────────────────────────►
PRD-14 (Contact Flow Framework) ─────────────────────────────────►
PRD-20 (EventBridge — adds Kinesis CTR streaming) ───────────────►
PRD-10a (Voicemail + Customer-Audio Cutover) ────────────────────►
PRD-50 (Agent Hierarchy) ────────────────────────────────────────►
PRD-70 (Lex Bot Foundation) ─────────────────────────────────────►
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| KMS env key (PRD-02) | Inbound | CloudWatch log encryption, S3 placeholder bucket encryption |
| Connect service-linked role (PRD-02) | Inbound | Connect instance IAM dependency |
| Audit bucket (PRD-03) | Optional inbound | S3 access logging target for placeholder recordings bucket when audit/evidence services are enabled |
| Platform alert SNS topic (PRD-03) | Optional inbound | Shared CloudWatch alarm action target when `alarm_action_arns` explicitly includes it |
| CloudWatch Logs | Outbound | Contact flow execution logs |
| Placeholder S3 bucket | Outbound | Temporary call recording storage until PRD-10a cutover |
| PRD-20 (EventBridge layer) | Future inbound | Will add Kinesis CTR streaming to this instance |
| PRD-10a (Voicemail Solution) | Future inbound | Will supersede placeholder bucket via storage association update |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `connect_instance_id` | string | Connect instance ID (short UUID format) | PRD-11, 12, 13, 14, 10a, 20, 50, 51, 52, 53, 54, 70, 71, 72, 73 |
| `connect_instance_arn` | string | Connect instance ARN (full) | PRD-20, PRD-10a, IAM policies |
| `connect_instance_url` | string | Connect admin console URL | Operations runbooks |
| `admin_security_profile_id` | string | Platform-Admin security profile ID | PRD-50 (user provisioning) |
| `agent_security_profile_id` | string | Agent-Default security profile ID | PRD-50 (user provisioning) |
| `contact_flow_log_group_name` | string | CloudWatch log group for contact flow logs | PRD-14, future observability and cutover health checks |
| `placeholder_recordings_bucket` | string | Placeholder S3 bucket name — superseded by PRD-10a | PRD-10a (to update storage association) |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-connect-instance/        # PRD-10
        ├── main.tf                 # Terraform config, provider, remote state lookups, locals
        ├── variables.tf
        ├── outputs.tf
        ├── connect.tf              # Connect instance, security profiles
        ├── s3-placeholder.tf       # Temporary call recording bucket (superseded by PRD-10a)
        └── cloudwatch.tf           # Log group for contact flow logs, CloudWatch alarms
```

### Key Resources Declared

```hcl
# main.tf

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

  default_tags {
    tags = {
      Layer   = var.layer_id
      PRD     = var.prd_id
      Project = var.org_name
    }
  }
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "account_baseline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "audit_pipeline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/l0-audit-pipeline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
}

# connect.tf

resource "aws_connect_instance" "main" {
  identity_management_type = var.identity_management_type
  inbound_calls_enabled    = true
  outbound_calls_enabled   = true
  early_media_enabled      = true
  auto_resolve_best_voices_enabled    = true
  contact_flow_logs_enabled           = true
  contact_lens_enabled                = true
  multi_party_conference_enabled      = false  # Enable in PRD-54 when transfer service is configured

  instance_alias = "${var.org_name}-${terraform.workspace}"

  timeouts {
    create = "5m"
    delete = "5m"
  }

  lifecycle {
    prevent_destroy = true
  }

  # FR-008: Cross-validate identity management type against SSO capability pack
  precondition {
    condition     = var.identity_management_type == "CONNECT_MANAGED" || var.sso_integration_enabled
    error_message = "identity_management_type SAML or EXISTING_DIRECTORY requires PRD-120 SSO integration capability pack to be enabled in the deployment manifest (var.sso_integration_enabled = true). Enable the capability pack or use CONNECT_MANAGED."
  }

  # Note: aws_connect_instance does not support the tags argument.
  # Use aws_connect_instance tag-on-create via the default_tags provider block
  # or apply tags via a separate tagging mechanism.
}

resource "aws_connect_security_profile" "platform_admin" {
  instance_id = aws_connect_instance.main.id
  name        = "Platform-Admin"
  description = "Full administrative access for platform engineer. Assigned to named users only."

  permissions = [
    "BasicAgentAccess",
    "OutboundCallAccess",
    "VoiceCall",
    "VideoCall",
    "RealtimeContactLens",
    "ContactLens",
    "HistoricalReporting",
    "RealtimeReporting",
    "AgentStatusEdit",
    "AgentStatusView",
    "AgentHierarchyGroupView",
    "AgentHierarchyGroupEdit",
    "PhoneNumberView",
    "PhoneNumberEdit",
    "QueueEdit",
    "QueueView",
    "RoutingProfileEdit",
    "RoutingProfileView",
    "SecurityProfileEdit",
    "SecurityProfileView",
    "UserEdit",
    "UserView",
    "ContactFlowEdit",
    "ContactFlowView",
    "ContactFlowModuleEdit",
    "ContactFlowModuleView",
    "HoursOfOperationEdit",
    "HoursOfOperationView",
    "PromptEdit",
    "PromptView",
    "QuickConnectEdit",
    "QuickConnectView",
    "LexBotEdit",
    "LexBotView",
    "MetricsAccess"
  ]

  tags = { Layer = "L1", PRD = "PRD-10" }
}

resource "aws_connect_security_profile" "agent_default" {
  instance_id = aws_connect_instance.main.id
  name        = "Agent-Default"
  description = "Standard agent permissions. Assigned to all agents provisioned in PRD-50."

  permissions = [
    "BasicAgentAccess",
    "OutboundCallAccess",
    "VoiceCall",
    "RealtimeContactLens"
  ]

  tags = { Layer = "L1", PRD = "PRD-10" }
}

# Kinesis Data Stream and CTR storage association are deferred to PRD-20.
# Connect retains CTRs natively for 24 months. The stream can be added to
# an existing instance at any time via aws_connect_instance_storage_config.

# s3-placeholder.tf

resource "aws_s3_bucket" "recordings_placeholder" {
  bucket = "${var.org_name}-connect-recordings-placeholder-${data.aws_caller_identity.current.account_id}"

  tags = {
    Layer        = "L1"
    PRD          = "PRD-10"
    Superseded-By = "PRD-10a"
    Purpose      = "Temporary call recording bucket. PRD-10a provisions the production customer-audio architecture and updates this storage association."
  }
}

resource "aws_s3_bucket_versioning" "recordings_placeholder" {
  bucket = aws_s3_bucket.recordings_placeholder.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "recordings_placeholder" {
  bucket = aws_s3_bucket.recordings_placeholder.id

  rule {
    id     = "expire-placeholder-recordings"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    filter {}
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "recordings_placeholder" {
  bucket = aws_s3_bucket.recordings_placeholder.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.env_kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "recordings_placeholder" {
  bucket                  = aws_s3_bucket.recordings_placeholder.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "recordings_placeholder_tls" {
  bucket = aws_s3_bucket.recordings_placeholder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.recordings_placeholder.arn,
        "${aws_s3_bucket.recordings_placeholder.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket_logging" "recordings_placeholder" {
  bucket        = aws_s3_bucket.recordings_placeholder.id
  target_bucket = data.terraform_remote_state.audit_pipeline.outputs.audit_bucket_name
  target_prefix = "s3-access-logs/recordings-placeholder/"
}

resource "aws_connect_instance_storage_config" "call_recordings" {
  instance_id   = aws_connect_instance.main.id
  resource_type = "CALL_RECORDINGS"

  storage_config {
    s3_config {
      bucket_name   = aws_s3_bucket.recordings_placeholder.bucket
      bucket_prefix = "recordings"

      encryption_config {
        encryption_type = "KMS"
        key_id          = local.env_kms_key_arn
      }
    }
    storage_type = "S3"
  }
}

# cloudwatch.tf

resource "aws_cloudwatch_log_group" "contact_flow_logs" {
  name              = "/aws/connect/${aws_connect_instance.main.id}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = {
    Layer = "L1"
    PRD   = "PRD-10"
  }
}

resource "aws_cloudwatch_metric_alarm" "concurrent_call_breach" {
  alarm_name          = "${var.org_name}-connect-concurrent-call-breach-${terraform.workspace}"
  alarm_description   = "ALARM-10-01: Callers being rejected — concurrent call limit breached"
  namespace           = "AWS/Connect"
  metric_name         = "CallsBreachingConcurrencyQuota"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn]

  dimensions = {
    InstanceId = aws_connect_instance.main.id
    MetricGroup = "VoiceCalls"
  }

  tags = { Layer = "L1", PRD = "PRD-10" }
}

resource "aws_cloudwatch_metric_alarm" "contact_flow_fatal" {
  alarm_name          = "${var.org_name}-connect-flow-fatal-${terraform.workspace}"
  alarm_description   = "ALARM-10-02: Contact flow fatal error — callers experiencing broken flows"
  namespace           = "AWS/Connect"
  metric_name         = "ContactFlowFatalErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn]

  dimensions = {
    InstanceId = aws_connect_instance.main.id
    MetricGroup = "ContactFlow"
  }

  tags = { Layer = "L1", PRD = "PRD-10" }
}

resource "aws_cloudwatch_metric_alarm" "recording_upload_failure" {
  alarm_name          = "${var.org_name}-connect-recording-failure-${terraform.workspace}"
  alarm_description   = "ALARM-10-03: Call recording upload failure — compliance obligations at risk"
  namespace           = "AWS/Connect"
  metric_name         = "CallRecordingUploadError"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn]

  dimensions = {
    InstanceId = aws_connect_instance.main.id
    MetricGroup = "CallRecordings"
  }

  tags = { Layer = "L1", PRD = "PRD-10" }
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
  default     = "us-east-1"
}

variable "identity_management_type" {
  type        = string
  description = "Connect instance identity management type. CONNECT_MANAGED by default. Change to SAML only when PRD-120 is applied."
  default     = "CONNECT_MANAGED"

  validation {
    condition     = contains(["CONNECT_MANAGED", "SAML", "EXISTING_DIRECTORY"], var.identity_management_type)
    error_message = "identity_management_type must be CONNECT_MANAGED, SAML, or EXISTING_DIRECTORY."
  }
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "alarm_action_arns" {
  type        = list(string)
  description = "Optional alarm action ARNs for instance alarms. Leave empty to keep PRD-10 deployable without PRD-03 or another shared alerting sink."
  default     = []
}

variable "placeholder_access_log_bucket_name" {
  type        = string
  description = "Optional access-log target for the placeholder recordings bucket. Set when PRD-03 or another logging sink is intentionally enabled."
  default     = null
}

variable "sso_integration_enabled" {
  type        = bool
  description = "Set to true when the PRD-120 SSO integration capability pack is enabled in the deployment manifest. Gates SAML and EXISTING_DIRECTORY identity management types."
  default     = false
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-10"
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
  }
}
```

### Outputs

```hcl
# outputs.tf

output "connect_instance_id" {
  description = "Amazon Connect instance ID. Consumed by every downstream telephony PRD."
  value       = aws_connect_instance.main.id
}

output "connect_instance_arn" {
  description = "Amazon Connect instance ARN."
  value       = aws_connect_instance.main.arn
}

output "connect_instance_url" {
  description = "Connect admin console URL."
  value       = "https://${aws_connect_instance.main.instance_alias}.my.connect.aws"
}

output "admin_security_profile_id" {
  description = "Platform-Admin security profile ID. Consumed by PRD-50 for admin user provisioning."
  value       = aws_connect_security_profile.platform_admin.security_profile_id
}

output "agent_security_profile_id" {
  description = "Agent-Default security profile ID. Consumed by PRD-50 for agent provisioning."
  value       = aws_connect_security_profile.agent_default.security_profile_id
}

output "contact_flow_log_group_name" {
  description = "CloudWatch log group for Connect contact flow logs. Consumed by PRD-14 and future observability or cutover health checks."
  value       = aws_cloudwatch_log_group.contact_flow_logs.name
}

output "placeholder_recordings_bucket" {
  description = "Placeholder recording bucket name. PRD-10a updates this storage association to the production customer-audio architecture."
  value       = aws_s3_bucket.recordings_placeholder.bucket
}
```

### Backend Configuration

Backend configuration uses the partial backend config pattern established by PRD-00. The `backend "s3" {}` block is empty — all values (bucket, key, region, encrypt, kms_key_id, dynamodb_table) are supplied at `terraform init` time via `-backend-config` flags or a `backend-{profile}.hcl` file. This is defined in `main.tf` above — no separate `backend.tf` file is needed.

The state key follows the convention `{workspace}/l1-connect-instance/terraform.tfstate`, matching the downstream consumption pattern used by all dependent PRDs.

### Environment Toggle Behavior

| Profile Setting | Behavior |
|---|---|
| `sso_integration_enabled = true` | Validates that `identity_management_type != "CONNECT_MANAGED"`. Set in environment tfvars when PRD-120 capability pack is enabled in the deployment manifest. |
| `deployment_profile.instance_count > 1` | Reserved for PRD-121 (Multi-Instance). PRD-10 provisions one instance only. |
| `alarm_action_arns = []` | Instance alarms are still created, but no external SNS/PagerDuty-style sink is required |
| `placeholder_access_log_bucket_name = null` | Placeholder bucket deploys without cross-module access logging target |

Note: Kinesis shard sizing based on `agent_capacity` is deferred to PRD-20.

### Service Limit Increase Requirements

Before applying PRD-10 to a production environment expected to have 100-500 agents, the following AWS service limit increases must be requested via the AWS Support console:

| Limit | Default | Required | Request Before |
|---|---|---|---|
| Concurrent active calls per instance | 10 | 500+ | PRD-10 prod apply |
| Phone numbers per instance | 10 | Per PRD-11 requirements | PRD-11 prod apply |
| Users per instance | 500 | 500+ (if >500 agents) | PRD-50 prod apply |
| Queues per instance | 500 | Per PRD-13 design | PRD-13 prod apply |

---

## 10. EVENT SCHEMA

PRD-10 does not publish events. The Kinesis CTR streaming and event schema are defined in PRD-20 (EventBridge layer). Connect retains CTRs natively and they are queryable via the Connect API (`SearchContacts`, `GetContactAttributes`) and the Connect console historical metrics without requiring Kinesis.

---

## 11. API / INTERFACE CONTRACT

PRD-10 exposes no HTTP APIs. Its contract is Terraform outputs consumed by downstream PRDs via remote state.

### Standard Downstream Consumption Pattern

```hcl
# Pattern used in PRD-11 through PRD-14, PRD-50 through PRD-73
data "terraform_remote_state" "connect_instance" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "${terraform.workspace}/l1-connect-instance/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  connect_instance_id  = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  connect_instance_arn = data.terraform_remote_state.connect_instance.outputs.connect_instance_arn
}
```

---

## 12. DATA MODEL

### State File Location

```
s3://skyfuse-tfstate-{account_id}/
└── {workspace}/
    └── l1-connect-instance/
        └── terraform.tfstate
```

### Placeholder S3 Bucket

The placeholder recordings bucket created in FR-006 is a temporary resource. When PRD-10a is applied with the storage cutover enabled, it will adopt and update the `aws_connect_instance_storage_config.call_recordings` resource to point to the production recordings bucket. The placeholder bucket must be emptied and removed as part of the PRD-10a acceptance criteria after cutover verification. It must not be assumed to contain recordings in any operational procedure.

---

## 13. CI/CD SPECIFICATION

### Workflow Reference

```yaml
# ci.yml caller for PRD-10
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l1-connect-instance

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l1-connect-instance
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l1-connect-instance
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l1-connect-instance-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Apply Duration Note

The `aws_connect_instance` resource has a 5-minute creation timeout. GitHub Actions job timeout must be set to at least 15 minutes for this module to account for Connect provisioning time plus Terraform overhead.

### Rollback Procedure

The Connect instance cannot be modified once created for certain attributes (instance alias, identity management type). Rollback considerations:

1. **Instance alias:** Immutable after creation. Requires destroy and recreate. All downstream resources (phone numbers, queues, flows) must be recreated.
2. **Identity management type:** Immutable after creation. Same as alias — requires full destroy and recreate. This is why `identity_management_type` is an explicit variable with clear documentation.
3. **Security profile permissions:** Mutable. Safe to roll back via re-apply.
4. **Contact flow logs, Contact Lens:** Mutable. Safe to roll back.

**Never destroy the Connect instance in a production environment without a full migration plan.** All phone numbers, routing configurations, and agent assignments are lost on instance deletion.

---

## 14. OBSERVABILITY SPECIFICATION

### CloudWatch Metrics (Auto-Published by Connect)

| Metric | Namespace | Purpose |
|---|---|---|
| `CallsBreachingConcurrencyQuota` | `AWS/Connect` | Detect when concurrent call limit is being hit |
| `CallRecordingUploadError` | `AWS/Connect` | Detect recording upload failures |
| `ContactFlowErrors` | `AWS/Connect` | Detect contact flow execution failures |
| `ContactFlowFatalErrors` | `AWS/Connect` | Critical contact flow failures |
| `MissedCalls` | `AWS/Connect` | Calls not answered by any agent |

### Alarms (Terraform resources defined in `cloudwatch.tf`)

**ALARM-10-01: Concurrent Call Limit Breach**
- Metric: `CallsBreachingConcurrencyQuota` > 0
- Action: publish to `alarm_action_arns` when non-empty; otherwise alarm locally with no required external sink
- Severity: Critical — callers are being rejected at the instance level

**ALARM-10-02: Contact Flow Fatal Error**
- Metric: `ContactFlowFatalErrors` > 0 in 5 minutes
- Action: publish to `alarm_action_arns` when non-empty; otherwise alarm locally with no required external sink
- Severity: High — callers are experiencing broken call flows

**ALARM-10-03: Call Recording Upload Failure**
- Metric: `CallRecordingUploadError` > 0 in 15 minutes
- Action: publish to `alarm_action_arns` when non-empty; otherwise alarm locally with no required external sink
- Severity: High — PCI-DSS and SOC 2 call recording obligations may not be met

Note: Kinesis iterator age alarm (ALARM-10-04 in v1.1.0) is deferred to PRD-20 along with the Kinesis stream.

### Log Groups

| Log Group | Retention | Purpose |
|---|---|---|
| `/aws/connect/{instance_id}` | 365 days | Contact flow execution logs — all flow actions and errors |

### SOC 2 and PCI Evidence Artifacts

| Artifact | Demonstrates |
|---|---|
| Connect instance configuration (Terraform state) | SOC 2 CC6.1 — system component inventory |
| Security profile permission documents | SOC 2 CC6.1, PCI-DSS Req 8.1 — access control |
| CloudWatch contact flow logs | PCI-DSS Req 10.2 — system component access logging |

---

## 15. ACCEPTANCE CRITERIA

### Definition of Done

| ID | Criterion | Verification Method |
|---|---|---|
| AC-10-01 | Connect instance exists and is active | `aws connect list-instances` returns instance with status ACTIVE |
| AC-10-02 | Instance alias follows naming convention | Instance alias equals `{org_name}-{environment}` |
| AC-10-03 | Inbound and outbound calling enabled | `aws connect describe-instance` returns both enabled |
| AC-10-04 | Contact flow logs enabled | `aws connect describe-instance-attribute` for CONTACT_FLOW_LOGS returns ENABLED |
| AC-10-05 | Contact Lens enabled | `aws connect describe-instance-attribute` for CONTACT_LENS returns ENABLED |
| AC-10-06 | Admin console URL accessible | Browser navigation to instance URL returns Connect login page |
| AC-10-07 | Platform-Admin security profile exists | `aws connect list-security-profiles` returns Platform-Admin |
| AC-10-08 | Agent-Default security profile exists | `aws connect list-security-profiles` returns Agent-Default |
| AC-10-09 | Placeholder S3 bucket exists and is KMS encrypted | `aws s3api get-bucket-encryption` returns env KMS key |
| AC-10-10 | Call recording storage association points to placeholder bucket | `aws connect list-instance-storage-configs` returns S3 config for CALL_RECORDINGS |
| AC-10-11 | CloudWatch log group exists with 365-day retention | `aws logs describe-log-groups` returns group with retentionInDays: 365 |
| AC-10-12 | Contact flow log written after test call | Place a test call through the instance; confirm log entry in `/aws/connect/{instance_id}` |
| AC-10-13 | ALARM-10-01 through ALARM-10-03 are active | `aws cloudwatch describe-alarms` returns all three alarms in OK state |
| AC-10-14 | Placeholder S3 bucket enforces TLS-only access | `aws s3api get-bucket-policy` returns DenyNonTLS statement |
| AC-10-15 | Placeholder S3 bucket access logging behavior matches configuration | If `placeholder_access_log_bucket_name` is set, `aws s3api get-bucket-logging` returns that target; if unset, no cross-module log target is required |
| AC-10-16 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l1-connect-instance/` returns clean output |
| AC-10-17 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l1-connect-instance/` returns clean output |

---

## 16. COST ESTIMATION

### Idle Cost (No Active Calls)

| Resource | Monthly Cost | Notes |
|---|---|---|
| Amazon Connect instance | $0.00 | No instance fee — purely usage-based per-minute pricing |
| Contact Lens (enabled, no calls analyzed) | $0.00 | Per-minute charge only when analyzing calls ($0.015/min) |
| Placeholder S3 bucket (empty) | $0.00 | No storage = no charge |
| CloudWatch Log Group (empty, 365-day retention) | $0.00 | No ingestion = no charge |
| CloudWatch Alarms (3 standard metric alarms) | $0.30 | $0.10/alarm/month |
| **Total idle cost** | **~$0.30/month** | |

No new KMS keys are created by this PRD. All encryption uses the existing environment key (`alias/skyfuse-{workspace}`) from PRD-02. Kinesis costs (~$10.95/month/shard) are deferred to PRD-20.

---

## 17. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Connect instance alias already taken — alias is globally unique across AWS | Medium | High | Include org_name and environment in alias. If collision occurs, append a short suffix. Document the alias used in the operations runbook. |
| Identity management type chosen incorrectly — immutable after creation | Medium | Critical | `identity_management_type` is an explicit variable with validation. Document the SSO decision before first apply. OQ-10-01 flags this. |
| Concurrent call limit (default 10) hit in dev during testing | High | Medium | Request limit increase before load testing. Set ALARM-10-01 to alert at > 0 breaches. |
| Placeholder S3 bucket orphaned after PRD-10a cutover is applied | High | Low | PRD-10a acceptance criteria includes removing the placeholder bucket after cutover verification. Tagged with `Superseded-By = PRD-10a` for visibility. |
| Connect instance creation times out at 5 minutes in congested region | Low | Medium | Retry the apply. Connect provisioning is idempotent — a second apply after a timeout will detect the existing instance or complete provisioning. |
| Multi_party_conference_enabled set to false blocks warm transfer | Low | Medium | Warm transfer (PRD-53) does not require multi-party conference at the instance level. Enabled in PRD-54 when the full transfer service is configured. |

---

## 18. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-10-01 | Has the identity management type been decided for production? CONNECT_MANAGED is the default and means SSO cannot be added to this instance later — a new instance would be required. If SSO is planned within 12 months, PRD-120 should be designed before PRD-10 is applied to production. | Open | Platform engineer to decide before prod apply. Decision must be recorded in this PRD's revision history. |
| OQ-10-02 | Should Contact Lens (speech analytics and transcription) be enabled at the instance level? It is enabled by default in this PRD. There is a per-minute cost for Contact Lens analysis. For a large deployment this cost can be significant. | Open | Enabled by default. Can be disabled per-queue after provisioning. Full cost analysis recommended before prod apply. |

---

## 19. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Placeholder S3 bucket pattern established for later storage-association cutover, now consolidated under PRD-10a. Kinesis shard sizing table locked for reference by PRD-20. |
| 1.1.0 | 2026-03-21 | — | Gap review and hardening. Removed unused `connect-kinesis` IAM role. Fixed provider/terraform versions to match codebase. Replaced hardcoded backend with partial config pattern. Added FR-008 (identity management cross-validation), `prevent_destroy` lifecycle, S3 TLS enforcement, server access logging, CloudWatch alarms as Terraform resources. Fixed enterprise tier shard count, CI/CD artifact name separator. Added `main.tf` with remote state lookups, cost estimation section. |
| 1.2.0 | 2026-03-21 | — | **Deferred Kinesis to PRD-20.** Removed Kinesis Data Stream, CTR storage association, kinesis.tf, ALARM-10-04 (iterator age), Kinesis outputs, and FR-010 (KMS key policy for Kinesis). Connect retains CTRs natively for 24 months — the stream has no consumer until PRD-20 is built and can be added to an existing instance at any time. This eliminates ~$10.95/month idle cost per account. PRD-10 idle cost reduced from ~$11.38/month to ~$0.30/month. Renumbered FRs (FR-004 is now Administrative Security Profile, FR-005 is Storage Placeholder, etc.). |
| 1.2.1 | 2026-03-30 | — | Audit decoupling target-state normalization. Clarified that placeholder bucket access logging and alarm sinks are optional integration points, not mandatory PRD-03 dependencies for future implementations. |
| 1.3.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section. Moved SSO identity gate from deployment_profile.optional_layers to manifest/capability-pack control. |
