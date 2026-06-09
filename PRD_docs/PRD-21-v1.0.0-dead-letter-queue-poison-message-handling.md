---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-21 |
| **Version** | 1.2.3 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 2 — Event Bus |
| **Depends On** | PRD-02 (KMS keys), PRD-20 (event bus ARN). PRD-03 (platform alert topic) is optional if alert routing is enabled. |
| **Blocks** | Event-driven downstream PRDs that create EventBridge rules |
| **Optional** | Yes — conditional foundation for event-driven profiles |

---

## 2. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Event-driven services in this platform rely on EventBridge rule targets. When a target fails delivery after EventBridge's own retry policy is exhausted, the failed event must land somewhere durable so operators can inspect it and recover it safely.

Dead Letter Queues provide that terminal safety net. PRD-21 provisions the shared EventBridge DLQ and a poison message handler that makes one republish attempt per DLQ delivery. If republishing fails, the handler alerts operations and returns the failed message ID in `batchItemFailures` so the message stays on the queue for automatic SQS/Lambda retry and can still be investigated through the queue, logs, and runbooks.

### What Problem It Solves

- Provides a shared SQS DLQ for EventBridge rule delivery failures
- Implements a poison message handler Lambda that attempts one republish per DLQ delivery and lets SQS/Lambda retry failed records automatically
- Prevents silent event loss in event-driven deployments
- Provides a CloudWatch alarm for DLQ depth monitoring
- Establishes the downstream EventBridge target retry contract used by event-driven PRDs

---

## 3. GOALS

### Goals

- Provision a platform-wide SQS Dead Letter Queue for EventBridge rule delivery failures
- Provision a poison message handler Lambda that republishes failed events once per delivery, then returns failed message IDs so SQS/Lambda retry continues when recovery does not succeed
- Export the DLQ ARN as the standard reference for downstream EventBridge rule `dead_letter_config` blocks
- Establish the downstream EventBridge target retry policy: 3 attempts over 1 hour before DLQ

### Non-Goals

- This PRD does not implement a custom looping recovery queue; failed records rely on the standard Lambda/SQS retry cycle instead
- This PRD does not implement event replay tooling — that is PRD-22
- This PRD does not implement per-service DLQ consumers — each service implements its own if needed
- This PRD does not require PRD-03 for basic deployability; PRD-03 is only an optional alert sink

---

## 4. MODULE GOVERNANCE

### Module Classification

- `classification`: `conditional-foundation`
- `minimum_deployment_profile`: `standard` for event-driven profiles
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Catalog Entry

- `path`: `modules/l2-dlq`
- `capability_packs`: `["eventing"]` when the pack exists in the live catalog
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l2-event-bus"]`
- `state_key`: `l2-dlq/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `null`
- `supports_destroy`: `true`

### Shared Sink Behavior

- `optional_shared_sinks`: `PRD-03 platform alert topic`
- `sink_behavior`: optional input, not a hard dependency

### Destroy / Retention Posture

- `destroy_posture`: `conditional`
- `retention_notes`: queue messages are retained 14 days; the queue and handler are safe to remove only if no downstream rule targets still depend on the exported DLQ ARN

### Control Plane Statement

This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-21-01 | Platform Engineer | As the platform engineer, I want all failed event deliveries captured in a DLQ so that no event is silently lost | EventBridge rule with DLQ configured; failed test event appears in DLQ |
| US-21-02 | Operations Engineer | As an operations engineer, I want to be alerted when the DLQ has messages so that I can investigate failures | ALARM-21-01 fires when DLQ depth > 0 |
| US-21-03 | Platform Engineer | As the platform engineer, I want a poison message handler that makes one safe recovery attempt per delivery so that transient issues can be cleared without a separate recovery tool | Handler Lambda attempts one republish per delivery, returns failed message IDs for retry on failure, and alerts operations |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Platform EventBridge DLQ
Provision an SQS queue named `{org_name}-eventbridge-dlq-{environment}` as the platform-wide dead letter destination for EventBridge rule delivery failures. The queue must be encrypted with the environment KMS key, have a message retention of 14 days, and have a visibility timeout of 300 seconds.

### FR-002 — Poison Message Handler Lambda
Provision a Lambda function that is triggered by the DLQ SQS queue. The Lambda must parse each DLQ message, extract the original EventBridge event, and attempt one republish per delivery to the event bus. The function must be configured for partial batch responses so SQS acknowledgments are explicit: when a record is successfully re-published, that record is treated as recovered and omitted from the returned failure list so Lambda acknowledges and deletes it from the queue; when republish fails, the function must add that record's message ID to `batchItemFailures`, publish an alert to the platform alert topic when one is configured, and log the failed event payload for manual investigation. Failed records remain on the queue for automatic retry until the queue retention policy expires or operators intervene.

### FR-003 — Optional Alert Sink
The DLQ handler must treat the platform alert topic as an optional input, not a hard dependency. If `alert_topic_arn` is configured, the handler publishes a failure alert to that topic. If it is not configured, the handler logs the failure and leaves the DLQ message available for automatic retry and manual inspection.

### FR-004 — DLQ ARN Export
Export the platform EventBridge DLQ ARN as `eventbridge_dlq_arn`. This is the value used in every downstream PRD's EventBridge rule `dead_letter_config` block.

### FR-005 — Standard Rule Pattern
Define the standard EventBridge rule pattern with DLQ that all downstream PRDs must follow:

```hcl
# Standard pattern — used in downstream event-driven PRDs
resource "aws_cloudwatch_event_rule" "example" {
  name           = "${var.org_name}-{service}-{event}"
  event_bus_name = local.event_bus_name
  event_pattern   = jsonencode({ ... })
}

resource "aws_cloudwatch_event_target" "example" {
  rule           = aws_cloudwatch_event_rule.example.name
  event_bus_name = local.event_bus_name
  target_id      = "{service}-lambda"
  arn            = aws_lambda_function.example.arn

  dead_letter_config {
    arn = local.eventbridge_dlq_arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts        = 3
  }
}
```

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
SQS is a managed AWS service with 99.9% availability. DLQ messages are durable and survive Lambda restarts and regional issues.

### Scale
The platform DLQ handles all EventBridge rule failures across all services. At enterprise scale with thousands of events per hour, DLQ volume should be near zero during normal operation. A DLQ depth above 10 indicates a systemic issue requiring investigation.

### Security
- DLQ encrypted with environment KMS key
- Poison message handler execution role scoped to SQS read/delete/change-visibility, EventBridge PutEvents, SNS publish, and KMS decrypt
- Permission boundary from PRD-02 applied

---

## 8. ARCHITECTURE

```text
EventBridge Rule Target Fails
          │
          │ (after EventBridge target retries are exhausted)
          ▼
Platform EventBridge DLQ (SQS)
          │
          ├── Trigger: Poison Message Handler Lambda
          │         │
          │         ├── Attempt one republish per DLQ delivery to the event bus
          │         │
          │         └── If recovery fails
          │             ├── Publish SNS alert when configured
          │             └── Log payload for manual investigation
          │
          └── ALARM-21-01: DLQ depth > 0 → SNS alert
```

Recovered records are acknowledged by the Lambda event source mapping through `ReportBatchItemFailures`; only failed `messageId` values are returned so successful republish attempts are deleted from SQS and failed ones remain visible for automatic retry.

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `eventbridge_dlq_arn` | string | Platform EventBridge DLQ ARN | Downstream event-driven EventBridge rule `dead_letter_config` blocks |
| `eventbridge_dlq_url` | string | DLQ URL for manual inspection | Operations runbooks |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```text
connect-pbx/
└── modules/
    └── l2-dlq/                     # PRD-21
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            └── poison-message-handler/
                └── index.py
```

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

data "terraform_remote_state" "event_bus" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "env:/${terraform.workspace}/l2-event-bus/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn       = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  event_bus_arn         = data.terraform_remote_state.event_bus.outputs.event_bus_arn
  event_bus_name        = data.terraform_remote_state.event_bus.outputs.event_bus_name
}

data "archive_file" "poison_handler" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/poison-message-handler"
  output_path = "${path.module}/.terraform-build/poison-message-handler.zip"
}

resource "aws_sqs_queue" "eventbridge_dlq" {
  name                       = "${var.org_name}-eventbridge-dlq-${terraform.workspace}"
  kms_master_key_id          = local.env_kms_key_arn
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 300
  receive_wait_time_seconds  = 20

  tags = { Layer = "L2", PRD = "PRD-21" }
}

resource "aws_sqs_queue_policy" "eventbridge_dlq" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowEventBridgeSend"
      Effect = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.eventbridge_dlq.arn
    }]
  })
}

resource "aws_lambda_function" "poison_message_handler" {
  function_name = "${var.org_name}-poison-message-handler-${terraform.workspace}"
  role          = aws_iam_role.poison_handler.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.poison_handler.output_path
  source_code_hash = data.archive_file.poison_handler.output_base64sha256

  environment {
    variables = {
      EVENT_BUS_NAME  = local.event_bus_name
      ALERT_TOPIC_ARN = var.alert_topic_arn
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L2", PRD = "PRD-21" }
}

resource "aws_lambda_event_source_mapping" "dlq_trigger" {
  event_source_arn         = aws_sqs_queue.eventbridge_dlq.arn
  function_name            = aws_lambda_function.poison_message_handler.arn
  batch_size               = 10
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_cloudwatch_metric_alarm" "eventbridge_dlq_depth" {
  alarm_name          = "${var.org_name}-eventbridge-dlq-depth-${terraform.workspace}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    QueueName = aws_sqs_queue.eventbridge_dlq.name
  }

  alarm_actions = var.alert_topic_arn != "" ? [var.alert_topic_arn] : []
  ok_actions    = var.alert_topic_arn != "" ? [var.alert_topic_arn] : []

  tags = { Layer = "L2", PRD = "PRD-21" }
}

resource "aws_cloudwatch_metric_alarm" "poison_handler_errors" {
  alarm_name          = "${var.org_name}-poison-message-handler-errors-${terraform.workspace}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    FunctionName = aws_lambda_function.poison_message_handler.function_name
  }

  alarm_actions = var.alert_topic_arn != "" ? [var.alert_topic_arn] : []
  ok_actions    = var.alert_topic_arn != "" ? [var.alert_topic_arn] : []

  tags = { Layer = "L2", PRD = "PRD-21" }
}
```

```hcl
# iam.tf

resource "aws_iam_role" "poison_handler" {
  name = "${var.org_name}-poison-handler-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = local.permission_boundary_arn != "" ? local.permission_boundary_arn : null
  tags                 = { Layer = "L2", PRD = "PRD-21" }
}

resource "aws_iam_role_policy" "poison_handler" {
  name = "poison-handler-policy"
  role = aws_iam_role.poison_handler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "SQSRead"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:GetQueueAttributes",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.eventbridge_dlq.arn
      },
      {
        Sid      = "EventBridgePublish"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = local.event_bus_arn
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.env_kms_key_arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:log-group:/aws/lambda/${var.org_name}-poison-message-handler-${terraform.workspace}:*"
      }
    ], var.alert_topic_arn != "" ? [{
      Sid      = "SNSPublish"
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = var.alert_topic_arn
    }] : [])
  })
}

# The sns:Publish statement is only rendered when `alert_topic_arn` is configured.
# When the alert sink is omitted, the handler still logs the failure and returns the failed message ID in `batchItemFailures` so the record stays on the queue for automatic retry.

resource "aws_cloudwatch_log_group" "poison_handler" {
  name              = "/aws/lambda/${aws_lambda_function.poison_message_handler.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = { Layer = "L2", PRD = "PRD-21" }
}
```

### Lambda Source

```python
# lambda-src/poison-message-handler/index.py
import json
import os
import boto3

events_client = boto3.client("events")
sns_client = boto3.client("sns")

EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]
ALERT_TOPIC_ARN = os.environ.get("ALERT_TOPIC_ARN", "")


def handler(event, context):
    batch_item_failures = []

    for record in event.get("Records", []):
        body = json.loads(record["body"])
        original_event = body.get("requestPayload", body)

        try:
            response = events_client.put_events(Entries=[{
                "Source": original_event.get("source", "connect-pbx.dlq-recovery"),
                "DetailType": original_event.get("detail-type", "DLQ.Recovery"),
                "Detail": json.dumps(original_event.get("detail", original_event)),
                "EventBusName": EVENT_BUS_NAME,
            }])

            if response.get("FailedEntryCount", 0) > 0:
                raise RuntimeError(json.dumps(response.get("Entries", [])))

            print("Recovered DLQ message by republishing original event")
        except Exception as exc:
            print(f"Recovery failed: {exc}")
            if ALERT_TOPIC_ARN:
                sns_client.publish(
                    TopicArn=ALERT_TOPIC_ARN,
                    Subject="POISON MESSAGE: DLQ recovery failed",
                    Message=json.dumps({
                        "alarm": "ALARM-21-POISON",
                        "original_event": original_event,
                        "error": str(exc)
                    }, indent=2)
                )
            batch_item_failures.append({
                "itemIdentifier": record["messageId"]
            })

    return {"batchItemFailures": batch_item_failures}
```

### Variables

```hcl
variable "org_name"     { type = string }
variable "aws_region"   { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "alert_topic_arn" {
  type        = string
  default     = ""
  description = "Optional platform alert topic ARN from PRD-03 or another approved alert sink."
}
variable "layer_id"     { type = string; default = "L2" }
variable "prd_id"       { type = string; default = "PRD-21" }
```

### Outputs

```hcl
output "eventbridge_dlq_arn" {
  description = "Platform EventBridge DLQ ARN. Referenced in dead_letter_config of all EventBridge rule targets."
  value       = aws_sqs_queue.eventbridge_dlq.arn
}

output "eventbridge_dlq_url" {
  description = "Platform EventBridge DLQ URL for manual inspection."
  value       = aws_sqs_queue.eventbridge_dlq.id
}
```

### Backend

```hcl
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

Backend configuration follows the partial backend config pattern established by PRD-00. The module's own backend key follows the catalog convention `l2-dlq/terraform.tfstate`.
The remote-state dependency example intentionally mirrors the repo's workspace-scoped pattern for layer-to-layer dependencies: `env:/${terraform.workspace}/l2-event-bus/terraform.tfstate`.

---

## 10. EVENT SCHEMA

PRD-21 produces no new EventBridge events. It consumes failed events from the DLQ and either re-publishes the original event envelope to the bus or publishes an SNS alert when configured.

---

## 11. API / INTERFACE CONTRACT

Downstream event-driven PRDs consume the exported DLQ ARN as the shared contract for `dead_letter_config` blocks.

---

## 12. DATA MODEL

SQS message format when EventBridge sends to DLQ:

```json
{
  "requestPayload": { "source": "connect-pbx.ctr-bridge", "detail-type": "ConnectPBX.ContactCompleted", "detail": { } },
  "responsePayload": { "error": "..." },
  "approximateInvokeCount": 3,
  "requestContext": { "functionArn": "...", "condition": "RetryAttemptsExhausted" }
}
```

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l2-dlq
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l2-dlq
      environment: ${{ inputs.environment }}
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l2-dlq
      environment: ${{ inputs.environment }}
      plan_run_id: ${{ github.run_id }}
    secrets: inherit
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-21-01: EventBridge DLQ Depth > 0**
- Metric: `ApproximateNumberOfMessagesVisible` > 0
- Action: SNS alert to platform alert topic when configured
- Severity: High

**ALARM-21-02: Poison Message Handler Error**
- Metric: Lambda `Errors` > 0 for poison-message-handler
- Severity: Critical — DLQ messages are not being recovered or escalated

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-21-01 | DLQ exists and is encrypted | `aws sqs get-queue-attributes` returns the env KMS key |
| AC-21-02 | EventBridge can send to DLQ | SQS queue policy allows `events.amazonaws.com` SendMessage |
| AC-21-03 | Poison handler Lambda triggers on DLQ message | Send test message to DLQ; confirm Lambda invoked |
| AC-21-04 | Handler republished the original event once per delivery | Send a valid EventBridge payload to the DLQ; confirm the event is written back to the bus and that the message is acknowledged via partial batch success |
| AC-21-05 | Handler preserves failed messages for retry | Simulate bus publish failure; confirm the Lambda response includes the failed `messageId` in `batchItemFailures` and the SQS message remains on the queue |
| AC-21-06 | Handler publishes alert when configured and recovery fails | Simulate bus publish failure; confirm SNS alert published if `alert_topic_arn` is set |
| AC-21-07 | ALARM-21-01 fires when DLQ has messages | Send message to DLQ; confirm alarm transitions to ALARM |
| AC-21-08 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| DLQ handler recovery fails repeatedly | Low | High | Partial batch responses keep failed records on the queue for retry while successful republish acknowledgments delete recovered records; EventBridge target retry policy remains the primary retry mechanism |
| DLQ fills up with high-volume failures before handler processes them | Medium | Medium | Long polling and batch size 10. Handler scales with Lambda concurrency. DLQ retention is 14 days |
| Alert topic not configured | Medium | Low | Alert sink is optional; failures are still logged and the DLQ message remains available for manual investigation |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-21-01 | Should `alert_topic_arn` be wired from PRD-03 when audit/evidence is enabled, or from a separate optional alert sink in event-driven profiles? | Open — keep optional for now |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Standard dead_letter_config pattern established for all downstream EventBridge rules. |
| 1.1.0 | 2026-04-05 | — | Normalized PRD-21 to the current manifest/catalog model. Replaced the internal retry loop with a single-shot recovery handler, made PRD-03 alert routing optional, removed stale backend/provider examples, and added repo-owned module governance content. |
| 1.1.1 | 2026-04-06 | — | Clarified partial batch acknowledgment semantics, aligned the remote-state example with the workspace-scoped convention, and tightened acceptance criteria and risk wording for implementation readiness. |
| 1.2.0 | 2026-04-06 | — | Implementation-readiness hardening. Aligned the prose, requirements, architecture, risks, and acceptance criteria with the sample's actual SQS retry behavior, added the missing account-baseline remote-state inputs and archive/permission-boundary locals, and provisioned honest DLQ depth and handler error alarms. |
| 1.2.1 | 2026-04-06 | — | Follow-up hardening. Made the optional SNS publish permission conditional so the alert sink can truly be omitted without leaving an invalid policy path behind. |
| 1.2.3 | 2026-04-06 | — | Follow-up correction. Removed the last wording drift that implied PRD-21 avoided automatic retry entirely; the doc now consistently describes one republish attempt per delivery plus the standard Lambda/SQS retry cycle for failed records. |
| 1.2.2 | 2026-04-06 | — | Follow-up correction. Removed the leftover unconditional SNS publish policy entry so the optional alert path is truly optional. |
