# PRD-31 — DynamoDB Table Design (Contact State, Agent State)

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-31 |
| **Version** | 1.5.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 3 — Storage & Data |
| **Module Classification** | conditional-foundation |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-00 (bootstrap state backend), PRD-02 (account baseline and environment KMS key) |
| **Blocks** | Downstream modules that explicitly opt into shared contact or agent state |
| **Optional Shared Sinks** | CloudWatch alarms; audit/evidence export, if enabled |
| **Destroy / Retention Posture** | protected / retained |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is only a runtime-shape input for scale, topology, and capacity; it is not the authority for whether this module exists in an environment.

### Module Classification

- `classification`: `conditional-foundation`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l3-dynamodb`
- `capability_packs`: `[]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline"]`
- `state_key`: `l3-dynamodb/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `dynamodb.tfvars`
- `supports_destroy`: `false`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated capability pack exists

### Shared Sink Behavior

- `optional_shared_sinks`: CloudWatch alarms; audit/evidence export
- `sink_behavior`: optional inputs only. They are not activation conditions and they are not provisioning dependencies for the table resources.

### Destroy / Retention Posture

- `destroy_posture`: `protected`
- `retention_notes`: this module owns shared state. The tables are intended to be retained unless a later migration or teardown plan explicitly handles state preservation and consumer cutover.

### Control Plane Statement

This PRD uses the repo's module catalog and deployment manifest as the feature-activation control plane. `deployment_profile` only describes runtime shape such as scale, topology, and capacity. It does not decide whether the module is enabled.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Some deployments need a shared contact and agent context plane. Others do not. Core telephony, lean migration, and narrowly scoped feature packs can operate without a shared DynamoDB state substrate, while richer CRM, observability, agent, and voicemail experiences may benefit from one.

This PRD provisions two shared state tables - Contact State and Agent State - for deployments that choose to centralize contact and agent context. These tables are not the mandatory memory of the whole platform; they are a conditional shared-state foundation. Whether the module is present in an environment is decided by the module catalog and deployment manifest.

### What Problem It Solves

- Provides the Contact State table — a record per contact ID storing the full lifecycle of each call: queue, agent, timestamps, voicemail location, transcription, CRM record ID, and contact attributes
- Provides the Agent State table — a record per agent tracking current status, queue assignment, and shift information
- Establishes the DynamoDB access pattern used by services that opt into shared contact or agent context
- Enables the CRM adapter (PRD-80) to look up contact context without calling the Connect API on every event
- Provides the data substrate for future contact analytics and observability dashboards

### How It Fits the Overall Architecture

PRD-31 sits beneath the modules that choose to share contact and agent context. The tables may be written by direct Lambda/service integrations, by event-driven consumers, or by administrative tools depending on the enabled deployment graph. They are never accessed directly by Connect or EventBridge, and `deployment_profile` is not used to decide whether the module exists.

---

## 4. GOALS

### Goals

- Provision the Contact State DynamoDB table with a schema that covers the full contact lifecycle
- Provision the Agent State DynamoDB table
- Enable point-in-time recovery (PITR) on both tables
- Configure TTL on the Contact State table to automatically expire records after 90 days
- Encrypt both tables with the environment KMS key from PRD-02
- Export table names and ARNs as module-owned outputs for downstream consumers that explicitly opt into shared state

### Non-Goals

- This PRD does not require DynamoDB Streams by default. When downstream integrations need streams, PRD-31 still owns the table-level stream configuration through explicit module inputs.
- This PRD does not implement Global Tables for multi-region — that is PRD-122
- This PRD does not define the access patterns of individual Lambda functions — those are in their respective PRDs
- This PRD does not implement the idempotency table from PRD-20 — that table is scoped to the CTR bridge and is provisioned there

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Provisions both tables and verifies they are accessible by Lambda functions with the correct tags.

**Service Developer** — Any Lambda function author that opts into shared state references the table names from PRD-31 outputs or catalog-derived remote-state wiring rather than hard-coding them.

**Operations Engineer** — Uses the Contact State table to look up the full history of a specific contact ID during incident investigation.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-31-01 | Platform Engineer | As the platform engineer, I want a Contact State table that tracks the full lifecycle of every contact so that downstream services that opt into shared state have a single source of truth | Table exists; seed record written on first lifecycle event; subsequent lifecycle-stage updates use versioned conditional writes |
| US-31-02 | Service Developer | As a service developer, I want table names exported from PRD-31 so that I never hard-code table names in Lambda environment variables | Table names available as Terraform outputs; shared-state consumers reference them via remote state or explicit module outputs |
| US-31-03 | Operations Engineer | As an operations engineer, I want to look up any contact by its ID and see the full record including queue, agent, voicemail, and CRM fields | `aws dynamodb get-item` by ContactId returns complete record |
| US-31-04 | Platform Engineer | As the platform engineer, I want records to expire after 90 days automatically so that the table does not grow unbounded | TTL configured on ExpiresAt attribute; records deleted automatically |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Contact State Table
Provision a DynamoDB table named `{org_name}-contact-state-{environment}` with the following schema:

**Primary Key:**
- Partition key: `ContactId` (String) — the Amazon Connect contact ID

**Attributes (written by various services throughout the contact lifecycle):**

| Attribute | Type | Written By | Description |
|---|---|---|---|
| `ContactId` | S | contact-lifecycle writer | Primary key |
| `Channel` | S | contact-lifecycle writer | VOICE / CHAT / TASK |
| `InitiationMethod` | S | contact-lifecycle writer | INBOUND / OUTBOUND / TRANSFER |
| `CustomerEndpoint` | S | contact-lifecycle writer | Caller E.164 number |
| `QueueName` | S | contact-lifecycle writer | Queue the contact was routed to |
| `QueueArn` | S | contact-lifecycle writer | Queue ARN |
| `AgentUsername` | S | contact-lifecycle writer | Agent who handled the contact |
| `InitiationTimestamp` | S | contact-lifecycle writer | ISO 8601 call start |
| `DisconnectTimestamp` | S | contact-lifecycle writer | ISO 8601 call end |
| `RecordingLocation` | S | contact-lifecycle writer | S3 URI of call recording |
| `VoicemailLocation` | S | PRD-60 | S3 URI of voicemail recording |
| `TranscriptionLocation` | S | PRD-61 | S3 URI of transcription JSON |
| `TranscriptionText` | S | PRD-61 | Optional short transcript excerpt only. Full transcript content remains authoritative in S3 at `TranscriptionLocation` |
| `CRMContactId` | S | PRD-81 | CRM system contact/ticket ID |
| `CRMRecordUrl` | S | PRD-81 | CRM record URL for agent screen pop |
| `ContactAttributes` | M | PRD-14 flows | Map of Connect contact attributes |
| `Status` | S | contact-lifecycle writer | INITIATED / QUEUED / CONNECTED / COMPLETED |
| `ExpiresAt` | N | contact-lifecycle writer | Unix timestamp TTL - 90 days after contact end |
| `CreatedAt` | S | contact-lifecycle writer | ISO 8601 record creation time |
| `UpdatedAt` | S | any writer | ISO 8601 last update time, informational only |
| `RecordVersion` | N | any writer | Monotonic optimistic-concurrency token used for compare-and-swap updates |

**Global Secondary Index (GSI-1):**
- Partition key: `AgentUsername` (String)
- Sort key: `InitiationTimestamp` (String)
- Purpose: Query all contacts handled by a specific agent, sorted by time

**GSI-2:**
- Partition key: `QueueName` (String)
- Sort key: `InitiationTimestamp` (String)
- Purpose: Query all contacts that passed through a specific queue

### FR-002 — Agent State Table
Provision a DynamoDB table named `{org_name}-agent-state-{environment}` with the following schema:

**Primary Key:**
- Partition key: `AgentUsername` (String)

**Attributes:**

| Attribute | Type | Written By | Description |
|---|---|---|---|
| `AgentUsername` | S | agent-state writer | Primary key - Connect username |
| `AgentArn` | S | agent-state writer | Connect agent ARN |
| `CurrentStatus` | S | agent-state writer | AVAILABLE / ON_CALL / AFTER_CALL_WORK / OFFLINE |
| `RoutingProfileId` | S | agent-state writer | Current routing profile ID |
| `RoutingProfileName` | S | agent-state writer | Current routing profile name |
| `CurrentContactId` | S | agent-state writer | Active contact ID if on call |
| `LastStatusChange` | S | agent-state writer | ISO 8601 last status change |
| `ShiftStart` | S | agent-state writer | ISO 8601 start of current shift |
| `UpdatedAt` | S | any writer | ISO 8601 last update, informational only |
| `RecordVersion` | N | any writer | Monotonic optimistic-concurrency token used for compare-and-swap updates |

No TTL on Agent State — records are updated in place and retained as long as the agent exists.

### FR-002A — Shared-State Writer Contract
Contact State and Agent State are shared tables with multiple potential writers. Implementation must follow these ownership rules:

- Initial record creation uses `PutItem` with `ConditionExpression = attribute_not_exists(...)` only for the primary key seed write.
- The seed write initializes `RecordVersion = 1`.
- All subsequent writes use targeted `UpdateExpression` operations that modify only writer-owned attributes.
- Every update must include `ConditionExpression = RecordVersion = :expected_version` and `SET RecordVersion = RecordVersion + :one`.
- Contact lifecycle writers own lifecycle fields such as queue, agent, timestamps, status, and `ExpiresAt`.
- Voicemail and transcription writers own only voicemail and transcription fields.
- CRM writers own only CRM linkage fields.
- Full-item replacement writes are not allowed after record creation.
- If the compare-and-swap condition fails, the writer must refetch the current record and retry or surface a conflict. Silent overwrite is not allowed.

### FR-003 — Point-in-Time Recovery
Both tables must have PITR enabled. This allows restoration to any point within the last 35 days — critical for recovering from accidental mass-delete operations or data corruption.

### FR-004 — Encryption
Both tables must be encrypted using the environment KMS key from PRD-02 (customer-managed key). AWS-managed keys are not acceptable — the CMK requirement is mandated by the PCI-DSS and SOC 2 compliance posture established in PRD-02.

### FR-005 — Billing Mode
Both tables must use `PAY_PER_REQUEST` billing mode. This provides automatic scaling to any throughput level without provisioned capacity planning — essential for a system that must scale from small to enterprise without code changes.

### FR-006 — DynamoDB Streams Ownership
The Contact State table is created with streams disabled by default, but stream configuration remains owned by PRD-31. When a downstream integration requires stream records, this module enables streams through explicit inputs such as `contact_state_stream_enabled` and `contact_state_stream_view_type`, then exports the resulting stream ARN for downstream consumers. Downstream PRDs may attach event source mappings, but they do not mutate the PRD-31-owned table resource directly.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
DynamoDB is a multi-AZ managed service with 99.999% (five nines) availability for global tables and 99.99% for regional tables. PAY_PER_REQUEST mode scales automatically — no capacity planning required.

### Latency
- Single-item reads (GetItem by ContactId): < 5ms P99
- GSI queries: < 10ms P99 at small scale, < 20ms P99 at enterprise scale

### Scale
PAY_PER_REQUEST handles any throughput. At enterprise scale (500 agents, 50,000+ calls/day), expect approximately 500,000–1,000,000 write units and 2,000,000–5,000,000 read units per day across both tables — well within DynamoDB's automatic scaling.

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 3.4 | Contact state encrypted with CMK | Table encryption configuration |
| PCI-DSS Req 3.5 | KMS key access restricted | Key policy from PRD-02 |
| SOC 2 CC6.7 | Encryption at rest | CMK encryption on both tables |
| SOC 2 A1.2 | Data durability and recovery | PITR enabled |

---

## 8. ARCHITECTURE

### Data Flow Diagram

```
Optional contact-lifecycle writers
      │ direct Lambda calls, event consumers, or operator tools
      ▼
Contact State Table: {org}-contact-state-{env}
      │
      ├── GSI-1: by AgentUsername + time
      ├── GSI-2: by QueueName + time
      │
      ├── optional downstream writers: VoicemailLocation
      ├── optional downstream writers: TranscriptionLocation, TranscriptionText
      ├── optional downstream writers: CRMContactId, CRMRecordUrl
      └── optional readers: dashboards, analytics, and incident lookups

Optional agent-state writers
      │ direct Lambda calls or operator tools
      │
      ▼
Agent State Table: {org}-agent-state-{env}
      │
      └── optional readers: future screen-pop or agent-assist consumers
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `contact_state_table_name` | string | Contact State table name | downstream consumers that opt into shared contact state |
| `contact_state_table_arn` | string | Contact State table ARN | IAM policies in downstream Lambda roles |
| `agent_state_table_name` | string | Agent State table name | downstream consumers that opt into shared agent state |
| `agent_state_table_arn` | string | Agent State table ARN | IAM policies in downstream Lambda roles |
| `contact_state_gsi_agent_name` | string | GSI-1 name | Query optimization for agent-based lookups |
| `contact_state_gsi_queue_name` | string | GSI-2 name | Query optimization for queue-based lookups |
| `contact_state_stream_arn` | string or null | Contact State stream ARN when streams are enabled | downstream event consumers that opt into table-stream processing |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

`connect-pbx/modules/l3-dynamodb`

### Key Resources Declared

```hcl
terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "org_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "environment_kms_key_arn" {
  type = string
}

variable "contact_state_stream_enabled" {
  type    = bool
  default = false
}

variable "contact_state_stream_view_type" {
  type    = string
  default = "NEW_AND_OLD_IMAGES"
}

variable "alarm_action_arns" {
  type    = list(string)
  default = []
}

resource "aws_dynamodb_table" "contact_state" {
  name         = "${var.org_name}-contact-state-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ContactId"
  stream_enabled   = var.contact_state_stream_enabled
  stream_view_type = var.contact_state_stream_enabled ? var.contact_state_stream_view_type : null
  deletion_protection_enabled = true

  attribute {
    name = "ContactId"
    type = "S"
  }
  attribute {
    name = "AgentUsername"
    type = "S"
  }
  attribute {
    name = "QueueName"
    type = "S"
  }
  attribute {
    name = "InitiationTimestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ExpiresAt"
    enabled        = true
  }
  point_in_time_recovery { enabled = true }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.environment_kms_key_arn
  }

  global_secondary_index {
    name            = "AgentUsername-InitiationTimestamp-index"
    hash_key        = "AgentUsername"
    range_key       = "InitiationTimestamp"
    projection_type = "ALL"
  }

  global_secondary_index {
    name            = "QueueName-InitiationTimestamp-index"
    hash_key        = "QueueName"
    range_key       = "InitiationTimestamp"
    projection_type = "ALL"
  }

  tags = {
    Project     = "connect-pbx"
    Layer       = "L3"
    PRD         = "PRD-31"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_dynamodb_table" "agent_state" {
  name         = "${var.org_name}-agent-state-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "AgentUsername"
  deletion_protection_enabled = true

  attribute {
    name = "AgentUsername"
    type = "S"
  }

  point_in_time_recovery { enabled = true }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.environment_kms_key_arn
  }

  tags = {
    Project     = "connect-pbx"
    Layer       = "L3"
    PRD         = "PRD-31"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cloudwatch_metric_alarm" "contact_state_write_throttle" {
  count               = length(var.alarm_action_arns) > 0 ? 1 : 0
  alarm_name          = "${var.org_name}-contact-state-write-throttle-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "WriteThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = var.alarm_action_arns

  dimensions = {
    TableName = aws_dynamodb_table.contact_state.name
  }
}

resource "aws_cloudwatch_metric_alarm" "contact_state_read_throttle" {
  count               = length(var.alarm_action_arns) > 0 ? 1 : 0
  alarm_name          = "${var.org_name}-contact-state-read-throttle-${var.environment}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ReadThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = var.alarm_action_arns

  dimensions = {
    TableName = aws_dynamodb_table.contact_state.name
  }
}
```

### Outputs

```hcl
output "contact_state_table_name"    { value = aws_dynamodb_table.contact_state.name }
output "contact_state_table_arn"     { value = aws_dynamodb_table.contact_state.arn }
output "agent_state_table_name"      { value = aws_dynamodb_table.agent_state.name }
output "agent_state_table_arn"       { value = aws_dynamodb_table.agent_state.arn }
output "contact_state_gsi_agent_name" {
  value = "AgentUsername-InitiationTimestamp-index"
  description = "GSI-1 name for agent-based queries."
}
output "contact_state_gsi_queue_name" {
  value = "QueueName-InitiationTimestamp-index"
  description = "GSI-2 name for queue-based queries."
}
output "contact_state_stream_arn" {
  value       = var.contact_state_stream_enabled ? aws_dynamodb_table.contact_state.stream_arn : null
  description = "Contact State stream ARN when streams are enabled by PRD-31."
}
```

The repo's plan and apply workflows inject the backend key from the module catalog `state_key` during `terraform init`. This module does not hardcode environment names, workspace paths, or backend key fragments.

---

## 10. EVENT SCHEMA

PRD-31 produces no EventBridge events. It is a passive data store. DynamoDB Streams, when enabled through the PRD-31 module inputs, generate stream records that trigger Lambda functions defined by downstream PRDs such as PRD-60 and PRD-82.

---

## 11. API / INTERFACE CONTRACT

```hcl
# Standard downstream consumption pattern
data "terraform_remote_state" "dynamodb" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.dynamodb_state_key
    region = var.aws_region
  }
}

locals {
  contact_state_table_name = data.terraform_remote_state.dynamodb.outputs.contact_state_table_name
  agent_state_table_name   = data.terraform_remote_state.dynamodb.outputs.agent_state_table_name
  contact_state_table_arn  = data.terraform_remote_state.dynamodb.outputs.contact_state_table_arn
  agent_state_table_arn    = data.terraform_remote_state.dynamodb.outputs.agent_state_table_arn
}
```

The `dynamodb_state_key` input must match the catalog-declared `state_key` for this module. It is not a workspace-derived path. Consumers querying the GSIs must always use bounded time windows and pagination; 90-day unbounded queue or agent sweeps are not part of the supported contract.

### Standard DynamoDB IAM Policy Snippet

Applied to Lambda execution roles that opt into shared-state reads or writes against the Contact State table:

```hcl
{
  Effect = "Allow"
  Action = [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:Query"
  ]
  Resource = [
    local.contact_state_table_arn,
    "${local.contact_state_table_arn}/index/*"  # Allow GSI queries
  ]
  Condition = {
    StringEquals = {
      "aws:PrincipalTag/Project" = "connect-pbx"
    }
  }
}
```

---

## 12. DATA MODEL

### Contact State — Example Record

```json
{
  "ContactId": "abc-123-def-456",
  "Channel": "VOICE",
  "InitiationMethod": "INBOUND",
  "CustomerEndpoint": "+15551234567",
  "QueueName": "Sales",
  "QueueArn": "arn:aws:connect:us-east-1:...:queue/sales",
  "AgentUsername": "jsmith",
  "InitiationTimestamp": "2026-03-16T14:32:00Z",
  "DisconnectTimestamp": "2026-03-16T14:45:00Z",
  "RecordingLocation": "s3://{org}-recordings-{env}-{acct}/recordings/abc-123-def-456/20260316-143200.wav",
  "VoicemailLocation": null,
  "TranscriptionLocation": null,
  "TranscriptionText": null,
  "CRMContactId": "HS-78901",
  "CRMRecordUrl": "https://app.hubspot.com/contacts/...",
  "ContactAttributes": {
    "target_queue_name": "Sales",
    "lex_integration_enabled": "false"
  },
  "Status": "COMPLETED",
  "ExpiresAt": 1749945600,
  "CreatedAt": "2026-03-16T14:32:00Z",
  "UpdatedAt": "2026-03-16T14:45:01Z",
  "RecordVersion": 4
}
```

### Agent State — Example Record

```json
{
  "AgentUsername": "jsmith",
  "AgentArn": "arn:aws:connect:us-east-1:...:agent/jsmith",
  "CurrentStatus": "AVAILABLE",
  "RoutingProfileId": "routing-profile-id",
  "RoutingProfileName": "Sales-Primary",
  "CurrentContactId": null,
  "LastStatusChange": "2026-03-16T14:46:00Z",
  "ShiftStart": "2026-03-16T08:00:00Z",
  "UpdatedAt": "2026-03-16T14:46:00Z",
  "RecordVersion": 2
}
```

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l3-dynamodb
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l3-dynamodb
      environment: ${{ inputs.environment }}
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l3-dynamodb
      environment: ${{ inputs.environment }}
      plan_run_id: ${{ github.run_id }}
    secrets: inherit
```

### Rollback Procedure
Schema changes that add attributes are generally non-destructive. New GSIs are forward-only production changes: once added, they are not removed through routine rollback because deleting a GSI requires rebuild and data backfill. Table deletion must never occur in production — PITR assists recovery from accidental writes, while deletion protection and Terraform `prevent_destroy` block casual teardown.

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-31-01: Contact State Write Throttle**
- Metric: `WriteThrottleEvents` > 0 on contact-state table
- Activation note: provisioned only when `alarm_action_arns` is non-empty
- Severity: High — PAY_PER_REQUEST should never throttle; if it does, a service is in a write loop

**ALARM-31-02: Contact State Read Throttle**
- Metric: `ReadThrottleEvents` > 0
- Activation note: provisioned only when `alarm_action_arns` is non-empty
- Severity: High — same reasoning

**ALARM-31-03: Contact State Record Count Spike**
- Metric: `ItemCount` growth rate > 200% in 1 hour
- Activation note: operational monitoring contract only; implement in downstream observability stack if enabled
- Severity: Medium — abnormal contact volume or a write loop

### SOC 2 and PCI Evidence Artifacts

| Artifact | Demonstrates |
|---|---|
| Table encryption configuration | PCI-DSS Req 3.4, SOC 2 CC6.7 |
| PITR configuration | SOC 2 A1.2 — data recovery capability |
| Table access IAM policies | SOC 2 CC6.1 — least privilege access |

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-31-01 | Contact State table exists | `aws dynamodb describe-table` returns table details |
| AC-31-02 | Contact State encrypted with env KMS key | Table description returns KMS ARN |
| AC-31-03 | PITR enabled on Contact State | `aws dynamodb describe-continuous-backups` returns ENABLED |
| AC-31-04 | TTL configured on ExpiresAt | Table description returns TTL attribute ExpiresAt |
| AC-31-05 | GSI-1 (AgentUsername) exists | `aws dynamodb describe-table` returns GSI with correct keys |
| AC-31-06 | GSI-2 (QueueName) exists | Same verification |
| AC-31-07 | Agent State table exists with PITR | Same as AC-31-01 through AC-31-03 for agent table |
| AC-31-08 | Shared-state writer contract prevents full-item clobbering | Integration test uses seed `PutItem` with `RecordVersion = 1` plus targeted `UpdateExpression` writes from two writers with `ConditionExpression = RecordVersion = :expected_version`; unrelated fields remain intact and stale writes are rejected |
| AC-31-09 | IAM sample enforces the `Project=connect-pbx` tag condition | Tagged test role succeeds; untagged test role is denied |
| AC-31-10 | GSI query by AgentUsername returns correct records within a bounded time range | Write test records, query GSI-1 with start/end timestamps and pagination, confirm result |
| AC-31-11 | Queue-based GSI query returns correct records within a bounded time range | Write test records, query GSI-2 with start/end timestamps and pagination, confirm result |
| AC-31-12 | TTL expiry removes records after ExpiresAt | Write record with ExpiresAt in past; confirm deletion within 48h (DDB TTL SLA) |
| AC-31-13 | Deletion protection and Terraform `prevent_destroy` are enabled on both tables | `describe-table` shows deletion protection enabled; Terraform plan rejects destroy |
| AC-31-14 | Streams remain PRD-31-owned and exportable when enabled | Apply with `contact_state_stream_enabled=true`; stream ARN output is populated without downstream table mutation |
| AC-31-15 | tfsec and checkov pass with zero HIGH or CRITICAL findings | Clean scan output |
| AC-31-16 | Module catalog entry validates with required fields | `python connect-pbx/scripts/module_manifest.py validate-catalog --catalog connect-pbx/modules/dependency-order.json` succeeds |
| AC-31-17 | CI workflows resolve the catalog-declared state key and manifest eligibility | `tf-plan.yml` and `tf-apply.yml` call `module_manifest.py module-field --field state_key` and reject disabled module paths |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Contact State table grows very large — TTL not aggressive enough | Low | Medium | 90-day TTL covers all reasonable incident investigation windows. Reduce to 30 days if storage cost becomes a concern. |
| Multiple Lambda functions write the same ContactId simultaneously — race condition | Medium | Medium | Seed write uses `attribute_not_exists`, all follow-up writes use targeted `UpdateExpression` operations on writer-owned fields, and overlapping writers use optimistic concurrency. |
| GSI hot partition — same AgentUsername written thousands of times per day | Medium | Medium | Query contract requires bounded time windows and pagination rather than unbounded 90-day sweeps. ALARM-31-01 detects throttling. |
| Full transcript content exceeds practical item size | Medium | Medium | `TranscriptionLocation` remains authoritative for full transcript content. `TranscriptionText` is a short excerpt only and may be omitted when too large. |
| PITR window (35 days) insufficient for incident requiring older data recovery | Low | Medium | CloudTrail captures all DynamoDB API calls (PRD-03). EventBridge audit log (PRD-22) provides event-level history beyond PITR window. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-31-01 | Should the Contact State table TTL be reduced from 90 days to 30 days once transcription and CRM record creation are confirmed complete? A shorter TTL reduces table size and cost. | Open — start at 90 days, review after 3 months of production operation. |
| OQ-31-02 | Should Global Tables (multi-region replication) be enabled now or deferred to PRD-122? Global Tables require specific table configuration at creation time. | Deferred - this PRD stays regional; revisit in PRD-122 only if multi-region data access becomes a confirmed requirement. |
| OQ-31-03 | Should shared-state writers use an explicit numeric version attribute in addition to `UpdatedAt` for optimistic concurrency? | Resolved — `RecordVersion` is the compare-and-swap field. `UpdatedAt` is informational only. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Two-table design with GSIs for agent and queue queries. 90-day TTL on contact records. PITR enabled on both tables. |
| 1.1.0 | 2026-03-30 | — | Normalized PRD-31 as a conditional shared-state foundation instead of a universal platform substrate. Clarified that direct service writes are valid and PRD-20 is an optional integration rather than a defining dependency. |
| 1.2.0 | 2026-04-05 | — | Added repo-owned modularity/governance section, aligned the module classification and catalog entry to the manifest/control-plane model, narrowed hard dependencies to provisioning inputs, and replaced stale backend and CI examples with current repo conventions. |
| 1.3.0 | 2026-04-06 | — | Implementation-readiness hardening. Added explicit multi-writer ownership rules, kept stream configuration under PRD-31 ownership, enforced retained-table safeguards with deletion protection and `prevent_destroy`, bounded the supported GSI query pattern, added optional alarm inputs, and clarified transcript storage semantics. |
| 1.4.0 | 2026-04-06 | — | Implementation-readiness follow-up. Mandated `UpdatedAt` as the single compare-and-swap field for overlapping writers, updated acceptance coverage to verify stale-write rejection, and resolved the version-attribute open question. |
| 1.5.0 | 2026-04-06 | — | Implementation-readiness correction. Mandated `RecordVersion` as the compare-and-swap token for all shared writers, clarified that `UpdatedAt` is informational only, and aligned the example records and acceptance criteria with the versioned conditional-write pattern. |
