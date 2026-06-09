# PRD-52 — Whisper Flow Service

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-52 |
| **Version** | 1.1.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 5 — Agent Experience |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-10 (Connect instance ID), PRD-13 (queue IDs), PRD-14 (contact flow framework — whisper hook point) |
| **Blocks** | PRD-53 (Agent Transfer — transfer whisper flows reference this module) |
| **Optional Shared Sinks** | None |
| **Destroy / Retention Posture** | destroyable / no persistent state |
| **Optional** | Yes — optional agent-experience feature |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable whisper support.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l5-whisper-flows`
- `capability_packs`: `["core-telephony"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture", "modules/l1-contact-flow-framework"]`
- `state_key`: `l5-whisper-flows/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `whisper-flows.tfvars`
- `supports_destroy`: `true`
- `activation`: direct `enabled_modules` entry in the deployment manifest until the catalog entry is promoted into the active capability pack chain

### Shared Sink Behavior

- `optional_shared_sinks`: none
- `sink_behavior`: PRD-52 does not require PRD-03 alarm or audit sinks. If operational sinks are added later, they remain optional inputs and must not become activation conditions.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: this module owns Connect flow resources only. It carries no retained data boundary of its own.

### Control Plane Statement

The contract for PRD-52 is the exported whisper flow IDs. Downstream modules consume those outputs through declared inputs or catalog-wired remote state. No cross-module source edit or state surgery is part of the steady-state boundary.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

A whisper flow is the brief experience delivered to an agent immediately before they are connected to a caller. It runs in the moment between the agent accepting the contact and the caller hearing "hello." Without a whisper flow, the agent answers blind — no context about which queue the caller came from, what the caller said in the IVR, or any CRM data about the caller.

This PRD provisions agent whisper flows that provide agents with an audio briefing before connection and sets caller whisper flows that deliver a message to the caller while the agent is being connected. Both whisper flows use contact attributes written by PRD-14 (contact flow framework) and optionally enriched by PRD-82 (CRM contact attribute mapping).

### What Problem It Solves

- Provisions agent whisper flows that announce the queue name, caller intent, and any CRM match to the agent before connection
- Provisions caller whisper flows that play a connecting message to the caller
- Exports whisper flow IDs for downstream queue-transfer and transfer modules
- Reads contact attributes set by the main inbound flow to personalize the whisper message

---

## 4. GOALS

### Goals

- Provision a configurable set of agent whisper flows, one per queue, using contact attributes for personalization
- Provision a standard caller whisper flow (connecting message)
- Export whisper flow IDs for queue-flow and transfer modules that choose to consume them
- Export whisper flow IDs for use in PRD-53 (transfer flows)

### Non-Goals

- This PRD does not implement the CRM data lookup — that is PRD-82
- This PRD does not implement call recording consent announcements — those are handled in the main inbound flow (PRD-14)

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-52-01 | Agent | As an agent, I want to hear which queue and department the caller is from before I connect so I can prepare | Whisper plays "Connecting Sales call" before agent connects |
| US-52-02 | Agent | As an agent, I want to hear if there is CRM data available for the caller so I know if they are a known contact | Whisper includes "Known contact: Jane Smith" when CRM data is available |
| US-52-03 | Caller | As a caller, I want to hear a brief connecting message rather than silence while the agent is connecting | Caller hears "Please hold while we connect your call" |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Agent Whisper Flows
Provision one agent whisper flow per queue using contact attributes. The whisper must play the queue name and optionally the CRM contact name if the `CRMContactName` contact attribute is set:

```
"Connecting {QueueName} call.
[If CRMContactName is set: Known contact: {CRMContactName}.]
Please wait."
```

Contact attributes read: `target_queue_name`, `CRMContactName` (set by PRD-82 if available).

### FR-002 — Caller Whisper Flow
Provision a single caller whisper flow that plays: "Please hold while we connect your call." This applies to all queues uniformly.

### FR-003 — Flow Association
The agent and caller whisper flows must be consumable by the queue transfer module in PRD-14 and by PRD-53. The contract for this PRD is the exported whisper flow IDs, not a required edit to PRD-14 source files.

Downstream modules consume the outputs through their own declared module inputs or remote-state wiring. This PRD must not rely on manual state surgery or cross-module source edits as the steady-state boundary.

### FR-004 — Configurable Whisper Prompts
All whisper prompt text must be configurable via the `whisper_prompts` variable, following the same pattern as `flow_prompts` in PRD-14.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Latency
Whisper flows must complete within 3 seconds to avoid noticeable delay between agent acceptance and caller connection. Whisper flows must not invoke Lambda functions synchronously — all personalization data must come from contact attributes already set by the time the whisper executes.

---

## 8. ARCHITECTURE

```
Agent accepts contact
      │
      ▼
Agent Whisper Flow
      │
      ├── Read contact attribute: target_queue_name
      ├── Read contact attribute: CRMContactName (optional)
      ├── Play: "Connecting {queue_name} call. [Known contact: {name}.]"
      └── Connect agent to caller
             │
             ▼
      Caller Whisper Flow
             │
             └── Play: "Please hold while we connect your call."
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `agent_whisper_flow_ids` | map(string) | Queue key → agent whisper flow ID | Downstream queue-transfer and transfer modules |
| `caller_whisper_flow_id` | string | Caller whisper flow ID | Downstream queue-transfer and transfer modules |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l5-whisper-flows/           # PRD-52
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── flows/
            ├── agent-whisper.json.tftpl
            └── caller-whisper.json.tftpl
```

### Key Resources Declared

```hcl
# main.tf

locals {
  queue_keys = ["general", "sales", "customer-support", "billing", "technical-support", "escalations"]
}

resource "aws_connect_contact_flow" "agent_whisper" {
  for_each    = toset(local.queue_keys)
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-AgentWhisper-${title(replace(each.key, "-", ""))}"
  description = "Agent whisper for ${each.key} queue. Announces queue and CRM data before connection."
  type        = "AGENT_WHISPER"

  content = templatefile("${path.module}/flows/agent-whisper.json.tftpl", {
    queue_name        = each.key
    tts_voice_id      = var.tts_voice_id
    tts_language_code = var.tts_language_code
    prompt_connecting = var.whisper_prompts["connecting"]
    prompt_known      = var.whisper_prompts["known_contact"]
  })

  tags = { Layer = "L5", PRD = "PRD-52", Queue = each.key }
}

resource "aws_connect_contact_flow" "caller_whisper" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-CallerWhisper-Standard"
  description = "Standard caller whisper — plays connecting message to caller."
  type        = "CUSTOMER_WHISPER"

  content = templatefile("${path.module}/flows/caller-whisper.json.tftpl", {
    tts_voice_id      = var.tts_voice_id
    tts_language_code = var.tts_language_code
    prompt_hold       = var.whisper_prompts["hold_message"]
  })

  tags = { Layer = "L5", PRD = "PRD-52" }
}
```

### Agent Whisper Flow Template (Structural Outline)

```json
// flows/agent-whisper.json.tftpl
{
  "Version": "2019-10-30",
  "StartAction": "set-voice",
  "Actions": [
    {
      "Identifier": "set-voice",
      "Type": "UpdateContactTTSVoice",
      "Parameters": { "TextToSpeechVoice": "${tts_voice_id}" },
      "Transitions": { "NextAction": "check-crm-name" }
    },
    {
      "Identifier": "check-crm-name",
      "Type": "CheckAttribute",
      "Parameters": {
        "Attribute": "CRMContactName",
        "Type": "User Defined",
        "Conditions": [
          { "NextAction": "play-with-crm", "Condition": { "Operator": "NotEmpty" } }
        ]
      },
      "Transitions": { "NextAction": "play-without-crm" }
    },
    {
      "Identifier": "play-with-crm",
      "Type": "MessageParticipant",
      "Parameters": {
        "SSML": true,
        "Text": "<speak>${prompt_connecting} <emphasis level='moderate'>$.Attributes.target_queue_name</emphasis> ${prompt_known} $.Attributes.CRMContactName.</speak>"
      },
      "Transitions": { "NextAction": "end" }
    },
    {
      "Identifier": "play-without-crm",
      "Type": "MessageParticipant",
      "Parameters": {
        "Text": "${prompt_connecting} $.Attributes.target_queue_name call.",
        "TextToSpeechType": "text"
      },
      "Transitions": { "NextAction": "end" }
    },
    {
      "Identifier": "end",
      "Type": "EndFlowExecution",
      "Parameters": {},
      "Transitions": {}
    }
  ]
}
```

### Variables

```hcl
variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "whisper_flows_state_key" { type = string }
variable "tts_voice_id" { type = string; default = "Joanna" }
variable "tts_language_code" { type = string; default = "en-US" }
variable "layer_id"    { type = string; default = "L5" }
variable "prd_id"      { type = string; default = "PRD-52" }

variable "whisper_prompts" {
  type = map(string)
  default = {
    connecting    = "Connecting"
    known_contact = "Known contact:"
    hold_message  = "Please hold while we connect your call."
  }
}
```

### Outputs

```hcl
output "agent_whisper_flow_ids" {
  value = { for k, v in aws_connect_contact_flow.agent_whisper : k => v.id }
}
output "caller_whisper_flow_id" {
  value = aws_connect_contact_flow.caller_whisper.id
}
```

### Backend

```hcl
terraform {
  required_version = ">= 1.14.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.0" } }
  backend "s3" {}
}
```

The repo's plan and apply workflows inject the catalog-declared backend key for this module during `terraform init`. The module does not hardcode environment names, workspace fragments, or backend key prefixes.

---

## 10. EVENT SCHEMA

PRD-52 produces no EventBridge events.

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "whisper_flows" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.whisper_flows_state_key, region = var.aws_region }
}
locals {
  agent_whisper_flow_ids = data.terraform_remote_state.whisper_flows.outputs.agent_whisper_flow_ids
  caller_whisper_flow_id = data.terraform_remote_state.whisper_flows.outputs.caller_whisper_flow_id
}
```

The consumer state key is catalog-driven, not workspace-derived. Downstream modules that opt into whisper support should read the exported outputs through their own declared inputs or remote-state wiring rather than requiring a source edit to PRD-14.

---

## 12. DATA MODEL

PRD-52 provisions no data stores.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l5-whisper-flows }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l5-whisper-flows, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l5-whisper-flows
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules/l5-whisper-flows-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-52-01: Whisper Flow Fatal Error**
- Metric: `ContactFlowFatalErrors` filtered to whisper flow ARNs
- Severity: High — agent connecting without context briefing

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-52-01 | Agent whisper flows exist for all six queues | `aws connect list-contact-flows --instance-id` filtered to AGENT_WHISPER type |
| AC-52-02 | Caller whisper flow exists | Same query filtered to CUSTOMER_WHISPER type |
| AC-52-03 | Test call plays agent whisper before connection | Place test call; agent hears queue name announcement before caller connects |
| AC-52-04 | CRM name announced when CRMContactName attribute is set | Set CRMContactName attribute in test flow; confirm name announced in whisper |
| AC-52-05 | Module activation is manifest/catalog controlled | Deployment manifest enables the module and the PRD makes no activation claim based on `deployment_profile` |
| AC-52-06 | Current repo conventions are used | Terraform uses partial `s3` backend, `>= 1.14.0`, and AWS provider `~> 6.0` |
| AC-52-07 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Whisper flow exceeds 3 second duration — audible delay | Low | Medium | Prompts kept short. No Lambda invocations. Contact attribute reads are near-instant. |
| CRMContactName attribute not set before whisper executes | High (before PRD-82) | Low | Whisper checks attribute with CheckAttribute block — gracefully omits name if not set. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-52-01 | Should the whisper announce the caller's phone number to the agent? Some agents find this useful for recognition. | Open — can be added to the whisper template by adding a MessageParticipant block reading `$.CustomerEndpoint.Address`. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Six agent whisper flows and one caller whisper flow. CRM name integration hook for PRD-82. |
| 1.1.0 | 2026-04-05 | — | Added the repo-owned modularity section, removed cross-module source-edit coupling to PRD-14, normalized backend/state-key conventions, and made the output contract manifest/catalog aligned. |
