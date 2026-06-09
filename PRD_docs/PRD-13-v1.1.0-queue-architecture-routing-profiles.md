# PRD-13 — Queue Architecture & Routing Profiles

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-13 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-10 (Connect instance ID), PRD-12 (Hours of Operation IDs), PRD-02 (KMS key) |
| **Blocks** | PRD-14 (Contact Flow Framework), PRD-50 (Agent Hierarchy — routing profile assignment), PRD-54 (Agent Transfer Service) |
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
| `path` | `modules/l1-queue-architecture` |
| `capability_packs` | `["core-telephony"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-hours-of-operation"]` |
| `state_key` | `l1-queue-architecture/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `null` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 platform alert topic | **optional input** — queue alarms publish to the platform alert topic only when `alarm_action_arns` is supplied. PRD-03 is not required for queue provisioning. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `destroyable` |
| `retention_notes` | Queues are configuration resources with no persistent data. Individual queues can be disabled via the `enabled` flag without destroying the module. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Queues are the core routing mechanism of any PBX. A caller entering the system must be placed in a queue before an agent can be connected. Without queues, contact flows have nowhere to send callers. This PRD provisions the complete queue architecture — every queue, every routing profile, and the tiered assignment model that determines which agents handle which queues and in what priority order.

This PRD is designed around a templatized, data-driven pattern. Every queue is an entry in a Terraform variable map. Adding, removing, or customizing a queue is a `terraform.tfvars` change with no code modification. Every routing strategy option is available per queue via a toggle — the platform does not impose a single routing algorithm. Routing profiles follow a tiered model: every agent has a primary queue they serve and one or more overflow queues they serve when their primary queue is quiet or when overflow thresholds are reached.

### What Problem It Solves

- Provisions six department queues (General, Sales, Customer Support, Billing, Technical Support, Escalations) plus an internal system queue used for transfers and voicemail callbacks
- Establishes a templatized queue pattern that makes adding, removing, or customizing any queue a configuration change — not a code change
- Implements per-queue routing strategy selection: longest idle, least occupied, or round robin — configurable independently per queue
- Provisions tiered routing profiles: agents have a primary queue assignment and a configurable set of overflow queues with explicit priority ordering
- Exports queue IDs, queue ARNs, and routing profile IDs for consumption by PRD-14 (contact flows) and PRD-50 (agent hierarchy)

### How It Fits the Overall Architecture

PRD-13 sits between PRD-12 (hours of operation, which queues reference) and PRD-14 (contact flows, which route callers to queues). Routing profiles provisioned here are assigned to agents in PRD-50. The queue ARNs exported here are used in PRD-14 contact flow `Transfer to Queue` blocks. Quick connects for agent-to-agent transfer (PRD-53) reference queue IDs from this module.

---

## 4. GOALS

### Goals

- Provision all queues as a templatized `map(object)` variable — every queue attribute is configurable per entry
- Support per-queue routing strategy selection from all available Connect routing algorithms
- Provision tiered routing profiles with explicit primary and overflow queue assignments
- Export all queue IDs, ARNs, and routing profile IDs for downstream consumption
- Make queues togglable — setting `enabled = false` on a queue entry removes it without deleting the variable entry
- Provision a dedicated system queue used for internal transfers, voicemail callbacks, and outbound campaigns
- Implement queue-level maximum wait time and overflow behavior as configurable attributes

### Non-Goals

- This PRD does not implement contact flow logic for routing callers to queues — that is PRD-14
- This PRD does not assign routing profiles to agents — that is PRD-50
- This PRD does not implement skills-based routing attributes — that requires Connect Routing Profiles with channel concurrency settings beyond the scope of this PRD; flagged in OQ-13-03
- This PRD does not implement queue callbacks — that is PRD-54
- This PRD does not implement voicemail overflow — that is PRD-60

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Provisions the initial queue set from the variable map. Maintains queue configuration as code. Never creates queues manually in the Connect console.

**Operations Manager** — Adds, removes, or modifies queues by editing the `queues` variable in `terraform.tfvars`. Submits changes as a pull request through the standard pipeline.

**Workforce Manager** — Designs the routing profile tier structure determining which agents handle which queues. Expressed in the `routing_profiles` variable.

**Connect Administrator** — References queue names in the Connect console for operational monitoring and reporting.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-13-01 | Platform Engineer | As the platform engineer, I want all queues provisioned as Terraform resources so that queue configuration is version-controlled | All queues in Terraform state |
| US-13-02 | Operations Manager | As the operations manager, I want to add a new queue by adding an entry to tfvars so that no code change is required | New queue entry in variable → apply → queue exists in Connect |
| US-13-03 | Operations Manager | As the operations manager, I want to disable a queue without deleting its configuration so that I can re-enable it without data loss | `enabled = false` removes the queue resource while preserving the variable entry |
| US-13-04 | Workforce Manager | As the workforce manager, I want each routing profile to have a primary queue and configurable overflow queues so that agents are always utilized | Routing profiles have ordered queue channel configurations with priority settings |
| US-13-05 | Operations Manager | As the operations manager, I want each queue to have its own routing strategy so that high-volume queues and specialized queues can be tuned independently | `routing_strategy` attribute per queue selects the algorithm |
| US-13-06 | Platform Engineer | As the platform engineer, I want queue IDs and ARNs exported so that PRD-14 and PRD-50 can reference them without querying the Connect API | All IDs and ARNs available as Terraform outputs |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Templatized Queue Provisioning
The system must provision queues using a `for_each` loop over a `queues` input variable of type `map(object)`. Each entry fully specifies one queue. No queue is hard-coded in the Terraform module — all queue definitions live in `terraform.tfvars`. The module code must not change when queues are added, removed, or modified.

### FR-002 — Queue Toggle
Each queue entry must include an `enabled` boolean attribute. When `enabled = false`, the queue resource must not be created or must be destroyed on next apply. When `enabled = true` (default), the queue is created and active. The `for_each` must filter to only enabled queues: `for_each = { for k, v in var.queues : k => v if v.enabled }`.

### FR-003 — Queue Attributes
Each queue entry in the variable map must support the following attributes:

| Attribute | Type | Description |
|---|---|---|
| `enabled` | bool | Whether this queue is active |
| `name` | string | Human-readable queue name displayed in Connect console |
| `description` | string | Purpose of this queue |
| `hours_of_operation_key` | string | Key into `hours_of_operation_ids` output from PRD-12 |
| `routing_strategy` | string | `LONGEST_IDLE`, `LEAST_OCCUPIED`, or `ROUND_ROBIN` |
| `max_contacts` | number | Maximum callers allowed in queue before overflow (0 = unlimited) |
| `max_wait_minutes` | number | Maximum wait time in minutes before overflow routing in contact flow |
| `overflow_action` | string | `VOICEMAIL`, `CALLBACK`, or `DISCONNECT` — used in PRD-14 flow logic |
| `cost_center` | string | Business unit for cost allocation tagging |
| `priority` | number | Queue priority weight — lower number = higher priority (1 = highest) |

### FR-004 — Default Queue Set
The default `queues` variable must include the following seven queues. All are enabled by default. Each can be disabled, customized, or removed via tfvars:

| Key | Name | Strategy | Hours Key | Overflow | Priority |
|---|---|---|---|---|---|
| `general` | General-Inbound | LONGEST_IDLE | standard-business | VOICEMAIL | 3 |
| `sales` | Sales | LEAST_OCCUPIED | standard-business | VOICEMAIL | 2 |
| `customer-support` | Customer-Support | LONGEST_IDLE | standard-business | VOICEMAIL | 2 |
| `billing` | Billing | LONGEST_IDLE | standard-business | VOICEMAIL | 2 |
| `technical-support` | Technical-Support | LEAST_OCCUPIED | extended | VOICEMAIL | 2 |
| `escalations` | Escalations-Tier2 | LEAST_OCCUPIED | standard-business | CALLBACK | 1 |
| `system` | System-Internal | LEAST_OCCUPIED | twenty-four-seven | DISCONNECT | 5 |

The `system` queue is a reserved internal queue used for transfers, voicemail callbacks, and outbound. It must never be exposed to inbound callers via a contact flow.

### FR-005 — Routing Strategy Implementation
Amazon Connect natively supports two routing strategies at the routing profile level: `LONGEST_IDLE` (agent who has been idle longest receives the next contact) and `LEAST_OCCUPIED` (agent handling the fewest concurrent contacts). These are configured via the routing profile's queue channel configuration and are evaluated by Connect at contact-routing time.

The `routing_strategy` attribute on each queue entry is stored as a tag and in the `queue_config` output. It serves two purposes: (1) documentation of the intended routing behavior for each queue, and (2) it is consumed by PRD-14 contact flow logic for any custom routing decisions (e.g., distributing contacts across multiple queues before agent assignment).

**Note:** `ROUND_ROBIN` is not a native Connect routing strategy. It is included as a valid value for use in custom contact flow logic in PRD-14 — if a queue is tagged `ROUND_ROBIN`, the contact flow distributes callers across a set of queues in rotation rather than sending all callers to a single queue. If `ROUND_ROBIN` is not needed, restrict the validation to `LONGEST_IDLE` and `LEAST_OCCUPIED` only.

### FR-006 — Tiered Routing Profiles
The system must provision routing profiles using a `routing_profiles` input variable of type `map(object)`. Each routing profile entry defines a name, description, default outbound queue key, media concurrencies, an optional agent availability timer, and a list of queue channel configurations. Each queue channel configuration specifies the queue key, channel (VOICE, CHAT, or TASK), priority (1 = highest), and delay in seconds before the queue appears to the agent.

The tiered model works as follows:
- **Priority 1 (primary):** Agent's home queue. Calls presented immediately (delay = 0).
- **Priority 2 (secondary overflow):** Adjacent department queue. Calls presented after a configurable delay (default 120 seconds) when the agent has no priority-1 contacts.
- **Priority 3 (tertiary overflow):** General inbound. Calls presented after a longer delay (default 300 seconds) when the agent has no priority-1 or priority-2 contacts.

### FR-007 — Default Routing Profile Set
The default `routing_profiles` variable must include the following profiles:

| Key | Name | Primary Queue | Secondary Overflow | Tertiary Overflow |
|---|---|---|---|---|
| `sales-primary` | Sales-Primary | sales | general | — |
| `support-primary` | Support-Primary | customer-support | technical-support | general |
| `billing-primary` | Billing-Primary | billing | customer-support | general |
| `tech-support-primary` | TechSupport-Primary | technical-support | customer-support | general |
| `escalations-primary` | Escalations-Primary | escalations | — | — |
| `general-primary` | General-Primary | general | — | — |
| `omni` | Omni-All-Queues | All queues at P1, delay 0 | — | — |

The `omni` profile is for senior or overflow agents who can handle any queue. All queues (general, sales, customer-support, billing, technical-support, escalations) are assigned at priority 1 with delay 0 — these agents receive contacts from any queue immediately. The `escalations-primary` profile is restricted — agents on this profile only receive escalation contacts and never receive general overflow.

### FR-008 — Queue Maximum Contacts
When `max_contacts` is greater than 0, the queue must be configured with a maximum contacts in queue limit. Calls that arrive when the queue is at capacity must be handled by the contact flow overflow logic defined in PRD-14. When `max_contacts` is 0, no limit is applied.

### FR-009 — Output Exports
The module must export: queue IDs (map), queue ARNs (map), routing profile IDs (map), routing profile ARNs (map), and a convenience output `queue_config` that is the full resolved queue inventory including actual Connect resource IDs, enabling PRD-14 to build contact flow logic without additional API calls.

### FR-010 — CloudWatch Alarms
The module must provision CloudWatch alarms for queue health monitoring. Alarm actions are driven by an explicit `alarm_action_arns` input. When the list is empty, the module must remain deployable and the alarms still exist without requiring PRD-03 or any other shared sink. See Section 13 for alarm definitions.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
Queues and routing profiles are Connect configuration resources. Availability is governed by the Connect instance SLA from PRD-10.

### Scale

| Scale | Queue Count | Routing Profile Count | Notes |
|---|---|---|---|
| Small (default) | 7 | 7 | Default set, all enabled |
| Medium | Up to 50 | Up to 50 | Add entries to tfvars |
| Large / Enterprise | Up to 500 | Up to 500 | Connect default limit — request increase if needed |

The templatized pattern supports any number of queues and routing profiles without code changes. The only limit is the Connect service quota of 500 queues and 500 routing profiles per instance.

### Performance
- Queue assignment to agents via routing profiles is evaluated in real time by Connect
- Overflow delay timers (priority 2 at 120s, priority 3 at 300s) are configurable per routing profile entry
- No Terraform or Lambda is in the critical call routing path — Connect evaluates routing profiles natively

### API Limits
The Connect `CreateRoutingProfile` API accepts a maximum of 10 `QueueConfigs` entries per request. The service quota allows up to 50 queues per routing profile. The Terraform AWS provider batches queue config updates automatically via `UpdateRoutingProfileQueues` when the initial 10-entry limit is exceeded. If a routing profile has more than 10 queue associations, the first apply may require multiple API calls — this is handled transparently by the provider.

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| SOC 2 CC6.1 | Queue and routing profile configuration version-controlled | Terraform state, PR history |
| PCI-DSS Req 1.1 | System component inventory includes queue definitions | Terraform state |

---

## 8. ARCHITECTURE

### Component Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│                    QUEUE ARCHITECTURE                            │
│                                                                  │
│  queues variable (tfvars)                                        │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  general:           enabled, LONGEST_IDLE,   priority 3  │    │
│  │  sales:             enabled, LEAST_OCCUPIED, priority 2  │    │
│  │  customer-support:  enabled, LONGEST_IDLE,   priority 2  │    │
│  │  billing:           enabled, LONGEST_IDLE,   priority 2  │    │
│  │  technical-support: enabled, LEAST_OCCUPIED, priority 2  │    │
│  │  escalations:       enabled, LEAST_OCCUPIED, priority 1  │    │
│  │  system:            enabled, LEAST_OCCUPIED, priority 5  │    │
│  └────────────────────────────┬─────────────────────────────┘    │
│                               │ for_each (enabled only)          │
│                               ▼                                  │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │           aws_connect_queue (for_each)                   │    │
│  │  Hours of Operation: from PRD-12                        │    │
│  │  Max contacts: configurable per queue                   │    │
│  └──────────────────────────┬─────────────────────────────┘     │
│                             │                                    │
│  routing_profiles variable (tfvars)                              │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │  sales-primary:                                          │    │
│  │    P1: sales (delay 0s)                                  │    │
│  │    P2: general (delay 120s)                              │    │
│  │                                                          │    │
│  │  support-primary:                                        │    │
│  │    P1: customer-support (delay 0s)                       │    │
│  │    P2: technical-support (delay 120s)                    │    │
│  │    P3: general (delay 300s)                              │    │
│  │                                                          │    │
│  │  omni:                                                   │    │
│  │    P1: general, sales, support, billing, tech,           │    │
│  │        escalations (all delay 0s)                        │    │
│  └──────────────────────────┬─────────────────────────────┘     │
│                             │ for_each                           │
│                             ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │        aws_connect_routing_profile (for_each)            │    │
│  │  Queue configs with priority, delay, queue_reference     │    │
│  │  Media concurrencies per channel                         │    │
│  └──────────────────────────┬─────────────────────────────┘     │
│                             │                                    │
│         Outputs: queue_ids, routing_profile_ids                  │
│                             │                                    │
│       PRD-14 ◄──────────────┤  (route callers to queue)         │
│       PRD-50 ◄──────────────┘  (assign routing profile to agent) │
└──────────────────────────────────────────────────────────────────┘
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| Connect instance (PRD-10) | Inbound | Instance ID for all queue and routing profile resources |
| Hours of Operation (PRD-12) | Inbound | `hours_of_operation_id` per queue |
| Account Baseline (PRD-02) | Inbound | KMS key ARN for CloudWatch log group encryption |
| Audit Pipeline (PRD-03) | Inbound | SNS alert topic ARN for CloudWatch alarm actions |
| PRD-14 (Contact Flow Framework) | Outbound | Queue ARNs for Transfer to Queue blocks |
| PRD-50 (Agent Hierarchy) | Outbound | Routing profile IDs for agent assignment |
| PRD-53 (Agent Transfer Service) | Outbound | Queue IDs for quick connect configuration |
| PRD-54 (Routing Profile Management) | Outbound | Routing profile IDs for dynamic updates |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `queue_ids` | map(string) | Queue key → Connect queue ID | PRD-14, PRD-53 |
| `queue_arns` | map(string) | Queue key → Queue ARN | PRD-14, PRD-91 cutover readiness checks as needed |
| `routing_profile_ids` | map(string) | Profile key → Routing profile ID | PRD-50 |
| `routing_profile_arns` | map(string) | Profile key → ARN | future migration readiness checks as needed |
| `queue_config` | map(object) | Full resolved queue config with IDs, strategy, overflow | PRD-14 contact flow logic |
| `system_queue_id` | string | System queue ID (convenience output) | PRD-53, PRD-60 |
| `system_queue_arn` | string | System queue ARN | PRD-60 voicemail, PRD-54 callback |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-queue-architecture/      # PRD-13
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── locals.tf
        ├── cloudwatch.tf
        └── backend.tf
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

Backend values are supplied at init time via `-backend-config` flags. The state key for this module is `l1-queue-architecture/terraform.tfstate`. See `connect-pbx/docs/plan-apply-docs/plan-apply.md` for the full init procedure.

### Provider and Data Sources

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

locals {
  connect_instance_id    = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  hours_of_operation_ids = data.terraform_remote_state.hours_of_operation.outputs.hours_of_operation_ids
  env_kms_key_arn        = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  alert_topic_arn        = data.terraform_remote_state.audit_pipeline.outputs.platform_alert_topic_arn

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-13"
  }
}
```

### Key Resources Declared

```hcl
# main.tf — Queues

resource "aws_connect_queue" "queues" {
  for_each = local.enabled_queues

  instance_id           = local.connect_instance_id
  name                  = "${var.org_name}-${each.value.name}"
  description           = each.value.description
  hours_of_operation_id = local.hours_of_operation_ids[each.value.hours_of_operation_key]
  max_contacts          = each.value.max_contacts > 0 ? each.value.max_contacts : null

  tags = merge(local.common_tags, {
    QueueKey        = each.key
    RoutingStrategy = each.value.routing_strategy
    OverflowAction  = each.value.overflow_action
    MaxWaitMinutes  = tostring(each.value.max_wait_minutes)
    CostCenter      = each.value.cost_center
    Priority        = tostring(each.value.priority)
  })
}

# main.tf — Routing Profiles

resource "aws_connect_routing_profile" "profiles" {
  for_each = var.routing_profiles

  instance_id               = local.connect_instance_id
  name                      = "${var.org_name}-${each.value.name}"
  description               = each.value.description
  default_outbound_queue_id = aws_connect_queue.queues[each.value.default_outbound_queue_key].queue_id

  dynamic "media_concurrencies" {
    for_each = each.value.media_concurrencies
    content {
      channel     = media_concurrencies.value.channel
      concurrency = media_concurrencies.value.concurrency
    }
  }

  dynamic "queue_configs" {
    for_each = each.value.queue_configs
    content {
      channel  = queue_configs.value.channel
      delay    = queue_configs.value.delay_seconds
      priority = queue_configs.value.priority
      queue_id = aws_connect_queue.queues[queue_configs.value.queue_key].queue_id
    }
  }

  tags = merge(local.common_tags, {
    ProfileKey = each.key
  })
}
```

### Locals

```hcl
# locals.tf

locals {
  # Filter to only enabled queues
  enabled_queues = {
    for k, v in var.queues : k => v if v.enabled
  }

  # Validate that every queue_key referenced in routing_profiles exists in var.queues and is enabled.
  # This produces a clear error at plan time rather than a confusing for_each key lookup failure.
  _routing_profile_queue_key_validation = [
    for profile_key, profile in var.routing_profiles : [
      for qc in profile.queue_configs :
      lookup(local.enabled_queues, qc.queue_key, null) != null
      ? true
      : tobool("ERROR: routing profile '${profile_key}' references queue key '${qc.queue_key}' which is not in var.queues or is disabled")
    ]
  ]
}
```

### CloudWatch Alarms

```hcl
# cloudwatch.tf

resource "aws_cloudwatch_metric_alarm" "queue_depth" {
  for_each = local.enabled_queues

  alarm_name          = "${var.org_name}-queue-depth-${each.key}-${terraform.workspace}"
  alarm_description   = "ALARM-13-01: Queue ${each.key} depth exceeds threshold — callers accumulating"
  namespace           = "AWS/Connect"
  metric_name         = "QueueSize"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alert_topic_arn]

  dimensions = {
    InstanceId = local.connect_instance_id
    MetricGroup = "Queue"
    QueueName   = aws_connect_queue.queues[each.key].name
  }

  tags = merge(local.common_tags, {
    QueueKey = each.key
  })
}

resource "aws_cloudwatch_metric_alarm" "oldest_contact" {
  for_each = {
    for k, v in local.enabled_queues : k => v if v.max_wait_minutes > 0
  }

  alarm_name          = "${var.org_name}-oldest-contact-${each.key}-${terraform.workspace}"
  alarm_description   = "ALARM-13-02: Queue ${each.key} oldest contact approaching overflow timeout (80% of max_wait_minutes)"
  namespace           = "AWS/Connect"
  metric_name         = "OldestContactAge"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = each.value.max_wait_minutes * 60 * 0.8
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.alert_topic_arn]

  dimensions = {
    InstanceId  = local.connect_instance_id
    MetricGroup = "Queue"
    QueueName   = aws_connect_queue.queues[each.key].name
  }

  tags = merge(local.common_tags, {
    QueueKey = each.key
  })
}
```

**Note on ALARM-13-03 and ALARM-13-04:** The PRD v1.0.0 specified two additional alarms — "No Agents Available" (AgentsAvailable = 0 during scheduled hours) and "High Abandonment Rate" (ratio of abandoned to handled contacts). Both require CloudWatch metric math expressions (`metric_query` blocks), and "No Agents Available" additionally requires awareness of the schedule to suppress outside business hours. These alarms are deferred to PRD-81 (Observability & Alerting) where the full observability dashboard and composite alarm infrastructure is built. PRD-13 provisions the two straightforward per-queue alarms (queue depth and oldest contact age) that require no metric math.

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
  description = "Optional alarm action ARNs for queue alarms. Leave empty to keep PRD-13 deployable without PRD-03 or another shared alert sink."
  default     = []
}

variable "queues" {
  description = "Queue inventory. Add, remove, or customize queues here. Set enabled=false to deactivate without deleting the entry."
  type = map(object({
    enabled                = bool
    name                   = string
    description            = string
    hours_of_operation_key = string
    routing_strategy       = string  # LONGEST_IDLE | LEAST_OCCUPIED | ROUND_ROBIN
    max_contacts           = number  # 0 = unlimited
    max_wait_minutes       = number  # Used by PRD-14 contact flow overflow logic
    overflow_action        = string  # VOICEMAIL | CALLBACK | DISCONNECT
    cost_center            = string
    priority               = number  # 1 = highest
  }))

  default = {
    general = {
      enabled                = true
      name                   = "General-Inbound"
      description            = "Main inbound queue for calls not matching a specific department"
      hours_of_operation_key = "standard-business"
      routing_strategy       = "LONGEST_IDLE"
      max_contacts           = 0
      max_wait_minutes       = 10
      overflow_action        = "VOICEMAIL"
      cost_center            = "operations"
      priority               = 3
    }
    sales = {
      enabled                = true
      name                   = "Sales"
      description            = "Sales team inbound queue"
      hours_of_operation_key = "standard-business"
      routing_strategy       = "LEAST_OCCUPIED"
      max_contacts           = 0
      max_wait_minutes       = 10
      overflow_action        = "VOICEMAIL"
      cost_center            = "sales"
      priority               = 2
    }
    customer-support = {
      enabled                = true
      name                   = "Customer-Support"
      description            = "Customer support inbound queue"
      hours_of_operation_key = "standard-business"
      routing_strategy       = "LONGEST_IDLE"
      max_contacts           = 0
      max_wait_minutes       = 10
      overflow_action        = "VOICEMAIL"
      cost_center            = "support"
      priority               = 2
    }
    billing = {
      enabled                = true
      name                   = "Billing"
      description            = "Billing and accounts inbound queue"
      hours_of_operation_key = "standard-business"
      routing_strategy       = "LONGEST_IDLE"
      max_contacts           = 0
      max_wait_minutes       = 10
      overflow_action        = "VOICEMAIL"
      cost_center            = "billing"
      priority               = 2
    }
    technical-support = {
      enabled                = true
      name                   = "Technical-Support"
      description            = "Technical support inbound queue — extended hours"
      hours_of_operation_key = "extended"
      routing_strategy       = "LEAST_OCCUPIED"
      max_contacts           = 0
      max_wait_minutes       = 15
      overflow_action        = "VOICEMAIL"
      cost_center            = "tech-support"
      priority               = 2
    }
    escalations = {
      enabled                = true
      name                   = "Escalations-Tier2"
      description            = "Escalation queue for Tier 2 issues. Highest priority routing."
      hours_of_operation_key = "standard-business"
      routing_strategy       = "LEAST_OCCUPIED"
      max_contacts           = 0
      max_wait_minutes       = 5
      overflow_action        = "CALLBACK"
      cost_center            = "support"
      priority               = 1
    }
    system = {
      enabled                = true
      name                   = "System-Internal"
      description            = "Reserved system queue for transfers, voicemail callbacks, and outbound. Not exposed to inbound callers."
      hours_of_operation_key = "twenty-four-seven"
      routing_strategy       = "LEAST_OCCUPIED"
      max_contacts           = 0
      max_wait_minutes       = 0
      overflow_action        = "DISCONNECT"
      cost_center            = "operations"
      priority               = 5
    }
  }

  validation {
    condition = alltrue([
      for k, v in var.queues :
      contains(["LONGEST_IDLE", "LEAST_OCCUPIED", "ROUND_ROBIN"], v.routing_strategy)
    ])
    error_message = "Each queue routing_strategy must be LONGEST_IDLE, LEAST_OCCUPIED, or ROUND_ROBIN."
  }

  validation {
    condition = alltrue([
      for k, v in var.queues :
      contains(["VOICEMAIL", "CALLBACK", "DISCONNECT"], v.overflow_action)
    ])
    error_message = "Each queue overflow_action must be VOICEMAIL, CALLBACK, or DISCONNECT."
  }

  validation {
    condition = alltrue([
      for k, v in var.queues :
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) || length(k) == 1
    ])
    error_message = "Each queue map key must be lowercase alphanumeric with hyphens only."
  }
}

variable "routing_profiles" {
  description = "Routing profile inventory. Each profile defines which queues an agent serves and in what priority order."
  type = map(object({
    name                       = string
    description                = string
    default_outbound_queue_key = string
    media_concurrencies = list(object({
      channel     = string  # VOICE | CHAT | TASK
      concurrency = number  # max simultaneous contacts per channel
    }))
    queue_configs = list(object({
      queue_key      = string  # Must match a key in var.queues
      channel        = string  # VOICE | CHAT | TASK
      priority       = number  # 1 = highest
      delay_seconds  = number  # seconds before queue is offered to this profile
    }))
  }))

  default = {
    sales-primary = {
      name                       = "Sales-Primary"
      description                = "Primary profile for Sales agents. Overflow to General after 2 minutes."
      default_outbound_queue_key = "sales"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "sales",   channel = "VOICE", priority = 1, delay_seconds = 0   },
        { queue_key = "general", channel = "VOICE", priority = 2, delay_seconds = 120 }
      ]
    }

    support-primary = {
      name                       = "Support-Primary"
      description                = "Primary profile for Customer Support agents. Overflow to Tech Support then General."
      default_outbound_queue_key = "customer-support"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "customer-support",  channel = "VOICE", priority = 1, delay_seconds = 0   },
        { queue_key = "technical-support", channel = "VOICE", priority = 2, delay_seconds = 120 },
        { queue_key = "general",           channel = "VOICE", priority = 3, delay_seconds = 300 }
      ]
    }

    billing-primary = {
      name                       = "Billing-Primary"
      description                = "Primary profile for Billing agents. Overflow to Customer Support then General."
      default_outbound_queue_key = "billing"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "billing",          channel = "VOICE", priority = 1, delay_seconds = 0   },
        { queue_key = "customer-support", channel = "VOICE", priority = 2, delay_seconds = 120 },
        { queue_key = "general",          channel = "VOICE", priority = 3, delay_seconds = 300 }
      ]
    }

    tech-support-primary = {
      name                       = "TechSupport-Primary"
      description                = "Primary profile for Technical Support agents. Overflow to Customer Support then General."
      default_outbound_queue_key = "technical-support"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "technical-support", channel = "VOICE", priority = 1, delay_seconds = 0   },
        { queue_key = "customer-support",  channel = "VOICE", priority = 2, delay_seconds = 120 },
        { queue_key = "general",           channel = "VOICE", priority = 3, delay_seconds = 300 }
      ]
    }

    escalations-primary = {
      name                       = "Escalations-Primary"
      description                = "Restricted profile for Tier 2 escalation agents. No general overflow — escalations only."
      default_outbound_queue_key = "escalations"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "escalations", channel = "VOICE", priority = 1, delay_seconds = 0 }
      ]
    }

    general-primary = {
      name                       = "General-Primary"
      description                = "Primary profile for General Inbound agents."
      default_outbound_queue_key = "general"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "general", channel = "VOICE", priority = 1, delay_seconds = 0 }
      ]
    }

    omni = {
      name                       = "Omni-All-Queues"
      description                = "Omni profile for senior or overflow agents who can handle any queue. All queues at equal priority."
      default_outbound_queue_key = "general"
      media_concurrencies = [
        { channel = "VOICE", concurrency = 1 }
      ]
      queue_configs = [
        { queue_key = "general",           channel = "VOICE", priority = 1, delay_seconds = 0 },
        { queue_key = "sales",             channel = "VOICE", priority = 1, delay_seconds = 0 },
        { queue_key = "customer-support",  channel = "VOICE", priority = 1, delay_seconds = 0 },
        { queue_key = "billing",           channel = "VOICE", priority = 1, delay_seconds = 0 },
        { queue_key = "technical-support", channel = "VOICE", priority = 1, delay_seconds = 0 },
        { queue_key = "escalations",       channel = "VOICE", priority = 1, delay_seconds = 0 }
      ]
    }
  }
}

variable "layer_id" {
  type    = string
  default = "L1"
}

variable "prd_id" {
  type    = string
  default = "PRD-13"
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-13. It exists for
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
  description = "Platform-wide deployment profile. Not consumed by PRD-13 — declared for contract consistency. See PRD-00 for authoritative schema."
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

output "queue_ids" {
  description = "Map of queue key to Connect queue ID. Consumed by PRD-14 and PRD-53."
  value = {
    for k, v in aws_connect_queue.queues : k => v.queue_id
  }
}

output "queue_arns" {
  description = "Map of queue key to queue ARN. Consumed by PRD-14 and PRD-91 cutover readiness checks as needed."
  value = {
    for k, v in aws_connect_queue.queues : k => v.arn
  }
}

output "routing_profile_ids" {
  description = "Map of routing profile key to routing profile ID. Consumed by PRD-50."
  value = {
    for k, v in aws_connect_routing_profile.profiles : k => v.routing_profile_id
  }
}

output "routing_profile_arns" {
  description = "Map of routing profile key to ARN."
  value = {
    for k, v in aws_connect_routing_profile.profiles : k => v.arn
  }
}

output "queue_config" {
  description = "Full resolved queue config including IDs, strategy, overflow action, and max wait. Consumed by PRD-14 to build contact flow logic."
  value = {
    for k, v in aws_connect_queue.queues : k => {
      queue_id         = v.queue_id
      queue_arn        = v.arn
      name             = v.name
      routing_strategy = var.queues[k].routing_strategy
      overflow_action  = var.queues[k].overflow_action
      max_wait_minutes = var.queues[k].max_wait_minutes
      priority         = var.queues[k].priority
      cost_center      = var.queues[k].cost_center
    }
  }
}

output "system_queue_id" {
  description = "System internal queue ID. Convenience output for PRD-53, PRD-60."
  value       = aws_connect_queue.queues["system"].queue_id
}

output "system_queue_arn" {
  description = "System internal queue ARN."
  value       = aws_connect_queue.queues["system"].arn
}
```

---

## 10. EVENT SCHEMA

PRD-13 produces no EventBridge events directly. Queue metrics are published automatically by Connect to CloudWatch. Contact trace records (Kinesis — PRD-10) include queue ARN and queue name in every CTR, providing the event stream for future contact analytics and Contact Lens-style processing.

---

## 11. API / INTERFACE CONTRACT

```hcl
# Standard downstream consumption pattern for PRD-14 and PRD-50
data "terraform_remote_state" "queue_architecture" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-queue-architecture/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  queue_ids            = data.terraform_remote_state.queue_architecture.outputs.queue_ids
  queue_arns           = data.terraform_remote_state.queue_architecture.outputs.queue_arns
  queue_config         = data.terraform_remote_state.queue_architecture.outputs.queue_config
  routing_profile_ids  = data.terraform_remote_state.queue_architecture.outputs.routing_profile_ids
  system_queue_id      = data.terraform_remote_state.queue_architecture.outputs.system_queue_id
}
```

---

## 12. DATA MODEL

### State File Location

```
s3://{org}-tfstate-{account_id}/
└── env:/
    └── {workspace}/
        └── l1-queue-architecture/
            └── terraform.tfstate
```

### Queue Tag Schema

Each queue resource carries the following tags that encode its operational configuration for use by contact flows, reporting, and the CRM integration layer (PRD-130):

```
RoutingStrategy: LONGEST_IDLE | LEAST_OCCUPIED | ROUND_ROBIN
OverflowAction:  VOICEMAIL | CALLBACK | DISCONNECT
MaxWaitMinutes:  string(number)
Priority:        string(number)
CostCenter:      string
QueueKey:        string (matches variable map key)
```

---

## 13. CI/CD SPECIFICATION

### Workflow Reference

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l1-queue-architecture

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l1-queue-architecture
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l1-queue-architecture
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules/l1-queue-architecture-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Queue Disable Procedure

To disable a queue without destroying its configuration entry:

```hcl
# Step 1: Set enabled = false in tfvars
queues = {
  billing = {
    enabled = false
    # ... all other attributes unchanged
  }
}

# Step 2: Submit PR, get plan reviewed (plan shows destroy of the queue resource)
# Step 3: Verify no active contacts are in the queue before applying
# Step 4: Apply — queue is removed from Connect
# Step 5: Update any PRD-14 contact flow that routes to this queue to use a fallback
```

### Rollback Procedure

Queue configuration changes (routing strategy, hours of operation, max contacts) are safe to roll back via re-apply. Queue deletion is not reversible if contacts were routed to the queue — the queue ID changes on recreation. Routing profile changes take effect immediately for agents who are next offered a contact.

---

## 14. OBSERVABILITY SPECIFICATION

### CloudWatch Metrics (Auto-Published by Connect)

| Metric | Purpose |
|---|---|
| `QueueSize` | Current number of contacts waiting |
| `OldestContactAge` | Age in seconds of the oldest contact in queue |
| `AgentsAvailable` | Available agent count per queue |
| `AgentsOnContact` | Agents actively handling contacts |
| `ContactsInQueue` | Total contacts waiting per queue |
| `ContactsHandled` | Contacts handled per interval |
| `ContactsAbandoned` | Contacts that disconnected while waiting |

### Alarms (Provisioned by This Module)

**ALARM-13-01: Queue Depth Threshold** (per enabled queue)
- Metric: `QueueSize` per queue
- Threshold: 20 contacts waiting (default)
- Period: 5 minutes
- Action: publish to `alarm_action_arns` when non-empty; otherwise no external sink required
- Severity: High

**ALARM-13-02: Oldest Contact Age** (per enabled queue with max_wait_minutes > 0)
- Metric: `OldestContactAge` per queue
- Threshold: `max_wait_minutes * 60 * 0.8` (alert at 80% of overflow threshold)
- Period: 1 minute
- Action: publish to `alarm_action_arns` when non-empty; otherwise no external sink required
- Severity: High — caller approaching overflow timeout

### Alarms (Deferred to PRD-81 — Observability & Alerting)

The following alarms require metric math expressions or composite alarm logic that belongs in the centralized observability module:

**ALARM-13-03: No Agents Available** — `AgentsAvailable = 0` during scheduled hours. Requires schedule-aware suppression to avoid false alerts outside business hours.

**ALARM-13-04: High Abandonment Rate** — `ContactsAbandoned / (ContactsHandled + ContactsAbandoned) > 15%` over a 15-minute evaluation period. Requires `metric_query` blocks with metric math.

### SOC 2 and PCI Evidence Artifacts

| Artifact | Demonstrates |
|---|---|
| Queue configuration in Terraform state | SOC 2 CC6.1 — system component inventory |
| Routing profile configuration | SOC 2 CC6.1 — access control (agent to queue mapping) |
| CloudWatch queue metrics | SOC 2 A1.1 — availability monitoring |

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-13-01 | All enabled queues exist in Connect | `aws connect list-queues` returns all seven default queues |
| AC-13-02 | Queue names follow naming convention | Names equal `{org_name}-{queue.name}` |
| AC-13-03 | Each queue references correct hours of operation | `aws connect describe-queue` returns correct hours ID for each queue |
| AC-13-04 | System queue is not associated with any contact flow | Verified in PRD-14 acceptance criteria |
| AC-13-05 | All routing profiles exist in Connect | `aws connect list-routing-profiles` returns all seven default profiles |
| AC-13-06 | Sales-Primary profile has sales as P1 and general as P2 | `aws connect describe-routing-profile` returns correct queue configs |
| AC-13-07 | Omni profile includes all six non-system queues at P1 | `aws connect describe-routing-profile` for omni returns six queue configs all at priority 1 |
| AC-13-08 | Escalations-Primary profile has no overflow queues | Profile has exactly one queue config entry |
| AC-13-09 | Setting enabled=false removes queue on apply | Set billing.enabled=false in dev, apply, confirm queue removed from Connect |
| AC-13-10 | Re-enabling queue recreates it cleanly | Set billing.enabled=true again, apply, confirm queue recreated |
| AC-13-11 | queue_config output contains all enabled queues | `terraform output queue_config` returns map with all enabled entries |
| AC-13-12 | ALARM-13-01 and ALARM-13-02 are active for all enabled queues | `aws cloudwatch describe-alarms` returns per-queue alarms in OK state |
| AC-13-13 | Adding a new queue via tfvars provisions it | Add test queue entry, apply, confirm queue in Connect |
| AC-13-14 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l1-queue-architecture/` returns clean |
| AC-13-15 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l1-queue-architecture/` returns clean |
| AC-13-16 | Routing profile queue_configs use nested queue_reference structure | `terraform plan` succeeds without block structure errors |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Queue deleted while contacts are active in it | Low | High | Apply queue disables during off-hours only. ALARM-13-01 shows queue depth before apply. |
| Routing profile references a disabled queue key | Medium | High | Terraform validation block checks that all queue_key values in routing_profiles exist in var.queues and are enabled. |
| Overflow action CALLBACK referenced before PRD-54 is deployed | Medium | Medium | PRD-14 contact flow checks overflow_action tag at runtime. CALLBACK falls back to VOICEMAIL if PRD-54 is not yet deployed. |
| max_contacts limit reached — callers rejected at queue | Low | High | Default max_contacts = 0 (unlimited). ALARM-13-01 provides early warning on queue depth. |
| Connect service quota of 500 queues reached | Very Low | High | Templatized pattern supports disabling unused queues. Monitor queue count via CloudWatch. Request limit increase proactively at 400 queues. |
| CreateRoutingProfile API rejects >10 QueueConfigs | Low | Medium | Default profiles have ≤6 queue configs. Terraform provider batches via UpdateRoutingProfileQueues for larger sets. Document limit in variable description. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-13-01 | What are the actual max_wait_minutes thresholds per queue for production? Defaults used here (10 min general/sales/support/billing, 15 min tech support, 5 min escalations). | Open | Operations manager to confirm before prod apply. Update prod.tfvars accordingly. |
| OQ-13-02 | Should the escalations queue have a different overflow action than CALLBACK? If PRD-54 (callback) is not being deployed, this must be changed to VOICEMAIL or DISCONNECT. | Open | Resolved when PRD-54 deployment decision is made. |
| OQ-13-03 | Should skills-based routing be implemented? This requires additional routing profile complexity with skill attributes and Connect Routing Profiles v2 configuration. Out of scope for this PRD but can be layered on top of this design. | Open | Deferred. Skills-based routing can be added as a new routing profile template without changing the queue architecture. |
| OQ-13-04 | Should chat (VOICE + CHAT) or task channels be enabled on any routing profiles? Currently all profiles are VOICE only. | Open | Operations manager to confirm. Adding CHAT or TASK requires adding media_concurrencies and queue_configs entries for those channels. |
| OQ-13-05 | Should `OutboundCallerConfig` be set per queue? Connect supports outbound caller ID name, number, and outbound whisper flow per queue. Currently not exposed — queues have no outbound caller config. | Open | Deferred. Can be added as optional attributes on the queue variable when outbound calling requirements are defined. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Templatized queue and routing profile pattern established. Seven default queues and seven default routing profiles. All routing strategies available per queue via toggle. Tiered routing profile model with configurable priority and delay. |
| 1.1.0 | 2026-03-23 | — | Architecture alignment review and deployment. **Breaking changes:** (1) Backend config corrected to `backend "s3" {}` with runtime `-backend-config`, Terraform `>= 1.14.0`, AWS provider `~> 6.0`. (2) `queue_configs` dynamic block corrected to flat structure (`channel`, `queue_id` as direct attributes, not nested under `queue_reference`) — AWS provider v6.x flattens the API's `QueueReference` object. (3) Added `backend.tf`, `cloudwatch.tf` to module file list. **Additions:** (4) Provider block, four remote state data sources (`connect_instance`, `hours_of_operation`, `account_baseline`, `audit_pipeline`), and `common_tags` local added to `main.tf`. (5) CloudWatch alarms ALARM-13-01 (queue depth) and ALARM-13-02 (oldest contact age) implemented with full Terraform. (6) ALARM-13-03 and ALARM-13-04 deferred to PRD-81 (require metric math). (7) Queue key format validation added. (8) `deployment_profile` variable updated with contract-consistency comment. (9) FR-007 omni profile description corrected to match variable default (all queues at P1, delay 0). (10) API interface contract corrected to use `workspace = terraform.workspace` pattern. (11) State file location corrected to show `env:/{workspace}/` prefix. (12) Added PRD-02 and PRD-03 to Depends On in metadata. (13) Added API limits section documenting CreateRoutingProfile 10-entry QueueConfigs limit. (14) Added OQ-13-05 for OutboundCallerConfig. (15) Added AC-13-16 for queue_reference structure verification. **Deployed to dev** (017677777575) — 27 resources created successfully. |
| 1.1.1 | 2026-03-30 | — | Audit decoupling target-state normalization. Removed PRD-03 from required dependencies in the architecture contract and made queue alarm sinks explicit optional inputs via `alarm_action_arns`. |
| 1.2.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section with catalog entry, shared sink behavior, destroy posture, and control plane statement. |
