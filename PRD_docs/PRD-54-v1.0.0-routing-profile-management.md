# PRD-54 — Routing Profile Management

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-54 |
| **Version** | 1.3.0 |
| **Status** | Green |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 5 — Agent Experience |
| **Depends On** | PRD-10 (Connect instance), PRD-13 (routing profile registry) |
| **Blocks** | PRD-53 warm-transfer rollout in environments that require multi-party conferencing |
| **Optional Shared Sinks** | EventBridge change events and Agent State updates, if enabled |
| **Destroy / Retention Posture** | conditional / Connect conferencing attribute is operator-reviewed state |
| **Optional** | Yes — optional feature and conditional foundation for agent-routing operations |

---

## 2. MODULE GOVERNANCE

### Module Classification

- `classification`: `conditional-foundation`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Catalog Entry

- `path`: `modules/l5-routing-profile-management`
- `capability_packs`: `[]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture"]`
- `state_key`: `l5-routing-profile-management/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `routing-profile-management.tfvars`
- `supports_destroy`: `true`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated agent-operations capability pack exists

### Shared Sink Behavior

- `optional_shared_sinks`: `routing change events, audit exports, and shared Agent State updates`
- `sink_behavior`: `optional input`

PRD-03 must not become a hidden prerequisite for routing-profile updates. If an environment enables extra audit capture, it is an additive sink, not a deployability condition. Event bus and shared-state integrations are also optional unless a specific environment explicitly chooses the event-driven mode.

### Destroy / Retention Posture

- `destroy_posture`: `conditional`
- `retention_notes`: removing the module should withdraw the Lambda, EventBridge rule, and supporting IAM, but it should not be treated as a steady-state mechanism for reversing Connect instance conferencing or rewriting retained Agent State history

### Control Plane Statement

This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Routing profile management is an operational capability for environments that need controlled runtime changes without turning Terraform into a human-in-the-loop workflow. Supervisors and workforce managers may need to reassign an agent to a different routing profile during a spike, and the platform should support that through an authorized event-driven path.

This PRD also enables multi-party conferencing on the Connect instance so warm-transfer flows can work when PRD-53 is enabled in the same environment. That instance attribute is a deliberate module-side control-plane change, not a `deployment_profile` toggle.

### What Problem It Solves

- Enables guarded runtime routing-profile updates through a controlled operator path
- Activates multi-party conferencing for environments that need warm-transfer support
- Updates the Agent State record after a routing-profile change when shared state is enabled
- Emits a change event only when optional audit or automation consumers are enabled

---

## 4. GOALS

### Goals

- Provision a controlled routing-profile manager Lambda only when the event-driven mode is enabled for approved operators
- Enable multi-party conferencing as part of the module's controlled apply path
- Keep shared-state writes explicit and documented
- Make audit/event sinks optional inputs rather than hidden prerequisites

### Non-Goals

- This PRD does not define routing profile creation or naming conventions; that remains PRD-13
- This PRD does not implement workforce scheduling or forecasting
- This PRD does not add a supervisor UI
- This PRD does not make `deployment_profile` the activation authority

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-54-01 | Supervisor | As a supervisor, I want to move an agent from one routing profile to another during a demand spike so calls stay covered | An authorized event updates the agent's routing profile in Connect |
| US-54-02 | Platform Engineer | As the platform engineer, I want multi-party conferencing enabled when this module is selected so warm transfers can run | Connect instance attribute is set to enabled by the module apply |
| US-54-03 | Operations Manager | As the operations manager, I want the Agent State table updated after a routing-profile change so reports remain accurate | Agent State record reflects the latest routing profile key |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Manifest-Controlled Activation

The module must be activated by the module catalog and per-environment deployment manifest. `deployment_profile` must not decide whether the module exists. The module's runtime behavior may vary by environment, but the activation decision comes from the repo control plane.

When the module is enabled, it must set the Connect instance `multi_party_conference_enabled` attribute to `true` for that environment.

### FR-002 — Optional Event-Driven Routing Update Path

If the environment enables the event-driven operating mode, provision a Lambda function `{org_name}-routing-profile-manager` that consumes `ConnectPBX.RoutingProfileChangeRequested` events from the platform bus. The Lambda must:

1. Validate that `source` is `connect-pbx.supervisor` or `connect-pbx.workforce-management`
2. Resolve the Connect instance ID from PRD-10
3. Resolve routing profile IDs from PRD-13
4. Resolve the Agent State table only when shared-state integration is enabled
5. Call `connect:UpdateUserRoutingProfile`
6. Update the Agent State record with the new routing profile key
7. Publish `ConnectPBX.RoutingProfileChanged` after a successful update only when the environment enables the optional audit/change-event sink

### FR-003 — Bulk Profile Update

When the event-driven mode is enabled, the Lambda must support a bulk-update payload. When `bulk = true`, the payload contains an array of `{agent_username, routing_profile_key}` objects. The Lambda processes them sequentially and inserts a short delay between calls to avoid Connect API throttling.

### FR-004 — Authorization Failure Handling

If the event source is not authorized, the Lambda must raise a permanent failure, log the rejection, and stop processing without mutating Connect or Agent State. Unauthorized sources are not DLQ-worthy business failures; they are rejected control-plane inputs.

### FR-005 — Runbook / CLI Invocation Contract

When the event-driven mode is not enabled, the supported runtime operating path is an approved runbook/CLI flow that uses the same payload schema as the event-driven Lambda. That path must:

1. Use the same allowlisted operator personas and routing-profile key validation rules as the Lambda path
2. Resolve the same Connect instance and routing-profile registry inputs
3. Update Agent State only when shared-state integration is enabled
4. Avoid turning Terraform apply or destroy into a day-to-day routing-operations workflow

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Latency

- Single-agent profile update: less than 5 seconds end-to-end
- Bulk update of 50 agents: less than 60 seconds

### Security

- Lambda execution role scoped to `connect:UpdateUserRoutingProfile` on the specific instance
- Lambda execution role scoped to Agent State updates on the named table only
- Permission boundary from PRD-02 applied

---

## 8. ARCHITECTURE

```
Authorized operator or automation
      │
      │ Publish ConnectPBX.RoutingProfileChangeRequested
      ▼
EventBridge Custom Bus (PRD-20)
      │
      ▼
routing-profile-manager Lambda
      │
      ├── Validate source allowlist
      ├── Read PRD-10 / PRD-13 / PRD-31 outputs
      ├── connect:UpdateUserRoutingProfile
      ├── dynamodb:UpdateItem on Agent State
      └── Publish ConnectPBX.RoutingProfileChanged for downstream consumers
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `routing_profile_manager_arn` | string or null | Routing profile manager Lambda ARN when the optional event-driven mode is enabled | optional operational or audit consumers |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```text
connect-pbx/
└── modules/
    └── l5-routing-profile-management/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            └── routing-profile-manager/
                └── index.py
```

### Key Resources Declared

```hcl
# versions.tf
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
data "terraform_remote_state" "connect_instance" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.connect_instance_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "routing_profiles" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.routing_profiles_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "agent_state" {
  count   = var.agent_state_state_key == null ? 0 : 1
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.agent_state_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "event_bus" {
  count   = var.event_bus_state_key == null ? 0 : 1
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.event_bus_state_key
    region = var.aws_region
  }
}

locals {
  connect_instance_id      = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  routing_profile_ids      = data.terraform_remote_state.routing_profiles.outputs.routing_profile_ids
  agent_state_table_name   = var.agent_state_state_key == null ? null : data.terraform_remote_state.agent_state[0].outputs.agent_state_table_name
  agent_state_table_arn    = var.agent_state_state_key == null ? null : data.terraform_remote_state.agent_state[0].outputs.agent_state_table_arn
  event_bus_name           = var.event_bus_state_key == null ? null : data.terraform_remote_state.event_bus[0].outputs.event_bus_name
  event_bus_arn            = var.event_bus_state_key == null ? null : data.terraform_remote_state.event_bus[0].outputs.event_bus_arn
  permission_boundary_arn  = data.terraform_remote_state.connect_instance.outputs.permission_boundary_arn
  eventbridge_dlq_arn      = var.eventbridge_dlq_arn
}

resource "aws_connect_instance_attribute" "multi_party_conference" {
  instance_id    = local.connect_instance_id
  attribute_type = "MULTI_PARTY_CONFERENCING"
  value          = "true"
}

resource "aws_cloudwatch_event_rule" "routing_profile_change" {
  count          = var.enable_event_driven_updates ? 1 : 0
  name           = "${var.org_name}-routing-profile-change-${terraform.workspace}"
  event_bus_name = local.event_bus_name
  event_pattern  = jsonencode({
    source      = ["connect-pbx.supervisor", "connect-pbx.workforce-management"]
    detail-type = ["ConnectPBX.RoutingProfileChangeRequested"]
  })
}

resource "aws_cloudwatch_event_target" "routing_profile_manager" {
  count          = var.enable_event_driven_updates ? 1 : 0
  rule           = aws_cloudwatch_event_rule.routing_profile_change[0].name
  event_bus_name = local.event_bus_name
  target_id      = "routing-profile-manager-lambda"
  arn            = aws_lambda_alias.routing_profile_manager_live[0].arn

  dynamic "dead_letter_config" {
    for_each = local.eventbridge_dlq_arn == null ? [] : [1]
    content {
      arn = local.eventbridge_dlq_arn
    }
  }

  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 2
  }
}

resource "aws_iam_role" "routing_profile_manager" {
  count = var.enable_event_driven_updates ? 1 : 0
  name = "${var.org_name}-routing-profile-mgr-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })

  permissions_boundary = local.permission_boundary_arn
  tags = {
    Layer = "L5"
    PRD   = "PRD-54"
  }
}

resource "aws_iam_role_policy" "routing_profile_manager_service" {
  count = var.enable_event_driven_updates ? 1 : 0
  name = "service-specific"
  role = aws_iam_role.routing_profile_manager[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConnectUpdateRoutingProfile"
        Effect   = "Allow"
        Action   = ["connect:UpdateUserRoutingProfile", "connect:SearchUsers"]
        Resource = "arn:aws:connect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${local.connect_instance_id}/*"
      },
      {
        Sid      = "DynamoDBAgentState"
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = local.agent_state_table_arn == null ? [] : [local.agent_state_table_arn]
      },
      {
        Sid      = "EventBridgePublish"
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = local.event_bus_arn == null ? [] : [local.event_bus_arn]
      }
    ]
  })
}

resource "aws_lambda_function" "routing_profile_manager" {
  count         = var.enable_event_driven_updates ? 1 : 0
  function_name = "${var.org_name}-routing-profile-manager-${terraform.workspace}"
  role          = aws_iam_role.routing_profile_manager[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 120
  memory_size   = 256

  filename         = data.archive_file.routing_profile_manager.output_path
  source_code_hash = data.archive_file.routing_profile_manager.output_base64sha256

  environment {
    variables = {
      CONNECT_INSTANCE_ID    = local.connect_instance_id
      AGENT_STATE_TABLE_NAME = local.agent_state_table_name
      ROUTING_PROFILE_IDS    = jsonencode(local.routing_profile_ids)
      EVENT_BUS_NAME         = local.event_bus_name
      ENABLE_SHARED_STATE    = local.agent_state_table_name == null ? "false" : "true"
      ENABLE_CHANGE_EVENTS   = local.event_bus_name == null ? "false" : "true"
    }
  }

  tracing_config {
    mode = "Active"
  }

  tags = {
    Layer = "L5"
    PRD   = "PRD-54"
  }
}

resource "aws_lambda_alias" "routing_profile_manager_live" {
  count            = var.enable_event_driven_updates ? 1 : 0
  name             = "LIVE"
  function_name    = aws_lambda_function.routing_profile_manager[0].function_name
  function_version = aws_lambda_function.routing_profile_manager[0].version

  lifecycle {
    ignore_changes = [function_version, routing_config]
  }
}

resource "aws_lambda_permission" "routing_profile_manager_events" {
  count         = var.enable_event_driven_updates ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.routing_profile_manager[0].function_name
  qualifier     = "LIVE"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.routing_profile_change[0].arn
}
```

### Lambda Source

```python
# lambda-src/routing-profile-manager/index.py
import json
import logging
import os
import time

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

connect_client = boto3.client("connect")
dynamodb = boto3.resource("dynamodb")
events = boto3.client("events")

INSTANCE_ID = os.environ["CONNECT_INSTANCE_ID"]
AGENT_STATE_TABLE_NAME = os.environ["AGENT_STATE_TABLE_NAME"]
ROUTING_PROFILE_IDS = json.loads(os.environ["ROUTING_PROFILE_IDS"])
EVENT_BUS_NAME = os.environ["EVENT_BUS_NAME"]
ENABLE_SHARED_STATE = os.environ.get("ENABLE_SHARED_STATE", "false") == "true"
ENABLE_CHANGE_EVENTS = os.environ.get("ENABLE_CHANGE_EVENTS", "false") == "true"
ALLOWED_SOURCES = {
    "connect-pbx.supervisor",
    "connect-pbx.workforce-management",
}


class PermanentError(Exception):
    pass


def lookup_user_id(username: str) -> str:
    response = connect_client.search_users(
        InstanceId=INSTANCE_ID,
        SearchCriteria={
            "StringCondition": {
                "FieldName": "Username",
                "Value": username,
                "ComparisonType": "EXACT",
            }
        },
        MaxResults=1,
    )
    users = response.get("Users", [])
    if not users:
        raise PermanentError(f"Unknown agent username: {username}")
    return users[0]["Id"]


def update_agent_state(username: str, profile_key: str) -> None:
    if not ENABLE_SHARED_STATE:
        return
    table = dynamodb.Table(AGENT_STATE_TABLE_NAME)
    table.update_item(
        Key={"AgentUsername": username},
        UpdateExpression="SET RoutingProfileKey = :rk, UpdatedAt = :ua",
        ExpressionAttributeValues={
            ":rk": profile_key,
            ":ua": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
    )


def publish_change_event(username: str, profile_key: str) -> None:
    if not ENABLE_CHANGE_EVENTS:
        return
    events.put_events(
        Entries=[
            {
                "Source": "connect-pbx.routing-profile-manager",
                "DetailType": "ConnectPBX.RoutingProfileChanged",
                "EventBusName": EVENT_BUS_NAME,
                "Detail": json.dumps(
                    {
                        "schema_version": "1.0",
                        "payload": {
                            "agent_username": username,
                            "routing_profile_key": profile_key,
                        },
                    }
                ),
            }
        ]
    )


def handle_update(update: dict) -> dict:
    username = update.get("agent_username")
    profile_key = update.get("routing_profile_key")
    if not username or not profile_key:
        raise PermanentError(f"Malformed routing-profile update: {update}")

    profile_id = ROUTING_PROFILE_IDS.get(profile_key)
    if not profile_id:
        raise PermanentError(f"Unknown routing profile key: {profile_key}")

    user_id = lookup_user_id(username)
    connect_client.update_user_routing_profile(
        InstanceId=INSTANCE_ID,
        UserId=user_id,
        RoutingProfileId=profile_id,
    )
    update_agent_state(username, profile_key)
    publish_change_event(username, profile_key)
    return {"agent_username": username, "routing_profile_key": profile_key, "status": "success"}


def handler(event, context):
    source = event.get("source", "")
    if source not in ALLOWED_SOURCES:
        LOGGER.warning("Rejected routing profile change from unauthorized source: %s", source)
        raise PermanentError(f"Unauthorized event source: {source}")

    payload = event.get("detail", {}).get("payload", {})
    updates = payload.get("updates", []) if payload.get("bulk") else [payload]

    results = []
    for update in updates:
        result = handle_update(update)
        results.append(result)
        if payload.get("bulk"):
            time.sleep(0.1)

    return {"statusCode": 200, "results": results}
```

### Variables and Outputs

```hcl
# variables.tf
variable "org_name" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type = string
}

variable "connect_instance_state_key" {
  type = string
}

variable "routing_profiles_state_key" {
  type = string
}

variable "agent_state_state_key" {
  type    = string
  default = null
}

variable "event_bus_state_key" {
  type    = string
  default = null
}

variable "enable_event_driven_updates" {
  type    = bool
  default = false
}

variable "eventbridge_dlq_arn" {
  type    = string
  default = null
}

output "routing_profile_manager_arn" {
  value = var.enable_event_driven_updates ? aws_lambda_function.routing_profile_manager[0].arn : null
}
```

---

## 10. EVENT SCHEMA

### RoutingProfileChangeRequested (Inbound)

```json
{
  "source": "connect-pbx.supervisor",
  "detail-type": "ConnectPBX.RoutingProfileChangeRequested",
  "detail": {
    "schema_version": "1.0",
    "event_id": "{uuid}",
    "timestamp": "{ISO 8601}",
    "environment": "prod",
    "payload": {
      "agent_username": "jsmith",
      "routing_profile_key": "omni",
      "bulk": false
    }
  }
}
```

### RoutingProfileChanged (Outbound)

```json
{
  "source": "connect-pbx.routing-profile-manager",
  "detail-type": "ConnectPBX.RoutingProfileChanged",
  "detail": {
    "schema_version": "1.0",
    "event_id": "{uuid}",
    "timestamp": "{ISO 8601}",
    "environment": "prod",
    "payload": {
      "agent_username": "jsmith",
      "routing_profile_key": "omni"
    }
  }
}
```

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "connect_instance" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.connect_instance_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "routing_profiles" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.routing_profiles_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "agent_state" {
  count   = var.agent_state_state_key == null ? 0 : 1
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.agent_state_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "event_bus" {
  count   = var.event_bus_state_key == null ? 0 : 1
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.event_bus_state_key
    region = var.aws_region
  }
}
```

The runner resolves the state keys from the catalog. The PRD should not hardcode environment-specific backend names or workspace prefixes. `agent_state_state_key` and `event_bus_state_key` are optional inputs used only when shared-state or event-driven integrations are enabled.

---

## 12. DATA MODEL

Updates existing Agent State records in PRD-31. No new tables.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l5-routing-profile-management
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l5-routing-profile-management
      environment: "${{ inputs.environment }}"
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l5-routing-profile-management
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l5-routing-profile-management-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

- `ALARM-54-01: Routing Profile Manager Lambda Error`
  - Metric: Lambda `Errors` > 0
  - Severity: High

- `ALARM-54-02: Unauthorized Source Attempt`
  - Metric: CloudWatch Logs filter for `Unauthorized event source`
  - Threshold: greater than 0 in 5 minutes
  - Severity: High

- `ALARM-54-03: Bulk Update Throttle or Timeout`
  - Metric: Lambda `Throttles` or `Duration` nearing timeout
  - Severity: Medium

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-54-01 | Module is selected through manifest/catalog rather than `deployment_profile` | Deployment manifest enables the module and the PRD makes no activation claim based on `deployment_profile` |
| AC-54-02 | Multi-party conferencing is enabled when the module is applied | `aws connect describe-instance-attribute` returns `true` for `MULTI_PARTY_CONFERENCING` |
| AC-54-03 | Routing profile change updates Connect and Agent State | Event is published and the agent profile and Agent State key both change |
| AC-54-04 | Unauthorized source is rejected | Source outside the allowlist raises a permanent error and does not mutate Connect |
| AC-54-05 | Bulk update runs sequentially | A 5-agent bulk update completes successfully without throttling failures |
| AC-54-06 | Optional audit sink is not required for activation | Module remains deployable when the optional audit sink is omitted |
| AC-54-07 | Current repo conventions are used | Terraform uses partial `s3` backend, `>= 1.14.0`, and AWS provider `~> 6.0` |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Bulk updates exceed Connect API rate limits | Medium | Medium | Process sequentially and insert a delay between updates |
| Unauthorized source attempts reach the Lambda | Low | High | Fail permanently and alert on the rejection pattern |
| Module destruction leaves the instance attribute enabled | Medium | Medium | Treat instance conferencing as retained state and document the retention boundary |
| Audit sink drift turns into a hidden prerequisite | Medium | High | Keep audit/change-event publishing optional and do not bind deployability to PRD-03 |

---

## 17. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.3.0 | 2026-04-06 | — | Implementation-readiness hardening: made the CLI/runbook path explicit when event-driven updates are disabled, made shared-state and change-event integrations truly optional in the Terraform and Lambda samples, and aligned plan artifact naming with current repo conventions. |
| 1.0.0 | 2026-03-16 | — | Initial release. Multi-party conference activated. Runtime routing profile management via EventBridge. Bulk update support. Unauthorized source protection. |
| 1.1.0 | 2026-03-30 | — | Normalized PRD-54 as optional agent-operations tooling. Clarified CLI-first invocation could coexist with event-driven entrypoints. |
| 1.2.0 | 2026-04-05 | — | Aligned PRD-54 to the repo's manifest/catalog control plane, added the repo-owned modularity section, removed `deployment_profile` activation language, and normalized backend/provider examples and sample Lambda behavior. |
