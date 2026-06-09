# PRD-20 — EventBridge Custom Bus & Schema Registry

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-20 |
| **Version** | 1.4.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 2 — Event Bus |
| **Depends On** | PRD-02 (KMS keys, permission boundary), PRD-10 (Connect instance ID — for CTR storage association) |

### Module Governance

| Field | Value | Notes |
| --- | --- | --- |
| Classification | optional-feature | Activated only through the module catalog + per-environment manifest |
| Minimum deployment profile | event-driven / standard | Not part of bare-bones or core-telephony profiles |
| Bare-bones omission | Yes | Safe to omit unless an event bus is explicitly required |
| Catalog entry | `modules/l2-event-bus` | Add to `modules/dependency-order.json` when implemented |
| Workspace state object | `env:/{workspace}/l2-event-bus/terraform.tfstate` | Matches the repo's workspace-scoped backend convention |
| Hard dependencies | PRD-02, PRD-10 | KMS, permission boundary, and Connect instance ID |
| Optional sink | PRD-03 platform alert topic | Optional only if an alert ARN is explicitly wired |
| Destroy posture | Supported with explicit retention boundaries | Must remain destroyable without hidden reverse-dependency locks; idempotency state is intentionally retained or explicitly recreated rather than silently discarded |
| **Blocks** | PRD-21 (DLQ), PRD-22 (Event Replay), and event-driven downstream modules that explicitly publish or consume platform events |
| **Optional** | Yes — optional feature and conditional foundation for event-driven profiles |

---

## 2. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Some deployments need a decoupled event-driven integration backbone. Others do not. Core telephony, lean migration, and small operational profiles can function without EventBridge as the universal coordination layer.

This PRD establishes the custom EventBridge bus, the Schema Registry that enforces the event envelope contract defined in the Preface, the Kinesis Data Stream that receives real-time CTRs from Amazon Connect, and the Kinesis-to-EventBridge bridge Lambda that transforms those CTRs into normalized platform events for deployments that enable the event-driven profile. Services outside that profile are not required to publish to or consume from this bus.

### What Problem It Solves

- Provides the event bus that decouples services in the event-driven profile
- Provisions the Kinesis Data Stream that receives real-time CTRs from Amazon Connect and associates it with the Connect instance
- Implements the Kinesis → Lambda → EventBridge pipeline that converts raw Connect CTRs into normalized `connect-pbx.*` events
- Establishes the Schema Registry so event schemas are versioned, discoverable, and validated
- Defines the canonical event envelope that event-driven platform services must follow
- Provides cross-account event bus publishing permissions for the multi-account topology (PRD-112)
- Exports the event bus ARN and name as the integration contract for event-driven services

### How It Fits the Overall Architecture

PRD-20 is the integration foundation for event-driven deployments. It sits above the telephony core and below the services that choose to communicate through platform events. This PRD provisions its own Kinesis Data Stream and associates it with the Connect instance from PRD-10 to receive real-time CTRs. The bridge Lambda reads from this stream, normalizes CTRs, and publishes them to the custom bus. Only services that enable the event-driven profile are expected to subscribe to this bus.

---

## 3. GOALS

### Goals

- Provision the `connect-pbx` custom EventBridge event bus with KMS encryption
- Provision the Kinesis Data Stream for real-time CTR ingestion and associate it with the Connect instance from PRD-10
- Provision the EventBridge Schema Registry for the platform
- Implement the Kinesis CTR bridge Lambda that transforms Connect CTRs into normalized platform events
- Define and register the canonical platform event schemas in the Schema Registry
- Provision the EventBridge archive for event replay (consumed by PRD-22)
- Export the event bus ARN and name as the integration contract for event-driven services
- Establish cross-account event bus resource policy placeholder (inactive until PRD-112 activates the multi-account mesh)

### Non-Goals

- This PRD does not implement Dead Letter Queues for EventBridge rules — that is PRD-21
- This PRD does not implement event replay tooling — that is PRD-22
- This PRD does not implement any event consumers (Lambda subscribers) — those are in their respective service PRDs
- This PRD does not implement the application event bus for the multi-account cross-account mesh — it provides the foundation; PRD-112 activates the cross-account policy
- This PRD is not a prerequisite for core telephony, lean migration, or other non-event-driven deployment profiles

---

## 4. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Provisions the event bus and verifies CTR events are flowing after applying PRD-10 and PRD-20 together.

**Service Developer (future)** — Any developer building a new service references the bus ARN through the module catalog's state-key contract for PRD-20 to publish or subscribe to platform events.

**Operations Engineer** — Uses the Schema Registry to discover what events are available and what their structure looks like without reading source code.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-20-01 | Platform Engineer | As the platform engineer, I want an event bus for event-driven service communication so that no service in that profile is directly coupled to another | Custom bus exists; event-driven services publish to it |
| US-20-02 | Platform Engineer | As the platform engineer, I want CTRs from Connect to appear as normalized platform events on the bus so that downstream services never need to parse raw CTR JSON | CTR bridge Lambda running; `ContactCompleted` event visible on bus within 5 minutes of a test call |
| US-20-03 | Service Developer | As a service developer, I want event schemas in a registry so that I can discover available events and their structure | Schema Registry populated with all canonical event schemas |
| US-20-04 | Operations Engineer | As an operations engineer, I want every event on the bus to have a consistent envelope so that event routing, filtering, and debugging are predictable | All events follow the envelope defined in Section 9 |

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Custom Event Bus
The system must provision an Amazon EventBridge custom event bus named `connect-pbx-{environment}`. The bus must be encrypted using the environment KMS key from PRD-02. The bus must have a resource policy that permits all IAM principals within the account to publish events. Cross-account publishing permissions are added by PRD-112 when the multi-account topology is activated.

### FR-002 — Schema Registry
The system must provision an EventBridge Schema Registry named `connect-pbx-{environment}`. All canonical platform event schemas must be registered in this registry at apply time. The registry enables discovery, code generation, and schema validation for all platform event types.

### FR-003 — Kinesis Data Stream for CTR Ingestion
The system must provision an Amazon Kinesis Data Stream to receive real-time Contact Trace Records from the Connect instance provisioned by PRD-10. The stream must be encrypted with the environment KMS key from PRD-02. The stream must be associated with the Connect instance via `aws_connect_instance_storage_config` with `resource_type = "CONTACT_TRACE_RECORDS"`. Connect uses its service-linked role (provisioned by PRD-02) to write CTRs to Kinesis — no customer-managed IAM role is required. The stream retention period must be 24 hours for small and medium capacity tiers, and 48 hours for large and enterprise tiers.

### FR-004 — Kinesis Stream Shard Sizing
The Kinesis stream shard count must be determined by the `deployment_profile.agent_capacity` variable. Each shard supports up to 1,000 records per second or 1 MB/s ingestion. The enterprise tier uses ON_DEMAND stream mode, which auto-scales:

| Agent Capacity | Shard Count | Stream Mode | Supports Approx. Agents |
|---|---|---|---|
| small | 1 | PROVISIONED | Up to 50 agents |
| medium | 4 | PROVISIONED | Up to 200 agents |
| large | 10 | PROVISIONED | Up to 500 agents |
| enterprise | ON_DEMAND (auto-scaling) | ON_DEMAND | 500+ agents |

### FR-005 — KMS Key Policy Prerequisite for Kinesis
The environment KMS key policy (provisioned by PRD-02) must include `kinesis.amazonaws.com` as a permitted service principal with `kms:Decrypt`, `kms:GenerateDataKey`, and `kms:DescribeKey` permissions. Without this, the Kinesis stream will fail to encrypt/decrypt records using the environment KMS key. This is a prerequisite update to l0-account-baseline that must be applied before PRD-20.

### FR-006 — Kinesis CTR Bridge Lambda
The system must provision a Lambda function named `{org_name}-ctr-bridge` that reads from the Kinesis Data Stream provisioned in FR-003 and publishes normalized events to the custom EventBridge bus. The Lambda must use standard GetRecords polling for all capacity tiers. Larger tiers may tune concurrency and batch settings, but the design must not claim Enhanced Fan-Out unless a registered stream consumer is added to the implementation. The Lambda must be idempotent — processing the same CTR twice must not publish duplicate events.

### FR-007 — CTR Bridge Event Mapping
The CTR bridge Lambda must publish the following event types based on the CTR content:

| CTR Field | EventBridge Event Type | Trigger Condition |
|---|---|---|
| First contact observed by the bridge | `ContactInitiated` | Every new contact first seen by the bridge; `initiation_method` is preserved in the payload |
| Agent.ConnectedToAgentTimestamp set | `ContactConnected` | Agent answered the call |
| DisconnectTimestamp set | `ContactCompleted` | Call disconnected |
| Queue.EnqueueTimestamp set | `ContactQueued` | Contact entered a queue |
| Queue.DequeueTimestamp set | `ContactDequeued` | Reserved for future queue analytics; not emitted by this bridge |

### FR-008 — Idempotency
The CTR bridge Lambda must use DynamoDB to track processed events with a 48-hour TTL. The idempotency key must be `{ContactId}#{EventType}` because a single CTR produces multiple event types. Before publishing each event, the Lambda must check whether that specific `ContactId#EventType` combination has already been processed. If it has, that event is skipped.

The publish path must not silently burn an idempotency key before the corresponding EventBridge publish has succeeded. The implementation contract is:

- retry failed `PutEvents` entries explicitly
- commit the idempotency key only after the corresponding EventBridge entry succeeds
- raise and re-drive the Kinesis batch if `PutEvents` still fails after retries, rather than returning success with unpublished events marked as processed

This prevents silent event loss while still suppressing duplicates in cases of Lambda retry or Kinesis replay.

### FR-009 — EventBridge Archive
The system must provision an EventBridge archive named `connect-pbx-{environment}-archive` on the custom bus. The archive must retain all events for 30 days. This archive is the source for the event replay capability implemented in PRD-22.

### FR-010 — Schema Registration
The following schemas must be registered in the Schema Registry at apply time using `aws_schemas_schema` resources. Each schema uses JSONSchema Draft 4 format:

- `ContactInitiated` — first contact observed by the bridge
- `ContactQueued` — contact entered a queue
- `ContactConnected` — agent connected
- `ContactCompleted` — contact ended

Reserved schema contracts (not emitted by this PRD):
- `ContactDequeued` — future queue analytics / queue departure consumers
- `AgentStatusChanged` — future real-time monitoring consumers
- `VoicemailReceived` — future voicemail workflow consumers
- `CRMContactCreated` — future CRM layer
- `CRMContactUpdated` — future CRM layer

### FR-011 — Dead Letter Configuration Placeholder
Every EventBridge rule created by downstream event-driven PRDs should reference an SQS Dead Letter Queue. PRD-21 provisions these DLQs. PRD-20 exports the event bus ARN so PRD-21 can create rules against it. The DLQ ARN will be exported by PRD-21 and consumed by those rule definitions.

### FR-012 — Cross-Account Resource Policy Placeholder
The event bus resource policy must include a placeholder statement for cross-account publishing, guarded by the `account_topology != "standalone"` condition. When PRD-112 is applied, this condition evaluates to true and the cross-account grant is activated:

```hcl
dynamic "statement" {
  for_each = var.deployment_profile.account_topology != "standalone" ? [1] : []
  content {
    # Cross-account publishing grant — activated by PRD-112
    sid    = "AllowCrossAccountPublish"
    effect = "Allow"
    principals { type = "AWS", identifiers = [var.deployment_profile.hub_account_id] }
    actions   = ["events:PutEvents"]
    resources = [aws_cloudwatch_event_bus.main.arn]
  }
}
```

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### Availability
EventBridge is a fully managed AWS service with 99.99% availability. The CTR bridge Lambda uses Kinesis as its trigger — Kinesis provides durable event delivery with at-least-once semantics. The idempotency mechanism in FR-008 handles duplicate deliveries.

### Throughput

| Capacity Tier | Expected CTR Volume | Kinesis Consumer | Lambda Concurrency |
|---|---|---|---|
| small | < 500 calls/day | Standard polling | 2 concurrent |
| medium | < 5,000 calls/day | Standard polling | 10 concurrent |
| large | < 50,000 calls/day | Standard polling | 25 concurrent |
| enterprise | 50,000+ calls/day | Standard polling | 100 concurrent |

EventBridge supports 10,000 events per second per bus by default — sufficient for all capacity tiers without a limit increase.

### Security
- Event bus encrypted with environment KMS key
- CTR bridge Lambda execution role scoped to Kinesis read, DynamoDB read/write, EventBridge PutEvents, and KMS decrypt
- Permission boundary from PRD-02 applied to Lambda execution role
- Schema Registry access restricted to account principals only

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| SOC 2 CC7.2 | All inter-service events recorded in EventBridge archive | Archive configuration |
| PCI-DSS Req 10.2 | Contact lifecycle events published and archivable | CTR bridge event output |

---

## 7. ARCHITECTURE

### Event Flow Diagram

```
Amazon Connect (PRD-10)
      │
      │ Contact Trace Records (via service-linked role)
      ▼
Kinesis Data Stream (PRD-20 — owned here)
      │
      │ Kinesis trigger (standard polling)
      ▼
Lambda: ctr-bridge
      │
      ├── Check idempotency (DynamoDB)
      ├── Map CTR → normalized event envelope
      └── PutEvents
            │
            ▼
EventBridge Custom Bus: connect-pbx-{env}
      │
      ├── Archive (30 days) ──────────────────► PRD-22 (Event Replay)
      │
      ├── Rule: ContactCompleted ─────────────► PRD-60 (Voicemail check)
      ├── Rule: ContactCompleted ─────────────► PRD-130-133 (CRM bundle)
      ├── Rule: ContactInitiated ─────────────► PRD-130-133 (CRM bundle)
      ├── Rule: VoicemailReceived ────────────► PRD-62 (Email notification)
      ├── Rule: AgentStatusChanged ───────────► future real-time monitoring consumers
      └── (Additional rules added by each downstream PRD)

Schema Registry: connect-pbx-{env}
      │
      └── All canonical event schemas registered here
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| Connect instance ID (PRD-10) | Inbound | CTR storage association — associates Kinesis stream with Connect instance |
| KMS env key (PRD-02) | Inbound | Kinesis stream, bus, archive, DynamoDB, and log group encryption |
| Permission boundary (PRD-02) | Inbound | Applied to CTR bridge Lambda execution role |
| Platform alert topic (optional) | Optional outbound sink | Bridge Lambda failure alerts when an ARN is provided |
| All downstream service PRDs | Outbound | Bus ARN for PutEvents and rule creation |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `event_bus_arn` | string | Custom event bus ARN | Event-driven PRDs publishing or subscribing to events |
| `event_bus_name` | string | Custom event bus name | Event-driven EventBridge rule resources |
| `kinesis_stream_arn` | string | CTR Kinesis stream ARN | future observability and contact analytics layers |
| `kinesis_stream_name` | string | CTR Kinesis stream name | future observability and contact analytics layers |
| `schema_registry_name` | string | Schema Registry name | Service developers, PRD-22 |
| `archive_arn` | string | EventBridge archive ARN | PRD-22 (Event Replay) |
| `idempotency_table_name` | string | DynamoDB idempotency table | PRD-21 (for DLQ Lambda reference) |
| `ctr_bridge_function_arn` | string | CTR bridge Lambda ARN | future observability and contact analytics layers |

---

## 8. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l2-event-bus/               # PRD-20
        ├── main.tf                 # Terraform config, provider, remote state lookups, locals
        ├── variables.tf
        ├── outputs.tf
        ├── locals.tf
        ├── kinesis.tf              # Kinesis Data Stream, Connect CTR storage association
        ├── eventbridge.tf          # Bus, archive, schema registry
        ├── schemas.tf              # Schema registrations
        ├── lambda.tf               # CTR bridge Lambda
        ├── dynamodb.tf             # Idempotency table
        ├── iam.tf                  # Lambda execution role
        └── lambda-src/
            └── ctr-bridge/
                └── index.py
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
    key    = "env:/${terraform.workspace}/l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "connect_instance" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "env:/${terraform.workspace}/l1-connect-instance/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn       = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  connect_instance_id   = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
}

# kinesis.tf — Kinesis Data Stream for CTR ingestion (moved from PRD-10 in v1.2.0)

locals {
  # Enterprise tier uses ON_DEMAND mode — shard count is managed by AWS.
  kinesis_shard_count = {
    small  = 1
    medium = 4
    large  = 10
  }

  kinesis_retention_hours = contains(
    ["large", "enterprise"],
    var.deployment_profile.agent_capacity
  ) ? 48 : 24

  # Standard polling is used for all tiers; higher tiers are tuned via batch/concurrency settings, not EFO.
}

resource "aws_kinesis_stream" "connect_ctr" {
  name             = "${var.org_name}-connect-ctr-${terraform.workspace}"
  retention_period = local.kinesis_retention_hours

  shard_count = var.deployment_profile.agent_capacity != "enterprise" ? local.kinesis_shard_count[var.deployment_profile.agent_capacity] : null

  encryption_type = "KMS"
  kms_key_id      = local.env_kms_key_arn

  stream_mode_details {
    stream_mode = var.deployment_profile.agent_capacity == "enterprise" ? "ON_DEMAND" : "PROVISIONED"
  }

  tags = {
    Layer = "L2"
    PRD   = "PRD-20"
  }
}

resource "aws_connect_instance_storage_config" "kinesis_ctr" {
  instance_id   = local.connect_instance_id
  resource_type = "CONTACT_TRACE_RECORDS"

  storage_config {
    kinesis_stream_config {
      stream_arn = aws_kinesis_stream.connect_ctr.arn
    }
    storage_type = "KINESIS_STREAM"
  }
}

# eventbridge.tf

resource "aws_cloudwatch_event_bus" "main" {
  name              = "connect-pbx-${terraform.workspace}"
  kms_key_identifier = local.env_kms_key_arn

  tags = {
    Layer = "L2"
    PRD   = "PRD-20"
  }
}

resource "aws_cloudwatch_event_bus_policy" "main" {
  event_bus_name = aws_cloudwatch_event_bus.main.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "AllowAccountPublish"
          Effect = "Allow"
          Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
          Action   = "events:PutEvents"
          Resource = aws_cloudwatch_event_bus.main.arn
        }
      ],
      var.deployment_profile.account_topology != "standalone" ? [
        {
          Sid    = "AllowCrossAccountPublish"
          Effect = "Allow"
          Principal = { AWS = var.deployment_profile.hub_account_id }
          Action   = "events:PutEvents"
          Resource = aws_cloudwatch_event_bus.main.arn
        }
      ] : []
    )
  })
}

resource "aws_cloudwatch_event_archive" "main" {
  name             = "connect-pbx-${terraform.workspace}-archive"
  event_source_arn = aws_cloudwatch_event_bus.main.arn
  retention_days   = 30
  description      = "30-day event archive for replay. Source for PRD-22."
}

resource "aws_schemas_registry" "main" {
  name        = "connect-pbx-${terraform.workspace}"
  description = "Schema registry for all connect-pbx platform events"

  tags = {
    Layer = "L2"
    PRD   = "PRD-20"
  }
}

# dynamodb.tf — Idempotency table

resource "aws_dynamodb_table" "idempotency" {
  name         = "${var.org_name}-ctr-bridge-idempotency-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "IdempotencyKey"

  attribute {
    name = "IdempotencyKey"  # Format: {ContactId}#{EventType}
    type = "S"
  }

  ttl {
    attribute_name = "ExpiresAt"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.env_kms_key_arn
  }

  point_in_time_recovery { enabled = true }

  tags = { Layer = "L2", PRD = "PRD-20" }
}

# lambda.tf — CTR Bridge

resource "aws_lambda_function" "ctr_bridge" {
  function_name = "${var.org_name}-ctr-bridge-${terraform.workspace}"
  role          = aws_iam_role.ctr_bridge.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.ctr_bridge.output_path
  source_code_hash = data.archive_file.ctr_bridge.output_base64sha256

  environment {
    variables = {
      EVENT_BUS_NAME       = aws_cloudwatch_event_bus.main.name
      IDEMPOTENCY_TABLE    = aws_dynamodb_table.idempotency.name
      ENVIRONMENT          = terraform.workspace
      LOG_LEVEL            = "INFO"
    }
  }

  tracing_config { mode = "Active" }

  tags = { Layer = "L2", PRD = "PRD-20" }
}

resource "aws_lambda_event_source_mapping" "kinesis" {
  event_source_arn              = aws_kinesis_stream.connect_ctr.arn
  function_name                 = aws_lambda_function.ctr_bridge.arn
  starting_position             = "LATEST"
  batch_size                    = contains(["large", "enterprise"], var.deployment_profile.agent_capacity) ? 100 : 10
  parallelization_factor        = contains(["large", "enterprise"], var.deployment_profile.agent_capacity) ? 10 : 1
  bisect_batch_on_function_error = true

  dynamic "filter_criteria" {
    for_each = [1]
    content {
      filter {
        pattern = jsonencode({ data = { eventVersion = ["1"] } })
      }
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.ctr_bridge_dlq.arn
    }
  }
}

# iam.tf — CTR Bridge Lambda execution role

resource "aws_iam_role" "ctr_bridge" {
  name = "${var.org_name}-ctr-bridge-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = local.permission_boundary_arn
  tags                 = { Layer = "L2", PRD = "PRD-20" }
}

resource "aws_iam_role_policy" "ctr_bridge" {
  name = "ctr-bridge-policy"
  role = aws_iam_role.ctr_bridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KinesisRead"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:ListShards",
          "kinesis:ListStreams",
          "kinesis:SubscribeToShard"
        ]
        Resource = aws_kinesis_stream.connect_ctr.arn
      },
      {
        Sid    = "DynamoDBIdempotency"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.idempotency.arn
      },
      {
        Sid      = "EventBridgePublish"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = aws_cloudwatch_event_bus.main.arn
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = local.env_kms_key_arn
      },
      {
        Sid      = "DLQSend"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.ctr_bridge_dlq.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/${var.org_name}-ctr-bridge-${terraform.workspace}:*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ctr_bridge" {
  name              = "/aws/lambda/${aws_lambda_function.ctr_bridge.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = { Layer = "L2", PRD = "PRD-20" }
}

resource "aws_sqs_queue" "ctr_bridge_dlq" {
  name                      = "${var.org_name}-ctr-bridge-dlq-${terraform.workspace}"
  kms_master_key_id         = local.env_kms_key_arn
  message_retention_seconds = 1209600  # 14 days

  tags = { Layer = "L2", PRD = "PRD-20" }
}
```

### Lambda Source Code

```python
# lambda-src/ctr-bridge/index.py
import json
import base64
import os
import boto3
import time
from datetime import datetime, timezone

events_client = boto3.client('events')
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ['IDEMPOTENCY_TABLE'])
EVENT_BUS_NAME = os.environ['EVENT_BUS_NAME']
ENVIRONMENT = os.environ['ENVIRONMENT']

CTR_EVENT_MAP = {
    'INBOUND':  'ContactInitiated',
    'OUTBOUND': 'ContactInitiated',
    'TRANSFER': 'ContactInitiated',
    'CALLBACK': 'ContactInitiated',
    'API':      'ContactInitiated',
}

def handler(event, context):
    platform_events = []
    pending_idempotency_keys = []

    for record in event.get('Records', []):
        raw = base64.b64decode(record['kinesis']['data'])
        ctr = json.loads(raw)
        contact_id = ctr.get('ContactId')

        if not contact_id:
            continue

        # Map CTR to platform events
        candidate_events = map_ctr_to_events(ctr)

        # Per-event idempotency check using {ContactId}#{EventType}.
        # Read first, publish second, then commit the idempotency key only after
        # the publish batch succeeds so a failed publish can never be marked done.
        for evt in candidate_events:
            event_type = evt['DetailType']
            idempotency_key = f"{contact_id}#{event_type}"
            existing = table.get_item(
                Key={'IdempotencyKey': idempotency_key},
                ConsistentRead=True
            )
            if existing.get('Item'):
                print(f"Duplicate event skipped: {idempotency_key}")
                continue

            platform_events.append(evt)
            pending_idempotency_keys.append(idempotency_key)

    # Batch publish (max 10 per PutEvents call) with partial failure retry
    published = 0
    for i in range(0, len(platform_events), 10):
        batch = platform_events[i:i+10]
        batch_keys = pending_idempotency_keys[i:i+10]
        response = events_client.put_events(Entries=batch)

        # Retry failed entries up to 3 times with exponential backoff
        failed_count = response.get('FailedEntryCount', 0)
        retries = 0
        while failed_count > 0 and retries < 3:
            time.sleep(2 ** retries)
            failed_entries = [
                batch[j] for j, entry in enumerate(response['Entries'])
                if 'ErrorCode' in entry
            ]
            response = events_client.put_events(Entries=failed_entries)
            failed_count = response.get('FailedEntryCount', 0)
            retries += 1

        if failed_count > 0:
            raise RuntimeError(
                f"{failed_count} events failed after retries; batch will be retried without committing idempotency keys"
            )

        for idempotency_key in batch_keys:
            table.put_item(
                Item={
                    'IdempotencyKey': idempotency_key,
                    'ExpiresAt': int(time.time()) + 172800  # 48h TTL
                },
                ConditionExpression='attribute_not_exists(IdempotencyKey)'
            )

        published += len(batch)

    return {'statusCode': 200, 'eventsPublished': published}


def map_ctr_to_events(ctr):
    events = []
    contact_id = ctr.get('ContactId')
    instance_arn = ctr.get('InstanceARN', '')
    channel = ctr.get('Channel', 'VOICE')
    now = datetime.now(timezone.utc).isoformat()

    base_detail = {
        'schema_version': '1.0',
        'event_id': contact_id,
        'timestamp': now,
        'environment': ENVIRONMENT,
        'payload': {
            'contact_id': contact_id,
            'channel': channel,
            'instance_arn': instance_arn,
            'initiation_method': ctr.get('InitiationMethod'),
            'customer_endpoint': ctr.get('CustomerEndpoint', {}).get('Address'),
            'queue_name': (ctr.get('Queue') or {}).get('Name'),
            'queue_arn': (ctr.get('Queue') or {}).get('ARN'),
            'agent_username': (ctr.get('Agent') or {}).get('Username'),
            'initiation_timestamp': ctr.get('InitiationTimestamp'),
            'disconnect_timestamp': ctr.get('DisconnectTimestamp'),
            'recording_location': (ctr.get('Recording') or {}).get('Location'),
        }
    }

    # ContactInitiated
    initiation_method = ctr.get('InitiationMethod', '')
    events.append(make_event('ContactInitiated', base_detail, contact_id))

    # ContactQueued
    if ctr.get('Queue') and (ctr.get('Queue') or {}).get('EnqueueTimestamp'):
        events.append(make_event('ContactQueued', base_detail, contact_id))

    # ContactConnected
    if ctr.get('Agent') and (ctr.get('Agent') or {}).get('ConnectedToAgentTimestamp'):
        events.append(make_event('ContactConnected', base_detail, contact_id))

    # ContactCompleted
    if ctr.get('DisconnectTimestamp'):
        events.append(make_event('ContactCompleted', base_detail, contact_id))

    return events


def make_event(event_type, detail, contact_id):
    return {
        'Source': 'connect-pbx.ctr-bridge',
        'DetailType': f'ConnectPBX.{event_type}',
        'Detail': json.dumps(detail),
        'EventBusName': EVENT_BUS_NAME,
    }
```

### Schemas

```hcl
# schemas.tf — ContactCompleted schema example (pattern repeated for all schemas)

resource "aws_schemas_schema" "contact_completed" {
  name          = "ConnectPBX.ContactCompleted"
  registry_name = aws_schemas_registry.main.name
  type          = "JSONSchemaDraft4"
  description   = "Published when a contact ends. Source: connect-pbx.ctr-bridge"

  content = jsonencode({
    "$schema"    = "http://json-schema.org/draft-04/schema#"
    title        = "ConnectPBX.ContactCompleted"
    description  = "Contact completed event"
    type         = "object"
    properties = {
      schema_version = { type = "string" }
      event_id       = { type = "string", description = "ContactId" }
      timestamp      = { type = "string", format = "date-time" }
      environment    = { type = "string", enum = ["dev", "staging", "prod"] }
      payload = {
        type = "object"
        properties = {
          contact_id           = { type = "string" }
          channel              = { type = "string", enum = ["VOICE", "CHAT", "TASK"] }
          instance_arn         = { type = "string" }
          initiation_method    = { type = "string" }
          customer_endpoint    = { type = "string" }
          queue_name           = { type = "string" }
          queue_arn            = { type = "string" }
          agent_username       = { type = "string" }
          initiation_timestamp = { type = "string" }
          disconnect_timestamp = { type = "string" }
          recording_location   = { type = "string" }
        }
        required = ["contact_id", "channel"]
      }
    }
    required = ["schema_version", "event_id", "timestamp", "environment", "payload"]
  })
}

# Additional schemas follow the same pattern for:
# Implemented schemas: ContactInitiated, ContactQueued, ContactConnected, ContactCompleted
# Reserved schemas: ContactDequeued, AgentStatusChanged, VoicemailReceived, CRMContactCreated, CRMContactUpdated
```

### Variables

```hcl
variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "layer_id" {
  type    = string
  default = "L2"
}

variable "prd_id" {
  type    = string
  default = "PRD-20"
}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. agent_capacity drives Kinesis shard sizing."
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
output "event_bus_arn"          { value = aws_cloudwatch_event_bus.main.arn }
output "event_bus_name"         { value = aws_cloudwatch_event_bus.main.name }
output "kinesis_stream_arn"     { value = aws_kinesis_stream.connect_ctr.arn }
output "kinesis_stream_name"    { value = aws_kinesis_stream.connect_ctr.name }
output "schema_registry_name"   { value = aws_schemas_registry.main.name }
output "archive_arn"            { value = aws_cloudwatch_event_archive.main.arn }
output "idempotency_table_name" { value = aws_dynamodb_table.idempotency.name }
output "ctr_bridge_function_arn" { value = aws_lambda_function.ctr_bridge.arn }
output "ctr_bridge_dlq_arn"     { value = aws_sqs_queue.ctr_bridge_dlq.arn }
```

### Backend Configuration

Backend configuration uses the partial backend config pattern established by PRD-00. The `backend "s3" {}` block is empty — all values are supplied at `terraform init` time via `-backend-config` flags or a `backend-{profile}.hcl` file. This is defined in `main.tf` above.

The state key follows the convention `env:/{workspace}/l2-event-bus/terraform.tfstate`.

---

## 9. EVENT SCHEMA

### Platform Event Envelope (All Events)

Every event published to the `connect-pbx-{env}` bus must follow this envelope exactly:

```json
{
  "Source": "connect-pbx.{service-name}",
  "DetailType": "ConnectPBX.{EventName}",
  "EventBusName": "connect-pbx-{environment}",
  "Detail": {
    "schema_version": "1.0",
    "event_id": "{uuid or ContactId}",
    "timestamp": "{ISO 8601 UTC}",
    "environment": "dev | staging | prod",
    "payload": {
      "contact_id": "string",
      "channel": "VOICE | CHAT | TASK",
      "instance_arn": "string",
      "initiation_method": "INBOUND | OUTBOUND | TRANSFER | CALLBACK | API",
      "customer_endpoint": "string — E.164 phone number",
      "queue_name": "string",
      "queue_arn": "string",
      "agent_username": "string",
      "initiation_timestamp": "ISO 8601",
      "disconnect_timestamp": "ISO 8601",
      "recording_location": "string — S3 URI"
    }
  }
}
```

### Standard Downstream Consumption Pattern

```hcl
variable "event_bus_state_key" {
  type        = string
  description = "Catalog-provided state key for PRD-20."
}

data "terraform_remote_state" "event_bus" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.event_bus_state_key
    region = var.aws_region
  }
}

locals {
  event_bus_name = data.terraform_remote_state.event_bus.outputs.event_bus_name
  event_bus_arn  = data.terraform_remote_state.event_bus.outputs.event_bus_arn
}

# Every downstream EventBridge rule uses this pattern:
resource "aws_cloudwatch_event_rule" "example" {
  name           = "${var.org_name}-{service}-{event-type}"
  event_bus_name = local.event_bus_name
  event_pattern  = jsonencode({
    source      = ["connect-pbx.ctr-bridge"]
    detail-type = ["ConnectPBX.ContactCompleted"]
  })
}
```

---

## 10. API / INTERFACE CONTRACT

PRD-20 exposes no HTTP APIs. Its contract is the event bus, the event envelope schema, and Terraform outputs.

---

## 11. DATA MODEL

### DynamoDB Idempotency Table

| Attribute | Type | Description |
|---|---|---|
| `IdempotencyKey` | String (PK) | `{ContactId}#{EventType}` — unique per event per contact |
| `CommittedAt` | Number | Unix timestamp written only after EventBridge accepts the publish |
| `ExpiresAt` | Number | Unix timestamp TTL — 48 hours after insertion |

### EventBridge Archive

All events on the custom bus are archived for 30 days. Events older than 30 days are automatically deleted by EventBridge. PRD-22 implements the replay tooling that uses this archive.

---

## 12. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l2-event-bus
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l2-event-bus
      environment: ${{ inputs.environment }}
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l2-event-bus
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l2-event-bus-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Rollback Procedure
Event bus changes are safe to roll back. In-flight events in the archive are unaffected by bus configuration changes. The idempotency DynamoDB table should normally be retained across rollback and rebuild operations so duplicate-suppression history is preserved; if it is intentionally destroyed, the next CTR bridge run must assume dedupe state has been reset and duplicates may reappear.

If the bridge exhausts `PutEvents` retries, the handler must fail the Kinesis batch before committing any new idempotency keys. Operators should treat that path as a retryable publish failure, not as a successfully processed CTR.

---

## 13. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-20-01: CTR Bridge Lambda Error Rate**
- Metric: Lambda `Errors` > 0 for `{org_name}-ctr-bridge`
- Severity: High — CTRs not being converted to platform events

**ALARM-20-02: CTR Bridge DLQ Depth**
- Metric: SQS `ApproximateNumberOfMessagesVisible` on CTR bridge DLQ > 0
- Severity: High — failed CTR records accumulating

**ALARM-20-03: Kinesis Iterator Age**
- Metric: `GetRecords.IteratorAgeMilliseconds` > 300000 (5 minute lag)
- Severity: High — CTR bridge falling behind Kinesis stream

**ALARM-20-04: Event Bus Invocation Failures**
- Metric: EventBridge `FailedInvocations` > 0 on custom bus
- Severity: High — rule targets failing to receive events

---

## 14. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-20-01 | Custom event bus exists | `aws events list-event-buses` returns `connect-pbx-{env}` |
| AC-20-02 | Bus encrypted with environment KMS key | `aws events describe-event-bus` returns KMS key ARN |
| AC-20-03 | Schema Registry exists | `aws schemas list-registries` returns `connect-pbx-{env}` |
| AC-20-04 | ContactCompleted schema registered | `aws schemas list-schemas` returns `ConnectPBX.ContactCompleted` |
| AC-20-05 | Archive exists with 30-day retention | `aws events list-archives` returns archive with retention 30 |
| AC-20-06 | Kinesis stream is active | `aws kinesis describe-stream` returns ACTIVE status |
| AC-20-07 | Kinesis stream encrypted with environment KMS key | `aws kinesis describe-stream` returns KMS key ARN matching env key |
| AC-20-08 | Kinesis stream shard count matches agent_capacity | Shard count equals profile-specified value (or ON_DEMAND for enterprise) |
| AC-20-09 | Connect CTR storage association points to Kinesis stream | `aws connect list-instance-storage-configs` returns KINESIS_STREAM for CONTACT_TRACE_RECORDS |
| AC-20-10 | KMS key policy includes `kinesis.amazonaws.com` service principal | `aws kms get-key-policy` for env key includes Kinesis service access |
| AC-20-11 | CTR bridge Lambda exists and active | `aws lambda get-function` returns ACTIVE state |
| AC-20-12 | Kinesis trigger attached to Lambda | `aws lambda list-event-source-mappings` returns Kinesis ESM |
| AC-20-13 | Test call produces ContactCompleted event on bus | Place test call; use EventBridge CloudWatch Logs rule to capture; confirm event within 5 minutes |
| AC-20-14 | Duplicate CTR skipped by idempotency check and failed publishes are retried rather than silently dropped | Replay the same Kinesis record twice and simulate a failed `PutEvents` call; confirm duplicates are suppressed on success paths and failed publish attempts re-drive the batch without leaving unpublished events marked as processed |
| AC-20-15 | Cross-account policy not present in standalone mode | Inspect bus resource policy — no AllowCrossAccountPublish statement |
| AC-20-16 | tfsec passes with zero HIGH or CRITICAL findings | Clean output |
| AC-20-17 | checkov passes with zero HIGH or CRITICAL findings | Clean output |

---

## 15. COST ESTIMATION

### Idle Cost (No Active Calls, agent_capacity = small)

| Resource | Monthly Cost | Notes |
|---|---|---|
| Kinesis Data Stream (1 shard, PROVISIONED) | **$10.95** | $0.015/shard-hour x 730 hours. Main cost driver — always-on. |
| EventBridge custom bus | $0.00 | Free. $1.00 per million events published — zero at idle. |
| EventBridge archive (30 days) | $0.00 | $0.10/GB stored — zero events at idle. |
| Schema Registry | $0.00 | Free. |
| DynamoDB idempotency table (PAY_PER_REQUEST) | $0.00 | No reads/writes at idle. |
| Lambda CTR bridge | $0.00 | Not invoked at idle. |
| SQS DLQ | $0.00 | No messages at idle. |
| CloudWatch Log Group (Lambda) | $0.00 | No log ingestion at idle. |
| CloudWatch Alarms (4) | $0.40 | $0.10/alarm/month. |
| **PRD-20 Total** | **~$11.35/month** | |

### Scaling Cost (Kinesis Only)

| agent_capacity | Shards | Stream Mode | Kinesis Monthly |
|---|---|---|---|
| small | 1 | PROVISIONED | $10.95 |
| medium | 4 | PROVISIONED | $43.80 |
| large | 10 | PROVISIONED | $109.50 |
| enterprise | auto | ON_DEMAND | Variable — $0.04/GB in + $0.04/GB out |

No new KMS keys are created by this PRD. All encryption uses the existing environment key from PRD-02.

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| CTR bridge Lambda throttled at high call volume | Medium | High | Lambda concurrency scaled by capacity tier. Reserved concurrency set to prevent throttling from other functions. |
| `PutEvents` fails after the bridge has evaluated the CTR | Low | High | The sample retries failed entries explicitly and fails the Kinesis batch before committing new idempotency keys, so retryable publish failures are not silently converted into dropped events. |
| EventBridge bus KMS key rotated — events unreadable | Very Low | High | KMS automatic rotation maintains decryption of old ciphertexts. Bus does not store events — only routes them. Archive uses the same key with rotation support. |
| Schema Registry schema version mismatch between publisher and consumer | Medium | Medium | Schema Registry enforces registered schemas. All publishers must use schema_version field. Consumers check schema_version before processing. |
| KMS key policy missing `kinesis.amazonaws.com` — Kinesis encryption fails | High | High | FR-005 requires adding `kinesis.amazonaws.com` to the PRD-02 KMS key policy before PRD-20 is applied. Must be deployed to l0-account-baseline first. |
| Kinesis stream undersized for actual call volume | Medium | High | Enterprise tier uses ON_DEMAND mode which auto-scales. ALARM-20-03 detects iterator lag before calls are affected. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-20-01 | Should the EventBridge archive retention be extended beyond 30 days for compliance purposes? CloudTrail captures all API events independently. 30 days covers operational replay needs. | Open — extend in PRD-22 if needed. |
| OQ-20-02 | Should AgentStatusChanged events be sourced from the CTR bridge or from a separate Connect Streams API Lambda? AgentStatusChanged is not in the CTR — it requires the Connect real-time metrics API. | Open — a future real-time monitoring or contact analytics layer will address this. Stub schema registered now. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. CTR bridge Lambda with idempotency. Five canonical event types. Schema Registry with nine schemas. Cross-account policy placeholder. |
| 1.1.0 | 2026-03-21 | — | **Kinesis ownership transferred from PRD-10.** Added FR-003 (Kinesis Data Stream + Connect CTR storage association), FR-004 (shard sizing by agent_capacity), FR-005 (KMS key policy prerequisite for `kinesis.amazonaws.com`). Added `kinesis.tf` with stream resource, storage config, and shard sizing locals. Added `main.tf` with terraform/provider blocks, remote state lookups for account_baseline, audit_pipeline, and connect_instance. Fixed provider `~> 5.0` → `~> 6.0`, terraform version `>= 1.6.0` → `>= 1.14.0`. Replaced hardcoded backend with partial config pattern. Fixed CI/CD artifact name separator `/` → `-`. Added Kinesis outputs (`kinesis_stream_arn`, `kinesis_stream_name`). Added cost estimation section (Section 15). Updated all `local.kinesis_stream_arn` references to `aws_kinesis_stream.connect_ctr.arn`. Renumbered FRs and ACs. |
| 1.4.0 | 2026-04-06 | — | Implementation-readiness hardening. Moved idempotency commitment behind successful publish so failed `PutEvents` batches are not marked processed, replaced the downstream remote-state example with catalog-supplied state-key consumption, and aligned the downstream interface language with the repo model. |
| 1.3.0 | 2026-04-05 | — | Aligned PRD-20 to the current manifest/catalog model, removed the unnecessary PRD-03 hard dependency, clarified implemented versus reserved schemas, and replaced the EFO claim with an honest standard-polling design. |
| 1.2.0 | 2026-03-30 | — | Normalized PRD-20 as an optional feature and conditional foundation for event-driven profiles rather than a universal platform backbone. Clarified that core telephony and lean migration do not require this PRD. |
