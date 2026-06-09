# PRD-53 — Agent-to-Agent Transfer Service

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-53 |
| **Version** | 1.2.0 |
| **Status** | Green |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 5 — Agent Experience |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-10 (Connect instance ID), PRD-13 (queue IDs, system queue ID) |
| **Blocks** | PRD-54 (Routing Profile Management) |
| **Optional Shared Sinks** | Alarm and audit exports, if enabled |
| **Destroy / Retention Posture** | destroyable / no persistent state |
| **Optional** | Yes — optional agent-experience feature; activation is controlled by the module catalog and deployment manifests |

---

## 2. MODULE GOVERNANCE

Feature activation for PRD-53 is controlled by the module catalog and per-environment deployment manifests. `deployment_profile` is runtime shape only and is not used to enable or disable the transfer service.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### PRD-52 Coupling

PRD-52 is an optional integration input, not a hard dependency. If a deployment wants whisper-enhanced consult behavior, it may pass the PRD-52 flow ID as an input. The base transfer service does not require editing PRD-52 source files, manual state surgery, or any cross-module mutation.

### Optional Sinks

If alarms or audit records are routed to PRD-03 in a target environment, those sinks are optional inputs rather than activation conditions.

### Intended Catalog Entry

- `path`: `modules/l5-agent-transfer`
- `capability_packs`: `[]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture"]`
- `state_key`: `l5-agent-transfer/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `agent-transfer.tfvars`
- `supports_destroy`: `true`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated agent-experience capability pack exists

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: this module provisions Connect quick connects and flows only. It owns no retained data store.

### Control Plane Statement

The transfer service must stay additive over the queue architecture. Optional consult-whisper behavior, alarm sinks, and audit exports are all additive inputs and must not become activation conditions.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Agents frequently need to transfer callers to other agents, other queues, or external numbers. Amazon Connect supports this via Quick Connects — pre-configured transfer destinations that agents can select from the CCP without dialing manually. Without Quick Connects, agents cannot perform internal transfers efficiently and must dial external numbers manually, increasing handle time and error rate.

This PRD provisions Quick Connects for every queue and a base transfer contact flow for blind transfers. When warm consult mode is enabled, it also provisions a consult flow for agent-to-agent consultation before handoff.

### What Problem It Solves

- Provisions Quick Connects for all six department queues
- Provisions Quick Connects for the system internal queue
- Implements the transfer contact flow that manages the warm transfer consultation experience
- Associates Quick Connects with all relevant queues so agents can initiate transfers from the CCP

---

## 4. GOALS

### Goals

- Provision Quick Connect resources for every queue using PRD-13 queue IDs
- Implement a base transfer contact flow and, when enabled, a warm transfer consultation flow
- Associate Quick Connects with queues so they appear in the agent CCP
- Export Quick Connect IDs for PRD-54 (routing profile management)

### Non-Goals

- This PRD does not implement callback queuing — that is PRD-54
- This PRD does not implement external number Quick Connects — those are added via the operations runbook as needed
- This PRD does not require PRD-52 to be implemented; whisper-enhanced consult behavior is optional when the input flow exists

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-53-01 | Agent | As an agent, I want to transfer a caller to another queue from my CCP with one click | Quick Connects appear in CCP transfer panel; click transfers caller to correct queue |
| US-53-02 | Agent | As an agent, I want to consult with another agent before transferring so I can brief them | Warm transfer flow connects agent to destination agent privately before caller is merged |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Queue Quick Connects
Provision one Quick Connect per queue of type `QUEUE`. Each Quick Connect must reference the corresponding queue ID from PRD-13 and use the system transfer flow:

| Quick Connect Name | Type | Destination Queue Key |
|---|---|---|
| `{org}-Transfer-General` | QUEUE | general |
| `{org}-Transfer-Sales` | QUEUE | sales |
| `{org}-Transfer-Support` | QUEUE | customer-support |
| `{org}-Transfer-Billing` | QUEUE | billing |
| `{org}-Transfer-TechSupport` | QUEUE | technical-support |
| `{org}-Transfer-Escalations` | QUEUE | escalations |

### FR-002 — Transfer Contact Flow
Provision a contact flow of type `CONTACT_FLOW` named `{org_name}-Transfer-Flow` that:
1. Sets a contact attribute `transfer_initiated = true`
2. Sets the target queue from the Quick Connect configuration
3. Optionally plays a brief transfer announcement to the caller
4. Executes the transfer

### FR-003 — Quick Connect to Queue Association
Each Quick Connect must be associated with every queue using `aws_connect_queue_quick_connect_association` so agents in any queue can transfer to any other queue. This provides maximum flexibility.

### FR-004 — Warm Transfer Flow
Provision a contact flow of type `CONTACT_FLOW` named `{org_name}-Warm-Transfer-Consult` when warm consult mode is enabled. The consult flow depends on PRD-54 enabling multi-party conferencing in the same environment. The flow must:
1. Places the original caller on hold
2. Connects the transferring agent to the destination agent for consultation
3. Optionally uses the PRD-52 whisper consult flow when that input is supplied
4. On agent confirmation, merges the caller into the three-party call
5. When the transferring agent disconnects, the call continues between caller and destination agent

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
Quick Connects are Connect configuration resources. Transfer operations complete within 3 seconds at the platform level. The actual call transfer latency is governed by carrier SLAs.

---

## 8. ARCHITECTURE

```
Agent CCP Transfer Panel
      │
      ├── Blind Transfer
      │   └── Select Quick Connect → Transfer-{Queue}
      │             └── Caller moved to target queue
      │
      └── Warm Transfer
          └── Select Quick Connect → Transfer-{Queue}
                    └── Warm-Transfer-Consult flow
                              ├── Caller placed on hold
                              ├── Transferring agent consults destination
                              └── Merge → caller connected to destination agent
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `quick_connect_ids` | map(string) | Queue key → Quick Connect ID | PRD-54 routing profile updates |
| `transfer_flow_id` | string | Transfer contact flow ID | PRD-14 if needed for flow updates |
| `warm_transfer_consult_flow_id` | string or null | Warm consult flow ID when warm consult mode is enabled | PRD-54 or downstream operator tooling |

Optional input: `whisper_consult_flow_id` may be supplied by a deployment that also enables PRD-52. It is not required for the base transfer service.

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l5-agent-transfer/          # PRD-53
        ├── flows/
        │   ├── transfer-flow.json
        │   └── warm-transfer-consult.json.tftpl
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Key Resources Declared

```hcl
# main.tf

# Transfer contact flow
resource "aws_connect_contact_flow" "transfer" {
  instance_id = var.connect_instance_id
  name        = "${var.org_name}-Transfer-Flow"
  description = "Standard transfer flow used by all Queue Quick Connects"
  type        = "CONTACT_FLOW"
  content     = file("${path.module}/flows/transfer-flow.json")

  tags = { Layer = "L5", PRD = "PRD-53" }
}

resource "aws_connect_contact_flow" "warm_transfer_consult" {
  count       = var.enable_warm_transfer_consult ? 1 : 0
  instance_id = var.connect_instance_id
  name        = "${var.org_name}-Warm-Transfer-Consult"
  type        = "CONTACT_FLOW"
  content = templatefile("${path.module}/flows/warm-transfer-consult.json.tftpl", {
    whisper_consult_flow_id    = var.whisper_consult_flow_id
    warm_transfer_timeout_secs = var.warm_transfer_timeout_secs
  })
}

# Quick Connects — one per queue
resource "aws_connect_quick_connect" "queues" {
  for_each    = var.queue_ids
  instance_id = var.connect_instance_id
  name        = "${var.org_name}-Transfer-${title(replace(each.key, "-", ""))}"
  description = "Transfer to ${each.key} queue"

  quick_connect_config {
    quick_connect_type = "QUEUE"
    queue_config {
      contact_flow_id = aws_connect_contact_flow.transfer.id
      queue_id        = each.value
    }
  }

  tags = { Layer = "L5", PRD = "PRD-53", TargetQueue = each.key }
}

# Associate Quick Connects with all queues (each queue can transfer to all others)
resource "aws_connect_queue_quick_connect_association" "associations" {
  for_each = {
    for pair in flatten([
      for queue_key, queue_id in var.queue_ids : [
        for qc_key, qc_id in aws_connect_quick_connect.queues :
        { queue_key = queue_key, qc_key = qc_key }
        if queue_key != qc_key  # Don't associate a queue with its own Quick Connect
      ]
    ]) : "${pair.queue_key}-${pair.qc_key}" => pair
  }

  instance_id      = var.connect_instance_id
  queue_id         = var.queue_ids[each.value.queue_key]
  quick_connect_id = aws_connect_quick_connect.queues[each.value.qc_key].quick_connect_id
}
```

### Variables

```hcl
variable "org_name" { type = string }
variable "aws_region" { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "agent_transfer_state_key" { type = string }
variable "connect_instance_id" { type = string }
variable "queue_ids" { type = map(string) }
variable "whisper_consult_flow_id" { type = string; default = null }
variable "enable_warm_transfer_consult" { type = bool; default = false }
variable "warm_transfer_timeout_secs" { type = number; default = 30 }
```

### Outputs

```hcl
output "quick_connect_ids" {
  description = "Map of queue key to Quick Connect ID."
  value = { for k, v in aws_connect_quick_connect.queues : k => v.quick_connect_id }
}
output "transfer_flow_id" {
  description = "Transfer contact flow ID."
  value       = aws_connect_contact_flow.transfer.id
}
output "warm_transfer_consult_flow_id" {
  description = "Warm transfer consult flow ID."
  value       = var.enable_warm_transfer_consult ? aws_connect_contact_flow.warm_transfer_consult[0].id : null
}
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

---

## 10. EVENT SCHEMA

PRD-53 produces no EventBridge events.

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "agent_transfer" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.agent_transfer_state_key
    region = var.aws_region
  }
}
locals {
  quick_connect_ids = data.terraform_remote_state.agent_transfer.outputs.quick_connect_ids
}
```

The `agent_transfer_state_key` input must match the catalog-declared `state_key` for this module. Consumers that opt into the warm consult flow may also read `warm_transfer_consult_flow_id`; they do not edit this module's source files to wire the dependency.

---

## 12. DATA MODEL

PRD-53 provisions no data stores.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l5-agent-transfer }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l5-agent-transfer, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l5-agent-transfer
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l5-agent-transfer-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-53-01: Transfer Flow Error Spike**
- Metric: `ContactFlowErrors` on transfer flow ARN > 5 in 5 minutes
- Severity: High — agents unable to complete transfers
- If PRD-03 alarm/audit sinks are enabled in the target environment, wire them as optional inputs rather than prerequisites.

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-53-01 | Six queue Quick Connects exist | `aws connect list-quick-connects` returns all six |
| AC-53-02 | Quick Connects visible in agent CCP transfer panel | Log in as test agent; open CCP transfer panel; confirm all Quick Connects appear |
| AC-53-03 | Blind transfer routes caller to correct queue | Initiate blind transfer to Sales; confirm caller arrives in Sales queue |
| AC-53-04 | Quick Connects associated with all queues | Each queue has five Quick Connects (all other queues) |
| AC-53-05 | Warm consult flow export exists only when warm consult mode is enabled | `terraform output warm_transfer_consult_flow_id` returns a flow ID when enabled and null otherwise |
| AC-53-06 | Module activation is manifest/catalog controlled | Deployment manifest enables the module and the PRD makes no activation claim based on `deployment_profile` |
| AC-53-07 | Current repo conventions are used | Terraform uses partial `s3` backend, `>= 1.14.0`, and AWS provider `~> 6.0` |
| AC-53-08 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Quick Connect association matrix (6×5 = 30 associations) creates long apply time | Low | Low | Terraform for_each handles this efficiently. Apply time < 2 minutes for 30 associations. |
| Warm transfer leaves caller on hold indefinitely if consultation agent does not accept | Low | Medium | Warm transfer flow sets a 30-second timeout — caller is returned to the original agent if destination does not accept within 30 seconds. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-53-01 | Should external number Quick Connects be provisioned for common external transfer destinations (e.g., billing vendor, external escalation line)? | Open — add external Quick Connects via the operations runbook using `aws connect create-quick-connect` with type PHONE_NUMBER. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Six queue Quick Connects. Full cross-queue association matrix. Transfer and warm transfer flows. |
| 1.2.0 | 2026-04-06 | — | Implementation-readiness hardening: made warm consult explicitly conditional on PRD-54 conferencing, replaced placeholder inline flow content with repo-owned flow templates, made the warm consult output nullable when disabled, and aligned plan artifact naming with current repo conventions. |
| 1.1.0 | 2026-04-05 | — | Added the repo-owned modularity section, made PRD-52 consult-whisper behavior optional, normalized backend/state-key conventions, and brought the Terraform examples in line with the functional requirements. |
