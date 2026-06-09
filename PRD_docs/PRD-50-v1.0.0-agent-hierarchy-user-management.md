# PRD-50 — Agent Hierarchy & User Management

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-50 |
| **Version** | 1.3.0 |
| **Status** | Green |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 5 — Agent Experience |
| **Module Classification** | conditional-foundation |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-10 (Connect instance ID, security profile IDs), PRD-13 (routing profile IDs) |
| **Blocks** | PRD-51 (CCP Configuration), PRD-52 (Whisper Flows), PRD-53 (Agent Transfer), PRD-54 (Routing Profile Management) |
| **Optional Shared Sinks** | EventBridge onboarding events and shared Agent State writes, if enabled |
| **Destroy / Retention Posture** | conditional / hierarchy resources destroyable; user lifecycle integrations require operator review |
| **Optional** | Yes — optional foundation for agent hierarchy and user bootstrap |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and per-environment deployment manifests. `deployment_profile` is runtime shape only for scale, capacity, topology, and regional behavior; it does not decide whether this module is enabled.

### Module Classification

- `classification`: `conditional-foundation`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l5-agent-hierarchy`
- `capability_packs`: `[]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture"]`
- `state_key`: `l5-agent-hierarchy/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `agent-hierarchy.tfvars`
- `supports_destroy`: `true`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated agent-experience capability pack exists

### Shared Sink Behavior

- `optional_shared_sinks`: EventBridge onboarding events; shared Agent State writes; alarm and audit exports, if enabled
- `sink_behavior`: optional inputs only. They do not determine whether the hierarchy module exists in an environment.

### Destroy / Retention Posture

- `destroy_posture`: `conditional`
- `retention_notes`: hierarchy groups are destroyable with the environment, but user lifecycle integrations should not rely on destroy/apply cycles as a steady-state operator workflow.

### Control Plane Statement

The core PRD-50 boundary is the Connect hierarchy structure plus exported hierarchy identifiers. Centralized provisioning, shared-state writes, and onboarding events are additive integrations and must not become hidden prerequisites.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Amazon Connect requires agents to be defined as users within the instance before they can receive calls. Each agent needs a security profile, a routing profile, and an optional hierarchy group assignment. Without agents, queues have no recipients and calls never connect to a human.

This PRD establishes the three-tier Connect agent hierarchy structure (Managers -> Supervisors -> Agents), provisions hierarchy groups for each of the six departments, and optionally implements centralized agent provisioning. Shared Agent State tracking and event-driven onboarding are follow-on integrations that are only active when their owning modules and deployment manifests enable them.

### What Problem It Solves

- Provisions the three-tier Connect hierarchy group structure across six departments
- Supports centralized agent provisioning through CLI or an optional provisioning Lambda when the module is enabled in the catalog and manifest
- Supports optional tracking of agent skills, shift schedule, and department in shared state when that integration is enabled
- Exports hierarchy group IDs for reporting, Contact Lens, and supervisor monitoring dashboards
- Establishes the agent attribute schema that PRD-83 (Screen Pop) and future observability or workforce monitoring layers consume

### How It Fits the Overall Architecture

PRD-50 sits at the base of the Agent Experience layer. Layer 5 PRDs that provision agent-facing capabilities can consume its outputs when the manifest enables this module. The hierarchy structure defined here is also the organizational backbone for future real-time and historical reporting layers.

---

## 4. GOALS

### Goals

- Provision Connect hierarchy groups for three tiers (Manager, Supervisor, Agent) across six departments
- Support centralized agent provisioning that creates Connect users from structured payloads
- Support optional writing of agent attributes (skills, shift, department) to shared state on provisioning when the shared-state module is enabled
- Export hierarchy group IDs and ARNs for downstream PRDs
- Establish optional event schemas for `AgentOnboarding` and `AgentDeprovisioned` when the event-driven integration is enabled

### Non-Goals

- This PRD does not implement real-time agent status tracking — that is a future observability or workforce monitoring layer
- This PRD does not implement SSO/SAML user federation — that is PRD-120
- This PRD does not provision the Connect CCP for agents — that is PRD-51
- This PRD does not manage routing profile changes at runtime — that is PRD-54
- This PRD does not implement agent skills-based routing at the queue level — noted in OQ-13-03

---

## 5. PERSONAS & USER STORIES

### Personas

**HR / Operations Manager** — Submits a structured onboarding request through the approved operating path for the environment. That may be a CLI/runbook flow or an optional event-driven provisioning integration.

**Connect Administrator** — Views the hierarchy structure in the Connect console to understand the organizational layout and assign supervisors to their teams.

**Platform Engineer** — Provisions the hierarchy group structure as Terraform resources. Verifies agents can be created through the selected operating path before PRD-51 is applied.

**Supervisor** — Uses the Connect Real-Time Metrics dashboard to monitor the agents in their hierarchy group.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-50-01 | Platform Engineer | As the platform engineer, I want the three-tier hierarchy group structure provisioned via Terraform so that the organizational model is version-controlled | All hierarchy groups exist in Connect after apply |
| US-50-02 | Operations Manager | As the operations manager, I want a controlled onboarding path for new agents so that no one needs ad hoc Connect console work | Submit the approved onboarding contract; confirm the Connect user is created correctly |
| US-50-03 | Operations Manager | As the operations manager, I want agent skills and department tracked in DynamoDB so that I can query agent profiles without calling Connect | Agent State record written on provisioning with skills, shift, and department |
| US-50-04 | Supervisor | As a supervisor, I want agents in my team assigned to my hierarchy group so that I can monitor them on the real-time dashboard | Agents assigned to correct department hierarchy group on provisioning |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Three-Tier Hierarchy Group Structure
The system must provision Connect hierarchy groups following a three-tier structure. Tier 1 is the highest (Manager), Tier 2 is middle (Supervisor), Tier 3 is lowest (Agent). The hierarchy must be provisioned for each of the six departments: General, Sales, Customer Support, Billing, Technical Support, and Escalations.

The hierarchy levels are provisioned as `aws_connect_hierarchy_structure` (the level definitions — only one per instance) and `aws_connect_hierarchy_group` resources (the actual groups at each level).

### FR-002 — Hierarchy Level Definitions
The instance hierarchy structure must define three levels:

| Level | Name |
|---|---|
| Level 1 | Manager |
| Level 2 | Supervisor |
| Level 3 | Agent |

Only one `aws_connect_hierarchy_structure` resource exists per Connect instance. It defines the level names, not the groups themselves.

### FR-003 — Hierarchy Group Provisioning
The system must provision the following hierarchy groups. Groups are organized as a tree: each Supervisor group has a Manager group as its parent; each Agent group has a Supervisor group as its parent.

```
Manager Groups (Level 1 — one per department):
  {org}-General-Manager
  {org}-Sales-Manager
  {org}-Support-Manager
  {org}-Billing-Manager
  {org}-TechSupport-Manager
  {org}-Escalations-Manager

Supervisor Groups (Level 2 — one per department, parent = department Manager):
  {org}-General-Supervisor    → parent: {org}-General-Manager
  {org}-Sales-Supervisor      → parent: {org}-Sales-Manager
  {org}-Support-Supervisor    → parent: {org}-Support-Manager
  {org}-Billing-Supervisor    → parent: {org}-Billing-Manager
  {org}-TechSupport-Supervisor → parent: {org}-TechSupport-Manager
  {org}-Escalations-Supervisor → parent: {org}-Escalations-Manager

Agent Groups (Level 3 — one per department, parent = department Supervisor):
  {org}-General-Agents        → parent: {org}-General-Supervisor
  {org}-Sales-Agents          → parent: {org}-Sales-Supervisor
  {org}-Support-Agents        → parent: {org}-Support-Supervisor
  {org}-Billing-Agents        → parent: {org}-Billing-Supervisor
  {org}-TechSupport-Agents    → parent: {org}-TechSupport-Supervisor
  {org}-Escalations-Agents    → parent: {org}-Escalations-Supervisor
```

### FR-004 — Centralized Agent Provisioning Contract
The module must support centralized agent provisioning for environments that choose to enable it. The steady-state boundary is the provisioning contract, not a mandatory Lambda. The default production-safe operating path is an operator-reviewed runbook/CLI flow that reads a structured onboarding manifest and a Secrets Manager reference for the temporary password. An environment may additionally enable an event-driven Lambda integration, but that is optional.

The supported automated onboarding contract in this PRD is limited to frontline agent users. Supervisor and manager provisioning remain operator-reviewed workflows outside the Lambda path.

When the optional event-driven path is enabled, the Lambda function `{org_name}-agent-provisioner` consumes `ConnectPBX.AgentOnboarding` events and must:

1. Parse the `AgentOnboarding` event payload
2. Read the temporary password from the referenced Secrets Manager secret rather than from the event payload itself
3. Create a Connect user via `aws connect create-user` with the specified username, routing profile, security profile, temporary password, and hierarchy group
4. Optionally write an Agent State record to the Agent State DynamoDB table when PRD-31 is also enabled in the manifest, carrying agent attributes including skills, shift schedule, and department
5. Publish a `ConnectPBX.AgentProvisioned` event only when the optional event bus integration is enabled
6. On failure, publish a `ConnectPBX.AgentProvisioningFailed` event only when the optional event bus integration is enabled

### FR-005 — Optional Agent Deprovision Integration
If the environment enables centralized deprovisioning, the implementation may provide a Lambda function `{org_name}-agent-deprovisioner` or an equivalent controlled operator workflow. The enabled path must delete the Connect user and remove the Agent State record when shared state is also enabled. The event-driven deprovisioner remains optional; the runbook/CLI contract is the default authority.

### FR-006 — Agent Attribute Tracking
When PRD-31 shared state is enabled alongside PRD-50, the following attributes must be written to the Agent State DynamoDB table during provisioning:

| Attribute | Source | Description |
|---|---|---|
| `AgentUsername` | Event payload | Connect username (primary key) |
| `Department` | Event payload | One of: general, sales, support, billing, technical-support, escalations |
| `HierarchyGroupKey` | Derived from department | e.g., `{org}-Sales-Agents` |
| `RoutingProfileKey` | Event payload | Key into routing_profiles map from PRD-13 |
| `Skills` | Event payload | List of skill strings (e.g., `["spanish", "technical-tier-2"]`) |
| `ShiftStart` | Event payload | HH:MM in the agent's local time zone |
| `ShiftEnd` | Event payload | HH:MM in the agent's local time zone |
| `ShiftTimezone` | Event payload | IANA timezone string |
| `SecurityProfileKey` | Derived | `agent-default` for agents, `platform-admin` for managers |
| `CurrentStatus` | Default: `OFFLINE` | Updated by future real-time agent status tracking |

### FR-007 — Hierarchy Group ID Export
All hierarchy group IDs and ARNs must be exported as maps keyed by a combination of department and tier (e.g., `sales-agent`, `sales-supervisor`, `sales-manager`). These are consumed by future real-time monitoring and workforce visibility layers.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Scale
If the optional provisioning Lambda is enabled, it handles one agent onboarding event at a time. At large deployments (500 agents), initial bulk provisioning may require sequential processing. The onboarding contract must remain idempotent regardless of whether the environment uses Lambda or a runbook/CLI path.

### Security
- If the optional provisioning Lambda path is enabled, the provisioner role is scoped to `connect:CreateUser`, `connect:DescribeUser`, `connect:SearchUsers`, temporary-password secret read access, optional EventBridge publish, and Agent State writes only when shared state is enabled
- If the optional provisioning Lambda path is enabled, the deprovisioner role is scoped to `connect:DeleteUser`, `connect:SearchUsers`, and Agent State deletes only when shared state is enabled
- Permission boundary from PRD-02 applied
- No automation component has `connect:*` — always minimum required actions

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| SOC 2 CC6.1 | Agent access controlled via security profiles and hierarchy | Connect user configuration |
| PCI-DSS Req 8.1 | Each agent has a unique username | Connect enforces unique usernames per instance |

---

## 8. ARCHITECTURE

### Hierarchy Group Tree

```
Connect Instance
└── Hierarchy Structure (3 levels: Manager, Supervisor, Agent)
    │
    ├── {org}-General-Manager (L1)
    │   └── {org}-General-Supervisor (L2)
    │       └── {org}-General-Agents (L3) ← agents assigned here
    │
    ├── {org}-Sales-Manager (L1)
    │   └── {org}-Sales-Supervisor (L2)
    │       └── {org}-Sales-Agents (L3)
    │
    ├── {org}-Support-Manager (L1)
    │   └── {org}-Support-Supervisor (L2)
    │       └── {org}-Support-Agents (L3)
    │
    ├── {org}-Billing-Manager (L1)
    │   └── {org}-Billing-Supervisor (L2)
    │       └── {org}-Billing-Agents (L3)
    │
    ├── {org}-TechSupport-Manager (L1)
    │   └── {org}-TechSupport-Supervisor (L2)
    │       └── {org}-TechSupport-Agents (L3)
    │
    └── {org}-Escalations-Manager (L1)
        └── {org}-Escalations-Supervisor (L2)
            └── {org}-Escalations-Agents (L3)
```

### Event-Driven Provisioning Flow

```
HR System / Operations Manager
      │
      │ Publish AgentOnboarding event to platform bus
      ▼
EventBridge Custom Bus (PRD-20)
      │
      ├── Rule: ConnectPBX.AgentOnboarding
      │         │
      │         ▼
      │   agent-provisioner Lambda
      │         │
      │         ├── connect:CreateUser
      │         ├── DynamoDB PutItem (Agent State)
      │         └── Publish ConnectPBX.AgentProvisioned
      │
      └── Rule: ConnectPBX.AgentDeprovisioned
                │
                ▼
          agent-deprovisioner Lambda
                │
                ├── connect:DeleteUser
                └── DynamoDB DeleteItem (Agent State)
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `hierarchy_group_ids` | map(string) | Map of `{dept}-{tier}` → hierarchy group ID | future monitoring layers, PRD-54 |
| `hierarchy_group_arns` | map(string) | Map of `{dept}-{tier}` → ARN | future monitoring layers |
| `hierarchy_structure_id` | string | Connect hierarchy structure ID | PRD-54 |
| `provisioner_function_arn` | string or null | Agent provisioner Lambda ARN when the optional event-driven mode is enabled | future monitoring layers |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l5-agent-hierarchy/         # PRD-50
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            ├── agent-provisioner/
            │   └── index.py
            └── agent-deprovisioner/
                └── index.py
```

### Key Resources Declared

```hcl
# main.tf

# Hierarchy level definitions (one resource per instance)
resource "aws_connect_hierarchy_structure" "main" {
  instance_id = local.connect_instance_id

  hierarchy_structure {
    level_one   { name = "Manager" }
    level_two   { name = "Supervisor" }
    level_three { name = "Agent" }
  }
}

# Hierarchy groups — use locals to define the department/tier matrix

locals {
  departments = ["General", "Sales", "Support", "Billing", "TechSupport", "Escalations"]

  manager_groups = {
    for dept in local.departments :
    "${lower(dept)}-manager" => {
      name       = "${var.org_name}-${dept}-Manager"
      level_id   = aws_connect_hierarchy_structure.main.hierarchy_structure[0].level_one[0].id
      parent_key = null
    }
  }

  supervisor_groups = {
    for dept in local.departments :
    "${lower(dept)}-supervisor" => {
      name       = "${var.org_name}-${dept}-Supervisor"
      level_id   = aws_connect_hierarchy_structure.main.hierarchy_structure[0].level_two[0].id
      parent_key = "${lower(dept)}-manager"
    }
  }

  agent_groups = {
    for dept in local.departments :
    "${lower(dept)}-agent" => {
      name       = "${var.org_name}-${dept}-Agents"
      level_id   = aws_connect_hierarchy_structure.main.hierarchy_structure[0].level_three[0].id
      parent_key = "${lower(dept)}-supervisor"
    }
  }

  all_groups = merge(
    local.manager_groups,
    local.supervisor_groups,
    local.agent_groups
  )

  lambda_runtime_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-*"
      },
      {
        Sid      = "XRayTracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules", "xray:GetSamplingTargets"]
        Resource = "*"
      }
    ]
  })
}

# Manager groups (no parent)
resource "aws_connect_hierarchy_group" "managers" {
  for_each    = local.manager_groups
  instance_id = local.connect_instance_id
  name        = each.value.name
  level_id    = each.value.level_id

  tags = { Layer = "L5", PRD = "PRD-50", Tier = "manager", Department = split("-", each.key)[0] }
}

# Supervisor groups (parent = manager group)
resource "aws_connect_hierarchy_group" "supervisors" {
  for_each         = local.supervisor_groups
  instance_id      = local.connect_instance_id
  name             = each.value.name
  level_id         = each.value.level_id
  parent_group_id  = aws_connect_hierarchy_group.managers[each.value.parent_key].hierarchy_group_id

  tags = { Layer = "L5", PRD = "PRD-50", Tier = "supervisor", Department = split("-", each.key)[0] }
}

# Agent groups (parent = supervisor group)
resource "aws_connect_hierarchy_group" "agents" {
  for_each        = local.agent_groups
  instance_id     = local.connect_instance_id
  name            = each.value.name
  level_id        = each.value.level_id
  parent_group_id = aws_connect_hierarchy_group.supervisors[each.value.parent_key].hierarchy_group_id

  tags = { Layer = "L5", PRD = "PRD-50", Tier = "agent", Department = split("-", each.key)[0] }
}

# EventBridge rule — AgentOnboarding (optional event-driven mode only)
resource "aws_cloudwatch_event_rule" "agent_onboarding" {
  count          = var.enable_event_driven_provisioning ? 1 : 0
  name           = "${var.org_name}-agent-onboarding-${terraform.workspace}"
  event_bus_name = local.event_bus_name
  event_pattern  = jsonencode({
    source      = ["connect-pbx.hr"]
    detail-type = ["ConnectPBX.AgentOnboarding"]
  })
}

resource "aws_cloudwatch_event_target" "agent_provisioner" {
  count          = var.enable_event_driven_provisioning ? 1 : 0
  rule           = aws_cloudwatch_event_rule.agent_onboarding[0].name
  event_bus_name = local.event_bus_name
  target_id      = "agent-provisioner-lambda"
  arn            = aws_lambda_alias.agent_provisioner_live[0].arn

  dynamic "dead_letter_config" {
    for_each = local.eventbridge_dlq_arn == null ? [] : [1]
    content { arn = local.eventbridge_dlq_arn }
  }
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# EventBridge rule — AgentDeprovisioned (optional event-driven mode only)
resource "aws_cloudwatch_event_rule" "agent_deprovisioned" {
  count          = var.enable_event_driven_provisioning ? 1 : 0
  name           = "${var.org_name}-agent-deprovisioned-${terraform.workspace}"
  event_bus_name = local.event_bus_name
  event_pattern  = jsonencode({
    source      = ["connect-pbx.hr"]
    detail-type = ["ConnectPBX.AgentDeprovisioned"]
  })
}

resource "aws_cloudwatch_event_target" "agent_deprovisioner" {
  count          = var.enable_event_driven_provisioning ? 1 : 0
  rule           = aws_cloudwatch_event_rule.agent_deprovisioned[0].name
  event_bus_name = local.event_bus_name
  target_id      = "agent-deprovisioner-lambda"
  arn            = aws_lambda_alias.agent_deprovisioner_live[0].arn

  dynamic "dead_letter_config" {
    for_each = local.eventbridge_dlq_arn == null ? [] : [1]
    content { arn = local.eventbridge_dlq_arn }
  }
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 3
  }
}

# IAM roles for Lambda functions
# The optional event-driven path may use self-contained function packages.
# If a deployment also enables PRD-40, shared layers may be attached as an additive input,
# but PRD-40 is not a hidden prerequisite for PRD-50 itself.

resource "aws_iam_role" "agent_provisioner" {
  count = var.enable_event_driven_provisioning ? 1 : 0
  name = "${var.org_name}-agent-provisioner-${terraform.workspace}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  permissions_boundary = local.permission_boundary_arn
  tags = { Layer = "L5", PRD = "PRD-50" }
}

resource "aws_iam_role_policy" "agent_provisioner_baseline" {
  count  = var.enable_event_driven_provisioning ? 1 : 0
  name   = "baseline"
  role   = aws_iam_role.agent_provisioner[0].id
  policy = local.lambda_runtime_policy_json
}

resource "aws_iam_role_policy" "agent_provisioner_service" {
  count = var.enable_event_driven_provisioning ? 1 : 0
  name = "service-specific"
  role = aws_iam_role.agent_provisioner[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConnectCreateUser"
        Effect   = "Allow"
        Action   = ["connect:CreateUser", "connect:DescribeUser", "connect:SearchUsers"]
        Resource = "arn:aws:connect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${local.connect_instance_id}/*"
      },
      {
        Sid      = "SecretsManagerReadTemporaryPassword"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.temporary_password_secret_arn]
      },
      {
        Sid      = "DynamoDBAgentState"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
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

resource "aws_iam_role" "agent_deprovisioner" {
  count = var.enable_event_driven_provisioning ? 1 : 0
  name = "${var.org_name}-agent-deprovisioner-${terraform.workspace}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  permissions_boundary = local.permission_boundary_arn
  tags = { Layer = "L5", PRD = "PRD-50" }
}

resource "aws_iam_role_policy" "agent_deprovisioner_baseline" {
  count  = var.enable_event_driven_provisioning ? 1 : 0
  name   = "baseline"
  role   = aws_iam_role.agent_deprovisioner[0].id
  policy = local.lambda_runtime_policy_json
}

resource "aws_iam_role_policy" "agent_deprovisioner_service" {
  count = var.enable_event_driven_provisioning ? 1 : 0
  name = "service-specific"
  role = aws_iam_role.agent_deprovisioner[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConnectDeleteUser"
        Effect   = "Allow"
        Action   = ["connect:DeleteUser", "connect:SearchUsers"]
        Resource = "arn:aws:connect:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${local.connect_instance_id}/*"
      },
      {
        Sid      = "DynamoDBAgentState"
        Effect   = "Allow"
        Action   = ["dynamodb:DeleteItem"]
        Resource = local.agent_state_table_arn == null ? [] : [local.agent_state_table_arn]
      }
    ]
  })
}

# Lambda permissions for EventBridge invocation

resource "aws_lambda_permission" "agent_provisioner_events" {
  count         = var.enable_event_driven_provisioning ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent_provisioner[0].function_name
  qualifier     = "LIVE"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.agent_onboarding[0].arn
}

resource "aws_lambda_permission" "agent_deprovisioner_events" {
  count         = var.enable_event_driven_provisioning ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent_deprovisioner[0].function_name
  qualifier     = "LIVE"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.agent_deprovisioned[0].arn
}

# Lambda functions
resource "aws_lambda_function" "agent_provisioner" {
  count         = var.enable_event_driven_provisioning ? 1 : 0
  function_name = "${var.org_name}-agent-provisioner-${terraform.workspace}"
  role          = aws_iam_role.agent_provisioner[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.agent_provisioner.output_path
  source_code_hash = data.archive_file.agent_provisioner.output_base64sha256

  environment {
    variables = {
      CONNECT_INSTANCE_ID      = local.connect_instance_id
      AGENT_SECURITY_PROFILE   = local.agent_security_profile_id
      TEMP_PASSWORD_SECRET_ARN = var.temporary_password_secret_arn
      HIERARCHY_GROUP_IDS      = jsonencode({
        for k, v in aws_connect_hierarchy_group.agents : k => v.hierarchy_group_id
      })
      ROUTING_PROFILE_IDS      = jsonencode(local.routing_profile_ids)
      AGENT_STATE_TABLE        = local.agent_state_table_name
      ENABLE_SHARED_STATE      = local.agent_state_table_name == null ? "false" : "true"
      ENABLE_EVENT_BUS         = local.event_bus_name == null ? "false" : "true"
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L5", PRD = "PRD-50" }
}

resource "aws_lambda_alias" "agent_provisioner_live" {
  count            = var.enable_event_driven_provisioning ? 1 : 0
  name             = "LIVE"
  function_name    = aws_lambda_function.agent_provisioner[0].function_name
  function_version = aws_lambda_function.agent_provisioner[0].version
  lifecycle { ignore_changes = [function_version, routing_config] }
}

resource "aws_lambda_function" "agent_deprovisioner" {
  count         = var.enable_event_driven_provisioning ? 1 : 0
  function_name = "${var.org_name}-agent-deprovisioner-${terraform.workspace}"
  role          = aws_iam_role.agent_deprovisioner[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.agent_deprovisioner.output_path
  source_code_hash = data.archive_file.agent_deprovisioner.output_base64sha256

  environment {
    variables = {
      CONNECT_INSTANCE_ID = local.connect_instance_id
      AGENT_STATE_TABLE   = local.agent_state_table_name
      ENABLE_SHARED_STATE = local.agent_state_table_name == null ? "false" : "true"
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L5", PRD = "PRD-50" }
}

resource "aws_lambda_alias" "agent_deprovisioner_live" {
  count            = var.enable_event_driven_provisioning ? 1 : 0
  name             = "LIVE"
  function_name    = aws_lambda_function.agent_deprovisioner[0].function_name
  function_version = aws_lambda_function.agent_deprovisioner[0].version
  lifecycle { ignore_changes = [function_version, routing_config] }
}
```

### Lambda Source — Agent Provisioner

```python
# lambda-src/agent-provisioner/index.py
import json
import os
import boto3
import time
from datetime import datetime, timezone
from connect_pbx.logger import Logger
from connect_pbx.errors import TransientError, PermanentError
from connect_pbx import events, dynamodb
from connect_pbx.dynamodb import AgentState

connect  = boto3.client('connect')
secrets  = boto3.client('secretsmanager')
INSTANCE_ID            = os.environ['CONNECT_INSTANCE_ID']
AGENT_SECURITY_PROFILE = os.environ['AGENT_SECURITY_PROFILE']
TEMP_PASSWORD_SECRET_ARN = os.environ['TEMP_PASSWORD_SECRET_ARN']
HIERARCHY_GROUP_IDS    = json.loads(os.environ['HIERARCHY_GROUP_IDS'])
ROUTING_PROFILE_IDS    = json.loads(os.environ['ROUTING_PROFILE_IDS'])
ENABLE_SHARED_STATE    = os.environ.get('ENABLE_SHARED_STATE', 'false') == 'true'
ENABLE_EVENT_BUS       = os.environ.get('ENABLE_EVENT_BUS', 'false') == 'true'

def get_temporary_password(secret_arn: str) -> str:
    value = secrets.get_secret_value(SecretId=secret_arn)
    if 'SecretString' not in value:
        raise PermanentError('Temporary password secret must use SecretString')
    return value['SecretString']

def handler(event, context):
    log     = Logger()
    payload = event.get('detail', {}).get('payload', {})

    username        = payload.get('username')
    department      = payload.get('department')
    routing_profile = payload.get('routing_profile_key', f"{department}-primary")
    skills          = payload.get('skills', [])
    shift_start     = payload.get('shift_start')
    shift_end       = payload.get('shift_end')
    shift_tz        = payload.get('shift_timezone', 'America/New_York')
    email           = payload.get('email')
    first_name      = payload.get('first_name', username)
    last_name       = payload.get('last_name', '')

    if not username or not department:
        raise PermanentError("AgentOnboarding event missing required fields: username, department")

    hierarchy_key      = f"{department.lower().replace('-', '')}-agent"
    hierarchy_group_id = HIERARCHY_GROUP_IDS.get(hierarchy_key)
    routing_profile_id = ROUTING_PROFILE_IDS.get(routing_profile)

    if not routing_profile_id:
        raise PermanentError(f"Unknown routing profile key: {routing_profile}")

    temporary_password = get_temporary_password(
        payload.get('temporary_password_secret_arn', TEMP_PASSWORD_SECRET_ARN)
    )

    log.info("Provisioning agent", username=username, department=department)

    try:
        connect.create_user(
            Username=username,
            InstanceId=INSTANCE_ID,
            IdentityInfo={
                'FirstName': first_name,
                'LastName':  last_name,
                'Email':     email or f"{username}@placeholder.internal"
            },
            PhoneConfig={'PhoneType': 'SOFT_PHONE', 'AutoAccept': False, 'AfterContactWorkTimeLimit': 30},
            SecurityProfileIds=[AGENT_SECURITY_PROFILE],
            RoutingProfileId=routing_profile_id,
            HierarchyGroupId=hierarchy_group_id,
            Password=temporary_password
        )
        log.info("Connect user created", username=username)
    except connect.exceptions.DuplicateResourceException:
        log.warning("Agent already exists in Connect, updating DynamoDB only", username=username)
    except Exception as e:
        raise TransientError(f"Failed to create Connect user: {e}")

    if ENABLE_SHARED_STATE:
        agent_state = AgentState(
            AgentUsername      = username,
            CurrentStatus      = 'OFFLINE',
            RoutingProfileName = routing_profile
        )
        dynamodb.put_agent(agent_state)

        db = boto3.resource('dynamodb')
        table = db.Table(os.environ['AGENT_STATE_TABLE'])
        table.update_item(
            Key={'AgentUsername': username},
            UpdateExpression='SET #dept = :dept, #skills = :skills, #ss = :ss, #se = :se, #tz = :tz, #hg = :hg, #rp = :rp, UpdatedAt = :ua',
            ExpressionAttributeNames={
                '#dept': 'Department', '#skills': 'Skills',
                '#ss': 'ShiftStart', '#se': 'ShiftEnd', '#tz': 'ShiftTimezone',
                '#hg': 'HierarchyGroupKey', '#rp': 'RoutingProfileKey'
            },
            ExpressionAttributeValues={
                ':dept': department, ':skills': skills,
                ':ss': shift_start, ':se': shift_end, ':tz': shift_tz,
                ':hg': hierarchy_key, ':rp': routing_profile,
                ':ua': datetime.now(timezone.utc).isoformat()
            }
        )

    if ENABLE_EVENT_BUS:
        events.publish('AgentProvisioned', {'username': username, 'department': department}, source_suffix='agent-hierarchy')
    log.info("Agent provisioning complete", username=username)
    return {'statusCode': 200, 'username': username}
```

### Variables

```hcl
# variables.tf
variable "org_name" { type = string }
variable "aws_region" { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "agent_hierarchy_state_key" { type = string }
variable "connect_instance_id" { type = string }
variable "routing_profile_ids" { type = map(string) }
variable "security_profile_ids" { type = map(string) }
variable "agent_state_table_name" { type = string, default = null }
variable "event_bus_name" { type = string, default = null }
variable "enable_event_driven_provisioning" { type = bool, default = false }
variable "temporary_password_secret_arn" { type = string, default = null }
```

### Outputs

```hcl
# outputs.tf

output "hierarchy_group_ids" {
  description = "Map of {dept}-{tier} to hierarchy group ID. Consumed by future monitoring layers and PRD-54."
  value = merge(
    { for k, v in aws_connect_hierarchy_group.managers    : k => v.hierarchy_group_id },
    { for k, v in aws_connect_hierarchy_group.supervisors : k => v.hierarchy_group_id },
    { for k, v in aws_connect_hierarchy_group.agents      : k => v.hierarchy_group_id }
  )
}

output "hierarchy_group_arns" {
  description = "Map of {dept}-{tier} to hierarchy group ARN."
  value = merge(
    { for k, v in aws_connect_hierarchy_group.managers    : k => v.arn },
    { for k, v in aws_connect_hierarchy_group.supervisors : k => v.arn },
    { for k, v in aws_connect_hierarchy_group.agents      : k => v.arn }
  )
}

output "hierarchy_structure_id" {
  value = aws_connect_hierarchy_structure.main.id
}

output "provisioner_function_arn" {
  value = var.enable_event_driven_provisioning ? aws_lambda_function.agent_provisioner[0].arn : null
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

The repo's plan and apply workflows inject the catalog-declared `state_key` during `terraform init`. This module does not hardcode environment names or workspace-derived backend paths.

---

## 10. EVENT SCHEMA

### AgentOnboarding (Inbound — published by HR system)

```json
{
  "source": "connect-pbx.hr",
  "detail-type": "ConnectPBX.AgentOnboarding",
  "detail": {
    "schema_version": "1.0",
    "event_id": "{uuid}",
    "timestamp": "{ISO 8601}",
    "environment": "prod",
    "payload": {
      "username": "jsmith",
      "first_name": "Jane",
      "last_name": "Smith",
      "email": "jsmith@company.com",
      "temporary_password_secret_arn": "arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-onboarding/jsmith",
      "department": "sales",
      "routing_profile_key": "sales-primary",
      "skills": ["spanish", "enterprise-accounts"],
      "shift_start": "08:00",
      "shift_end": "17:00",
      "shift_timezone": "America/New_York"
    }
  }
}
```

### AgentProvisioned (Outbound — published on success)

```json
{
  "source": "connect-pbx.agent-hierarchy",
  "detail-type": "ConnectPBX.AgentProvisioned",
  "detail": {
    "schema_version": "1.0",
    "event_id": "{uuid}",
    "timestamp": "{ISO 8601}",
    "environment": "prod",
    "payload": {
      "username": "jsmith",
      "department": "sales"
    }
  }
}
```

### AgentDeprovisioned (Inbound — published by HR system)

```json
{
  "source": "connect-pbx.hr",
  "detail-type": "ConnectPBX.AgentDeprovisioned",
  "detail": {
    "schema_version": "1.0",
    "event_id": "{uuid}",
    "timestamp": "{ISO 8601}",
    "environment": "prod",
    "payload": {
      "username": "jsmith"
    }
  }
}
```

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "agent_hierarchy" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.agent_hierarchy_state_key, region = var.aws_region }
}

locals {
  hierarchy_group_ids = data.terraform_remote_state.agent_hierarchy.outputs.hierarchy_group_ids
}
```

The `agent_hierarchy_state_key` input must match the catalog-declared `state_key` for this module. Optional EventBridge and shared-state integrations are wired through separate inputs and do not change the module's own backend key.

---

## 12. DATA MODEL

### Agent State Record (Extended — written by provisioner Lambda)

```json
{
  "AgentUsername":      "jsmith",
  "AgentArn":          "arn:aws:connect:...",
  "CurrentStatus":     "OFFLINE",
  "Department":        "sales",
  "HierarchyGroupKey": "sales-agent",
  "RoutingProfileKey": "sales-primary",
  "RoutingProfileName": "Sales-Primary",
  "Skills":            ["spanish", "enterprise-accounts"],
  "ShiftStart":        "08:00",
  "ShiftEnd":          "17:00",
  "ShiftTimezone":     "America/New_York",
  "CurrentContactId":  null,
  "LastStatusChange":  "2026-03-16T08:00:00Z",
  "UpdatedAt":         "2026-03-16T08:00:01Z"
}
```

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l5-agent-hierarchy }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l5-agent-hierarchy, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l5-agent-hierarchy
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l5-agent-hierarchy-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Bulk Provisioning Procedure

When the optional event-driven provisioning integration is enabled, an initial deployment with an existing agent roster may publish `AgentOnboarding` events in batch:

```bash
# bulk-provision.sh — run once after PRD-50 is applied
# Reads from a CSV: username,department,routing_profile,skills,shift_start,shift_end,timezone,email,temp_password_secret_arn
# If temp_password_secret_arn is blank, the module-level default secret ARN is used.

while IFS=, read -r username dept rp skills ss se tz email temp_secret; do
  aws events put-events --entries "[{
    \"Source\": \"connect-pbx.hr\",
    \"DetailType\": \"ConnectPBX.AgentOnboarding\",
    \"EventBusName\": \"{org}-connect-pbx-prod\",
    \"Detail\": \"{\\\"schema_version\\\":\\\"1.0\\\",\\\"event_id\\\":\\\"$(uuidgen)\\\",\\\"timestamp\\\":\\\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\\\",\\\"environment\\\":\\\"prod\\\",\\\"payload\\\":{\\\"username\\\":\\\"$username\\\",\\\"department\\\":\\\"$dept\\\",\\\"routing_profile_key\\\":\\\"$rp\\\",\\\"skills\\\":[$skills],\\\"shift_start\\\":\\\"$ss\\\",\\\"shift_end\\\":\\\"$se\\\",\\\"shift_timezone\\\":\\\"$tz\\\",\\\"email\\\":\\\"$email\\\",\\\"temporary_password_secret_arn\\\":\\\"$temp_secret\\\"}}\"
  }]"
  sleep 0.5  # Avoid Lambda throttle
done < agents.csv
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-50-01: Agent Provisioning Lambda Error**
- Metric: Lambda `Errors` > 0 on agent-provisioner
- Severity: High — agent onboarding failing

**ALARM-50-02: Agent Provisioning DLQ Depth**
- Metric: SQS `ApproximateNumberOfMessagesVisible` on provisioner DLQ > 0
- Severity: High — onboarding events failing after max retries

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-50-01 | Hierarchy structure exists with 3 levels | `aws connect describe-user-hierarchy-structure` returns 3 levels |
| AC-50-02 | All 18 hierarchy groups exist (6 depts × 3 tiers) | `aws connect list-user-hierarchy-groups` returns 18 groups |
| AC-50-03 | Parent-child relationships correct | Describe each group; confirm parent IDs match expected structure |
| AC-50-04 | Centralized provisioning contract works through the enabled operating path | Run the selected provisioning path; confirm user exists in Connect with the expected routing profile and hierarchy group |
| AC-50-05 | Agent State record written with all attributes when shared state is enabled | Check DynamoDB after provisioning; confirm skills, shift, department |
| AC-50-06 | Agent lifecycle events are published only when the optional event bus integration is enabled | Check EventBridge or equivalent sink only in environments that enable the event-driven path |
| AC-50-07 | Duplicate provisioning is idempotent | Submit the same onboarding contract twice; confirm a single Connect user |
| AC-50-08 | Centralized deprovisioning removes the user and shared state when those integrations are enabled | Execute the enabled deprovisioning path; confirm user deletion and shared-state cleanup |
| AC-50-09 | hierarchy_group_ids output contains all 18 groups | `terraform output hierarchy_group_ids` returns 18 entries |
| AC-50-10 | Current repo conventions are used | Terraform uses partial `s3` backend, `>= 1.14.0`, and AWS provider `~> 6.0` |
| AC-50-11 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Hierarchy group parent reference fails during first apply — ordering issue | Medium | Medium | Use explicit `depends_on` between manager, supervisor, and agent group resources. Apply manager groups first. |
| Bulk provisioning Lambda throttled on initial 500-agent load | Medium | Medium | Bulk script adds 500ms delay between events. Lambda concurrency reserved at 5 for provisioner to prevent throttling Connect CreateUser API. |
| Agent deleted from Connect but Agent State record not deleted (partial failure) | Low | Medium | Deprovisioner Lambda uses try/finally to attempt both operations. DLQ retry handles partial failures. |
| Skills list stored as DynamoDB List type — querying by skill requires scan | Low | Low | Skills are stored for reference and screen pop, not for routing. Skills-based routing via Connect Routing Profiles V2 is deferred to OQ-13-03. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-50-01 | How should agent passwords be set? Connect CONNECT_MANAGED mode requires a password on user creation. Options: auto-generated temporary password sent via email, or a fixed initial password rotated on first login. | Resolved — onboarding uses a Secrets Manager-backed temporary password reference. The event/runbook carries a secret ARN, not the password value. |
| OQ-50-02 | Should supervisor and manager users also be provisioned via the provisioning Lambda, or are they manually created? | Resolved — the automated provisioning contract in PRD-50 is limited to frontline agents. Supervisor and manager creation remains an operator-reviewed workflow. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.3.0 | 2026-04-06 | — | Implementation-readiness hardening: made the runbook/CLI provisioning path authoritative, limited the Lambda path to an optional integration, resolved temporary-password handling through Secrets Manager, made shared-state and event-bus behavior explicitly conditional, and aligned plan artifact naming with current repo conventions. |
| 1.0.0 | 2026-03-16 | — | Initial release. Three-tier hierarchy across six departments. Event-driven provisioning Lambda. Agent attributes: skills, shift, department. Bulk provisioning procedure documented. |
| 1.1.0 | 2026-03-30 | — | Normalized PRD-50 as an optional agent-management foundation rather than a mandatory prerequisite for all Layer 5 features. Removed mandatory PRD-31, PRD-40, and PRD-41 dependencies from the core architecture. |
| 1.2.0 | 2026-04-05 | — | Added the repo-owned modularity section, removed `deployment_profile` activation drift, normalized backend/state-key conventions, and made EventBridge plus shared-state integrations explicitly optional. |
