# PRD-73 — Bot Fallback & Escalation Handler

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-73 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-08 |
| **Layer** | 7 — AI & Automation |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-13 (queue IDs — general queue), PRD-14 (Queue Transfer Module), PRD-72 (Lex integration flow plus explicit `lex_last_utterance` / `lex_retry_count` fallback handoff attributes) |
| **Blocks** | None — this is the last PRD in Layer 7 |
| **Optional Shared Sinks** | Fallback review S3 export and LexFallback event publication, if enabled |
| **Destroy / Retention Posture** | destroyable / fallback review records retained only when an optional sink is configured |
| **Optional** | Yes — optional AI-pack feature |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable the fallback handler.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l7-lex-fallback`
- `capability_packs`: `["ai-assist"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture", "modules/l1-contact-flow-framework", "modules/l7-lex-integration"]`
- `state_key`: `l7-lex-fallback/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `lex-fallback.tfvars`
- `supports_destroy`: `true`
- `activation`: `enabled_capability_packs` should include `ai-assist` once the module is cataloged; direct `enabled_modules` staging is acceptable only during pre-catalog rollout

### Shared Sink Behavior

- `optional_shared_sinks`: fallback review S3 export; LexFallback event publication
- `sink_behavior`: optional inputs only. The core fallback call path must remain correct even when S3 export and event publication are omitted.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: the module owns a fallback flow and logger Lambda. Any exported fallback review records are retained only if an optional sink is configured elsewhere.

### Control Plane Statement

PRD-73 exists to protect the caller path when AI routing is enabled. The PRD-72 consumer boundary must stay a declared output/input or remote-state contract; normal deployment sequencing may require PRD-72 to pick up the fallback flow ID on its next apply, but the steady-state boundary must not rely on source edits or tfvars append scripts. The logger input contract is limited to explicit contact attributes set by PRD-72 before fallback transfer, not undeclared Lex internals.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

No NLU system achieves 100% intent recognition. After two failed recognition attempts, a caller must be transferred to a human agent gracefully — not disconnected, not sent to voicemail, not left in silence. The fallback handler is the safety net for all cases where Lex cannot determine intent: ambiguous utterances, heavy accents, background noise, caller silence, or requests that fall outside the defined intent set.

The business requirement specifies a specific message: *"To ensure you receive optimal service, an agent will be on the line shortly. Thank you for your patience."* This PRD implements exactly that message and routes the caller to the general queue.

### What Problem It Solves

- Provisions the fallback contact flow that handles all no-match and no-input conditions
- Plays the exact required escalation message before transferring
- Routes to the general queue (agents in the general routing profile handle these calls)
- Feeds fallback utterances to a Lambda that can export review records to S3 when that sink is enabled
- Optionally publishes a `ConnectPBX.LexFallback` event to the platform bus for monitoring and quality improvement when event publication is enabled
- Keeps fallback review export and event publication additive rather than turning them into hidden prerequisites for the caller path

---

## 4. GOALS

### Goals

- Provision the fallback contact flow with the exact required message
- Log the unrecognized utterance to S3 for NLU quality review when that optional sink is enabled
- Expose the fallback flow ID through a declared consumer contract for PRD-72
- Support optional event publication for richer monitoring when the event bus integration is enabled

### Non-Goals

- This PRD does not modify the Lex bot or intents — that is PRD-71
- This PRD does not implement voicemail fallback — callers who reach fallback are transferred to agents, not voicemail

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-73-01 | Caller | As a caller whose intent was not recognized, I want to hear a reassuring message and be connected to an agent | Exact message plays; caller connected to general queue within 30 seconds of fallback trigger |
| US-73-02 | Operations Manager | As the operations manager, I want to know how often fallback is triggered so I can improve the bot | Weekly fallback review export available when enabled; optional LexFallback event published when enabled |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Fallback Contact Flow
Provision a contact flow named `{org_name}-Lex-Fallback` of type `CONTACT_FLOW`. The flow must:
1. Play the exact escalation message: "To ensure you receive optimal service, an agent will be on the line shortly. Thank you for your patience."
2. Set `target_queue_id` to the general queue ID from PRD-13
3. Invoke the fallback logger Lambda using Amazon Connect's asynchronous Lambda execution mode so the caller path does not wait on review export or event publication
4. Transfer to the Queue Transfer Module (PRD-14)

### FR-002 — Fallback Logger Lambda
Provision a Lambda function `{org_name}-lex-fallback-logger` invoked asynchronously by the fallback contact flow. The Lambda must:
1. Read `lex_last_utterance` and `lex_retry_count` from contact attributes populated by PRD-72 before fallback transfer
2. Write a fallback record to S3: `s3://{review_bucket}/lex-fallback/{YYYY}/{MM}/{DD}/{contact_id}.json` only when the optional review sink is enabled
3. Publish `ConnectPBX.LexFallback` to the platform event bus only when event publication is enabled

### FR-003 — Fallback Record Schema
Each fallback S3 record must contain:
```json
{
  "contact_id":         "string",
  "timestamp":          "ISO 8601",
  "environment":        "dev | staging | prod",
  "unrecognized_text":  "string — $.Lex.InputTranscript",
  "attempts":           "number — how many Lex retries before fallback",
  "queue_transferred_to": "general"
}
```

### FR-004 — Two-Attempt Retry Before Fallback
The Lex integration flow in PRD-72 must attempt Lex recognition twice before invoking the fallback flow. The fallback is only triggered after two consecutive no-match or no-input responses. This retry behavior is implemented in the PRD-72 `Get customer input` block with `max_retries = 2`.

### FR-005 — Fallback Flow ID Consumer Contract
After PRD-73 is applied and the fallback flow ID is known, PRD-72 consumes `fallback_flow_id` through declared input or remote-state wiring. Until PRD-72 picks up that output, the Lex integration flow may use its own internal error branch as a safe temporary fallback.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
Fallback flow must never fail. It has no Lambda dependencies in the caller path — the fallback logger Lambda is invoked async so a Lambda error does not affect call routing.

### Caller Experience
Total time from fallback trigger to agent queue transfer: < 10 seconds. The escalation message must complete before the queue transfer begins.

## 8. ARCHITECTURE

```
Lex Get customer input — 2 failed attempts
      │
      └── PRD-72 invokes fallback flow
                │
                ▼
        {org}-Lex-Fallback contact flow
                │
                ├── Play escalation message (exact wording)
                ├── Async invoke fallback-logger Lambda
                └── Transfer to general queue (Queue Transfer Module)
                              │
                              ▼
                        Agent handles call

Fallback Logger Lambda (async — caller already in queue)
      │
      ├── Optional S3 review export: lex-fallback/{date}/{contact_id}.json
      └── Optionally publish ConnectPBX.LexFallback to event bus
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `fallback_flow_id` | string | Fallback contact flow ID | PRD-72 re-apply (fallback_flow_id variable) |
| `fallback_flow_arn` | string | Fallback flow ARN | future observability and operational monitoring |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l7-lex-fallback/            # PRD-73
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            └── lex-fallback-logger/
                └── index.py
```

### Key Resources Declared

```hcl
# main.tf

resource "aws_connect_contact_flow" "lex_fallback" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Lex-Fallback"
  description = "Fallback after 2 failed Lex recognition attempts. Plays escalation message and routes to general queue."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/lex-fallback.json.tftpl", {
    instance_id              = local.connect_instance_id
    tts_voice_id             = var.tts_voice_id
    queue_general_id         = local.queue_ids["general"]
    queue_transfer_module_id = local.queue_transfer_module_id
    fallback_logger_arn      = aws_lambda_function.fallback_logger.arn
    prompt_escalation        = var.escalation_message
  })

  tags = { Layer = "L7", PRD = "PRD-73" }
}

# iam.tf

resource "aws_iam_role" "fallback_logger" {
  name = "${var.org_name}-lex-fallback-logger-${terraform.workspace}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  permissions_boundary = local.permission_boundary_arn
  tags = { Layer = "L7", PRD = "PRD-73" }
}

data "aws_iam_policy_document" "fallback_logger_service" {
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = var.enable_fallback_review_export ? [1] : []
    content {
      sid     = "S3AuditWrite"
      effect  = "Allow"
      actions = ["s3:PutObject"]
      resources = [
        "${local.fallback_review_bucket_arn}/lex-fallback/*"
      ]
    }
  }

  dynamic "statement" {
    for_each = var.publish_fallback_event ? [1] : []
    content {
      sid     = "EventBridgePutEvents"
      effect  = "Allow"
      actions = ["events:PutEvents"]
      resources = [
        local.event_bus_arn
      ]
    }
  }

  dynamic "statement" {
    for_each = var.enable_fallback_review_export && local.kms_key_arn != "" ? [1] : []
    content {
      sid     = "KMS"
      effect  = "Allow"
      actions = ["kms:GenerateDataKey"]
      resources = [
        local.kms_key_arn
      ]
    }
  }
}

resource "aws_iam_role_policy" "fallback_logger_service" {
  name = "fallback-logger-service"
  role = aws_iam_role.fallback_logger.id
  policy = data.aws_iam_policy_document.fallback_logger_service.json
}

resource "aws_cloudwatch_log_group" "fallback_logger" {
  name              = "/aws/lambda/${var.org_name}-lex-fallback-logger-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.kms_key_arn
  tags = { Layer = "L7", PRD = "PRD-73" }
}

resource "aws_lambda_function" "fallback_logger" {
  function_name = "${var.org_name}-lex-fallback-logger-${terraform.workspace}"
  role          = aws_iam_role.fallback_logger.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 128

  filename         = data.archive_file.fallback_logger.output_path
  source_code_hash = data.archive_file.fallback_logger.output_base64sha256

  environment {
    variables = {
      REVIEW_BUCKET         = local.audit_bucket_name
      REVIEW_EXPORT_ENABLED = tostring(var.enable_fallback_review_export)
      EVENT_BUS_ENABLED = tostring(var.publish_fallback_event)
      EVENT_BUS_ARN         = local.event_bus_arn
      ENVIRONMENT           = terraform.workspace
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L7", PRD = "PRD-73" }
}

resource "aws_lambda_alias" "fallback_logger_live" {
  name             = "LIVE"
  function_name    = aws_lambda_function.fallback_logger.function_name
  function_version = aws_lambda_function.fallback_logger.version
  lifecycle { ignore_changes = [function_version, routing_config] }
}

resource "aws_lambda_permission" "connect_invoke_fallback" {
  statement_id  = "AllowConnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fallback_logger.function_name
  qualifier     = "LIVE"
  principal     = "connect.amazonaws.com"
  source_arn    = local.connect_instance_arn
}
```

### Fallback Flow Template (Key Blocks)

```json
// flows/lex-fallback.json.tftpl — structural outline
{
  "Version": "2019-10-30",
  "StartAction": "set-voice",
  "Actions": [
    {
      "Identifier": "set-voice",
      "Type": "UpdateContactTTSVoice",
      "Parameters": { "TextToSpeechVoice": "${tts_voice_id}" },
      "Transitions": { "NextAction": "play-escalation" }
    },
    {
      "Identifier": "play-escalation",
      "Type": "MessageParticipant",
      "Parameters": {
        "Text": "${prompt_escalation}",
        "TextToSpeechType": "text"
      },
      "Transitions": { "NextAction": "set-queue" }
    },
    {
      "Identifier": "set-queue",
      "Type": "UpdateContactAttributes",
      "Parameters": {
        "Attributes": [
          { "Name": "target_queue_id",    "Value": "${queue_general_id}" },
          { "Name": "target_queue_name",  "Value": "General" },
          { "Name": "max_wait_minutes",   "Value": "10" },
          { "Name": "overflow_action",    "Value": "VOICEMAIL" },
          { "Name": "lex_fallback",       "Value": "true" }
        ]
      },
      "Transitions": { "NextAction": "invoke-logger" }
    },
    {
      "Identifier": "invoke-logger",
      "Type": "InvokeLambdaFunction",
      "Metadata": {
        "ExecutionMode": "Asynchronous"
      },
      "Parameters": {
        "LambdaFunctionARN": "${fallback_logger_arn}:LIVE",
        "InvocationTimeLimitSeconds": "3"
      },
      "Transitions": {
        "NextAction": "transfer-to-queue",
        "Errors": [{ "NextAction": "transfer-to-queue", "ErrorType": "NoMatchingError" }]
      }
    },
    {
      "Identifier": "transfer-to-queue",
      "Type": "InvokeFlowModule",
      "Parameters": { "ContactFlowModuleId": "${queue_transfer_module_id}" },
      "Transitions": { "NextAction": "end", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "end",
      "Type": "DisconnectParticipant",
      "Parameters": {},
      "Transitions": {}
    }
  ]
}
```

### Lambda Source

```python
# lambda-src/lex-fallback-logger/index.py
import os
import json
import logging
import boto3
from datetime import datetime, timezone

s3           = boto3.client('s3')
events_client = boto3.client('events')
REVIEW_BUCKET = os.environ.get('REVIEW_BUCKET', '')
EVENT_BUS_ARN = os.environ.get('EVENT_BUS_ARN', '')
LOGGER        = logging.getLogger()
LOGGER.setLevel(logging.INFO)

def handler(event, context):
    details    = event.get('Details', {})
    contact_id = details.get('ContactData', {}).get('ContactId', 'unknown')
    utterance  = details.get('ContactData', {}).get('Attributes', {}).get('lex_last_utterance', 'unknown')

    now        = datetime.now(timezone.utc)
    date_prefix = now.strftime('%Y/%m/%d')
    s3_key     = f"lex-fallback/{date_prefix}/{contact_id}.json"

    attempts = int(details.get('ContactData', {}).get('Attributes', {}).get('lex_retry_count', '2'))

    record = {
        'contact_id':            contact_id,
        'timestamp':             now.isoformat(),
        'environment':           os.environ.get('ENVIRONMENT', 'unknown'),
        'unrecognized_text':     utterance,
        'attempts':              attempts,
        'queue_transferred_to':  'general'
    }

    if os.environ.get('REVIEW_EXPORT_ENABLED', 'false').lower() == 'true' and REVIEW_BUCKET:
        try:
            s3.put_object(
                Bucket=REVIEW_BUCKET,
                Key=s3_key,
                Body=json.dumps(record),
                ContentType='application/json'
            )
            LOGGER.info("Fallback record written", extra={"contact_id": contact_id, "key": s3_key})
        except Exception as e:
            LOGGER.error("Failed to write fallback record: %s", str(e))

    if os.environ.get('EVENT_BUS_ENABLED', 'false').lower() == 'true' and EVENT_BUS_ARN:
        try:
            events_client.put_events(
                Entries=[{
                    'Source': 'connect-pbx.lex-fallback',
                    'DetailType': 'ConnectPBX.LexFallback',
                    'EventBusName': EVENT_BUS_ARN,
                    'Detail': json.dumps({
                        'schema_version': '1.0',
                        'event_id': contact_id,
                        'timestamp': now.isoformat(),
                        'environment': os.environ.get('ENVIRONMENT', 'unknown'),
                        'payload': {
                            'contact_id': contact_id,
                            'unrecognized_text': utterance,
                            'fallback_key': s3_key
                        }
                    })
                }]
            )
        except Exception as e:
            LOGGER.error("Failed to publish LexFallback event: %s", str(e))

    # Always return success — Lambda failure must not affect caller routing
    return {'statusCode': 200}
```

### Variables and Outputs

```hcl
# variables.tf
variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "lex_fallback_state_key" { type = string }
variable "tts_voice_id" { type = string; default = "Joanna" }
variable "layer_id"    { type = string; default = "L7" }
variable "prd_id"      { type = string; default = "PRD-73" }

variable "escalation_message" {
  type        = string
  description = "Exact escalation message played to callers before transfer to agent."
  default     = "To ensure you receive optimal service, an agent will be on the line shortly. Thank you for your patience."
}

variable "enable_fallback_review_export" {
  type        = bool
  description = "Whether fallback records should be exported to S3 for review."
  default     = false
}

variable "publish_fallback_event" {
  type        = bool
  description = "Whether LexFallback should be published to the platform bus."
  default     = false
}

# outputs.tf
output "fallback_flow_id"  { value = aws_connect_contact_flow.lex_fallback.id }
output "fallback_flow_arn" { value = aws_connect_contact_flow.lex_fallback.arn }
```

### Backend

```hcl
terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  backend "s3" {}
}
```

The repo's plan and apply workflows inject the catalog-declared `state_key` during `terraform init`. This module does not hardcode environment names, workspace fragments, or backend key prefixes.

### PRD-72 Consumer Wiring

```hcl
data "terraform_remote_state" "lex_fallback" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.lex_fallback_state_key
    region = var.aws_region
  }
}

locals {
  fallback_flow_id = data.terraform_remote_state.lex_fallback.outputs.fallback_flow_id
}
```

PRD-72 picks up the fallback flow ID through its own declared consumer contract. No tfvars append script or source edit is required as the steady-state boundary.

---

## 10. EVENT SCHEMA

### LexFallback (Outbound)

```json
{
  "source": "connect-pbx.lex-fallback",
  "detail-type": "ConnectPBX.LexFallback",
  "detail": {
    "schema_version": "1.0",
    "event_id": "{contact_id}",
    "timestamp": "{ISO 8601}",
    "environment": "prod",
    "payload": {
      "contact_id":        "string",
      "unrecognized_text": "string — what the caller said that was not recognized",
      "fallback_key":      "s3://{review_bucket}/lex-fallback/{date}/{contact_id}.json"
    }
  }
}
```

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "lex_fallback" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.lex_fallback_state_key, region = var.aws_region }
}
locals {
  fallback_flow_id = data.terraform_remote_state.lex_fallback.outputs.fallback_flow_id
}
```

---

## 12. DATA MODEL

### Fallback Log S3 Structure

```
s3://{org}-audit-{acct}/
└── lex-fallback/
    └── {YYYY}/{MM}/{DD}/
        └── {contact_id}.json
```

Retention: governed by PRD-03 audit bucket lifecycle (7 years).
Retention: only relevant when the optional fallback-review export sink is enabled.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l7-lex-fallback }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l7-lex-fallback, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l7-lex-fallback
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l7-lex-fallback-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-73-01: LexFallback Rate Spike**
- Source: fallback review exports, custom metric, or EventBridge `MatchedEvents` for `ConnectPBX.LexFallback` when event publication is enabled
- Severity: High — significant NLU accuracy problem; may require intent expansion in PRD-71

**ALARM-73-02: Fallback Logger Lambda Error**
- Metric: Lambda `Errors` > 0 on fallback-logger
- Severity: Low — caller is not affected (error is async); but fallback records not being written

### Weekly Quality Review

When fallback review export is enabled, the fallback S3 log at `lex-fallback/` is reviewed weekly by the operations team. Recurring unrecognized utterances should be added as sample utterances in PRD-71 intents and the bot republished.

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-73-01 | Fallback flow exists | `aws connect list-contact-flows` returns `{org}-Lex-Fallback` |
| AC-73-02 | Exact escalation message plays | Place test call; trigger fallback (say nonsense twice); confirm exact message |
| AC-73-03 | Caller routed to general queue after message | Confirm queue assignment in CTR after fallback call |
| AC-73-04 | LexFallback event published when event publication is enabled | Check EventBridge audit log; confirm event after fallback trigger |
| AC-73-05 | Fallback S3 record written when fallback review export is enabled | Check `lex-fallback/` after fallback call; confirm JSON record |
| AC-73-06 | PRD-72 consumes the fallback flow ID through its declared contract | Verify PRD-72 input/remote-state wiring and confirm the flow update plan is coherent |
| AC-73-07 | Logger input contract is explicit and coherent | Confirm PRD-72 sets `lex_last_utterance` and `lex_retry_count` before fallback transfer and the logger reads those contact attributes |
| AC-73-08 | Lambda error does not affect caller routing | Force Lambda error; confirm caller still reaches agent |
| AC-73-09 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Escalation message changed by operations — exact wording differs from business requirement | Medium | Low | Message is a Terraform variable `escalation_message` with the exact required default. Changes go through PR review. |
| Fallback rate too high — poor NLU coverage before intent tuning | High (initial deployment) | Medium | ALARM-73-01 fires at 20% fallback rate. Weekly review of fallback S3 logs. Expand utterances in PRD-71 as patterns emerge. |
| PRD-72 does not pick up the fallback flow output after PRD-73 is enabled | High (first deployment) | Medium | PRD-72 consumer wiring is documented here and in PRD-72. AC-73-06 verifies the declared contract is in place. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-73-01 | Should the fallback route to a specific fallback queue (not general) to distinguish fallback calls in reporting? | Open — general queue is used for simplicity. A dedicated fallback queue can be added to PRD-13 if differentiated reporting is needed. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.2.0 | 2026-04-08 | — | Implementation-readiness hardening. Aligned the intended catalog entry to the `ai-assist` pack, made the PRD-72 fallback handoff attributes explicit, replaced the lingering PRD-40-style shared-layer and helper-library assumptions with self-contained Lambda examples, made the optional review/event sinks conditional in IAM, and normalized the CI plan artifact name. |
| 1.0.0 | 2026-03-16 | — | Initial release. Exact escalation message from business requirements. Async fallback logger with LexFallback event. S3 audit record for weekly NLU quality review. PRD-72 backfill procedure documented. Layer 7 AI & Automation complete. |
| 1.1.0 | 2026-04-06 | — | Added the repo-owned modularity section, removed `deployment_profile` activation drift, normalized backend/state-key conventions, and converted fallback review/event publication into optional sinks instead of hidden prerequisites. |
