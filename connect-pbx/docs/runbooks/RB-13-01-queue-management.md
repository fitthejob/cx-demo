# RB-13-01 — Queue & Routing Profile Management

**Runbook ID:** RB-13-01
**Module:** l1-queue-architecture (PRD-13)
**Audience:** Platform Engineer, Operations Manager
**Last Updated:** 2026-03-23

---

## Overview

This runbook covers how to add, edit, disable, and re-enable queues and routing profiles in the Amazon Connect PBX platform. All queue and routing profile configuration is managed exclusively via Terraform — no queues or routing profiles are created manually in the Connect console.

Queues and routing profiles are defined as entries in a Terraform variable map. Adding, removing, or modifying any queue is a `connect-pbx/environments/<env>/queues.tfvars` change — no module code changes are needed.

---

## Prerequisites

Before starting, confirm:

| Requirement | Verification |
|---|---|
| l1-queue-architecture module is deployed | `terraform state list` shows `aws_connect_queue.queues` resources |
| l1-hours-of-operation module is deployed | Queue `hours_of_operation_key` must reference a valid schedule |
| AWS profile is set to the correct account | `aws sts get-caller-identity` returns expected account ID |
| You are working against the correct environment | Confirm `dev`, `staging`, or `prod` before proceeding |

### Verify current state

```bash
export AWS_PROFILE=<aws_profile_dev>   # or <aws_profile_prod>
cd connect-pbx/modules/l1-queue-architecture

terraform workspace select dev
terraform state list | grep aws_connect_queue
terraform state list | grep aws_connect_routing_profile
```

---

## Adding a New Queue

### Step 1 — Determine queue requirements

Collect the following before editing any files:

| Field | Description | Example |
|---|---|---|
| **Key** | Unique identifier for this queue in Terraform (lowercase, hyphens only) | `after-hours`, `vip-support` |
| **Name** | Display name in the Connect console (prefixed with org name automatically) | `After-Hours` |
| **Description** | Plain-text description | `After-hours overflow queue` |
| **Hours of operation key** | Must match a key in PRD-12 schedules: `standard-business`, `extended`, or `twenty-four-seven` | `extended` |
| **Routing strategy** | `LONGEST_IDLE`, `LEAST_OCCUPIED`, or `ROUND_ROBIN` | `LONGEST_IDLE` |
| **Max contacts** | Maximum callers in queue before overflow. `0` = unlimited | `0` |
| **Max wait minutes** | Maximum wait time before overflow routing (used by PRD-14 contact flow) | `10` |
| **Overflow action** | `VOICEMAIL`, `CALLBACK`, or `DISCONNECT` | `VOICEMAIL` |
| **Cost center** | Business unit for cost allocation | `operations` |
| **Priority** | Queue priority weight. `1` = highest, `5` = lowest | `2` |

### Step 2 — Edit `queues.tfvars`

Open `connect-pbx/environments/dev/queues.tfvars` and add the new queue entry to the `queues` map.

```hcl
# Add this entry inside the queues map in dev/queues.tfvars

queues = {

  # ... existing queues ...

  after-hours = {
    enabled                = true
    name                   = "After-Hours"
    description            = "After-hours overflow queue for calls received outside business hours"
    hours_of_operation_key = "extended"
    routing_strategy       = "LONGEST_IDLE"
    max_contacts           = 0
    max_wait_minutes       = 10
    overflow_action        = "VOICEMAIL"
    cost_center            = "operations"
    priority               = 3
  }
}
```

**Key naming rules:**
- Lowercase alphanumeric with hyphens only (e.g., `after-hours`, `vip-support`)
- No underscores, spaces, or uppercase
- Must be unique within the map

### Step 3 — Plan and review

```bash
export AWS_PROFILE=<aws_profile_dev>
BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/<repo_slug>/bootstrap}"
cd connect-pbx/modules/l1-queue-architecture

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-<aws_profile_dev>.hcl" \
               -backend-config="key=l1-queue-architecture/terraform.tfstate"
terraform workspace select dev
terraform plan \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
```

The plan should show:
- 1 new `aws_connect_queue.queues["after-hours"]` to create
- 1 new `aws_cloudwatch_metric_alarm.queue_depth["after-hours"]` to create
- 1 new `aws_cloudwatch_metric_alarm.oldest_contact["after-hours"]` to create (if `max_wait_minutes > 0`)
- No changes to existing queues or routing profiles

**Review checklist:**
- [ ] Only the new queue and its alarms appear in the plan
- [ ] No existing queues are modified or destroyed
- [ ] The `hours_of_operation_key` references a valid schedule
- [ ] The queue name will display as `{org_name}-{name}` in the Connect console

### Step 4 — Apply

```bash
terraform apply \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
```

### Step 5 — Verify

```bash
# Confirm queue exists in Connect
INSTANCE_ID=$(terraform output -json queue_ids | python -c "import json,sys; print(list(json.load(sys.stdin).values())[0].split(':')[0])" 2>/dev/null)

# List all queues
terraform output queue_ids

# Verify specific queue
terraform output -json queue_config | python -c "
import json, sys
config = json.load(sys.stdin)
for k, v in sorted(config.items()):
    print(f\"{k}: {v['name']} ({v['routing_strategy']}, overflow={v['overflow_action']})\")
"
```

### Step 6 — Update routing profiles (if needed)

If the new queue should be part of any routing profile, add it to the `routing_profiles` variable in `connect-pbx/environments/dev/queues.tfvars`. See "Adding a Queue to a Routing Profile" below.

---

## Editing an Existing Queue

Queue attributes can be changed without recreating the queue. The following fields are safe to modify in-place:

| Field | In-place update? | Notes |
|---|---|---|
| `description` | Yes | No impact on routing |
| `hours_of_operation_key` | Yes | Takes effect immediately — verify the new schedule covers expected hours |
| `routing_strategy` | Yes | Tag-only change — no Connect behavior change until PRD-14 flow reads the tag |
| `max_contacts` | Yes | Takes effect immediately — increasing is safe, decreasing may reject callers if queue is near capacity |
| `max_wait_minutes` | Yes | Updates alarm threshold at 80% of new value |
| `overflow_action` | Yes | Tag-only change — consumed by PRD-14 flow logic |
| `cost_center` | Yes | Tag-only change |
| `priority` | Yes | Tag-only change |
| `name` | **Destroys and recreates** | Connect queue names are immutable — changing the name forces replacement. The new queue gets a new ID. Any downstream references (PRD-14 contact flows, PRD-53 quick connects) must be updated. |

### Procedure

1. Edit the queue entry in `connect-pbx/environments/dev/queues.tfvars`
2. Run `terraform plan` and verify the change is in-place (update), not a destroy/create
3. If the plan shows a destroy/create, **stop** — you are likely changing the `name` or `hours_of_operation_key` to an invalid value. Review the plan carefully.
4. Apply when satisfied

```bash
export AWS_PROFILE=<aws_profile_dev>
BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/<repo_slug>/bootstrap}"
cd connect-pbx/modules/l1-queue-architecture

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-<aws_profile_dev>.hcl" \
               -backend-config="key=l1-queue-architecture/terraform.tfstate"
terraform workspace select dev
terraform plan \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
# Review the plan — confirm changes are in-place updates
terraform apply \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
```

---

## Disabling a Queue

Disabling a queue removes the Connect resource while preserving the configuration entry in tfvars. The queue can be re-enabled later without rewriting the configuration.

### Pre-flight checks

Before disabling a queue:

1. **Verify no active contacts are in the queue:**

```bash
export AWS_PROFILE=<aws_profile_dev>

INSTANCE_ID=$(cd connect-pbx/modules/l1-queue-architecture && \
  terraform output -json queue_ids | python -c "import json,sys; d=json.load(sys.stdin); print(list(d.values())[0].split('/')[1].split(':')[0])" 2>/dev/null)

# Check real-time queue metrics in the Connect console, or:
aws cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id": "qsize",
    "MetricStat": {
      "Metric": {
        "Namespace": "AWS/Connect",
        "MetricName": "QueueSize",
        "Dimensions": [
          {"Name": "InstanceId", "Value": "'$INSTANCE_ID'"},
          {"Name": "MetricGroup", "Value": "Queue"},
          {"Name": "QueueName", "Value": "<org_prefix>-Billing"}
        ]
      },
      "Period": 60,
      "Stat": "Maximum"
    }
  }]' \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

2. **Verify no routing profiles reference this queue.** If they do, remove the queue from those routing profiles first (see "Removing a Queue from a Routing Profile" below), then disable the queue.

3. **Schedule the disable during off-hours** to minimize risk.

### Procedure

1. Set `enabled = false` on the queue entry in `connect-pbx/environments/dev/queues.tfvars`:

```hcl
billing = {
  enabled                = false    # <-- changed from true
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
```

2. Plan and review:

```bash
terraform plan \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
```

The plan should show:
- 1 `aws_connect_queue.queues["billing"]` to **destroy**
- 1 `aws_cloudwatch_metric_alarm.queue_depth["billing"]` to **destroy**
- 1 `aws_cloudwatch_metric_alarm.oldest_contact["billing"]` to **destroy**
- Any routing profiles that referenced this queue will fail validation — fix those first

3. Apply:

```bash
terraform apply \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
```

4. Update any PRD-14 contact flows that route to this queue to use a fallback.

---

## Re-enabling a Queue

Set `enabled = true` on the queue entry and apply. The queue is recreated in Connect with a **new queue ID** — downstream references (PRD-14, PRD-53) must be updated to use the new ID from Terraform outputs.

```hcl
billing = {
  enabled = true    # <-- changed back to true
  # ... all other attributes unchanged
}
```

```bash
terraform plan \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
terraform apply \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"

# Get the new queue ID
terraform output -json queue_ids | python -c "import json,sys; print(json.load(sys.stdin)['billing'])"
```

---

## Adding a Queue to a Routing Profile

To add a queue to an existing routing profile, add a `queue_configs` entry to the profile in `connect-pbx/environments/dev/queues.tfvars`.

### Example: Add `after-hours` queue as P2 overflow to the support-primary profile

```hcl
routing_profiles = {
  # ... other profiles ...

  support-primary = {
    name                       = "Support-Primary"
    description                = "Primary profile for Customer Support agents. Overflow to Tech Support, After-Hours, then General."
    default_outbound_queue_key = "customer-support"
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "customer-support",  channel = "VOICE", priority = 1, delay_seconds = 0   },
      { queue_key = "technical-support", channel = "VOICE", priority = 2, delay_seconds = 120 },
      { queue_key = "after-hours",       channel = "VOICE", priority = 2, delay_seconds = 120 },  # NEW
      { queue_key = "general",           channel = "VOICE", priority = 3, delay_seconds = 300 }
    ]
  }
}
```

**Priority and delay explained:**
- `priority = 1, delay_seconds = 0` — Agent's primary queue. Contacts offered immediately.
- `priority = 2, delay_seconds = 120` — Secondary overflow. Contacts offered after 2 minutes idle on primary.
- `priority = 3, delay_seconds = 300` — Tertiary overflow. Contacts offered after 5 minutes idle on primary and secondary.

Multiple queues can share the same priority and delay — the agent receives whichever contact has waited longest across those queues.

---

## Removing a Queue from a Routing Profile

Remove the `queue_configs` entry from the profile in `connect-pbx/environments/dev/queues.tfvars` and apply. The change takes effect immediately for agents on that routing profile — they stop receiving contacts from the removed queue on their next available contact.

**Warning:** If you remove a queue from all routing profiles, contacts in that queue have no agents to route to. Either disable the queue or ensure at least one routing profile still serves it.

---

## Adding a New Routing Profile

### Step 1 — Define the profile

```hcl
routing_profiles = {
  # ... existing profiles ...

  vip-primary = {
    name                       = "VIP-Primary"
    description                = "Dedicated profile for VIP support agents. Primary on VIP queue, overflow to escalations."
    default_outbound_queue_key = "vip-support"   # Must be a key in the queues map
    media_concurrencies = [
      { channel = "VOICE", concurrency = 1 }
    ]
    queue_configs = [
      { queue_key = "vip-support",  channel = "VOICE", priority = 1, delay_seconds = 0   },
      { queue_key = "escalations",  channel = "VOICE", priority = 2, delay_seconds = 120 }
    ]
  }
}
```

**Requirements:**
- `default_outbound_queue_key` must reference an enabled queue
- Every `queue_key` in `queue_configs` must reference an enabled queue
- At least one `media_concurrencies` entry is required (typically `VOICE` with concurrency `1`)

### Step 2 — Plan, review, apply

```bash
terraform plan \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"
terraform apply \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/queues.tfvars"

# Get the new routing profile ID (needed for PRD-50 agent assignment)
terraform output -json routing_profile_ids | python -c "import json,sys; print(json.load(sys.stdin)['vip-primary'])"
```

---

## Production Deployment

For production changes, follow the standard two-environment workflow:

1. Make and validate all changes in **dev** first using the steps above
2. Copy the same queue changes to `connect-pbx/environments/prod/queues.tfvars`
3. Switch to the prod profile and workspace:

```bash
export AWS_PROFILE=<aws_profile_prod>
BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/<repo_slug>/bootstrap}"
cd connect-pbx/modules/l1-queue-architecture

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-<aws_profile_prod>.hcl" \
               -backend-config="key=l1-queue-architecture/terraform.tfstate"
terraform workspace select prod

terraform plan \
  -var-file="../../environments/prod/global.tfvars" \
  -var-file="../../environments/prod/queues.tfvars"
# STOP — review the plan output manually before applying
terraform apply \
  -var-file="../../environments/prod/global.tfvars" \
  -var-file="../../environments/prod/queues.tfvars"
```

**Prod rules:**
- Always review the plan output before applying
- Schedule queue disables during off-hours
- Verify no active contacts in queues being disabled

---

## Troubleshooting

### Plan shows destroy/create instead of update

You likely changed the queue `name` attribute. Connect queue names are immutable — any name change forces replacement. The new queue gets a new ID. If this is intentional, proceed and update downstream references (PRD-14, PRD-53).

### Validation error: routing profile references disabled queue

```
ERROR: routing profile 'support-primary' references queue key 'billing' which is not in var.queues or is disabled
```

A routing profile references a queue that is disabled or missing. Remove the queue from the routing profile's `queue_configs` before disabling the queue, or re-enable the queue.

### Plan shows changes to routing profiles you didn't touch

If you added or removed a queue that is referenced by a routing profile, the routing profile resource updates to reflect the new queue ID. This is expected and safe.

### Warning: "Value for undeclared variable"

This warning usually means the wrong var files were loaded. For this module, load only `global.tfvars` and `queues.tfvars` for the selected environment.

---

## Quick Reference — Default Queues

| Key | Display Name | Strategy | Hours | Overflow | Priority |
|---|---|---|---|---|---|
| `general` | `<org_prefix>`-General-Inbound | LONGEST_IDLE | standard-business | VOICEMAIL | 3 |
| `sales` | `<org_prefix>`-Sales | LEAST_OCCUPIED | standard-business | VOICEMAIL | 2 |
| `customer-support` | `<org_prefix>`-Customer-Support | LONGEST_IDLE | standard-business | VOICEMAIL | 2 |
| `billing` | `<org_prefix>`-Billing | LONGEST_IDLE | standard-business | VOICEMAIL | 2 |
| `technical-support` | `<org_prefix>`-Technical-Support | LEAST_OCCUPIED | extended | VOICEMAIL | 2 |
| `escalations` | `<org_prefix>`-Escalations-Tier2 | LEAST_OCCUPIED | standard-business | CALLBACK | 1 |
| `system` | `<org_prefix>`-System-Internal | LEAST_OCCUPIED | twenty-four-seven | DISCONNECT | 5 |

## Quick Reference — Default Routing Profiles

| Key | Primary Queue | Overflow Queues |
|---|---|---|
| `sales-primary` | sales | general (P2, 120s) |
| `support-primary` | customer-support | technical-support (P2, 120s), general (P3, 300s) |
| `billing-primary` | billing | customer-support (P2, 120s), general (P3, 300s) |
| `tech-support-primary` | technical-support | customer-support (P2, 120s), general (P3, 300s) |
| `escalations-primary` | escalations | none |
| `general-primary` | general | none |
| `omni` | all queues at P1, delay 0 | none |

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-08-routing-drift-investigation-remediation.md](RB-11-08-routing-drift-investigation-remediation.md)
- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)
