# PRD-71 — Intent Design & Slot Architecture

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-71 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 7 — AI & Automation |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-70 (bot ID, locale ID, bot version resource) |
| **Blocks** | PRD-72 (Connect-Lex Integration — intents must exist before Connect can test the bot) |
| **Optional Shared Sinks** | none |
| **Destroy / Retention Posture** | destroyable / no persistent state |
| **Optional** | Yes — optional AI-pack feature |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable Lex intents.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l7-lex-intents`
- `capability_packs`: `[]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l7-lex-bot-foundation"]`
- `state_key`: `l7-lex-intents/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `lex-intents.tfvars`
- `supports_destroy`: `true`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated AI capability pack exists

### Shared Sink Behavior

- `optional_shared_sinks`: none
- `sink_behavior`: PRD-71 does not require shared sinks. Optional CRM integration remains a downstream feature and must not become a hidden prerequisite for the intent set.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: intents exist as Lex configuration artifacts only. The module should remain destroyable without requiring broad upstream cleanup.

### Control Plane Statement

The contract for PRD-71 is the intent set and its output IDs. CRM handling is an optional environment integration, not a deployment_profile toggle and not a prerequisite for the base intent pack.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

A Lex bot without intents understands nothing. This PRD defines all six intents the auto-attendant must recognize, their sample utterances, and their fulfillment behavior. It also documents the CRM integration toggle - when the optional CRM integration is not enabled, the `CheckAccountStatus` intent returns a friendly "our agents will assist you" response and routes to the appropriate queue; when CRM is enabled, the intent can invoke a CRM lookup Lambda from the future CRM integration layer.

### Provider Gap Inheritance

All provider gap constraints from PRD-70 apply here without re-documentation:
- `fulfillment_code_hook { enabled = false }` on all intents — Connect handles fulfillment
- After adding, changing, or removing intents: `terraform taint aws_lexv2models_bot_version.v1` in the PRD-70 module and re-apply to publish a new version
- No slots are used — department routing and account lookup are ANI-based or menu-based, not slot-based (consistent with the reference implementation pattern)

### Intent Design Decisions

| Intent | Handles | CRM Toggle |
|---|---|---|
| `RouteToDepartment` | "Sales", "Support", "Billing", "Technical Support" | No |
| `CheckAccountStatus` | "Check my order", "Account status", "Order status" | Yes — CRM disabled: route to support; CRM enabled: Lambda lookup |
| `BusinessHoursInquiry` | "Are you open?", "What are your hours?" | No |
| `RequestCallback` | "Call me back", "Schedule a callback" | No |
| `RepeatOptions` | "Repeat", "Say that again", "What are my options?" | No |
| `EscalateToAgent` | "Agent", "Human", "Operator", "Talk to someone" | No |

---

## 4. GOALS

### Goals

- Define and provision all six intents with comprehensive sample utterances
- Implement the CRM integration toggle on `CheckAccountStatus` via an optional CRM integration flag or downstream environment input, not via `deployment_profile`
- Extend the PRD-70 `aws_lexv2models_bot_version.v1` `depends_on` list to include all intent resources
- Export intent IDs for PRD-72 (Connect flow routing based on returned intent name)
- Keep `RequestCallback` viable even when no dedicated callback module is enabled

### Non-Goals

- This PRD does not use slots — routing is menu/ANI-based per the reference implementation pattern
- This PRD does not implement Lambda fulfillment hooks — Connect handles fulfillment
- This PRD does not implement multi-turn conversations beyond basic clarification retries

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-71-01 | Caller | As a caller, I want to say "Sales" or "I need to talk to billing" and be routed correctly without pressing keys | RouteToDepartment intent matches; correct queue assigned |
| US-71-02 | Caller | As a caller, I want to ask "what are your hours?" and get a helpful response | BusinessHoursInquiry intent matches; hours played back from contact flow |
| US-71-03 | Caller | As a caller, I want to say "agent" at any point and be connected to a human | EscalateToAgent intent matches; transfer to general queue |
| US-71-04 | Platform Engineer | As the platform engineer, I want CheckAccountStatus to gracefully degrade when CRM is not enabled | When CRM integration is disabled in the deployment manifest, intent routes to support queue with a "our agents will assist you" message |
| US-71-05 | Caller | As a caller asking for a callback, I want the system to preserve that request even if no dedicated callback automation is enabled yet | RequestCallback intent is recognized and the caller is routed to an agent path that can handle the callback request manually |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — RouteToDepartment Intent
Routes callers to a department by spoken name. No slots — department is identified by utterance pattern matching. The returned intent name `RouteToDepartment` plus a contact attribute `lex_department` (set by PRD-72 flow logic) drives the queue transfer.

Sample utterances (minimum — Lex NLU generalizes from these):
```
"Sales"
"I need sales"
"Connect me to sales"
"I want to speak to sales"
"Support"
"Customer support"
"I need help with my account"
"Billing"
"I have a billing question"
"I need to talk to billing"
"Technical support"
"I have a technical issue"
"My service is not working"
```

Intent closes session — Connect handles routing after intent is returned.

### FR-002 — CheckAccountStatus Intent
Handles order status, account status, and service status inquiries.

Sample utterances:
```
"Check my order"
"Order status"
"Where is my order"
"Track my order"
"Account status"
"Check my account"
"What is my account balance"
"Service status"
```

**Deployment manifest behavior:**
- `CRM integration disabled in the deployment manifest` (default): Intent is matched and returned to Connect. PRD-72 flow plays "Our agents will be able to assist you with your account. Please hold." and routes to customer support queue.
- `CRM integration enabled in the deployment manifest`: Intent is matched and returned to Connect. PRD-72 flow invokes the CRM lookup Lambda from the future CRM integration layer, retrieves account data, reads it back to the caller, and offers to transfer if further assistance is needed.

The toggle is implemented in the PRD-72 contact flow logic, not in the Lex intent itself. The intent always returns the same intent name regardless of CRM state. PRD-72 checks the optional CRM integration input, populated only when the optional CRM wiring exists, to decide which branch to take. If that input is absent or false, the flow stays on the support path.

### FR-003 — BusinessHoursInquiry Intent
Handles questions about operating hours.

Sample utterances:
```
"What are your hours"
"Are you open"
"When do you close"
"What time do you open"
"Are you open on weekends"
"What are your business hours"
```

PRD-72 handles the response by reading the current hours of operation from PRD-12 via a contact flow `CheckHoursOfOperation` block and playing the appropriate message.

### FR-004 — RequestCallback Intent
Handles caller requests to receive a return call rather than waiting.

Sample utterances:
```
"Call me back"
"I would like a callback"
"Schedule a callback"
"Call me later"
"I will wait for a call"
"Have someone call me"
```

PRD-72 must preserve the callback request even when no dedicated callback automation layer is enabled. In lean AI profiles, the intent routes the caller to an agent path with `callback_requested = true` so an agent can handle the request manually. If a future callback workflow is enabled, PRD-72 may instead transfer to that callback-specific flow.

### FR-005 — RepeatOptions Intent
Handles caller requests to hear the menu again.

Sample utterances:
```
"Repeat"
"Say that again"
"What are my options"
"I did not hear that"
"Can you repeat that"
"Start over"
"Go back"
```

PRD-72 loops back to the Lex invocation block, re-prompting the caller.

### FR-006 — EscalateToAgent Intent
Handles any caller request to speak with a human agent immediately. This must have broad utterance coverage — it is the safety valve that ensures no caller is ever trapped in the AI system.

Sample utterances:
```
"Agent"
"Human"
"Operator"
"Representative"
"Talk to someone"
"I want to speak to a person"
"Get me a human"
"I need a real person"
"Transfer me"
"Speak to an agent"
"I want to speak to a real person"
"Connect me to an agent"
```

PRD-72 immediately transfers to the general queue when this intent is matched.

### FR-007 — depends_on Extension in PRD-70
The `aws_lexv2models_bot_version.v1` resource in PRD-70 `depends_on` list must be extended to include all six intent resources from this PRD. This ensures intents are fully saved before the version snapshot is taken. This is accomplished by adding `depends_on` entries in the PRD-70 module that reference the intent resource addresses from PRD-71.

Since PRD-71 is a separate Terraform module from PRD-70, the dependency is expressed at the module level in the root `main.tf`:

```hcl
# Root main.tf — dependency between lex modules
module "lex_intents" {
  source = "./modules/l7-lex-intents"
  depends_on = [module.lex_bot_foundation]
}

module "lex_bot_version_publish" {
  source = "./modules/l7-lex-bot-foundation"
  # Re-apply after intents to trigger bot_version rebuild
  depends_on = [module.lex_intents]
}
```

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### NLU Performance
- Confidence threshold: 0.40 (inherited from PRD-70 bot locale)
- Expected intent recognition accuracy: > 90% for the defined utterance patterns in production
- Low utterance counts are acceptable — Lex generalizes from examples using its underlying language model

### Idempotency
Intent changes require a bot version republish (terraform taint procedure from PRD-70). Adding utterances to an existing intent is a non-destructive change. Removing an intent requires removing its resource and republishing.

---

## 8. ARCHITECTURE

```
Caller speaks to Lex bot
      │
      ├── "Sales" / "Billing" / "Support" / "Tech support"
      │   └── RouteToDepartment (confidence ≥ 0.40)
      │
      ├── "Check my order" / "Account status"
      │   └── CheckAccountStatus (confidence ≥ 0.40)
      │         ├── CRM integration is disabled in the deployment manifest → route to support + "agents will assist"
      │         └── CRM integration is enabled in the deployment manifest  → CRM lookup Lambda (future CRM integration layer)
      │
      ├── "What are your hours" / "Are you open"
      │   └── BusinessHoursInquiry → CheckHoursOfOperation in PRD-72 flow
      │
      ├── "Call me back"
      │   └── RequestCallback → agent-assisted callback handling or future callback flow
      │
      ├── "Repeat" / "Say that again"
      │   └── RepeatOptions → loop back to Lex invocation
      │
      ├── "Agent" / "Human" / "Operator"
      │   └── EscalateToAgent → general queue immediately
      │
      └── No match after 2 attempts
          └── FALLBACK → PRD-73 handler
              "To ensure you receive optimal service, an agent will be on the line shortly.
               Thank you for your patience." → general queue
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `intent_ids` | map(string) | Intent name → intent ID | PRD-72 for flow logic reference |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l7-lex-intents/             # PRD-71
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Complete main.tf

```hcl
# main.tf
# IMPORTANT: After any intent change, run:
#   terraform taint 'module.lex_bot_foundation.aws_lexv2models_bot_version.v1'
#   terraform apply
# This publishes a new bot version and updates the live alias.
# See PRD-70 Section 12 for the full republish procedure.

# ─────────────────────────────────────────────────────────────────
# RouteToDepartment
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_intent" "route_to_department" {
  bot_id      = local.lex_bot_id
  bot_version = "DRAFT"
  locale_id   = local.lex_bot_locale_id
  name        = "RouteToDepartment"

  sample_utterance { utterance = "Sales" }
  sample_utterance { utterance = "I need sales" }
  sample_utterance { utterance = "Connect me to sales" }
  sample_utterance { utterance = "I want to speak to sales" }
  sample_utterance { utterance = "Support" }
  sample_utterance { utterance = "Customer support" }
  sample_utterance { utterance = "I need help with my account" }
  sample_utterance { utterance = "Billing" }
  sample_utterance { utterance = "I have a billing question" }
  sample_utterance { utterance = "I need to talk to billing" }
  sample_utterance { utterance = "Technical support" }
  sample_utterance { utterance = "I have a technical issue" }
  sample_utterance { utterance = "My service is not working" }
  sample_utterance { utterance = "I need technical help" }

  fulfillment_code_hook { enabled = false }
}

# ─────────────────────────────────────────────────────────────────
# CheckAccountStatus
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_intent" "check_account_status" {
  bot_id      = local.lex_bot_id
  bot_version = "DRAFT"
  locale_id   = local.lex_bot_locale_id
  name        = "CheckAccountStatus"

  sample_utterance { utterance = "Check my order" }
  sample_utterance { utterance = "Order status" }
  sample_utterance { utterance = "Where is my order" }
  sample_utterance { utterance = "Track my order" }
  sample_utterance { utterance = "What is my order status" }
  sample_utterance { utterance = "Account status" }
  sample_utterance { utterance = "Check my account" }
  sample_utterance { utterance = "What is my account balance" }
  sample_utterance { utterance = "Service status" }
  sample_utterance { utterance = "I want to check on my order" }
  sample_utterance { utterance = "Can you check my account" }

  fulfillment_code_hook { enabled = false }
}

# ─────────────────────────────────────────────────────────────────
# BusinessHoursInquiry
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_intent" "business_hours_inquiry" {
  bot_id      = local.lex_bot_id
  bot_version = "DRAFT"
  locale_id   = local.lex_bot_locale_id
  name        = "BusinessHoursInquiry"

  sample_utterance { utterance = "What are your hours" }
  sample_utterance { utterance = "Are you open" }
  sample_utterance { utterance = "When do you close" }
  sample_utterance { utterance = "What time do you open" }
  sample_utterance { utterance = "Are you open on weekends" }
  sample_utterance { utterance = "What are your business hours" }
  sample_utterance { utterance = "Is anyone available now" }
  sample_utterance { utterance = "When can I reach someone" }

  fulfillment_code_hook { enabled = false }
}

# ─────────────────────────────────────────────────────────────────
# RequestCallback
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_intent" "request_callback" {
  bot_id      = local.lex_bot_id
  bot_version = "DRAFT"
  locale_id   = local.lex_bot_locale_id
  name        = "RequestCallback"

  sample_utterance { utterance = "Call me back" }
  sample_utterance { utterance = "I would like a callback" }
  sample_utterance { utterance = "Schedule a callback" }
  sample_utterance { utterance = "Call me later" }
  sample_utterance { utterance = "I will wait for a call" }
  sample_utterance { utterance = "Have someone call me" }
  sample_utterance { utterance = "I prefer a callback" }

  fulfillment_code_hook { enabled = false }
}

# ─────────────────────────────────────────────────────────────────
# RepeatOptions
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_intent" "repeat_options" {
  bot_id      = local.lex_bot_id
  bot_version = "DRAFT"
  locale_id   = local.lex_bot_locale_id
  name        = "RepeatOptions"

  sample_utterance { utterance = "Repeat" }
  sample_utterance { utterance = "Say that again" }
  sample_utterance { utterance = "What are my options" }
  sample_utterance { utterance = "I did not hear that" }
  sample_utterance { utterance = "Can you repeat that" }
  sample_utterance { utterance = "Start over" }
  sample_utterance { utterance = "Go back" }

  fulfillment_code_hook { enabled = false }
}

# ─────────────────────────────────────────────────────────────────
# EscalateToAgent — broad coverage is intentional safety valve
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_intent" "escalate_to_agent" {
  bot_id      = local.lex_bot_id
  bot_version = "DRAFT"
  locale_id   = local.lex_bot_locale_id
  name        = "EscalateToAgent"

  sample_utterance { utterance = "Agent" }
  sample_utterance { utterance = "Human" }
  sample_utterance { utterance = "Operator" }
  sample_utterance { utterance = "Representative" }
  sample_utterance { utterance = "Talk to someone" }
  sample_utterance { utterance = "I want to speak to a person" }
  sample_utterance { utterance = "Get me a human" }
  sample_utterance { utterance = "I need a real person" }
  sample_utterance { utterance = "Transfer me" }
  sample_utterance { utterance = "Speak to an agent" }
  sample_utterance { utterance = "I want to speak to a real person" }
  sample_utterance { utterance = "Connect me to an agent" }
  sample_utterance { utterance = "I need to speak with someone" }

  fulfillment_code_hook { enabled = false }
}
```

### Variables

```hcl
# variables.tf
variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "lex_intents_state_key" { type = string }
variable "layer_id"    { type = string; default = "L7" }
variable "prd_id"      { type = string; default = "PRD-71" }
```

### Outputs

```hcl
# outputs.tf
output "intent_ids" {
  description = "Map of intent name to intent ID. Referenced by PRD-72 for flow routing documentation."
  value = {
    RouteToDepartment    = aws_lexv2models_intent.route_to_department.intent_id
    CheckAccountStatus   = aws_lexv2models_intent.check_account_status.intent_id
    BusinessHoursInquiry = aws_lexv2models_intent.business_hours_inquiry.intent_id
    RequestCallback      = aws_lexv2models_intent.request_callback.intent_id
    RepeatOptions        = aws_lexv2models_intent.repeat_options.intent_id
    EscalateToAgent      = aws_lexv2models_intent.escalate_to_agent.intent_id
  }
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

The repo's plan and apply workflows inject the catalog-declared `state_key` during `terraform init`. This module does not hardcode environment names or workspace-derived backend paths.

---

## 10. EVENT SCHEMA

PRD-71 produces no events. Intent outcomes are returned synchronously to the Connect contact flow via the Lex-Connect integration in PRD-72.

### Intent Return Values to Connect

When Lex returns to the Connect flow, these session attributes are available:

| Attribute | Value | Set By |
|---|---|---|
| `x-amz-lex:intent-name` | Intent name string | Lex V2 (automatic) |
| `x-amz-lex:nlu-confidence-score` | Float 0.0-1.0 | Lex V2 (automatic) |
| `x-amz-lex:session-id` | Session UUID | Lex V2 (automatic) |

PRD-72 reads `x-amz-lex:intent-name` from the contact flow `Get customer input` block response and branches accordingly.

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "lex_intents" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.lex_intents_state_key, region = var.aws_region }
}
locals {
  intent_ids = data.terraform_remote_state.lex_intents.outputs.intent_ids
}
```

---

## 12. DATA MODEL

PRD-71 provisions no data stores. Intent state exists within the Lex V2 bot as part of the DRAFT version. Published versions are immutable snapshots.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l7-lex-intents }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l7-lex-intents, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l7-lex-intents
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules/l7-lex-intents-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Intent Change → Bot Republish Procedure

After any intent change is applied via this module's CI/CD pipeline, the bot version must be republished:

```bash
# After PRD-71 apply completes:
terraform taint 'module.lex_bot_foundation.aws_lexv2models_bot_version.v1'
terraform apply -target module.lex_bot_foundation
```

This is a two-step process by design — intents are applied first, then the version is republished. This prevents a half-built intent set from being captured in a published version.

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-71-01: Intent Miss Rate**
- Source: Amazon Lex CloudWatch metrics `MissedUtterances` per intent
- Threshold: > 20% of utterances not matching any intent in a 1-hour period
- Severity: Medium — indicates utterance coverage gaps; add sample utterances

**ALARM-71-02: CheckAccountStatus CRM Branch Error**
- Source: CloudWatch Lambda errors on the CRM lookup Lambda from the future CRM integration layer when `CRM integration enabled in the deployment manifest`
- Severity: High — CRM-dependent callers receiving no account data

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-71-01 | All six intents exist in DRAFT version | `aws lexv2-models list-intents --bot-id {id} --locale-id en_US` returns all six |
| AC-71-02 | RouteToDepartment matches "Sales" and "Billing" | Test bot via Lex console; type "Sales" → RouteToDepartment returned |
| AC-71-03 | EscalateToAgent matches "Agent" and "Get me a human" | Test bot; type "Agent" → EscalateToAgent returned |
| AC-71-04 | CheckAccountStatus matches "Order status" | Test bot; type "Order status" → CheckAccountStatus returned |
| AC-71-05 | All intents have fulfillment_code_hook disabled | `aws lexv2-models describe-intent` for each — fulfillmentCodeHook.enabled = false |
| AC-71-06 | Bot version republish after taint updates live alias | Taint v1; apply; confirm new version in SSM alias ARN |
| AC-71-07 | CRM integration disabled: CheckAccountStatus routes to support | Disable CRM integration; test call saying "order status"; confirm support queue |
| AC-71-08 | Module activation is manifest/catalog controlled | Deployment manifest enables the module and the PRD makes no activation claim based on `deployment_profile` |
| AC-71-09 | Current repo conventions are used | Terraform uses partial `s3` backend, `>= 1.14.0`, and AWS provider `~> 6.0` |
| AC-71-10 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| RouteToDepartment utterances overlap with EscalateToAgent — ambiguous classification | Low | Medium | EscalateToAgent has explicit "I want to speak to a real person" utterances that are distinct. Both use broad phrases but Lex NLU disambiguates by context. Test both in AC-71-02 and AC-71-03. |
| CheckAccountStatus CRM branch invoked before the CRM lookup Lambda exists | High (before CRM integration is enabled) | Medium | Keep the CRM branch disabled until the optional CRM integration is enabled in the environment. |
| "Repeat" utterances conflict with menu digit "0" from DTMF path | Low | Low | DTMF path is separate from Lex path — LEX_INTEGRATION_HOOK routes to Lex or DTMF exclusively, not both simultaneously. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-71-01 | Should additional languages (Spanish, French) be supported? Each requires a separate bot locale and intent set. | Open — en_US only for initial release. Additional locales can be added as separate `aws_lexv2models_bot_locale` and intent resources. |
| OQ-71-02 | Should utterance counts be expanded before prod? The current set is the minimum viable for Lex to generalize. Adding 3-5 more utterances per intent improves accuracy with minimal effort. | Open — recommend expanding EscalateToAgent and RouteToDepartment utterances before prod go-live based on IVR testing in dev. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Six intents. CRM integration toggle on CheckAccountStatus documented — implemented in PRD-72 flow logic. All intents have fulfillment disabled per provider gap pattern from PRD-70. |
| 1.1.0 | 2026-03-30 | — | Reclassified as an optional AI-pack feature. Corrected CRM references to the future CRM integration layer and removed the incorrect dependency on PRD-82. Standardized RequestCallback so it degrades to agent-assisted callback handling when no dedicated callback workflow is enabled. |
| 1.2.0 | 2026-04-05 | — | Added the repo-owned modularity section, removed `deployment_profile` activation drift, normalized backend/state-key conventions, and replaced CRM toggle language with optional environment input language. |
