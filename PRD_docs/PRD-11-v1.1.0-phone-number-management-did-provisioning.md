# PRD-11 — Phone Number Management & DID Provisioning

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-11 |
| **Version** | 1.4.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-10 (Connect instance ID and ARN), PRD-14 must be deployed before any porting cutover begins |
| **Blocks** | PRD-14 (Contact Flow Framework — flows must be associated with phone numbers), PRD-90 (migration state imports claimed/imported number inventory) |
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
| `path` | `modules/l1-phone-numbers` |
| `capability_packs` | `["core-telephony"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance"]` |
| `state_key` | `l1-phone-numbers/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `phone-numbers.tfvars` |
| `supports_destroy` | `false` |
| `supports_operator_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Not consumed. PRD-11 does not depend on audit or alarm sinks. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `conditional` |
| `retention_notes` | Phone numbers are retained by default. Terraform keeps `prevent_destroy` enabled unless an explicitly approved operator destroy run passes the temporary lifecycle override. Numbers remain a scarce external resource and must not be released by casual Terraform destroy. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

A PBX without phone numbers is unreachable. This PRD provisions the Direct Inward Dialing (DID) numbers that callers use to reach the platform and associates them with the Connect instance. It establishes the number inventory management pattern — tracking which numbers exist, what their purpose is, and what area code preference was requested — in a way that is version-controlled, auditable, and portable across environments.

Phone number provisioning in Amazon Connect is a two-step process: claim the number from the AWS telephony inventory, then associate it with a contact flow. The association step depends on PRD-14 (Contact Flow Framework). This PRD handles the claim step and establishes the association contract that PRD-14 fulfills.

### What Problem It Solves

- Claims DID phone numbers from the Amazon Connect telephony inventory for each environment
- Establishes the number inventory as a Terraform-managed resource so that number assignments are version-controlled and auditable
- Supports optional area code preference (`prefix`) per number so that newly claimed numbers can be biased toward a desired NPA
- Provides the association mechanism that links each claimed number to a specific contact flow (populated by PRD-14)
- Manages the number porting workstream for clients migrating from legacy systems (RingCentral, 8x8, Cisco, Avaya, Asterisk) — ported numbers follow a different provisioning path than newly claimed numbers
- Establishes the country code and number type (DID vs. toll-free) as explicit configuration

### Important: What Terraform Does and Does Not Control

**Terraform controls:** whether a number is claimed, its metadata (description, tags), and its association with a contact flow (via PRD-14).

**Terraform does not control:** the exact E.164 digits assigned. When you add an entry to the number inventory and apply, AWS assigns the next available number from their telephony pool for the specified country, type, and optional prefix. The actual digits are returned as Terraform outputs after the apply — they are not inputs.

For clients with existing numbers that must be preserved, those numbers are brought into Connect via carrier porting (a process that takes 2–4 weeks and cannot be automated). After porting completes, the number is imported into Terraform state using `terraform import`. See Section 12 and the platform runbooks for the full procedure.

### How It Fits the Overall Architecture

PRD-11 is a pure **number inventory** — it claims digits, tags them, and exports ARNs. Routing logic lives entirely in PRD-14 (contact flows), PRD-12 (queues), and PRD-13 (hours of operation). A number claimed by this module is reachable from the PSTN immediately after apply, but callers will receive the Connect default disconnect message until PRD-14 associates a contact flow.

```
dev.tfvars (phone_numbers map)
        ↓
  l1-phone-numbers (PRD-11) — claims digits, exports ARNs
        ↓
  PRD-14 (Contact Flow Framework) — associates number → flow
        ↓
  PRD-12 (Queue Architecture) — flows route callers into queues
        ↓
  Agent answers
```

### Number Porting Note

The platform consolidates from on-premises PBX (Cisco/Avaya/Asterisk) and cloud PBX (RingCentral, 8x8, Vonage). Existing phone numbers in those systems may need to be ported to Amazon Connect. Porting is a carrier-level process that takes 2–4 weeks and cannot be automated by Terraform.

**Critical sequencing requirement:** PRD-14 (contact flows) must be fully deployed and tested in Connect before any porting request is submitted. The reason: when a port completes, the number goes live in Connect immediately. If no contact flow is associated at that moment, callers hear a dead disconnect tone. The cutover window is narrow and there is no graceful fallback unless interim call forwarding has been pre-configured (see Section 12 and the porting runbook).

The full porting workstream is defined in PRD-90 (Migration State, Layer 9).

---

## 3. GOALS

### Goals

- Provision a configurable set of DID phone numbers claimed from the Amazon Connect number inventory
- Support optional area code preference (`prefix`) per number for newly claimed numbers
- Support both US and international number claiming via country code variable
- Support both DID (local) and toll-free number types
- Establish the number inventory as a module-scoped tfvars file — adding or removing numbers requires only a tfvars change, no module code changes
- Export number ARNs for consumption by PRD-14 (contact flow association)
- Document the ported number import process for the migration workstream
- Document the interim call forwarding strategy for zero-downtime cutover
- Apply consistent tagging to all numbers for cost allocation and operational tracking

### Non-Goals

- This PRD does not associate numbers with contact flows — that is PRD-14
- This PRD does not implement number porting — that is PRD-90 (Migration State, Layer 9)
- This PRD does not configure IVR or call routing logic — that is PRD-14
- This PRD does not configure outbound caller ID — that is PRD-54
- This PRD does not perform pre-LOA portability verification — that is PRD-15
- This PRD does not check spam reputation or STIR/SHAKEN attestation — that is PRD-16
- This PRD does not manage CNAM registry submissions — that is PRD-17
- This PRD does not implement E911 location registration — that is PRD-18
- This PRD does not detect routing drift between Terraform state and Connect API — that is PRD-19

---

## 4. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Claims numbers via Terraform and manages the number inventory as code. Never claims numbers manually in the Connect console.

**Operations Manager** — Requests new numbers or number changes via a pull request to the phone number tfvars file. Does not need AWS console access to manage numbers.

**Migration Lead** — Coordinates the porting of existing numbers from legacy systems. Uses the porting documentation in this PRD and the platform runbooks to manage carrier interactions and cutover timing.

**Finance / Cost Allocation** — Reviews number tags to allocate phone number costs to business units.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-11-01 | Platform Engineer | As the platform engineer, I want all phone numbers provisioned via Terraform so that the number inventory is version-controlled | All claimed numbers exist in Terraform state |
| US-11-02 | Platform Engineer | As the platform engineer, I want to add a new number by editing tfvars only so that number management does not require code changes | Adding an entry to the `phone_numbers` variable and applying provisions the number |
| US-11-03 | Platform Engineer | As the platform engineer, I want to specify an area code preference per number so that newly claimed numbers are biased toward a desired NPA | `prefix` attribute accepted per number; apply fails with a clear error if the prefix has no available inventory |
| US-11-04 | Operations Manager | As the operations manager, I want each number tagged with its business purpose so that cost allocation reports are meaningful | Each number has `Purpose` and `CostCenter` tags |
| US-11-05 | Migration Lead | As the migration lead, I want a documented process for importing ported numbers into Terraform state so that the migration does not require re-provisioning | Ported number import procedure documented in Section 12 and in the platform runbook |
| US-11-06 | Migration Lead | As the migration lead, I want an interim call forwarding strategy so that existing numbers remain reachable during the porting window | Interim forwarding procedure documented in Section 12 and in the platform runbook |
| US-11-07 | Platform Engineer | As the platform engineer, I want number ARNs exported from this module so that PRD-14 can associate them with contact flows without re-querying the Connect API | All number ARNs available as Terraform outputs |

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Phone Number Claiming
The system must provision phone numbers using the `aws_connect_phone_number` resource for each entry in the `phone_numbers` input variable. Each number must be associated with the Connect instance from PRD-10.

### FR-002 — Number Inventory Variable
The phone number inventory must be defined as a `map(object)` Terraform variable in a module-scoped tfvars file (`environments/phone-numbers/dev.tfvars`). Each map entry represents one phone number with the following attributes: `description`, `type` (DID or TOLL_FREE), `country_code`, `prefix` (optional area code hint), `purpose`, and `cost_center`. The map key is a human-readable identifier used in resource naming and tagging.

### FR-003 — Number Types Supported
The system must support the following number types via the `type` attribute per number entry:

| Type | AWS Value | Use Case |
|---|---|---|
| DID | `DID` | Local inbound numbers |
| Toll-Free | `TOLL_FREE` | National inbound numbers (US 800/888/877 etc.) |

### FR-004 — Country Code Support
Each number entry must specify a `country_code` attribute (ISO 3166-1 alpha-2 format, e.g. `US`, `GB`, `AU`). The system must support any country code supported by Amazon Connect for DID provisioning.

### FR-005 — Area Code Preference
Each number entry may optionally specify a `prefix` attribute (e.g. `+1212`, `+1415`). When provided, AWS will attempt to claim a number matching that prefix. If no inventory is available for the requested prefix, the apply will fail with an error — the engineer must either try a different prefix or set `prefix = null` to accept any available number. AWS does not guarantee prefix availability.

### FR-006 — Number Tags
Each provisioned number must be tagged with the platform common tags (`Environment`, `ManagedBy`, `OrgName`, `Layer`, `PRD`) plus three number-specific tags: `NumberKey` (the map key from the inventory), `Purpose` (e.g., `main-inbound`, `sales`, `support`, `billing`), and `CostCenter` (e.g., the business unit responsible for the number's cost). Tags are applied via `merge(local.common_tags, {...})` to ensure platform consistency.

### FR-007 — Number ARN Exports
All provisioned number ARNs must be exported as a `map(string)` output keyed by the same human-readable identifier used in the input variable. PRD-14 iterates this map to create contact flow associations.

### FR-008 — Ported Number Import Pattern
Numbers ported from legacy systems cannot be claimed via `aws_connect_phone_number` — they are already in the Connect instance after porting is complete. The module must support importing ported numbers into Terraform state using `terraform import`. The import command format and post-import steps must be documented in Section 12.

### FR-009 — Number Description
Each provisioned number must have its `description` attribute set to the human-readable description from the input variable. This description is visible in the Connect console and in the number inventory output.

### FR-010 — Remote State Dependency on PRD-10
The module must read the Connect instance ARN from PRD-10 remote state. The `target_arn` for all `aws_connect_phone_number` resources is sourced from `data.terraform_remote_state.connect_instance.outputs.connect_instance_arn`. No hardcoded instance IDs or ARNs.

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### Availability
Phone numbers in Amazon Connect are managed by the AWS telephony infrastructure. Number availability and reliability are governed by AWS carrier SLAs. Amazon Connect is used by large enterprise contact centers; the default concurrent call quota of 10 is a soft limit raised via service quota request, not an architectural ceiling.

### Scale
The number inventory scales by adding entries to the `phone_numbers` variable. There is no architectural limit imposed by this module. AWS default limit is 10 phone numbers per instance — this must be increased via service limit request before deploying more than 10 numbers. The service limit increase request is documented in PRD-10 Section 8.

### Security
- Number management is controlled exclusively via Terraform and the GitHub Actions pipeline
- No engineer claims or releases numbers manually in the Connect console
- Number ARNs are not sensitive but are tracked in Terraform state, which is encrypted via PRD-00 and PRD-02 KMS keys

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 1.1 | Phone number inventory documented and version-controlled | Terraform state, `phone_numbers` variable in tfvars |
| PCI-DSS Req 2.2 | System component inventory | `phone_number_inventory` Terraform output |
| SOC 2 CC6.1 | Number management access controlled via pipeline | GitHub Actions approval gates from PRD-01 |

---

## 7. ARCHITECTURE

### Component Diagram

```
┌───────────────────────────────────────────────────────────────────┐
│                    PHONE NUMBER MANAGEMENT                        │
│                                                                   │
│  environments/phone-numbers/dev.tfvars                           │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │  main-inbound:  { type: DID, country: US, prefix: null, ... }│ │
│  │  sales:         { type: DID, country: US, prefix: +1212, ...}│ │
│  │  support:       { type: DID, country: US, prefix: null, ... }│ │
│  │  tollfree-main: { type: TOLL_FREE, country: US, prefix: null}│ │
│  └────────────────────────────┬─────────────────────────────────┘ │
│                               │ for_each                          │
│                               ▼                                   │
│  ┌───────────────────────────────────────────────────────────────┐ │
│  │           aws_connect_phone_number (for_each)                 │ │
│  │                                                               │ │
│  │  target_arn  → Connect Instance ARN (from PRD-10 state)       │ │
│  │  prefix      → area code hint (optional, per number)          │ │
│  │  Status: CLAIMED                                              │ │
│  │  Tags: Environment, ManagedBy, OrgName, Layer, PRD,            │ │
│  │        NumberKey, Purpose, CostCenter (via local.common_tags)  │ │
│  │  lifecycle: prevent_destroy = true                            │ │
│  └────────────────────────────┬─────────────────────────────────┘ │
│                               │                                   │
│                               ▼                                   │
│  outputs: phone_number_arns, phone_number_ids,                   │
│           phone_number_inventory (E.164 digits, ARN, type, ...)   │
│                                                                   │
│  Consumed by PRD-14 to associate numbers with contact flows       │
└───────────────────────────────────────────────────────────────────┘
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| Connect instance (PRD-10) | Inbound | `target_arn` for number association — read from remote state |
| PRD-14 (Contact Flow Framework) | Outbound | Number ARNs used to associate flows to numbers |
| PRD-90 (Migration State, Layer 9) | Parallel | Ported number import into this module's state |
| PRD-15 (Number Portability Verification) | Outbound | Pre-LOA eligibility check gate — number inventory provides the numbers to verify |
| PRD-16 (Spam Reputation & STIR/SHAKEN) | Outbound | Post-claim reputation check gate — number inventory provides numbers to scan |
| PRD-17 (CNAM Registry Management) | Outbound | CNAM provisioner reads number inventory to register caller ID names |
| PRD-18 (E911 Emergency Services Compliance) | Outbound | E911 location registry links agent assignments to DIDs in this inventory |
| PRD-19 (Routing Drift Detection) | Outbound | Drift detector reads Terraform state from this module's S3 state file to compare expected vs actual routing |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `phone_number_arns` | map(string) | Map of number key to ARN | PRD-14 for contact flow association |
| `phone_number_ids` | map(string) | Map of number key to phone number ID | PRD-51 (CCP outbound caller ID config) |
| `phone_number_inventory` | map(object) | Full inventory including actual E.164 number, ARN, type, country, `prefix_requested` (what was asked for, not what was granted) | Operations runbooks, PRD-90 |

### Dependency Inversion Note for Migration Deployments

In a greenfield deployment, the standard layer order applies: PRD-11 → PRD-14.

In a migration deployment (porting existing numbers), the order has a hard constraint:

1. PRD-14 must be deployed and contact flows tested before any porting LOA is submitted
2. Interim call forwarding from the legacy number to a Connect DID must be active before the LOA is submitted
3. Porting completes → number arrives in Connect → Terraform import → PRD-14 associates flow → forwarding removed

Failing to deploy PRD-14 before porting results in a production outage at the FOC cutover date.

---

## 8. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-phone-numbers/           # PRD-11
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── backend.tf

environments/
└── phone-numbers/
    ├── dev.tfvars                  # dev number inventory
    └── prod.tfvars                 # prod number inventory
```

Note: The number inventory is in a module-scoped tfvars file (`environments/phone-numbers/`) separate from the platform config (`environments/dev.tfvars`). This allows the operations manager to manage numbers without touching platform-level variables.

### Key Resources Declared

```hcl
# main.tf

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Layer   = "L1"
      PRD     = "PRD-11"
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

locals {
  connect_instance_arn = data.terraform_remote_state.connect_instance.outputs.connect_instance_arn

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-11"
  }
}

resource "aws_connect_phone_number" "inventory" {
  for_each = var.phone_numbers

  target_arn   = local.connect_instance_arn
  country_code = each.value.country_code
  type         = each.value.type
  description  = each.value.description
  prefix       = each.value.prefix

  tags = merge(local.common_tags, {
    NumberKey  = each.key
    Purpose    = each.value.purpose
    CostCenter = each.value.cost_center
  })

  lifecycle {
    prevent_destroy = true
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

variable "phone_numbers" {
  description = <<-EOT
    Phone number inventory map. Each key is a human-readable identifier (e.g. main-inbound,
    sales, support). Modify this map in environments/phone-numbers/<env>.tfvars to add or
    remove numbers — no module code changes required.

    Digits are NOT specified here. AWS assigns the next available number from its telephony
    pool for the given country_code, type, and optional prefix. The actual E.164 number
    is available after apply in the phone_number_inventory output.

    prefix: Optional area code hint in E.164 prefix format (e.g. "+1212" for NYC, "+1415"
    for San Francisco). AWS will attempt to claim a number matching this prefix. If no
    inventory is available, the apply fails — try a different prefix or set null to accept
    any available number. Prefix availability is not guaranteed.

    IMPORTANT: default is empty map. The phone number inventory MUST be supplied via
    environments/phone-numbers/<env>.tfvars. Running apply without the tfvars file
    provisions zero numbers (safe). Running apply with the tfvars file provisions
    exactly the numbers listed. Each claimed number accrues charges immediately.
  EOT

  type = map(object({
    description  = string
    type         = string           # DID or TOLL_FREE
    country_code = string           # ISO 3166-1 alpha-2 e.g. US, GB, CA, AU
    prefix       = optional(string) # E.164 prefix e.g. "+1212". null = any available.
    purpose      = string           # e.g. main-inbound, sales, support, billing
    cost_center  = string           # Business unit for cost allocation
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      contains(["DID", "TOLL_FREE"], v.type)
    ])
    error_message = "Each phone_numbers entry type must be DID or TOLL_FREE."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      v.prefix == null || can(regex("^\\+[0-9]{1,6}$", v.prefix))
    ])
    error_message = "Each prefix must be null or an E.164 prefix string e.g. \"+1212\"."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      length(trimspace(v.purpose)) > 0 && length(trimspace(v.cost_center)) > 0
    ])
    error_message = "Each phone_numbers entry must have non-empty purpose and cost_center."
  }

  validation {
    condition = alltrue([
      for k, v in var.phone_numbers :
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) || length(k) == 1
    ])
    error_message = "Each phone_numbers map key must be lowercase alphanumeric with hyphens only (e.g. main-inbound, sales)."
  }
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-11. It exists for
# forward compatibility with the platform deployment profile contract
# (authoritative definition in PRD-00 bootstrap module). Every module
# declares this variable with the same schema and defaults so that:
#   - All modules accept the same deployment_profile from tfvars
#   - Modules that need conditional behavior (e.g. l0-account-baseline
#     uses .cross_region for KMS, l1-connect-instance uses
#     .optional_layers.sso_enabled for identity management) can reference
#     specific fields without changing their variable signature
#   - When the platform scales beyond single-instance (instance_count > 1),
#     PRD-11 may use .instance_count to scope phone numbers per instance
#
# Do not remove — this is intentional contract consistency, not dead code.
# -----------------------------------------------------------------------
variable "deployment_profile" {
  description = "Platform-wide deployment profile. Not consumed by PRD-11 — declared for contract consistency. See PRD-00 for authoritative schema."
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

### Number Inventory tfvars Files

```hcl
# environments/phone-numbers/dev.tfvars
# ---------------------------------------------------------------
# Phone Number Inventory — dev environment
# ---------------------------------------------------------------
# HOW TO ADD A NUMBER
#   1. Uncomment a stub below and fill in the fields, or copy a stub
#      and give it a new key.
#   2. Open a PR. CI will plan the change and show the new number
#      resource in the plan output.
#   3. Merge. The apply claims the number from the AWS telephony pool.
#   4. Check the phone_number_inventory output to see the actual E.164
#      digits that were assigned.
#
# HOW TO REMOVE A NUMBER (two-step process — prevent_destroy is active)
#   Step 1: Remove the lifecycle prevent_destroy block for that number
#           in main.tf, open a PR, merge, apply.
#   Step 2: Remove the entry from this file, open a PR, merge, apply.
#           The number is released back to the AWS pool permanently.
#           WARNING: Released numbers cannot be reclaimed.
#
# FIELD REFERENCE
#   type:         DID (local inbound) | TOLL_FREE (800/888/877 etc.)
#   country_code: ISO 3166-1 alpha-2 e.g. US, GB, CA, AU
#   prefix:       Optional area code hint e.g. "+1212" (NYC), "+1415" (SF).
#                 null = accept any available number in the country.
#                 AWS does not guarantee prefix availability. If unavailable,
#                 the apply fails with an error — try a different prefix.
#   purpose:      Human label for routing and reporting (main-inbound,
#                 sales, support, billing, etc.)
#   cost_center:  Business unit for cost allocation tagging.
#
# COST NOTE
#   Each US DID costs approximately $0.03/day (~$0.90/month).
#   Each US toll-free number costs approximately $0.06/day (~$1.80/month).
#   Numbers accrue charges immediately upon claim.
# ---------------------------------------------------------------

phone_numbers = {

  # --- ACTIVE (provisioned on first deploy) ---

  main-inbound = {
    description  = "Main inbound DID — primary customer-facing number"
    type         = "DID"
    country_code = "US"
    prefix       = "+1616" # West Michigan area code
    purpose      = "main-inbound"
    cost_center  = "operations"
  }

  # --- STUBS (uncomment and fill to provision) ---

  # sales = {
  #   description  = "Sales team direct DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null   # e.g. "+1212" to request a NYC area code
  #   purpose      = "sales"
  #   cost_center  = "sales"
  # }

  # support = {
  #   description  = "Customer support DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "support"
  #   cost_center  = "support"
  # }

  # billing = {
  #   description  = "Billing department direct DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "billing"
  #   cost_center  = "finance"
  # }

  # tollfree-main = {
  #   description  = "National toll-free main number"
  #   type         = "TOLL_FREE"
  #   country_code = "US"
  #   prefix       = null   # e.g. "+1800" or "+1888" — not guaranteed
  #   purpose      = "main-inbound-tollfree"
  #   cost_center  = "operations"
  # }

}
```

```hcl
# environments/phone-numbers/prod.tfvars
# ---------------------------------------------------------------
# Phone Number Inventory — prod environment
# ---------------------------------------------------------------
# See OQ-11-01: The complete production number inventory is a business
# decision. Replace the placeholder entries below with actual numbers
# required before prod apply.
#
# For ported numbers (existing client numbers from RingCentral, 8x8,
# Cisco, Avaya): do NOT add them here before porting is complete.
# After porting, import them into state using the procedure in
# connect-pbx/docs/runbooks/RB-11-02-porting-and-cutover.md,
# then add the entry to this file.
# ---------------------------------------------------------------

phone_numbers = {

  main-inbound = {
    description  = "Main inbound DID — primary customer number"
    type         = "DID"
    country_code = "US"
    prefix       = "+1616" # West Michigan area code
    purpose      = "main-inbound"
    cost_center  = "operations"
  }

  # sales = {
  #   description  = "Sales team direct DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "sales"
  #   cost_center  = "sales"
  # }

  # support = {
  #   description  = "Customer support DID"
  #   type         = "DID"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "support"
  #   cost_center  = "support"
  # }

  # tollfree-main = {
  #   description  = "National toll-free main number"
  #   type         = "TOLL_FREE"
  #   country_code = "US"
  #   prefix       = null
  #   purpose      = "main-inbound-tollfree"
  #   cost_center  = "operations"
  # }

}
```

### Outputs

```hcl
# outputs.tf

output "phone_number_arns" {
  description = "Map of number key to phone number ARN. Consumed by PRD-14 for contact flow association."
  value       = { for k, v in aws_connect_phone_number.inventory : k => v.arn }
}

output "phone_number_ids" {
  description = "Map of number key to phone number ID."
  value       = { for k, v in aws_connect_phone_number.inventory : k => v.phone_number_id }
}

output "phone_number_inventory" {
  description = "Full number inventory including actual E.164 number claimed, ARN, type, country, and prefix requested."
  value = {
    for k, v in aws_connect_phone_number.inventory : k => {
      phone_number     = v.phone_number
      arn              = v.arn
      type             = v.type
      country_code     = v.country_code
      prefix_requested = var.phone_numbers[k].prefix   # What was requested — may be null. Not the actual area code granted.
      description      = v.description
      purpose          = var.phone_numbers[k].purpose
      cost_center      = var.phone_numbers[k].cost_center
    }
  }
}
```

### Backend Configuration

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

Note: The backend block is intentionally empty. The shared backend config (`backend-nevs-cloud-dev.hcl`) provides bucket, region, encryption, and lock table. The state key is supplied per-module at init time: `-backend-config="key=l1-phone-numbers/terraform.tfstate"`. See the plan-apply runbook for the full init command pattern.

**Provider block:** This module declares an explicit `provider "aws"` block with `default_tags`, matching the pattern used by PRD-10 (l1-connect-instance) and other deployed modules. When running locally, the `AWS_PROFILE` environment variable selects the account; in CI/CD, the GitHub Actions OIDC role assumes the correct account via the terraform execution role.

---

## 9. EVENT SCHEMA

PRD-11 produces no EventBridge events and consumes no EventBridge events. Phone number provisioning is a configuration operation with no runtime event semantics.

---

## 10. API / INTERFACE CONTRACT

PRD-11 exposes no HTTP APIs. Its contract is Terraform outputs consumed by PRD-14.

### Downstream Consumption Pattern

```hcl
# PRD-14 reference pattern — reading phone number ARNs from remote state
data "terraform_remote_state" "phone_numbers" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-phone-numbers/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  phone_number_arns = data.terraform_remote_state.phone_numbers.outputs.phone_number_arns
}

# PRD-14 associates each number with a contact flow by updating the
# phone number's contact_flow_id attribute. See PRD-14 Section 8 for
# the authoritative implementation.
```

---

## 11. DATA MODEL

### State File Location

```
s3://{org}-tfstate-{account_id}/
└── {workspace}/
    └── l1-phone-numbers/
        └── terraform.tfstate
```

### Phone Number Lifecycle

| State | Description |
|---|---|
| `CLAIMED` | Number provisioned and held by the Connect instance. Reachable from PSTN but no routing configured — callers hear default Connect disconnect message. |
| `IN_USE` | Number associated with a contact flow (after PRD-14). Callers are routed. |
| `RELEASED` | Number released back to AWS pool — use `prevent_destroy` to prevent accidental release. Released numbers are permanently gone. |

All numbers provisioned by this module have `lifecycle { prevent_destroy = true }` applied. Releasing a number requires a deliberate two-step process: remove `prevent_destroy` in a separate PR/apply, then remove the tfvars entry in a second PR/apply. This prevents accidental release.

---

## 12. CI/CD SPECIFICATION

### Workflow Reference

```yaml
# ci.yml caller for PRD-11
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l1-phone-numbers

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l1-phone-numbers
      environment: ${{ inputs.environment }}
      extra_var_files: environments/phone-numbers/${{ inputs.environment }}.tfvars
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l1-phone-numbers
      environment: ${{ inputs.environment }}
      extra_var_files: environments/phone-numbers/${{ inputs.environment }}.tfvars
      plan_artifact_name: tfplan-modules/l1-phone-numbers-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

**Module-scoped tfvars — CI/CD integration note:**

PRD-11 is the first module that requires a second `-var-file` beyond the standard `environments/<env>.tfvars`. The reusable workflows (`tf-plan.yml`, `tf-apply.yml`) must support an optional `extra_var_files` input that appends additional `-var-file` flags to the `terraform plan` and `terraform apply` commands.

Implementation options for the reusable workflows:

1. **Explicit input (recommended):** Add an optional `extra_var_files` string input to `tf-plan.yml` and `tf-apply.yml`. When provided, the workflow appends `-var-file="../../${extra_var_files}"` to the terraform command. This is explicit and auditable — the caller declares exactly which additional tfvars are needed.

2. **Convention-based auto-detection:** The workflow scans for `environments/<module-scope>/<env>.tfvars` matching the module name and automatically includes it. This is more magical and harder to debug when things go wrong.

The convention for module-scoped tfvars paths is documented in `connect-pbx/docs/plan-apply-docs/plan-apply.md`.

### Init Command (local)

```bash
export AWS_PROFILE=nevs-cloud-dev
cd connect-pbx/modules/l1-phone-numbers

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-${PROFILE}.hcl" \
               -backend-config="key=l1-phone-numbers/terraform.tfstate"
# Note: the repo's runner scripts inject backend config from the module catalog.
# BOOTSTRAP_DIR and PROFILE are set by the CI/CD runner environment.
terraform workspace select dev

terraform plan  -var-file="../../environments/dev.tfvars" \
                -var-file="../../environments/phone-numbers/dev.tfvars"

terraform apply -var-file="../../environments/dev.tfvars" \
                -var-file="../../environments/phone-numbers/dev.tfvars"
```

### Ported Number Import Procedure (summary — full detail in runbook RB-11-02)

After a carrier port completes and the number is confirmed in the Connect instance:

```bash
# Step 1: Confirm the number is visible in Connect
aws connect list-phone-numbers-v2 \
  --instance-id {instance_id} \
  --query "ListPhoneNumbersSummaryList[?PhoneNumber=='+1XXXXXXXXXX']"

# Step 2: Capture the phone number ID
PHONE_NUMBER_ID=$(aws connect list-phone-numbers-v2 \
  --instance-id {instance_id} \
  --query "ListPhoneNumbersSummaryList[?PhoneNumber=='+1XXXXXXXXXX'].PhoneNumberId" \
  --output text)

# Step 3: Add the entry to environments/phone-numbers/dev.tfvars
# (without applying — import first, then plan should show no changes)

# Step 4: Import into Terraform state
terraform import \
  'aws_connect_phone_number.inventory["{your_key}"]' \
  ${PHONE_NUMBER_ID}

# Step 5: Verify — plan should show no changes
terraform plan -var-file="../../environments/dev.tfvars" \
               -var-file="../../environments/phone-numbers/dev.tfvars"

# Step 6: Commit the updated tfvars and confirm clean plan in CI
```

See `connect-pbx/docs/runbooks/RB-11-02-porting-and-cutover.md` for the complete procedure including interim forwarding, FOC day runbook, and unforward steps.

### Rollback Procedure

- **Adding a number:** Remove the entry from the phone-numbers tfvars and apply. The number is released back to the AWS pool. Note: `prevent_destroy` must be removed first in a separate apply.
- **Removing a number by accident:** Numbers cannot be reclaimed with the same digits after release — AWS assigns from a pool. Contact AWS support immediately if a number is accidentally released.
- **Changing number type or country:** Not possible on an existing number. Release and reclaim.
- **Changing prefix:** Not applicable after claim — prefix is only used at claim time. The number has already been assigned.

---

## 13. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-11-01: Phone Number Not Associated with Contact Flow**
- Source: Custom metric — Lambda checks `aws connect list-phone-numbers-v2` for numbers in `CLAIMED` status (no flow association) more than 24 hours after provisioning
- Action: SNS alert to platform alert topic
- Severity: Medium — number is reachable but calls will fail with a default Connect message
- Note: This alarm is described here but Terraform resources (Lambda, EventBridge rule) are implemented in PRD-19 (Routing Drift Detection), which supersedes this alarm definition. ALARM-19-01 covers the NO_FLOW drift type, which is a superset of what this alarm describes. See PRD-19 for the authoritative implementation.

### SOC 2 and PCI Evidence Artifacts

| Artifact | Demonstrates |
|---|---|
| `phone_number_inventory` Terraform output | System component inventory — PCI-DSS Req 2.2 |
| Terraform state (version-controlled number history) | SOC 2 CC6.1 — change management |

---

## 14. ACCEPTANCE CRITERIA

### Definition of Done

| ID | Criterion | Verification Method |
|---|---|---|
| AC-11-01 | All numbers in phone_numbers variable are claimed | `aws connect list-phone-numbers-v2` returns all expected numbers with status CLAIMED |
| AC-11-02 | Each number is associated with the correct Connect instance | `aws connect describe-phone-number` returns correct instance ARN |
| AC-11-03 | Each number has all required tags (Environment, ManagedBy, OrgName, Layer, PRD, NumberKey, Purpose, CostCenter) | `aws connect list-tags-for-resource` returns all 8 tags for each number |
| AC-11-04 | phone_number_arns output contains all claimed numbers | `terraform output phone_number_arns` returns map with one entry per number |
| AC-11-05 | phone_number_inventory output includes actual E.164 digits | `terraform output phone_number_inventory` shows real phone number for each key |
| AC-11-06 | prevent_destroy lifecycle is applied to all numbers | Attempt `terraform destroy` — confirm numbers are protected |
| AC-11-07 | Adding a number via tfvars change provisions the number | Add a test entry, apply, confirm new number appears in Connect |
| AC-11-08 | prefix attribute influences area code when set | Set prefix="+1212", apply, confirm claimed number is in 212 NPA (best effort — may fail if unavailable) |
| AC-11-09 | Removing prevent_destroy and then the entry releases the number | Two-step release procedure tested in dev |
| AC-11-10 | Ported number import procedure works correctly | Import a dev number using the documented procedure; confirm clean plan afterward |
| AC-11-11 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l1-phone-numbers/` returns clean output |
| AC-11-12 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l1-phone-numbers/` returns clean output |
| AC-11-13 | Apply with no tfvars file provisions zero numbers | `terraform apply` with only `environments/dev.tfvars` (no phone-numbers tfvars) produces empty plan — no numbers claimed |
| AC-11-14 | Validation rejects empty purpose or cost_center | Set `purpose = ""` in tfvars, run plan — confirm validation error message |
| AC-11-15 | Validation rejects invalid map key format | Set key to `Sales Team` (uppercase, space) in tfvars, run plan — confirm validation error message |

---

## 15. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Requested prefix (area code) unavailable in AWS inventory | Medium | Low | Apply fails with a clear error. Engineer retries with a different prefix or sets null. Document expected behavior in runbook. |
| Number accidentally released due to tfvars entry removal | Low | High | `prevent_destroy = true` requires two-step release. Documented in Section 12 and runbook RB-11-01. |
| Phone number limit (default 10) exceeded in prod without prior limit increase | High | High | Service limit increase must be completed before prod apply with >10 numbers. Documented in PRD-10 Section 8. |
| Ported number not available in Connect after carrier completes porting | Low | Medium | Verify via `list-phone-numbers-v2` before importing. PRD-90 and runbook RB-11-02 define the porting verification checklist. |
| Port completes with no contact flow ready — production outage at cutover | Medium | High | PRD-14 must be deployed and tested before LOA is submitted. Interim call forwarding must be active before port begins. See runbook RB-11-02. |
| Toll-free number not available in the requested country | Low | Medium | Not all countries support toll-free via Connect. Verify AWS Connect supported number types per country before adding to inventory. |
| Ported number ID format differs from claimed number format after porting | Low | Low | Always verify phone number ID via `list-phone-numbers-v2` after porting. Do not assume ID format. See runbook RB-11-02. |

---

## 16. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-11-01 | What is the complete phone number inventory for production? | **PAUSE REQUIRED** | Business decision required before prod apply. Operations manager and platform engineer to supply actual number requirements. |
| OQ-11-02 | Are any existing numbers from legacy systems being ported to Connect? If yes, how many and which ones? | Open | Feeds into PRD-90 (Migration State) and PRD-15 (Number Portability Verification). Ported numbers use the import procedure, not claiming. Pre-LOA eligibility check via PRD-15 is required before any LOA submission. |
| OQ-11-03 | Are international numbers (non-US) required? | Open | International DID availability varies by country in Amazon Connect. Verify per-country availability before adding to inventory. |
| OQ-11-04 | What is the interim forwarding carrier for each client's legacy numbers during the porting window? | Open | Required for runbook RB-11-02. Each client's legacy carrier (RingCentral, 8x8, etc.) has different forwarding configuration procedures. |

---

## 17. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. |
| 1.1.0 | 2026-03-22 | — | Added `prefix` attribute for area code preference. Clarified that E.164 digits are outputs not inputs. Added remote state data source for PRD-10 instance ARN (FR-010). Separated number inventory into module-scoped tfvars (`environments/phone-numbers/`). Added full annotated tfvars with stubs. Fixed backend block to use empty `backend "s3" {}` pattern consistent with other modules. Clarified ALARM-11-01 Terraform resources are deferred. Added dependency inversion note for migration deployments. Updated porting summary and cross-referenced runbooks RB-11-01 and RB-11-02. |
| 1.2.0 | 2026-03-22 | — | Expanded Non-Goals to reference PRD-15 through PRD-19 (portability verification, spam reputation, CNAM, E911, routing drift). Fixed PRD-111 naming collision — migration state workstream is PRD-90 (Layer 9), not PRD-111 (Shared Services Account Architecture, Layer 11). Expanded Integration Points table to include PRD-15 through PRD-19. Updated ALARM-11-01 note to reference PRD-19 as implementing PRD (NO_FLOW drift type). Updated OQ-11-02 to reference PRD-15 and PRD-90 together. Updated Risks table to fix PRD-111 → PRD-90 reference. |
| 1.3.0 | 2026-03-22 | — | Architectural quality pass. Replaced `merge()` no-op with `local.common_tags` pattern (Environment, ManagedBy, OrgName + Layer/PRD). Changed `phone_numbers` default from single-DID to empty map `{}` — prevents accidental number claiming; tfvars file is now required for any provisioning. Removed `layer_id` and `prd_id` variables — values hardcoded in `local.common_tags`. Added `deployment_profile` explanatory comment documenting contract consistency rationale. Added validation for non-empty `purpose` and `cost_center`. Added validation for lowercase-hyphen map key format. Renamed output field `prefix` → `prefix_requested` to clarify it shows the request, not the granted area code. Added provider inheritance note to backend section. Added `extra_var_files` input to CI/CD workflow YAML for module-scoped tfvars support. |
| 1.4.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section. Normalized bootstrap path in CI/CD examples to use runner-injected backend config. |
