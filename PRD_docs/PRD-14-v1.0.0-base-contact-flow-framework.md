# PRD-14 — Base Contact Flow Framework

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-14 |
| **Version** | 1.2.0 |
| **Status** | Target Design / Intended Full Implementation |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-10 (Connect instance ID), PRD-11 (phone number ARNs, IDs), PRD-12 (hours of operation IDs, daily closure status table, emergency closure SSM parameter), PRD-13 (queue IDs, ARNs, queue_config, system_queue_id) |
| **Blocks** | PRD-50 (Agent Experience — whisper flows reference this module), PRD-52 (Whisper Flows), PRD-10a (Voicemail — overflow routing), PRD-72 (Connect-Lex Integration — Lex hook defined here) |
| **Optional** | No |

### Intended Implementation Note

This PRD describes the intended full working implementation of PRD-14.

It should be interpreted as the target-state contract for when implementation resumes:
- main inbound flow
- after-hours module
- queue-transfer module
- error-handler flow
- closure-check Lambda integration
- phone-number association workflow
- ALARM-14-02 IVR no-input alarm

Repo-alignment rules for the intended implementation:
- environment config follows the repo-standard environment-folder model
- local backend config is read from the external bootstrap artifact directory, not `modules/bootstrap/backend-*.hcl`
- downstream local runs use named workspaces: `dev`, `staging`, `prod`
- CI/CD uses the shared reusable workflows with environment-aware domain tfvars loading
- PRD-14 remains deployable without PRD-03; any alarm sink or audit-owned integration must be passed explicitly as an optional input rather than assumed through shared remote state

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
| `path` | `modules/l1-contact-flow-framework` |
| `capability_packs` | `["core-telephony"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers", "modules/l1-hours-of-operation", "modules/l1-queue-architecture"]` |
| `state_key` | `l1-contact-flow-framework/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `contact-flows.tfvars` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 platform alert topic | **optional input** — ALARM-14-02 publishes to the platform alert topic only when `alarm_action_arns` is supplied. PRD-14 remains deployable without PRD-03. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `destroyable` |
| `retention_notes` | Contact flows are configuration resources. Flows can be replaced or removed without data loss. Active calls in progress may be affected during flow replacement. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Contact flows are the dial plan of Amazon Connect. Without a contact flow associated with an inbound phone number, callers receive a default AWS error message. This PRD provisions the foundational contact flows that give the platform its call routing behavior — the logic that every inbound caller passes through from the moment their call connects to the moment they reach an agent or overflow destination.

This PRD is designed around two principles. First, contact flows are code — they are defined as JSON in version-controlled files and managed by Terraform, not hand-built in the Connect visual designer. Second, the flows are built with explicit integration hooks — named contact attributes and flow module boundaries that allow PRD-72 (Lex integration) and PRD-10a (voicemail) to plug in cleanly without requiring changes to the flows defined here.

### What Problem It Solves

- Provisions the main inbound contact flow that every inbound caller passes through
- Implements a hybrid DTMF/voice input menu using Connect's native `Get customer input` block — callers can press a key or speak a number or department name without requiring Lex at this stage
- Implements time-based routing using the hours of operation resources from PRD-12
- Implements the after-hours handling path: message → callback offer → voicemail
- Associates each phone number from PRD-11 with an appropriate contact flow
- Establishes module flows for queue transfer, error handling, and the Lex integration hook point
- Provides a flow template pattern so new contact flows can be added via tfvars without code changes

### How It Fits the Overall Architecture

PRD-14 is the final piece of the telephony core Layer 1. Once this PRD is applied, the platform is end-to-end functional: callers can dial an inbound number, navigate an IVR, reach a queue, and be connected to an agent. All subsequent layers (voicemail, AI, CRM, observability) plug into this foundation without modifying it.

### Lex Integration Note

The main inbound flow uses Connect's native `Get customer input` block with both DTMF and speech input enabled. This provides voice recognition for digits and basic department names without requiring Lex. PRD-72 (Connect-Lex Integration) will replace this block with a full Lex V2 bot invocation that provides natural language understanding, intent classification, and slot filling. The replacement point is a named contact attribute `$.Attributes.lex_integration_enabled` checked at flow entry — when PRD-72 sets this attribute to `true` via a Lambda pre-hook, the flow branches to the Lex path. When it is absent or `false`, the flow uses the native DTMF/speech block. This means PRD-72 is a pure addition — it does not require this flow to be rewritten.

### Holiday / Emergency Closure Integration Note

PRD-12 already provisions the complete holiday infrastructure: a DynamoDB `daily_closure_status` table pre-computed by a scheduled Lambda, and an SSM `emergency_closure` parameter for real-time closures. PRD-14 **consumes** these outputs — it does not duplicate the Lambda or SSM parameter. The contact flow reads the pre-computed closure status from PRD-12's DynamoDB table via a Connect Lambda invocation (a lightweight `GetItem` call) and checks the emergency closure SSM parameter. Both checks are fail-open: if the read fails, the flow continues to the IVR menu.

---

## 4. GOALS

### Goals

- Provision the main inbound contact flow with hybrid DTMF/voice menu routing
- Implement hours of operation check at flow entry with after-hours handling path
- Implement after-hours path: play message → offer callback → route to voicemail
- Implement queue transfer flow module used by all department routing branches
- Implement error handling flow that gracefully recovers from system errors
- Associate all phone numbers from PRD-11 with appropriate contact flows
- Define a clear Lex integration hook point for PRD-72 to activate without flow modification
- Provision a contact flow template pattern for adding new flows via tfvars
- Export contact flow IDs for downstream PRDs (whisper flows, Lex integration, voicemail)

### Non-Goals

- This PRD does not implement Lex V2 bot invocation — that is PRD-72
- This PRD does not implement voicemail recording logic — that is PRD-10a
- This PRD does not implement whisper flows — that is PRD-52
- This PRD does not implement agent-to-agent transfer flows — that is PRD-53
- This PRD does not implement callback queuing — that is PRD-54
- This PRD does not implement the AI auto-attendant intent logic — that is PRD-71
- This PRD does not provision holiday status infrastructure — that is PRD-12

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Provisions contact flows via Terraform. Never builds flows manually in the Connect visual designer after initial provisioning.

**Caller** — Dials the inbound number, hears a greeting and menu, presses a key or speaks a department name, is routed to the appropriate queue.

**Operations Manager** — Reviews the flow logic for IVR prompt accuracy and routing correctness. Requests prompt changes via pull request to the flow JSON files.

**Connect Administrator** — Uses the Connect visual designer to view (not edit) flow diagrams for operational reference.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-14-01 | Caller | As a caller, I want to hear a greeting and then be told my options so I know how to reach the right department | Greeting plays within 2 seconds of call connect; menu options presented clearly |
| US-14-02 | Caller | As a caller, I want to press a number or say the department name to be routed | DTMF input and speech input both work; both route to the same queue |
| US-14-03 | Caller | As a caller calling after hours, I want to know the office is closed, be offered a callback or voicemail | After-hours path plays message, offers callback (press 1) or voicemail (press 2 or silence) |
| US-14-04 | Platform Engineer | As the platform engineer, I want all flows defined as JSON files in version control so that flow changes go through PR review | Flow JSON files in repository; no flow modified via Connect console |
| US-14-05 | Platform Engineer | As the platform engineer, I want the Lex hook point defined now so that PRD-72 requires no flow changes | `lex_integration_enabled` attribute check present in main flow as a branch point |
| US-14-06 | Operations Manager | As the operations manager, I want to change an IVR prompt by editing a text string in a file so that prompt updates are fast and reviewable | Prompt text defined in `flow_prompts` variable; flow JSON references the variable |
| US-14-07 | Platform Engineer | As the platform engineer, I want each phone number associated with a contact flow so that all numbers are functional after this PRD is applied | All PRD-11 numbers associated with flows |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Main Inbound Contact Flow
The system must provision a contact flow named `{org_name}-Main-Inbound` of type `CONTACT_FLOW`. This flow is the primary entry point for all inbound calls arriving on the main DID and toll-free numbers. The flow must implement the following logic sequence:

```
1. Set logging behavior (enable contact flow logging to CloudWatch)
2. Set voice (Amazon Polly — language and voice configurable via variable)
3. Check contact attribute: lex_integration_enabled
   → If true: branch to Lex Integration Hook Block (reserved block — populated by PRD-72)
   → If false or absent: continue to DTMF/Voice menu
4. Check hours of operation (using PRD-12 standard-business schedule)
   → If closed: branch to after-hours flow
   → If open: continue to closure checks
4a. Check emergency closure (read PRD-12 emergency_closure SSM parameter)
   → If active: branch to after-hours flow
   → If not active or read error: continue to holiday check (fail-open)
4b. Check holiday status (read PRD-12 daily_closure_status DynamoDB table via Lambda)
   → If closure: branch to after-hours flow
   → If not closure or read error: continue to IVR menu (fail-open)
5. Play greeting prompt
6. Get customer input (DTMF + speech, timeout 8 seconds, max retries 2)
   → 1 or "Sales":             Transfer to queue: sales
   → 2 or "Support":           Transfer to queue: customer-support
   → 3 or "Billing":           Transfer to queue: billing
   → 4 or "Technical Support": Transfer to queue: technical-support
   → 0 or "Repeat":            Loop back to step 5
   → No input / timeout:       Transfer to queue: general
   → Error:                    Branch to error flow
7. Transfer to Queue block (with queue-specific wait treatment flow)
8. On queue overflow (wait > max_wait_minutes): branch to overflow path
   → VOICEMAIL: Transfer to voicemail flow (PRD-10a hook)
   → CALLBACK:  Transfer to callback flow (PRD-54 hook)
   → DISCONNECT: Play message and disconnect
```

### FR-002 — After-Hours Flow Module
The system must provision a contact flow module named `{org_name}-After-Hours-Module` of type `CONTACT_FLOW_MODULE`. This module is invoked by the main inbound flow when the hours of operation check determines the office is closed. The module must:

1. Play the after-hours message prompt
2. Offer options: press 1 for a callback, press 2 for voicemail, or stay on the line for voicemail
3. On press 1: set contact attribute `after_hours_action = CALLBACK`, transfer to PRD-54 hook
4. On press 2 or silence or timeout: set contact attribute `after_hours_action = VOICEMAIL`, transfer to PRD-10a hook
5. On error: play apology message and disconnect

### FR-003 — Queue Transfer Flow Module
The system must provision a contact flow module named `{org_name}-Queue-Transfer-Module` of type `CONTACT_FLOW_MODULE`. This module is invoked by every department routing branch in the main flow. It handles the queue wait experience and overflow detection. The module must:

1. Set queue (passed as contact attribute `target_queue_id`)
2. Play queue position and estimated wait time (using Connect's native `Get queue metrics` block)
3. Start queue wait treatment (hold music via default Connect prompt)
4. Check wait time against queue's `max_wait_minutes` threshold
5. On threshold exceeded: read `overflow_action` from contact attribute and branch accordingly

### FR-004 — Error Handling Flow
The system must provision a contact flow named `{org_name}-Error-Handler` of type `CONTACT_FLOW`. This flow handles system errors encountered in any other flow. It must play an apology message, attempt to transfer the caller to the general queue, and if that fails, disconnect gracefully.

### FR-005 — Lex Integration Hook Block
Within the main inbound flow, a dedicated block must be reserved and labeled `LEX_INTEGRATION_HOOK`. This block checks the contact attribute `lex_integration_enabled`. When PRD-72 is applied, it will deploy a Lambda function that sets this attribute to `true` before the flow begins, causing the flow to branch into the Lex path. The Lex path block is pre-wired in the flow JSON as a no-op branch that transfers to the general queue — PRD-72 replaces this no-op with the actual Lex invocation block by updating the flow JSON.

### FR-006 — Phone Number Association
Every phone number exported by PRD-11 must be associated with an appropriate contact flow. The association is defined in the `number_flow_associations` variable — a map of phone number key to contact flow key. By default, all numbers are associated with the main inbound flow. Specific numbers can be mapped to dedicated flows (e.g., a direct-dial sales number that bypasses the IVR).

Phone number association uses the `AssociatePhoneNumberContactFlow` API via an `aws_connect_phone_number_contact_flow_association` approach. Since the AWS Terraform provider does not expose a native resource for this association, PRD-14 provisions an `aws_lambda_function` that performs the association via the Connect SDK. This Lambda is triggered by a `terraform_data` resource on each apply when the association mapping changes.

### FR-007 — Flow Prompt Variables
All customer-facing prompt text must be defined in a `flow_prompts` variable. The contact flow JSON must reference these strings rather than hard-coding them. This allows prompt changes without modifying flow logic. Prompts must support text-to-speech (Amazon Polly SSML) and plain text.

### FR-008 — Contact Flow JSON as Files
Contact flow definitions must be stored as JSON files in the module's `flows/` directory. The `aws_connect_contact_flow` resource must reference these files via `templatefile()` function calls, passing the relevant variable values as template parameters. Flow files must not contain hard-coded resource IDs — all IDs must be injected via template variables at apply time.

### FR-009 — Voice Configuration
The TTS voice used in all prompts must be configurable via the `tts_voice_id` variable (default: `Joanna`) and `tts_language_code` variable (default: `en-US`). These values are injected into the flow JSON template at apply time.

### FR-010 — Closure Status Check Lambda
The system must provision a Lambda function that reads the pre-computed daily closure status from PRD-12's `daily_closure_status` DynamoDB table and returns the result to the contact flow. This is a lightweight per-call Lambda invocation (single `GetItem`) with sub-100ms execution time. The Lambda is invoked by the main inbound contact flow via Connect's native `InvokeLambdaFunction` block.

This Lambda also reads the emergency closure SSM parameter from PRD-12. The emergency closure check takes priority: if the emergency closure is active, the Lambda returns `is_closure: true` regardless of the daily status table.

**IAM:** The Lambda must have `dynamodb:GetItem` on the daily closure status table, `ssm:GetParameter` on the emergency closure parameter path, `kms:Decrypt` on the environment KMS key, and CloudWatch Logs permissions. The execution role must be attached to the PRD-02 permission boundary.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
Contact flows are evaluated by Connect in real time. Flow availability is governed by the Connect instance SLA (99.99%). Flow evaluation adds less than 100ms latency to call setup.

### Latency

| Step | Target |
|---|---|
| Greeting starts playing after call connects | < 2 seconds |
| DTMF input recognition | < 500ms |
| Speech input recognition (native, no Lex) | < 1.5 seconds |
| Queue transfer completion | < 3 seconds |
| Closure status Lambda invocation | < 100ms |

### Resilience
- All flow branches must have explicit error handling — no unhandled error paths
- Every `Get customer input` block must have timeout and retry logic
- Every Lambda invoke block (when PRD-72 adds Lambda) must have error branches that fall back to DTMF-only mode
- The error handling flow (FR-004) must be reachable from every flow without a circular dependency
- Closure status check failure is fail-open — callers proceed to the IVR menu

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 12.3 | Call routing logic version-controlled | Flow JSON in Git, PR history |
| SOC 2 CC6.1 | System component behavior documented | Flow diagrams in this PRD |
| SOC 2 CC7.2 | Contact flow errors logged | CloudWatch contact flow logs (PRD-10) |

---

## 8. ARCHITECTURE

### Main Inbound Flow Diagram

```
CALL ARRIVES
     │
     ▼
Set Logging + Voice
     │
     ▼
Check: lex_integration_enabled == true?
     │
     ├── YES ──► LEX_INTEGRATION_HOOK (no-op → general queue until PRD-72)
     │
     └── NO ──►
               │
               ▼
          Check Hours of Operation (PRD-12: standard-business)
               │
               ├── CLOSED ──► After-Hours Module
               │                    │
               │               Play after-hours message
               │                    │
               │               Press 1: CALLBACK hook (PRD-54)
               │               Press 2 / silence: VOICEMAIL hook (PRD-10a)
               │
               └── OPEN ──►
                            │
                            ▼
                    Invoke Closure Status Lambda (FR-010)
                    Checks: 1. Emergency closure (SSM)  2. Daily closure (DynamoDB)
                            │
                            ├── CLOSURE ──► After-Hours Module
                            │
                            └── NOT CLOSURE / ERROR (fail-open) ──►
                                              │
                                              ▼
                                         Play Greeting Prompt
                            │
                            ▼
                  Get Customer Input (DTMF + Speech)
                  Timeout: 8s | Retries: 2
                            │
               ┌────────────┼──────────────┬──────────────┬───────────┐
               │            │              │              │           │
               ▼            ▼              ▼              ▼           ▼
            1/Sales    2/Support      3/Billing    4/TechSupport   0/Repeat
               │            │              │              │           │
               ▼            ▼              ▼              ▼           └──► Loop
          Queue-Transfer-Module (target_queue_id set per branch)
               │
               ├── Waiting ──► Hold music + position announcement
               │
               ├── Overflow ──► Read overflow_action from contact attribute
               │                    ├── VOICEMAIL ──► PRD-10a hook
               │                    ├── CALLBACK  ──► PRD-54 hook
               │                    └── DISCONNECT ──► Goodbye + End
               │
               └── Agent connected ──► Whisper flow (PRD-52) ──► Live call
```

### Integration Hook Points

| Hook Name | Location in Flow | Activated By | Behavior Until Activated |
|---|---|---|---|
| `LEX_INTEGRATION_HOOK` | After voice setup, before hours check | PRD-72 | No-op — falls through to DTMF menu |
| `VOICEMAIL_HOOK` | Overflow path and after-hours path | PRD-10a | Plays "voicemail unavailable" message and disconnects |
| `CALLBACK_HOOK` | Overflow path and after-hours path | PRD-54 | Falls back to VOICEMAIL_HOOK |
| `WHISPER_FLOW_HOOK` | Transfer to Queue block | PRD-52 | Uses Connect default whisper flow |

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| Connect instance (PRD-10) | Inbound | Instance ID for all flow resources |
| Phone numbers (PRD-11) | Inbound | Number ARNs and IDs for flow associations |
| Hours of operation (PRD-12) | Inbound | Schedule IDs for CheckHoursOfOperation blocks |
| Daily closure status table (PRD-12) | Inbound | Pre-computed closure status read by closure check Lambda |
| Emergency closure SSM parameter (PRD-12) | Inbound | Real-time emergency closure flag read by closure check Lambda |
| Queues (PRD-13) | Inbound | Queue IDs and ARNs for Transfer to Queue blocks |
| Account baseline (PRD-02) | Inbound | KMS key ARN, permission boundary ARN |
| Audit pipeline (PRD-03) | Inbound | Platform alert SNS topic ARN for alarms |
| PRD-52 (Whisper Flows) | Future inbound | Will update whisper flow associations |
| PRD-54 (Callback) | Future inbound | Will activate CALLBACK_HOOK |
| PRD-10a (Voicemail Solution) | Future inbound | Will activate VOICEMAIL_HOOK |
| PRD-72 (Lex Integration) | Future inbound | Will activate LEX_INTEGRATION_HOOK |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `main_inbound_flow_id` | string | Main inbound contact flow ID | PRD-11 association, PRD-72 |
| `main_inbound_flow_arn` | string | Main inbound contact flow ARN | PRD-52, PRD-72 |
| `after_hours_module_id` | string | After-hours module ID | PRD-10a, PRD-54 |
| `queue_transfer_module_id` | string | Queue transfer module ID | PRD-52, PRD-53 |
| `error_handler_flow_id` | string | Error handler flow ID | All downstream flows |
| `contact_flow_ids` | map(string) | All flow IDs keyed by flow name | PRD-52, PRD-72, PRD-91 cutover operations |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
├── environments/
│   └── contact-flows/
│       └── dev.tfvars                       # flow_prompts, number_flow_associations, tts config
└── modules/
    └── l1-contact-flow-framework/  # PRD-14
        ├── backend.tf
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── locals.tf
        ├── cloudwatch.tf               # ALARM-14-02 (IVR No Input Spike)
        ├── closure-check.tf             # Lambda that reads PRD-12 closure status (FR-010)
        ├── phone-associations.tf        # Phone number → flow associations (FR-006)
        ├── flows/
        │   ├── main-inbound.json.tftpl       # Main inbound flow template
        │   ├── after-hours-module.json.tftpl  # After-hours module template
        │   ├── queue-transfer-module.json.tftpl
        │   └── error-handler.json.tftpl
        └── lambda/
            ├── closure-check/
            │   └── closure_check.py          # Reads PRD-12 daily status + emergency closure
            └── phone-association/
                └── phone_association.py      # Associates phone numbers with contact flows
```

### Module-Scoped tfvars

PRD-14 follows the repo-standard environment-folder pattern. Platform-wide variables (`org_name`, `aws_region`, `state_bucket`, `deployment_profile`) come from `environments/<env>/global.tfvars`. Module-specific configuration comes from `environments/<env>/contact-flows.tfvars`.

```hcl
# environments/dev/contact-flows.tfvars
# ---------------------------------------------------------------
# Contact Flow Configuration — dev environment
# ---------------------------------------------------------------
# HOW TO CHANGE IVR PROMPTS
#   1. Edit the flow_prompts map below — change the text string.
#   2. Open a PR. CI will plan the change and show the prompt diff.
#   3. Merge. The apply updates the contact flow in Connect immediately.
#      No flow logic change — only the TTS text changes.
#
# HOW TO CHANGE PHONE NUMBER → FLOW ASSOCIATIONS
#   1. Edit the number_flow_associations map below.
#   2. Each key must match a phone number key in PRD-11.
#   3. Each value must match a contact flow key in this module
#      (currently: main-inbound, error-handler).
#
# HOW TO CHANGE TTS VOICE
#   Set tts_voice_id and tts_language_code below. Available voices:
#   https://docs.aws.amazon.com/polly/latest/dg/voicelist.html
#   Neural voices (e.g. "Joanna" with engine "neural") are higher quality
#   but higher cost. Standard voices are used by default.
#
# FIELD REFERENCE — flow_prompts
#   Key                    Where it plays
#   greeting               First thing the caller hears after call connects
#   main_menu              IVR menu options (DTMF + speech)
#   after_hours            Played when office is closed (hours check or holiday)
#   callback_offer         Played after after_hours message
#   queue_wait             Played while caller waits in queue
#   overflow               Played when queue overflow threshold is exceeded
#   error                  Played on system error
#   goodbye                Played before disconnect
#   voicemail_unavailable  Played when voicemail hook is not yet active (pre-PRD-10a)
# ---------------------------------------------------------------

tts_voice_id      = "Joanna"
tts_language_code = "en-US"

flow_prompts = {
  greeting = "Thank you for calling. Please listen carefully as our menu options have recently changed."

  main_menu = "For Sales, press 1 or say Sales. For Customer Support, press 2 or say Support. For Billing, press 3 or say Billing. For Technical Support, press 4 or say Technical Support. To repeat these options, press 0 or say Repeat."

  after_hours = "Thank you for calling. Our office is currently closed. Our business hours are Monday through Friday, 8am to 6pm Eastern Time."

  callback_offer = "To receive a callback when we reopen, press 1. To leave a voicemail, press 2 or stay on the line."

  queue_wait = "All of our agents are currently assisting other customers. Your call is important to us. Please continue to hold."

  overflow = "We are currently experiencing higher than normal call volume. We apologize for the wait."

  error = "We apologize, but we are experiencing a technical difficulty. Please try your call again in a few minutes."

  goodbye = "Thank you for calling. Goodbye."

  voicemail_unavailable = "We are unable to take your voicemail at this time. Please call back during business hours. Thank you."
}

number_flow_associations = {
  main-inbound = "main-inbound"
  # Uncomment as numbers are provisioned in PRD-11:
  # tollfree-main = "main-inbound"
  # sales         = "main-inbound"
  # support       = "main-inbound"
  # billing       = "main-inbound"
}
```

### Key Resources Declared

```hcl
# backend.tf

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

```hcl
# main.tf

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

data "terraform_remote_state" "connect_instance" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-connect-instance/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "hours_of_operation" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-hours-of-operation/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "queue_architecture" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-queue-architecture/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "phone_numbers" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-phone-numbers/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "audit_pipeline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-audit-pipeline/terraform.tfstate"
    region = var.aws_region
  }
}

# Main inbound contact flow
resource "aws_connect_contact_flow" "main_inbound" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Main-Inbound"
  description = "Primary inbound flow. Hybrid DTMF/voice menu. Hours check. After-hours handling. Lex hook point for PRD-72."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/main-inbound.json.tftpl", {
    instance_id                   = local.connect_instance_id
    org_name                      = var.org_name
    tts_voice_id                  = var.tts_voice_id
    tts_language_code             = var.tts_language_code
    hours_of_operation_id         = local.hours_of_operation_ids["standard-business"]
    queue_sales_id                = local.queue_ids["sales"]
    queue_support_id              = local.queue_ids["customer-support"]
    queue_billing_id              = local.queue_ids["billing"]
    queue_tech_id                 = local.queue_ids["technical-support"]
    queue_general_id              = local.queue_ids["general"]
    after_hours_module_id         = aws_connect_contact_flow_module.after_hours.id
    queue_transfer_module_id      = aws_connect_contact_flow_module.queue_transfer.id
    error_handler_flow_id         = aws_connect_contact_flow.error_handler.id
    closure_check_lambda_arn      = aws_lambda_function.closure_check.arn
    prompt_greeting               = var.flow_prompts["greeting"]
    prompt_menu                   = var.flow_prompts["main_menu"]
    prompt_after_hours            = var.flow_prompts["after_hours"]
    prompt_error                  = var.flow_prompts["error"]
    prompt_goodbye                = var.flow_prompts["goodbye"]
    max_wait_sales                = local.queue_config["sales"].max_wait_minutes
    max_wait_support              = local.queue_config["customer-support"].max_wait_minutes
    max_wait_billing              = local.queue_config["billing"].max_wait_minutes
    max_wait_tech                 = local.queue_config["technical-support"].max_wait_minutes
    overflow_sales                = local.queue_config["sales"].overflow_action
    overflow_support              = local.queue_config["customer-support"].overflow_action
    overflow_billing              = local.queue_config["billing"].overflow_action
    overflow_tech                 = local.queue_config["technical-support"].overflow_action
  })

  tags = merge(local.common_tags, {
    FlowType = "main-inbound"
  })
}

# After-hours module
resource "aws_connect_contact_flow_module" "after_hours" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-After-Hours-Module"
  description = "After-hours handling: message, callback offer, voicemail routing."

  content = templatefile("${path.module}/flows/after-hours-module.json.tftpl", {
    instance_id           = local.connect_instance_id
    tts_voice_id          = var.tts_voice_id
    tts_language_code     = var.tts_language_code
    prompt_after_hours    = var.flow_prompts["after_hours"]
    prompt_callback_offer = var.flow_prompts["callback_offer"]
    system_queue_id       = local.system_queue_id
  })

  tags = merge(local.common_tags, {
    FlowType = "after-hours-module"
  })
}

# Queue transfer module
resource "aws_connect_contact_flow_module" "queue_transfer" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Queue-Transfer-Module"
  description = "Handles queue wait experience, overflow detection, and transfer logic."

  content = templatefile("${path.module}/flows/queue-transfer-module.json.tftpl", {
    instance_id       = local.connect_instance_id
    tts_voice_id      = var.tts_voice_id
    tts_language_code = var.tts_language_code
    prompt_queue_wait = var.flow_prompts["queue_wait"]
    prompt_overflow   = var.flow_prompts["overflow"]
  })

  tags = merge(local.common_tags, {
    FlowType = "queue-transfer-module"
  })
}

# Error handler flow
resource "aws_connect_contact_flow" "error_handler" {
  instance_id = local.connect_instance_id
  name        = "${var.org_name}-Error-Handler"
  description = "Global error handler. Attempts transfer to general queue. Falls back to disconnect."
  type        = "CONTACT_FLOW"

  content = templatefile("${path.module}/flows/error-handler.json.tftpl", {
    instance_id       = local.connect_instance_id
    tts_voice_id      = var.tts_voice_id
    tts_language_code = var.tts_language_code
    queue_general_id  = local.queue_ids["general"]
    prompt_error      = var.flow_prompts["error"]
    prompt_goodbye    = var.flow_prompts["goodbye"]
  })

  tags = merge(local.common_tags, {
    FlowType = "error-handler"
  })
}
```

```hcl
# phone-associations.tf — FR-006: Phone number → contact flow associations
#
# The AWS Terraform provider does not expose a native resource for phone number
# to contact flow association. Association requires the AssociatePhoneNumberContactFlow
# API call. This is handled via a Lambda function invoked by terraform_data on apply.

data "archive_file" "phone_association" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/phone-association"
  output_path = "${path.module}/.build/phone-association.zip"
}

resource "aws_lambda_function" "phone_association" {
  function_name    = "${var.org_name}-phone-flow-association-${terraform.workspace}"
  description      = "Associates phone numbers with contact flows via Connect API."
  runtime          = "python3.12"
  handler          = "phone_association.handler"
  role             = aws_iam_role.phone_association.arn
  filename         = data.archive_file.phone_association.output_path
  source_code_hash = data.archive_file.phone_association.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      CONNECT_INSTANCE_ID = local.connect_instance_id
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "phone_association" {
  name              = "/aws/lambda/${aws_lambda_function.phone_association.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "phone_association" {
  name                 = "${var.org_name}-phone-flow-assoc-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "phone_association" {
  name = "phone-flow-association"
  role = aws_iam_role.phone_association.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "connect:AssociatePhoneNumberContactFlow",
          "connect:DisassociatePhoneNumberContactFlow"
        ]
        Resource = [
          "arn:aws:connect:${var.aws_region}:*:instance/${local.connect_instance_id}",
          "arn:aws:connect:${var.aws_region}:*:instance/${local.connect_instance_id}/phone-number/*",
          "arn:aws:connect:${var.aws_region}:*:instance/${local.connect_instance_id}/contact-flow/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.org_name}-phone-flow-association-${terraform.workspace}:*"
      }
    ]
  })
}

# Invoke the Lambda for each phone number association.
# terraform_data triggers re-invocation when the mapping changes.
resource "terraform_data" "phone_number_flow_associations" {
  for_each = var.number_flow_associations

  triggers_replace = {
    phone_number_id = local.phone_number_ids[each.key]
    contact_flow_id = local.contact_flow_id_map[each.value]
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws lambda invoke \
        --function-name ${aws_lambda_function.phone_association.function_name} \
        --payload '${jsonencode({
          phone_number_id = local.phone_number_ids[each.key]
          contact_flow_id = local.contact_flow_id_map[each.value]
          action          = "associate"
        })}' \
        --cli-binary-format raw-in-base64-out \
        /dev/null
    EOT
  }
}
```

```hcl
# closure-check.tf — FR-010: Closure status check Lambda
#
# Lightweight Lambda invoked by the main inbound contact flow to check
# whether today is a closure (holiday, company closure, or emergency).
# Reads PRD-12's pre-computed daily_closure_status DynamoDB table and
# emergency_closure SSM parameter. Returns result as contact attributes.

data "archive_file" "closure_check" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/closure-check"
  output_path = "${path.module}/.build/closure-check.zip"
}

resource "aws_lambda_function" "closure_check" {
  function_name    = "${var.org_name}-closure-check-${terraform.workspace}"
  description      = "Reads PRD-12 daily closure status and emergency closure. Invoked per-call by main inbound contact flow."
  runtime          = "python3.12"
  handler          = "closure_check.handler"
  role             = aws_iam_role.closure_check.arn
  filename         = data.archive_file.closure_check.output_path
  source_code_hash = data.archive_file.closure_check.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      DAILY_STATUS_TABLE_NAME       = local.daily_closure_status_table_name
      EMERGENCY_CLOSURE_PARAM_NAME  = local.emergency_closure_parameter_name
    }
  }

  tags = local.common_tags
}

resource "aws_connect_lambda_function_association" "closure_check" {
  function_arn = aws_lambda_function.closure_check.arn
  instance_id  = local.connect_instance_id
}

resource "aws_cloudwatch_log_group" "closure_check" {
  name              = "/aws/lambda/${aws_lambda_function.closure_check.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "closure_check" {
  name                 = "${var.org_name}-closure-check-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "closure_check" {
  name = "closure-check"
  role = aws_iam_role.closure_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem"]
        Resource = local.daily_closure_status_table_arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = local.emergency_closure_parameter_arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = local.env_kms_key_arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${var.org_name}-closure-check-${terraform.workspace}:*"
      }
    ]
  })
}
```

```hcl
# cloudwatch.tf — ALARM-14-02: IVR No Input Spike
#
# Note: ALARM-14-01 (ContactFlowFatalErrors) is already provisioned by
# PRD-10 (l1-connect-instance/cloudwatch.tf) and is NOT duplicated here.

resource "aws_cloudwatch_log_metric_filter" "ivr_no_input" {
  name           = "${var.org_name}-ivr-no-input-${terraform.workspace}"
  log_group_name = local.contact_flow_log_group_name
  pattern        = "{ $.ContactFlowModuleType = \"GetParticipantInput\" && $.Results = \"InputTimeLimitExceeded\" }"

  metric_transformation {
    name          = "IVRNoInputCount"
    namespace     = "${var.org_name}/Connect"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "ivr_no_input_spike" {
  alarm_name          = "${var.org_name}-ivr-no-input-spike-${terraform.workspace}"
  alarm_description   = "ALARM-14-02: IVR no-input rate exceeds threshold — callers not engaging with menu (prompt clarity issue)"
  namespace           = "${var.org_name}/Connect"
  metric_name         = "IVRNoInputCount"
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alert_topic_arn]

  tags = local.common_tags
}
```

### Locals

```hcl
# locals.tf

locals {
  connect_instance_id              = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  hours_of_operation_ids           = data.terraform_remote_state.hours_of_operation.outputs.hours_of_operation_ids
  daily_closure_status_table_name  = data.terraform_remote_state.hours_of_operation.outputs.daily_closure_status_table_name
  daily_closure_status_table_arn   = data.terraform_remote_state.hours_of_operation.outputs.daily_closure_status_table_arn
  emergency_closure_parameter_name = data.terraform_remote_state.hours_of_operation.outputs.emergency_closure_parameter_name
  emergency_closure_parameter_arn  = data.terraform_remote_state.hours_of_operation.outputs.emergency_closure_parameter_arn
  queue_ids                        = data.terraform_remote_state.queue_architecture.outputs.queue_ids
  queue_config                     = data.terraform_remote_state.queue_architecture.outputs.queue_config
  system_queue_id                  = data.terraform_remote_state.queue_architecture.outputs.system_queue_id
  phone_number_ids                 = data.terraform_remote_state.phone_numbers.outputs.phone_number_ids
  env_kms_key_arn                  = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn          = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  alert_topic_arn                  = data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn
  contact_flow_log_group_name      = data.terraform_remote_state.connect_instance.outputs.contact_flow_log_group_name

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-14"
  }

  # Map of flow key to flow resource ID — used for number associations
  contact_flow_id_map = {
    "main-inbound"  = aws_connect_contact_flow.main_inbound.id
    "error-handler" = aws_connect_contact_flow.error_handler.id
  }
}
```

### Variables

```hcl
# variables.tf

variable "org_name" {
  type        = string
  description = "Organization identifier."
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "alarm_action_arns" {
  type        = list(string)
  description = "Optional alarm action ARNs for ALARM-14-02. Leave empty to keep PRD-14 deployable without PRD-03 or another shared alert sink."
  default     = []
}

variable "tts_voice_id" {
  type        = string
  description = "Amazon Polly voice ID for text-to-speech prompts. Supplied via environments/<env>/contact-flows.tfvars."
  default     = "Joanna"
}

variable "tts_language_code" {
  type        = string
  description = "Language code for TTS and speech recognition. Supplied via environments/<env>/contact-flows.tfvars."
  default     = "en-US"
}

variable "flow_prompts" {
  description = <<-EOT
    All customer-facing IVR prompt text. Edit to change what callers hear
    without modifying flow logic or JSON templates.

    IMPORTANT: default is empty map. The prompt inventory MUST be supplied via
    the environment-scoped tfvars (environments/<env>/contact-flows.tfvars). Running
    apply without prompts will fail — all prompt keys are required by the
    flow JSON templates.

    Required keys: greeting, main_menu, after_hours, callback_offer,
    queue_wait, overflow, error, goodbye, voicemail_unavailable.
  EOT

  type    = map(string)
  default = {}

  validation {
    condition = length(var.flow_prompts) == 0 || alltrue([
      for k in ["greeting", "main_menu", "after_hours", "callback_offer", "queue_wait", "overflow", "error", "goodbye", "voicemail_unavailable"] :
      contains(keys(var.flow_prompts), k)
    ])
    error_message = "flow_prompts must contain all required keys: greeting, main_menu, after_hours, callback_offer, queue_wait, overflow, error, goodbye, voicemail_unavailable."
  }
}

variable "number_flow_associations" {
  description = <<-EOT
    Map of phone number key (from PRD-11) to contact flow key. Each key must
    match a provisioned phone number in PRD-11. Each value must match a flow
    key in this module's contact_flow_id_map (currently: main-inbound,
    error-handler).

    IMPORTANT: default is empty map. The association inventory MUST be supplied
    via the environment-scoped tfvars (environments/<env>/contact-flows.tfvars).
    Running apply without associations provisions zero phone number → flow
    associations.
  EOT

  type    = map(string)
  default = {}
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-14"
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-14. It exists for
# forward compatibility with the platform deployment profile contract
# (authoritative definition in PRD-00 bootstrap module). Every module
# declares this variable with the same schema and defaults so that:
#   - All modules accept the same deployment_profile from tfvars
#   - Modules that need conditional behavior can reference specific fields
#     without changing their variable signature
#
# Do not remove — this is intentional contract consistency, not dead code.
# -----------------------------------------------------------------------
variable "deployment_profile" {
  description = "Platform-wide deployment profile. Not consumed by PRD-14 — declared for contract consistency. See PRD-00 for authoritative schema."
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

output "main_inbound_flow_id" {
  description = "Main inbound contact flow ID. Consumed by PRD-72 (Lex integration)."
  value       = aws_connect_contact_flow.main_inbound.id
}

output "main_inbound_flow_arn" {
  description = "Main inbound contact flow ARN."
  value       = aws_connect_contact_flow.main_inbound.arn
}

output "after_hours_module_id" {
  description = "After-hours module ID. Consumed by PRD-10a (voicemail) and PRD-54 (callback)."
  value       = aws_connect_contact_flow_module.after_hours.id
}

output "queue_transfer_module_id" {
  description = "Queue transfer module ID. Consumed by PRD-52, PRD-53."
  value       = aws_connect_contact_flow_module.queue_transfer.id
}

output "error_handler_flow_id" {
  description = "Error handler flow ID. Referenced by all downstream flows for error recovery."
  value       = aws_connect_contact_flow.error_handler.id
}

output "contact_flow_ids" {
  description = "Map of all contact flow keys to IDs. Consumed by PRD-52, PRD-72, and PRD-91 cutover operations."
  value = {
    "main-inbound"          = aws_connect_contact_flow.main_inbound.id
    "after-hours-module"    = aws_connect_contact_flow_module.after_hours.id
    "queue-transfer-module" = aws_connect_contact_flow_module.queue_transfer.id
    "error-handler"         = aws_connect_contact_flow.error_handler.id
  }
}
```

### Contact Flow JSON Template Structure

The flow templates are `.json.tftpl` files using Terraform's `templatefile()` function. Below is the structural outline of the main inbound flow template. Full JSON is generated at apply time with all resource IDs injected.

```json
// flows/main-inbound.json.tftpl — structural outline
// Full Connect Contact Flow Language JSON
// All IDs are template variables — no hard-coded values
{
  "Version": "2019-10-30",
  "StartAction": "set-logging",
  "Metadata": {
    "entryPointPosition": { "x": 40, "y": 40 },
    "ActionMetadata": {}
  },
  "Actions": [
    {
      "Identifier": "set-logging",
      "Type": "UpdateContactEventHooks",
      "Parameters": { "AgentHungUp": "disconnect" },
      "Transitions": { "NextAction": "set-voice", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "set-voice",
      "Type": "UpdateContactTTSVoice",
      "Parameters": {
        "TextToSpeechVoice": "${tts_voice_id}"
      },
      "Transitions": { "NextAction": "check-lex-hook", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "check-lex-hook",
      "Type": "CheckAttribute",
      "Parameters": {
        "Attribute": "lex_integration_enabled",
        "Type": "User Defined",
        "Conditions": [
          {
            "NextAction": "LEX_INTEGRATION_HOOK",
            "Condition": { "Operator": "Equals", "Operands": ["true"] }
          }
        ]
      },
      "Transitions": {
        "NextAction": "check-hours",
        "Errors": [ { "NextAction": "check-hours", "ErrorType": "NoMatchingError" } ],
        "Conditions": []
      }
    },
    {
      "Identifier": "LEX_INTEGRATION_HOOK",
      "Type": "TransferToFlow",
      "Parameters": { "ContactFlowId": { "DynamicValue": "$.Attributes.lex_flow_id" } },
      "Transitions": {
        "NextAction": "check-hours",
        "Errors": [ { "NextAction": "check-hours", "ErrorType": "NoMatchingError" } ],
        "Conditions": []
      }
    },
    {
      "Identifier": "check-hours",
      "Type": "CheckHoursOfOperation",
      "Parameters": { "HoursOfOperationId": "${hours_of_operation_id}" },
      "Transitions": {
        "NextAction": "invoke-closure-check",
        "Errors": [],
        "Conditions": [
          { "NextAction": "after-hours-module", "Condition": { "Operator": "Equals", "Operands": ["False"] } }
        ]
      }
    },
    {
      "Identifier": "invoke-closure-check",
      "Type": "InvokeLambdaFunction",
      "Parameters": {
        "LambdaFunctionARN": "${closure_check_lambda_arn}"
      },
      "Transitions": {
        "NextAction": "check-closure-result",
        "Errors": [ { "NextAction": "play-greeting", "ErrorType": "NoMatchingError" } ],
        "Conditions": []
      }
    },
    {
      "Identifier": "check-closure-result",
      "Type": "CheckAttribute",
      "Parameters": {
        "Attribute": "is_closure",
        "Type": "External",
        "Conditions": [
          {
            "NextAction": "after-hours-module",
            "Condition": { "Operator": "Equals", "Operands": ["true"] }
          }
        ]
      },
      "Transitions": {
        "NextAction": "play-greeting",
        "Errors": [ { "NextAction": "play-greeting", "ErrorType": "NoMatchingError" } ],
        "Conditions": []
      }
    },
    {
      "Identifier": "after-hours-module",
      "Type": "InvokeFlowModule",
      "Parameters": { "ContactFlowModuleId": "${after_hours_module_id}" },
      "Transitions": { "NextAction": "disconnect", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "play-greeting",
      "Type": "MessageParticipant",
      "Parameters": {
        "Text": "${prompt_greeting}",
        "TextToSpeechType": "text"
      },
      "Transitions": { "NextAction": "get-input", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "get-input",
      "Type": "GetParticipantInput",
      "Parameters": {
        "Text": "${prompt_menu}",
        "TextToSpeechType": "text",
        "Timeout": "8",
        "MaxDigits": "1",
        "InputTimeLimitSeconds": "8",
        "DTMFHandling": "SEND_MESSAGE",
        "NluHandling": "USE_EXISTING_INPUT_MODE",
        "Conditions": [
          { "NextAction": "transfer-sales",   "Condition": { "Operator": "Equals", "Operands": ["1"] } },
          { "NextAction": "transfer-sales",   "Condition": { "Operator": "Equals", "Operands": ["Sales"] } },
          { "NextAction": "transfer-support", "Condition": { "Operator": "Equals", "Operands": ["2"] } },
          { "NextAction": "transfer-support", "Condition": { "Operator": "Equals", "Operands": ["Support"] } },
          { "NextAction": "transfer-billing", "Condition": { "Operator": "Equals", "Operands": ["3"] } },
          { "NextAction": "transfer-billing", "Condition": { "Operator": "Equals", "Operands": ["Billing"] } },
          { "NextAction": "transfer-tech",    "Condition": { "Operator": "Equals", "Operands": ["4"] } },
          { "NextAction": "transfer-tech",    "Condition": { "Operator": "Equals", "Operands": ["Technical Support"] } },
          { "NextAction": "play-greeting",    "Condition": { "Operator": "Equals", "Operands": ["0"] } },
          { "NextAction": "play-greeting",    "Condition": { "Operator": "Equals", "Operands": ["Repeat"] } }
        ]
      },
      "Transitions": {
        "NextAction": "transfer-general",
        "Errors": [
          { "NextAction": "error-handler", "ErrorType": "InputTimeLimitExceeded" },
          { "NextAction": "transfer-general", "ErrorType": "NoMatchingCondition" }
        ],
        "Conditions": []
      }
    },
    {
      "Identifier": "transfer-sales",
      "Type": "UpdateContactAttributes",
      "Parameters": {
        "Attributes": [
          { "Name": "target_queue_id",       "Value": "${queue_sales_id}" },
          { "Name": "target_queue_name",     "Value": "Sales" },
          { "Name": "max_wait_minutes",      "Value": "${max_wait_sales}" },
          { "Name": "overflow_action",       "Value": "${overflow_sales}" }
        ]
      },
      "Transitions": { "NextAction": "queue-transfer-module", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "transfer-support",
      "Type": "UpdateContactAttributes",
      "Parameters": {
        "Attributes": [
          { "Name": "target_queue_id",       "Value": "${queue_support_id}" },
          { "Name": "target_queue_name",     "Value": "Customer Support" },
          { "Name": "max_wait_minutes",      "Value": "${max_wait_support}" },
          { "Name": "overflow_action",       "Value": "${overflow_support}" }
        ]
      },
      "Transitions": { "NextAction": "queue-transfer-module", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "transfer-billing",
      "Type": "UpdateContactAttributes",
      "Parameters": {
        "Attributes": [
          { "Name": "target_queue_id",       "Value": "${queue_billing_id}" },
          { "Name": "target_queue_name",     "Value": "Billing" },
          { "Name": "max_wait_minutes",      "Value": "${max_wait_billing}" },
          { "Name": "overflow_action",       "Value": "${overflow_billing}" }
        ]
      },
      "Transitions": { "NextAction": "queue-transfer-module", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "transfer-tech",
      "Type": "UpdateContactAttributes",
      "Parameters": {
        "Attributes": [
          { "Name": "target_queue_id",       "Value": "${queue_tech_id}" },
          { "Name": "target_queue_name",     "Value": "Technical Support" },
          { "Name": "max_wait_minutes",      "Value": "${max_wait_tech}" },
          { "Name": "overflow_action",       "Value": "${overflow_tech}" }
        ]
      },
      "Transitions": { "NextAction": "queue-transfer-module", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "transfer-general",
      "Type": "UpdateContactAttributes",
      "Parameters": {
        "Attributes": [
          { "Name": "target_queue_id",   "Value": "${queue_general_id}" },
          { "Name": "target_queue_name", "Value": "General" },
          { "Name": "max_wait_minutes",  "Value": "10" },
          { "Name": "overflow_action",   "Value": "VOICEMAIL" }
        ]
      },
      "Transitions": { "NextAction": "queue-transfer-module", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "queue-transfer-module",
      "Type": "InvokeFlowModule",
      "Parameters": { "ContactFlowModuleId": "${queue_transfer_module_id}" },
      "Transitions": { "NextAction": "disconnect", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "error-handler",
      "Type": "TransferContactToFlow",
      "Parameters": { "ContactFlowId": "${error_handler_flow_id}" },
      "Transitions": { "NextAction": "disconnect", "Errors": [], "Conditions": [] }
    },
    {
      "Identifier": "disconnect",
      "Type": "DisconnectParticipant",
      "Parameters": {},
      "Transitions": {}
    }
  ]
}
```

---

## 10. EVENT SCHEMA

PRD-14 produces no EventBridge events directly. Contact flow execution is logged to CloudWatch (PRD-10 log group). Contact trace records (PRD-10 Kinesis stream) include the contact flow ARN in every CTR, providing the event stream for flow-level analytics.

### Contact Attributes Written by This Flow

The main inbound flow writes the following contact attributes that are readable by downstream services (PRD-52 whisper flows, PRD-10a voicemail, PRD-72 Lex, PRD-130 CRM adapter):

| Attribute | Values | Set By | Read By |
|---|---|---|---|
| `lex_integration_enabled` | `true` / absent | PRD-72 pre-hook Lambda | Main inbound flow |
| `target_queue_id` | Connect queue ID | Main inbound flow | Queue transfer module |
| `target_queue_name` | Human-readable name | Main inbound flow | PRD-52, PRD-130 |
| `max_wait_minutes` | Number string | Main inbound flow | Queue transfer module |
| `overflow_action` | `VOICEMAIL` / `CALLBACK` / `DISCONNECT` | Main inbound flow | Queue transfer module |
| `after_hours_action` | `CALLBACK` / `VOICEMAIL` | After-hours module | PRD-10a, PRD-54 |
| `is_closure` | `true` / `false` | Closure check Lambda (reads PRD-12 tables) | Main inbound flow |
| `closure_name` | Holiday/closure name string | Closure check Lambda | PRD-130 CRM adapter |
| `lex_flow_id` | Contact flow ID | PRD-72 pre-hook Lambda | LEX_INTEGRATION_HOOK block |

---

## 11. API / INTERFACE CONTRACT

```hcl
# Standard downstream consumption pattern for PRD-52, PRD-10a, PRD-72
data "terraform_remote_state" "contact_flow_framework" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-contact-flow-framework/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  main_inbound_flow_id     = data.terraform_remote_state.contact_flow_framework.outputs.main_inbound_flow_id
  after_hours_module_id    = data.terraform_remote_state.contact_flow_framework.outputs.after_hours_module_id
  queue_transfer_module_id = data.terraform_remote_state.contact_flow_framework.outputs.queue_transfer_module_id
  error_handler_flow_id    = data.terraform_remote_state.contact_flow_framework.outputs.error_handler_flow_id
}
```

---

## 12. DATA MODEL

### State File Location

```
s3://{org}-tfstate-{account_id}/
└── l1-contact-flow-framework/
    └── terraform.tfstate
```

### Contact Attribute Schema

Contact attributes are key-value string pairs stored on each contact. They are readable by Lambda functions, whisper flows, and the CRM adapter. The full set of attributes written by this flow is documented in Section 9. No attribute value exceeds 32KB (Connect limit).

### Flow File Versioning

Contact flow JSON files are version-controlled in Git. Changes to flow logic require a PR, plan review, and pipeline apply. The `aws_connect_contact_flow` resource detects JSON changes via content hash. A flow update is applied as an in-place modification — Connect activates the new version immediately without dropping in-flight calls.

---

## 13. CI/CD SPECIFICATION

### Local Plan/Apply

PRD-14 should follow the same local execution contract as the rest of the repo:
- bootstrap backend config comes from the external bootstrap artifact directory
- environment config comes from `connect-pbx/environments/<env>/`
- named workspaces are required for downstream modules

```bash
export AWS_PROFILE=nevs-cloud-dev
cd connect-pbx/modules/l1-contact-flow-framework

BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/bootstrap}"

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-nevs-cloud-dev.hcl" \
               -backend-config="key=l1-contact-flow-framework/terraform.tfstate"
terraform workspace select dev

terraform plan  -var-file="../../environments/dev/global.tfvars" \
                -var-file="../../environments/dev/contact-flows.tfvars"

terraform apply -var-file="../../environments/dev/global.tfvars" \
                -var-file="../../environments/dev/contact-flows.tfvars"
```

For prod:
```bash
export AWS_PROFILE=nevs-cloud-prod
cd connect-pbx/modules/l1-contact-flow-framework

BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/bootstrap}"

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-nevs-cloud-prod.hcl" \
               -backend-config="key=l1-contact-flow-framework/terraform.tfstate"
terraform workspace select prod

terraform plan  -var-file="../../environments/prod/global.tfvars" \
                -var-file="../../environments/prod/contact-flows.tfvars"
# Prod requires manual plan review before apply — inspect the plan output first.
terraform apply -var-file="../../environments/prod/global.tfvars" \
                -var-file="../../environments/prod/contact-flows.tfvars"
```

For staging:
```bash
export AWS_PROFILE=nevs-cloud-staging
cd connect-pbx/modules/l1-contact-flow-framework

BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/bootstrap}"

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-nevs-cloud-staging.hcl" \
               -backend-config="key=l1-contact-flow-framework/terraform.tfstate"
terraform workspace select staging

terraform plan  -var-file="../../environments/staging/global.tfvars" \
                -var-file="../../environments/staging/contact-flows.tfvars"
```

### Workflow Reference

Intended CI/CD behavior matches the shared reusable workflows already used by the repo:
- `tf-plan.yml` loads `global.tfvars` plus `contact-flows.tfvars` for this module
- `tf-apply.yml` applies the approved binary plan artifact
- workspace selection is driven by the `environment` input
- PRD-14 should only be reintroduced to CI once the module is fully implemented

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l1-contact-flow-framework

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l1-contact-flow-framework
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l1-contact-flow-framework
      environment: ${{ inputs.environment }}
      plan_run_id: ${{ github.run_id }}
    secrets: inherit
```

### Flow Change Procedure

Contact flow changes go through the standard pipeline. Special considerations:

- **Prompt text changes** (editing `flow_prompts` variable): Safe to apply at any time. Takes effect immediately. No impact on in-flight calls.
- **Flow logic changes** (editing `.json.tftpl` files): Apply during low-traffic periods. In-flight calls are not dropped, but new calls use the updated logic immediately on apply.
- **Adding a new flow**: Add the resource to `main.tf` and the flow key to `contact_flow_ids` output. No impact on existing flows.
- **Removing a flow**: Only possible if no phone numbers or other flows reference it. Terraform will error if dependencies exist.

### Rollback Procedure

Contact flows support immediate rollback via re-apply of the previous version from Git. The previous flow JSON is restored and activated within seconds of apply. The Terraform pipeline plan shows the exact JSON diff, making rollback decisions straightforward.

---

## 14. OBSERVABILITY SPECIFICATION

### CloudWatch Metrics

| Metric | Source | Purpose |
|---|---|---|
| `ContactFlowErrors` | Connect / CloudWatch | Flow execution errors |
| `ContactFlowFatalErrors` | Connect / CloudWatch | Fatal flow errors — **alarmed by PRD-10 (ALARM-10-02), not duplicated here** |
| `MissedCalls` | Connect / CloudWatch | Calls not answered — flow routing issue indicator |
| `IVRNoInputCount` | Custom metric via log metric filter | Callers not engaging with IVR menu |

### Alarms

**ALARM-14-02: IVR No Input Spike**
- Source: CloudWatch log metric filter on contact flow logs — count of `InputTimeLimitExceeded` events
- Threshold: > 10 in 15 minutes
- Action: publish to `alarm_action_arns` when non-empty; otherwise no external sink required
- Severity: Medium — callers are not engaging with the IVR menu (prompt clarity issue)

Note: ALARM-14-01 (Contact Flow Fatal Error) was removed from this PRD. It is already provisioned by PRD-10 as ALARM-10-02 (`{org_name}-connect-flow-fatal-{workspace}`). Duplicating it would create redundant alerts.

### Log Groups

| Log Group | Retention | Purpose |
|---|---|---|
| `/aws/connect/{instance_id}` | 365 days | Contact flow execution logs (provisioned in PRD-10) |
| `/aws/lambda/{org_name}-closure-check-{workspace}` | 365 days | Closure check Lambda logs (provisioned in this PRD) |
| `/aws/lambda/{org_name}-phone-flow-association-{workspace}` | 365 days | Phone association Lambda logs (provisioned in this PRD) |

### SOC 2 and PCI Evidence Artifacts

| Artifact | Demonstrates |
|---|---|
| Flow JSON files in Git history | SOC 2 CC8.1 — change management for system behavior |
| Contact flow execution logs | PCI-DSS Req 10.2 — system access logging |
| PR history for prompt changes | SOC 2 CC7.1 — authorized changes only |

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-14-01 | Main inbound flow exists in Connect | `aws connect list-contact-flows` returns `{org_name}-Main-Inbound` |
| AC-14-02 | After-hours module exists | `aws connect list-contact-flow-modules` returns `{org_name}-After-Hours-Module` |
| AC-14-03 | Queue transfer module exists | `aws connect list-contact-flow-modules` returns `{org_name}-Queue-Transfer-Module` |
| AC-14-04 | Error handler flow exists | `aws connect list-contact-flows` returns `{org_name}-Error-Handler` |
| AC-14-05 | All PRD-11 numbers associated with flows | `aws connect describe-phone-number` for each number returns a contact flow ID |
| AC-14-06 | Test call routes to Sales on press 1 | Place test call, press 1, confirm sales queue |
| AC-14-07 | Test call routes to Support on press 2 | Place test call, press 2, confirm support queue |
| AC-14-08 | Test call routes to Billing on press 3 | Place test call, press 3, confirm billing queue |
| AC-14-09 | Test call routes to Tech Support on press 4 | Place test call, press 4, confirm tech support queue |
| AC-14-10 | Saying "Sales" routes to sales queue | Place test call, say "Sales", confirm sales queue |
| AC-14-11 | Pressing 0 replays the menu | Place test call, press 0, confirm menu repeats |
| AC-14-12 | No input routes to general queue | Place test call, provide no input, confirm general queue after timeout |
| AC-14-13 | After-hours call plays message and offers callback/voicemail | Simulate after-hours call (set hours to closed), confirm message and options |
| AC-14-14 | Flow JSON contains no hard-coded resource IDs | Inspect `.json.tftpl` files — confirm all IDs are template variables |
| AC-14-15 | LEX_INTEGRATION_HOOK block present in main flow JSON | Inspect main-inbound.json.tftpl — confirm LEX_INTEGRATION_HOOK identifier |
| AC-14-16 | Prompt text change via variable applies without flow logic change | Change `greeting` prompt text in tfvars, apply, place test call, confirm new prompt |
| AC-14-17 | ALARM-14-02 is active | `aws cloudwatch describe-alarms` returns IVR no-input spike alarm |
| AC-14-18 | Closure check Lambda exists and is associated with Connect | `aws connect list-lambda-functions` returns the closure check Lambda ARN |
| AC-14-19 | Closure check returns is_closure=true on holiday | Set a holiday entry for today in DynamoDB, trigger PRD-12 Lambda, invoke closure check Lambda, confirm `is_closure: true` |
| AC-14-20 | Emergency closure overrides daily status | Set emergency closure SSM parameter to active, invoke closure check Lambda, confirm `is_closure: true` |
| AC-14-21 | Closure check failure is fail-open | Delete daily status table item, place test call, confirm IVR menu plays normally |
| AC-14-22 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l1-contact-flow-framework/` returns clean |
| AC-14-23 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l1-contact-flow-framework/` returns clean |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Flow JSON template syntax error causes apply failure | Medium | High | Flow JSON validated in CI using `aws connect describe-contact-flow` dry-run or a JSON schema validator step added to tf-security-scan.yml |
| IVR speech recognition misroutes callers (e.g., "billing" heard as "billing" but not matched) | Medium | Medium | Speech conditions use exact string matching. Add common variants as additional conditions. PRD-72 Lex integration will replace this with robust NLU. |
| Overflow hook (VOICEMAIL / CALLBACK) invoked before PRD-10a or PRD-54 is deployed | High (early phases) | Medium | Queue transfer module checks contact attribute `voicemail_enabled` before routing to voicemail hook. Falls back to `voicemail_unavailable` prompt and disconnect if not set. |
| LEX_INTEGRATION_HOOK block causes flow to hang if lex_flow_id attribute is not set | Low | High | Hook block has explicit error transition back to check-hours — Lex failure always falls through to DTMF path. |
| Flow update breaks in-flight calls | Low | Medium | In-flight calls use the version active at call start. New flows activate for new calls only. Apply during low-traffic windows as a precaution. |
| Phone number association Lambda fails silently | Low | Medium | Lambda returns error payload; `terraform_data` provisioner fails the apply. Re-apply to retry. Association state is verified by AC-14-05. |
| Closure check Lambda cold start adds latency to first call of the day | Medium | Low | Lambda memory set to 128MB; Python 3.12 cold starts are sub-500ms. Connect Lambda timeout set to 10s. Fail-open on timeout. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-14-01 | What are the exact DTMF menu key mappings and prompt text for production? Defaults used here map 1=Sales, 2=Support, 3=Billing, 4=Technical Support, 0=Repeat. Confirm or change before prod apply. | Open | Operations manager to confirm. Update `flow_prompts.main_menu` and the corresponding `get-input` conditions in the flow template. |
| OQ-14-02 | Should direct-dial numbers for specific departments (e.g., a direct Sales DID) bypass the IVR menu and route straight to the sales queue? | Open | If yes, add a dedicated flow that skips `get-input` and goes directly to `transfer-sales`. Map the direct DID to this flow in `number_flow_associations`. |
| OQ-14-03 | Should the queue wait treatment include a position announcement ("You are caller number 3 in the queue") or estimated wait time? Connect supports both natively via the `GetQueueMetrics` block. | Open | Operations manager to confirm. The queue transfer module template can include this block — it is currently omitted for simplicity. |
| OQ-14-04 | What Amazon Polly voice should be used in production? Default is Joanna (US English female). Other options include Matthew (US English male), Amy (UK English female), and Neural variants of each. | Open | Operations manager to confirm. Set `tts_voice_id` in `environments/prod/contact-flows.tfvars`. Neural voices (e.g., Joanna-Neural) are higher quality but higher cost. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Hybrid DTMF/voice menu using native Connect speech recognition. LEX_INTEGRATION_HOOK defined for PRD-72. VOICEMAIL_HOOK and CALLBACK_HOOK defined for PRD-10a and PRD-54. All flow IDs injected via templatefile — no hard-coded values. |
| 1.0.1 | 2026-03-25 | — | Canonical alignment revision. Fixed: backend.tf to match repo pattern (>= 1.14.0, ~> 6.0, empty backend "s3" {}). Replaced holiday-status.tf with closure-check.tf that consumes PRD-12 outputs (daily_closure_status table, emergency_closure SSM) instead of duplicating infrastructure. Added common_tags local block matching PRD-11/12/13 pattern. Added all six remote state data source declarations. Removed ALARM-14-01 (already in PRD-10 as ALARM-10-02). Added ALARM-14-02 Terraform resources (log metric filter + alarm). Replaced null_resource phone association with terraform_data + Lambda approach. Fixed state key paths (no environment prefix). Fixed downstream consumption example to match canonical remote state pattern. Added closure_name contact attribute. Updated module directory layout to include lambda/ subdirectory and cloudwatch.tf. |
| 1.0.2 | 2026-03-25 | — | Module-scoped tfvars alignment. Moved flow_prompts, number_flow_associations, tts_voice_id, and tts_language_code out of variable defaults and into environment-scoped `contact-flows.tfvars` following the repo-standard env-folder pattern. Added flow_prompts validation for required keys. Added empty defaults with IMPORTANT comments matching canonical variable documentation style. Added local plan/apply commands to CI/CD section. Updated module path tree to include environment folder usage. |
| 1.1.0 | 2026-03-27 | — | Repo-alignment target-state revision. Clarified that this document defines the intended full working implementation. Updated local/CI deployment examples to use the repo-standard environment-folder model (`environments/<env>/global.tfvars` + `environments/<env>/contact-flows.tfvars`), external bootstrap artifact directory, and `dev`/`staging`/`prod` named workspaces. |
| 1.1.1 | 2026-03-30 | — | Audit decoupling target-state normalization. Clarified that PRD-14 must remain deployable without PRD-03 and that ALARM-14-02 uses explicit optional alarm sinks rather than an assumed shared audit topic. |
| 1.2.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section with catalog entry, shared sink behavior, destroy posture, and control plane statement. |
