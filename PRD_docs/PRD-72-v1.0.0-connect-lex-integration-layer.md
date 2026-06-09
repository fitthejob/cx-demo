# PRD-72 — Connect-Lex Integration Layer

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-72 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-08 |
| **Layer** | 7 — AI & Automation |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-10 (Connect instance ID), PRD-13 (queue IDs), PRD-14 (Lex entry block plus explicit Set contact attributes mapping for the pre-hook response), PRD-70 (bot ID, SSM alias ARN parameter), PRD-71 (intents defined) |
| **Blocks** | PRD-73 (Fallback Handler — fallback flow is triggered from within the Lex integration flow) |
| **Optional Shared Sinks** | None |
| **Destroy / Retention Posture** | destroyable / no retained data store |
| **Optional** | Yes — optional AI-pack feature and conditional foundation within the AI pack |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable the Connect-Lex integration.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l7-lex-integration`
- `capability_packs`: `["ai-assist"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-hours-of-operation", "modules/l1-queue-architecture", "modules/l1-contact-flow-framework", "modules/l7-lex-bot-foundation", "modules/l7-lex-intents"]`
- `state_key`: `l7-lex-integration/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `lex-integration.tfvars`
- `supports_destroy`: `true`
- `activation`: `enabled_capability_packs` should include `ai-assist` once the module is cataloged; direct `enabled_modules` staging is acceptable only during pre-catalog rollout

### Shared Sink Behavior

- `optional_shared_sinks`: none
- `sink_behavior`: CRM lookup and fallback-flow integration are downstream optional contracts, not shared-sink activation gates.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: the module owns a Connect bot association, a contact flow, and an optional helper Lambda. It owns no retained state store.

### Control Plane Statement

PRD-72 wires Connect to the already-enabled Lex bot and intent modules. The PRD-14 consumer boundary must remain a declared output/input or remote-state contract; normal deployment sequencing may require PRD-14 to pick up PRD-72 outputs on its next apply, but the steady-state boundary must not require cross-module source edits or special re-apply rituals to function. Because Amazon Connect does not automatically persist Lambda return values as contact attributes, PRD-14 must explicitly map the pre-hook response into contact attributes by using a `Set contact attributes` block or an equivalent declared flow mapping step.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

The Lex bot from PRD-70/71 exists in isolation until it is wired to Amazon Connect. This PRD creates the association between the Connect instance and the Lex bot alias, provides the contact-flow and Lambda outputs consumed by the PRD-14 hook contract, and implements the Lex integration contact flow that handles each intent returned by the bot.

PRD-72 is part of the optional AI pack. It should remain primarily Connect-native, using a small Lambda pre-hook only where Connect flow activation needs it. Shared Lambda foundations from PRD-40 are an optional enhancement, not a hard prerequisite.

### Provider Gap Note

The alias ARN is read from SSM (not Terraform remote state) because `data "external"` is racy on first apply as documented in PRD-70. The `aws_connect_bot_association` resource requires the alias ARN — this PRD's apply must be sequenced after PRD-70 apply is fully complete and the SSM parameter contains the real ARN (not `PENDING_FIRST_APPLY`).

### What Problem It Solves

- Associates the Lex bot with the Connect instance via `aws_connect_bot_association`
- Provisions the Lex integration contact flow that receives Lex intent responses and routes callers accordingly
- Supplies the `LEX_INTEGRATION_HOOK` consumer contract in PRD-14 through declared outputs and normal downstream wiring
- Implements per-intent routing logic including the CRM toggle for `CheckAccountStatus`
- Sets the `lex_integration_enabled = true` contact attribute that the main flow checks to branch to Lex
- Sets explicit fallback handoff attributes so PRD-73 receives the last utterance and retry count through a declared contract rather than an implied flow variable

---

## 4. GOALS

### Goals

- Associate the Lex bot alias with the Connect instance
- Provision the Lex integration contact flow with per-intent routing branches
- Implement the CRM toggle branch for `CheckAccountStatus`
- Set `lex_integration_enabled = true` and `lex_flow_id` contact attributes to activate the LEX_INTEGRATION_HOOK
- Expose declared outputs that PRD-14 can consume on its next normal apply
- Export the Lex integration flow ID

### Non-Goals

- This PRD does not implement the fallback handler — that is PRD-73
- This PRD does not implement CRM Lambda lookup — that belongs to the optional CRM integration layer
- This PRD does not modify intents or the bot itself — that is PRD-71

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-72-01 | Caller | As a caller, I want to say my intent and be routed correctly by the AI without pressing keys | Say "Billing"; confirm routed to billing queue |
| US-72-02 | Caller | As a caller asking for business hours, I want to hear the hours and then be offered options | BusinessHoursInquiry intent returns; hours played back; caller offered transfer or main menu |
| US-72-03 | Platform Engineer | As the platform engineer, I want the Lex integration to be transparent — when Lex is disabled, callers use DTMF; when enabled, Lex handles them | LEX_INTEGRATION_HOOK activates on attribute; disabling crm_enabled reverts cleanly |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Connect Bot Association
Provision `aws_connect_bot_association` with:
- `instance_id` from PRD-10
- `lex_bot.alias_arn` from SSM parameter `/{environment}/lex/live-alias-arn` (PRD-70)
- `lex_bot.name` set to the bot name from PRD-70

This resource must reject the placeholder value explicitly. Use a Terraform `precondition` (or equivalent validation guard) that fails the plan/apply when `data.aws_ssm_parameter.lex_alias_arn.value == "PENDING_FIRST_APPLY"`. A `depends_on` on the data source is not sufficient because it does not validate the fetched value.

### FR-002 — Lex Integration Pre-Hook Lambda
Provision a Lambda function `{org_name}-lex-pre-hook` invoked from the PRD-14 Lex entry path once PRD-72 is enabled. This Lambda returns a flat STRING_MAP response containing:
1. `lex_flow_id` = the Lex integration flow ID
2. `lex_integration_enabled = true`
3. `crm_integration_enabled = true | false`

Amazon Connect does not automatically turn Lambda return values into contact attributes. PRD-14 must therefore invoke this Lambda and immediately copy the returned fields into contact attributes using a `Set contact attributes` block before evaluating the `LEX_INTEGRATION_HOOK` transfer.

### FR-003 — Lex Integration Contact Flow
Provision a contact flow named `{org_name}-Lex-Integration` of type `CONTACT_FLOW`. This flow is invoked by the `LEX_INTEGRATION_HOOK` in the main inbound flow. It must:
1. Invoke the Lex bot using `Get customer input` with the Lex bot association (not DTMF)
2. Branch on the returned intent name via `Check contact attributes` on `$.Lex.IntentName`
3. Per-intent routing branches (see FR-004)
4. Before invoking PRD-73, copy the current utterance and retry context into contact attributes:
   - `lex_last_utterance` = latest transcript or utterance text
   - `lex_retry_count` = retry count seen by the flow at the point fallback is triggered
5. On no match or fallback: invoke PRD-73 fallback handler flow

### FR-004 — Per-Intent Routing Branches
The Lex integration flow must implement the following routing logic per intent:

| Intent | Action |
|---|---|
| `RouteToDepartment` | Read `$.Lex.SessionState.Intent.Slots` or utterance pattern to determine department; set `target_queue_id`; transfer to Queue Transfer Module (PRD-13) |
| `CheckAccountStatus` | Check `crm_integration_enabled` contact attribute: if `true` → invoke CRM lookup Lambda from the optional CRM integration layer; if `false` → play "Our agents will assist you" → route to customer-support queue |
| `BusinessHoursInquiry` | Run `CheckHoursOfOperation` block → play open or closed message → offer "press 1 to continue, press 2 for main menu" |
| `RequestCallback` | Set `callback_requested = true`; play "An agent will help schedule your callback" message; route to customer-support queue by default. If a future callback automation flow is enabled, this branch may transfer to that flow instead. |
| `RepeatOptions` | Loop back to beginning of Lex integration flow (re-invoke bot) |
| `EscalateToAgent` | Set `target_queue_id` to general queue; play escalation message; transfer to Queue Transfer Module |
| No intent / fallback | Transfer to PRD-73 fallback handler |

### FR-005 — RouteToDepartment Department Extraction
Since no slots are used (per PRD-71 design), department is extracted from the raw utterance text (`$.Lex.InputTranscript`) using a `Check contact attributes` branch with string conditions:
- Contains "sales" → target: sales queue
- Contains "support" or "customer" → target: customer-support queue
- Contains "billing" → target: billing queue
- Contains "technical" or "tech" → target: technical-support queue
- Default → target: general queue

### FR-006 — Escalation Message
When `EscalateToAgent` is matched, the flow must play: "To ensure you receive optimal service, an agent will be on the line shortly. Thank you for your patience." before transferring to the general queue. This is the exact fallback message specified in the business requirements.

### FR-007 — CRM Integration Toggle
The `CheckAccountStatus` branch checks contact attribute `crm_integration_enabled`:
- When `true` (set when the optional CRM integration layer is active): invoke CRM lookup Lambda; read back account data; offer transfer
- When `false` or absent (default): play "Our agents will be happy to assist you with your account. Please hold." → route to customer-support queue

The attribute `crm_integration_enabled` is set by explicit module input or downstream environment wiring, not by `deployment_profile.optional_layers`. When CRM is not enabled, the attribute resolves to `false` and the Lex flow takes the support branch.

### FR-008 — RequestCallback Degradation Path
The `RequestCallback` branch must work even when no dedicated callback automation capability is enabled. In the default AI-only profile it:
- sets `callback_requested = true`
- optionally sets `callback_requested_at = {timestamp}` if the flow template supports it
- plays a handoff message indicating an agent will assist with the callback request
- routes to the customer-support queue

If a future callback workflow is enabled, the same branch may be redirected to that callback-specific flow without changing the Lex bot itself.

### FR-009 — PRD-14 Consumer Contract
After PRD-72 is applied, PRD-14 consumes the Lex pre-hook Lambda ARN and Lex integration flow ID through declared inputs or catalog-wired remote-state values so that the main inbound flow invokes the pre-hook at flow entry. This is a normal downstream contract update, not a cross-module source-edit boundary.

### FR-010 — PRD-73 Fallback Handoff Contract
When PRD-73 is enabled, PRD-72 must populate `lex_last_utterance` and `lex_retry_count` contact attributes before transferring to the fallback flow. PRD-73 consumes those explicit contact attributes in its logger Lambda. The fallback logger must not rely on undeclared Connect internals or implied Lex variables.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Latency
Lex invocation from Connect adds 200-500ms to caller response time. Total NLU + flow branching time: < 2 seconds. Caller experience: normal pause while the bot "thinks."

### Resilience
Every Lex integration flow branch must have an explicit error path that routes to PRD-73 fallback. No unhandled errors. If Lex returns a system error, the fallback handler plays the patience message and transfers to general queue.

### CRM Toggle Safety
When `crm_integration_enabled` is toggled from `true` to `false`, the `CheckAccountStatus` branch must immediately stop invoking the CRM Lambda without requiring a bot republish. The toggle is implemented as an explicit contact attribute check in the flow, not as a bot configuration change or a `deployment_profile` gate.

## 8. ARCHITECTURE

```
Inbound Call → Main Inbound Flow (PRD-14)
      │
      │ Invoke pre-hook Lambda
      ▼
Set contact attributes from Lambda result
      │
      ▼
LEX_INTEGRATION_HOOK branches to Lex Integration Flow
      │
      ▼
Get customer input (Lex V2 bot — not DTMF)
      │
      ├── RouteToDepartment
      │   └── Extract dept from $.Lex.InputTranscript
      │       └── Transfer to dept queue
      │
      ├── CheckAccountStatus
      │   ├── crm_integration_enabled=true → CRM lookup (optional CRM integration layer)
      │   └── crm_integration_enabled=false → "agents will assist" → support queue
      │
      ├── BusinessHoursInquiry
      │   └── CheckHoursOfOperation → play hours → offer continue/menu
      │
      ├── RequestCallback
      │   └── agent-assisted callback handling by default
      │      future callback automation may replace this branch
      │
      ├── RepeatOptions
      │   └── Loop back to Lex Get customer input
      │
      ├── EscalateToAgent
      │   └── Play escalation message → general queue
      │
      └── No match / error
          └── Set lex_last_utterance + lex_retry_count
          └── PRD-73 Fallback Handler
              "To ensure you receive optimal service, an agent will
               be on the line shortly. Thank you for your patience."
              → general queue
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `lex_integration_flow_id` | string | Lex integration contact flow ID | PRD-14 re-apply (lex_flow_id template variable), PRD-73 |
| `lex_pre_hook_lambda_arn` | string | Pre-hook Lambda ARN | PRD-14 re-apply |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l7-lex-integration/         # PRD-72
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            └── lex-pre-hook/
                └── index.py
```

### Key Resources Declared

```hcl
# main.tf

# Read alias ARN from SSM (not data "external" — avoids first-apply race condition)
data "aws_ssm_parameter" "lex_alias_arn" {
  name = local.lex_alias_arn_ssm_param
}

# Connect bot association
resource "aws_connect_bot_association" "main" {
  instance_id = local.connect_instance_id

  lex_bot {
    alias_arn = data.aws_ssm_parameter.lex_alias_arn.value
    name      = "${var.org_name}-auto-attendant-${terraform.workspace}"
  }

  lifecycle {
    precondition {
      condition     = data.aws_ssm_parameter.lex_alias_arn.value != "PENDING_FIRST_APPLY"
      error_message = "PRD-70 has not published a real live alias ARN to SSM yet."
    }
  }
}

# Lex integration contact flow
resource "aws_connect_contact_flow" "lex_integration" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Lex-Integration"
  description = "Routes callers based on Lex intent. Handles all six intents from PRD-71."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/lex-integration.json.tftpl", {
    instance_id             = local.connect_instance_id
    tts_voice_id            = var.tts_voice_id
    lex_bot_alias_arn       = data.aws_ssm_parameter.lex_alias_arn.value
    lex_bot_name            = "${var.org_name}-auto-attendant-${terraform.workspace}"
    queue_general_id        = local.queue_ids["general"]
    queue_sales_id          = local.queue_ids["sales"]
    queue_support_id        = local.queue_ids["customer-support"]
    queue_billing_id        = local.queue_ids["billing"]
    queue_tech_id           = local.queue_ids["technical-support"]
    queue_transfer_module_id = local.queue_transfer_module_id
    fallback_flow_id        = var.fallback_flow_id   # Populated by PRD-73 output when that optional integration is enabled
    hours_of_operation_id   = local.hours_of_operation_ids["standard-business"]
    crm_lookup_lambda_arn   = var.crm_integration_enabled ? var.crm_lookup_lambda_arn : ""
    prompt_escalation       = var.lex_prompts["escalation"]
    prompt_hours_open       = var.lex_prompts["hours_open"]
    prompt_hours_closed     = var.lex_prompts["hours_closed"]
    prompt_account_no_crm   = var.lex_prompts["account_no_crm"]
  })

  tags = { Layer = "L7", PRD = "PRD-72" }
}

# iam.tf

resource "aws_iam_role" "lex_pre_hook" {
  name = "${var.org_name}-lex-pre-hook-${terraform.workspace}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  permissions_boundary = local.permission_boundary_arn
  tags = { Layer = "L7", PRD = "PRD-72" }
}

resource "aws_iam_role_policy" "lex_pre_hook_logging" {
  name = "lex-pre-hook-logging"
  role = aws_iam_role.lex_pre_hook.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "CloudWatchLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "*"
    }]
  })
}

# Pre-hook Lambda has no service-specific permissions beyond logging.
# It returns a small STRING_MAP response that PRD-14 then copies into contact attributes.

resource "aws_cloudwatch_log_group" "lex_pre_hook" {
  name              = "/aws/lambda/${var.org_name}-lex-pre-hook-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.kms_key_arn
  tags = { Layer = "L7", PRD = "PRD-72" }
}

# Pre-hook Lambda
resource "aws_lambda_function" "lex_pre_hook" {
  function_name = "${var.org_name}-lex-pre-hook-${terraform.workspace}"
  role          = aws_iam_role.lex_pre_hook.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 10
  memory_size   = 128

  filename         = data.archive_file.lex_pre_hook.output_path
  source_code_hash = data.archive_file.lex_pre_hook.output_base64sha256

  environment {
    variables = {
      LEX_INTEGRATION_FLOW_ID = aws_connect_contact_flow.lex_integration.id
      CRM_ENABLED             = tostring(var.crm_integration_enabled)
      ENVIRONMENT             = terraform.workspace
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L7", PRD = "PRD-72" }
}

resource "aws_lambda_alias" "lex_pre_hook_live" {
  name             = "LIVE"
  function_name    = aws_lambda_function.lex_pre_hook.function_name
  function_version = aws_lambda_function.lex_pre_hook.version
  lifecycle { ignore_changes = [function_version, routing_config] }
}

resource "aws_lambda_permission" "connect_invoke_pre_hook" {
  statement_id  = "AllowConnectInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lex_pre_hook.function_name
  qualifier     = "LIVE"
  principal     = "connect.amazonaws.com"
  source_arn    = local.connect_instance_arn
}
```

### Pre-Hook Lambda Source

```python
# lambda-src/lex-pre-hook/index.py
import os
import logging

LEX_INTEGRATION_FLOW_ID = os.environ['LEX_INTEGRATION_FLOW_ID']
CRM_ENABLED             = os.environ.get('CRM_ENABLED', 'false').lower() == 'true'
LOGGER                  = logging.getLogger()
LOGGER.setLevel(logging.INFO)

def handler(event, context):
    """
    Returns a flat STRING_MAP that PRD-14 copies into contact attributes.
    Amazon Connect exposes Lambda results via $.External until the flow
    stores them explicitly with Set contact attributes.
    """
    LOGGER.info("Lex pre-hook invoked")

    return {
        'lex_integration_enabled': 'true',
        'lex_flow_id':             LEX_INTEGRATION_FLOW_ID,
        'crm_integration_enabled': 'true' if CRM_ENABLED else 'false'
    }
    # Connect reads these as contact attributes via the Lambda result
```

### Variables

```hcl
variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "lex_integration_state_key" { type = string }
variable "tts_voice_id" { type = string; default = "Joanna" }
variable "layer_id"    { type = string; default = "L7" }
variable "prd_id"      { type = string; default = "PRD-72" }

variable "fallback_flow_id" {
  type        = string
  description = "PRD-73 fallback flow ID. Populated after PRD-73 apply. Leave empty initially — flow uses error branch."
  default     = ""
}

variable "crm_lookup_lambda_arn" {
  type        = string
  description = "CRM lookup Lambda ARN from the optional CRM integration layer. Only used when crm_enabled = true."
  default     = ""
}

variable "crm_integration_enabled" {
  type        = bool
  description = "Whether the optional CRM integration path is enabled for the environment."
  default     = false
}

variable "lex_prompts" {
  type = map(string)
  default = {
    escalation    = "To ensure you receive optimal service, an agent will be on the line shortly. Thank you for your patience."
    hours_open    = "We are currently open. How can I direct your call?"
    hours_closed  = "Our office is currently closed. Our business hours are Monday through Friday, 8am to 6pm Eastern Time."
    account_no_crm = "Our agents will be happy to assist you with your account. Please hold while we connect you."
  }
}

```

### Outputs

```hcl
output "lex_integration_flow_id"  { value = aws_connect_contact_flow.lex_integration.id }
output "lex_pre_hook_lambda_arn"  { value = aws_lambda_function.lex_pre_hook.arn }
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

### PRD-14 Consumer Wiring

After PRD-72 apply, PRD-14 must be re-applied with the pre-hook Lambda ARN and Lex integration flow ID:

```hcl
data "terraform_remote_state" "lex_integration" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.lex_integration_state_key
    region = var.aws_region
  }
}

locals {
  lex_integration_flow_id = data.terraform_remote_state.lex_integration.outputs.lex_integration_flow_id
  lex_pre_hook_lambda_arn = data.terraform_remote_state.lex_integration.outputs.lex_pre_hook_lambda_arn
}
```

PRD-14 picks up these outputs through its own declared consumer contract, invokes the pre-hook Lambda, and explicitly copies the returned keys from `$.External` into contact attributes before transferring to `$.Attributes.lex_flow_id`. No cross-module source edits are required as the steady-state boundary.

---

## 10. EVENT SCHEMA

PRD-72 produces no EventBridge events. Intent routing is handled synchronously within the Connect contact flow.

### Contact Attributes Written By PRD-72

| Attribute | Value | Read By |
|---|---|---|
| `lex_integration_enabled` | `"true"` | PRD-14 main inbound flow LEX_INTEGRATION_HOOK branch |
| `lex_flow_id` | Lex integration flow ID | PRD-14 LEX_INTEGRATION_HOOK transfer block |
| `crm_integration_enabled` | `"true"` or `"false"` | Lex integration flow CheckAccountStatus branch |
| `lex_last_utterance` | Latest transcript before fallback | PRD-73 fallback logger |
| `lex_retry_count` | Retry count at fallback time | PRD-73 fallback logger |

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "lex_integration" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.lex_integration_state_key, region = var.aws_region }
}
locals {
  lex_integration_flow_id = data.terraform_remote_state.lex_integration.outputs.lex_integration_flow_id
  lex_pre_hook_lambda_arn = data.terraform_remote_state.lex_integration.outputs.lex_pre_hook_lambda_arn
}
```

---

## 12. DATA MODEL

PRD-72 provisions no data stores.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l7-lex-integration }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l7-lex-integration, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l7-lex-integration
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l7-lex-integration-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Apply Sequencing Requirement

PRD-72 apply must be sequenced AFTER:
1. PRD-70 apply is fully complete (including `null_resource.bot_alias_live` local-exec)
2. SSM parameter `/{env}/lex/live-alias-arn` contains a real ARN (not `PENDING_FIRST_APPLY`)
3. PRD-71 apply is complete and bot version is republished via taint

Verify before applying PRD-72:
```bash
aws ssm get-parameter --name "/${ENVIRONMENT}/lex/live-alias-arn" --query Parameter.Value --output text
# Must return a valid ARN, not "PENDING_FIRST_APPLY"
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-72-01: Lex Bot Association Error**
- Source: CloudTrail event `AssociateBot` with error code
- Severity: Critical — Lex not available to Connect; all callers fall through to DTMF

**ALARM-72-02: Lex Integration Flow Fatal Error**
- Metric: `ContactFlowFatalErrors` on Lex integration flow ARN > 0
- Severity: Critical — callers not being routed; falling to error handler

**ALARM-72-03: Pre-Hook Lambda Error**
- Metric: Lambda `Errors` > 0 on lex-pre-hook
- Severity: High — callers using DTMF fallback because pre-hook not setting attributes

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-72-01 | Connect bot association exists | `aws connect list-bots --instance-id` returns bot alias ARN |
| AC-72-02 | Lex integration flow exists | `aws connect list-contact-flows` returns `{org}-Lex-Integration` |
| AC-72-03 | Saying "Sales" routes to sales queue | Place test call; say "Sales"; confirm sales queue |
| AC-72-04 | Saying "Agent" plays escalation message and routes to general queue | Say "Agent"; confirm exact escalation message plays; general queue |
| AC-72-05 | Saying "What are your hours" returns business hours | Say hours inquiry; confirm hours response |
| AC-72-06 | CheckAccountStatus with crm_integration_enabled=false routes to support | Say "Order status"; confirm "agents will assist" message and support queue |
| AC-72-07 | Pre-hook Lambda returns the expected STRING_MAP and PRD-14 maps it into contact attributes | Invoke test Lambda; confirm `lex_integration_enabled`, `lex_flow_id`, and `crm_integration_enabled` are returned; inspect the PRD-14 flow wiring and confirm those fields are copied from `$.External` into contact attributes before `LEX_INTEGRATION_HOOK` transfer |
| AC-72-08 | SSM parameter not PENDING before apply | Verify SSM value before PRD-72 apply in acceptance test |
| AC-72-09 | Fallback handoff attributes are set before PRD-73 transfer | Trigger fallback path in a test flow and confirm `lex_last_utterance` and `lex_retry_count` are present on the contact before the fallback logger executes |
| AC-72-10 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| PRD-72 applied before SSM has real alias ARN — bot association uses PENDING value | Medium | High | AC-72-08 blocks apply if SSM is PENDING. ALARM-70-02 alerts if SSM not updated. |
| CRM Lambda ARN empty when crm_enabled=true — flow invokes empty ARN | Low | High | Lex integration flow handles empty Lambda ARN gracefully — falls through to "agents will assist" branch. ALARM-72-02 detects flow errors. |
| Department extraction from utterance text fails for multi-word department names | Low | Medium | Pattern matching uses `contains` on lowercase text. "Technical support" matches "technical". Default branch routes to general queue — caller still served. |
| RequestCallback has no dedicated automation path in lean profiles | High | Low | The branch degrades intentionally to agent-assisted callback handling so the intent remains useful without introducing a hidden dependency on a separate callback module. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-72-01 | Should the fallback_flow_id variable be populated at PRD-72 apply time or after PRD-73? PRD-73 has not been applied yet when PRD-72 first applies. | Resolved — `fallback_flow_id` defaults to empty string. Flow uses its own error branch until PRD-73 is applied and PRD-72 is re-applied with the fallback flow ID. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.2.0 | 2026-04-08 | — | Implementation-readiness hardening. Replaced the ineffective SSM `depends_on` fence with an explicit placeholder-value precondition, clarified that PRD-14 must map the pre-hook Lambda result into contact attributes, added the explicit fallback handoff attributes consumed by PRD-73, removed remaining PRD-40-style shared-layer and shared-env-var sample coupling, and normalized the CI plan artifact name. |
| 1.0.0 | 2026-03-16 | — | Initial release. SSM alias ARN pattern from PRD-70. CRM toggle on CheckAccountStatus. Exact escalation message from business requirements. PRD-14 re-apply activation documented. |
| 1.1.0 | 2026-04-06 | — | Added the repo-owned modularity section, removed `deployment_profile` activation drift, normalized backend/state-key conventions, and replaced the PRD-14 re-apply/source-boundary language with a declared consumer contract. |
