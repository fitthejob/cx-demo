# PRD-12 — Hours of Operation & Holiday Schedules

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-12 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-10 (Connect instance ID and ARN), PRD-02 (environment KMS key for DynamoDB encryption) |
| **Blocks** | PRD-13 (Queue Architecture — queues require an hours of operation assignment) |
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
| `path` | `modules/l1-hours-of-operation` |
| `capability_packs` | `["core-telephony"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance"]` |
| `state_key` | `l1-hours-of-operation/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `null` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Not consumed. PRD-12 does not depend on audit or alarm sinks. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `conditional` |
| `retention_notes` | DynamoDB tables storing company holiday closures should use `prevent_destroy = true` to protect user-configured data. Daily closure status table is ephemeral and can be recreated by Lambda. Operator must export holiday data before environment teardown. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Amazon Connect requires every queue to be associated with an Hours of Operation configuration. Without at least one hours of operation resource, no queue can be provisioned, and without queues there is no call routing. This PRD must be applied before PRD-13.

Beyond the technical dependency, Hours of Operation is the primary mechanism for time-based call routing. Calls received outside business hours must be handled differently from calls during business hours — typically routed to voicemail (PRD-60) or an after-hours message.

**Holiday & Closure Override Note:** Amazon Connect does not natively support holiday overrides on Hours of Operation resources. Closures are handled via a three-tier system with different lead times for different scenarios:

1. **US federal holidays (automatic, zero maintenance):** A daily Lambda (triggered by EventBridge at midnight local time) algorithmically computes all US federal holidays. These follow fixed rules (e.g., Thanksgiving = 4th Thursday in November, MLK Day = 3rd Monday in January) and never require manual updates. The 11 standard federal holidays are covered automatically every year. The Lambda writes the result to a daily-status DynamoDB item that contact flows read at call time — no Lambda in the call path.

2. **Planned company closures (tfvars, PR merge cycle):** This PRD provisions a company-specific closures DynamoDB table for known future closure dates (e.g., annual company shutdown Dec 26, planned maintenance). These are managed via the `holiday_closures` tfvars variable. When a new item is written, the daily Lambda is also triggered via DynamoDB Streams to recompute today's status immediately. Contact flows also check this table directly for today's date as a fallback.

3. **Emergency closures (SSM parameter, instant):** This PRD provisions an SSM parameter (`/{org_name}/{workspace}/emergency-closure`) that can be toggled immediately via CLI by the operations manager. Contact flows check this parameter first — before any holiday logic — and route to a closure message when active. No PR, no Terraform apply, no Lambda required. See runbook RB-12-01 for the emergency closure procedure.

**Contact flow check order (implemented in PRD-14):**
1. SSM parameter — emergency closure active? → route to closure message
2. Daily-status DynamoDB item — pre-computed holiday today? → route to after-hours
3. Company closures DynamoDB `GetItem` for today's date — same-day addition? → route to after-hours
4. None of the above → proceed with normal CheckHoursOfOperation routing

### What Problem It Solves

- Provisions all Hours of Operation configurations used by the Connect instance as Terraform-managed resources
- Establishes the weekly schedule template for each business unit or queue group
- Provisions the three-tier closure system: daily-status DynamoDB item (pre-computed by Lambda), company-specific closures DynamoDB table (Terraform-managed), and emergency closure SSM parameter (instant toggle)
- Provisions the daily holiday check Lambda and EventBridge schedule that pre-computes today's closure status at midnight — keeping Lambda out of the call path
- Exports Hours of Operation IDs for consumption by PRD-13 (Queue Architecture)
- Ensures that time zone configuration is explicit and version-controlled — not silently defaulting to UTC

### How It Fits the Overall Architecture

PRD-12 sits between PRD-10 (instance) and PRD-13 (queues). Every queue in PRD-13 references an Hours of Operation ID exported by this PRD. Contact flows in PRD-14 use the `CheckHoursOfOperation` contact flow block, which references these same configurations to make routing decisions at call time.

---

## 3. GOALS

### Goals

- Provision a configurable set of Hours of Operation schedules as Terraform resources
- Support multiple distinct schedules for different business units or queue groups (e.g., standard business hours, extended hours, 24/7)
- Support explicit time zone configuration per schedule
- Provision a three-tier closure system: automatic US federal holidays (computed daily by Lambda), planned company closures (DynamoDB via tfvars), and emergency closures (SSM parameter instant toggle)
- Provision the daily holiday check Lambda and EventBridge schedule to pre-compute closure status — no Lambda in the inbound call path
- Export all Hours of Operation IDs for PRD-13 consumption
- Make the schedule inventory a `terraform.tfvars` concern — no code changes required to add or modify schedules

### Non-Goals

- This PRD does not configure queues — that is PRD-13
- This PRD does not implement the after-hours contact flow logic — that is PRD-14
- This PRD does not implement voicemail for after-hours calls — that is PRD-60
- This PRD does not implement real-time schedule overrides — that requires a Lambda-based override mechanism planned for PRD-54

---

## 4. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Provisions the initial set of schedules from the hours_of_operation variable. Maintains schedules as code.

**Operations Manager** — Requests schedule changes or holiday additions via pull request to the tfvars file. Reviewed and applied through the standard CI/CD pipeline.

**Connect Administrator** — References the schedule names in the Connect console when verifying queue configurations.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-12-01 | Platform Engineer | As the platform engineer, I want all hours of operation provisioned as Terraform resources so that schedule changes are version-controlled and auditable | All schedules in Terraform state |
| US-12-02 | Operations Manager | As the operations manager, I want US federal holidays handled automatically and company-specific closures added by editing tfvars so that holiday routing requires no annual maintenance for standard holidays | US federal holidays routed automatically; adding a company closure entry to tfvars and applying creates the override |
| US-12-03 | Operations Manager | As the operations manager, I want multiple schedule templates available so that different teams can have different business hours | Multiple named schedules exported with distinct IDs |
| US-12-04 | Connect Administrator | As the Connect administrator, I want schedules named descriptively so that queue assignments in the console are unambiguous | Schedule names follow the convention `{OrgName}-{ScheduleName}` |

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Hours of Operation Provisioning
The system must provision one or more `aws_connect_hours_of_operation` resources, one per entry in the `hours_of_operation` input variable. Each resource must be associated with the Connect instance from PRD-10.

### FR-002 — Schedule Variable Structure
The hours of operation inventory must be defined as a `map(object)` variable where each entry specifies: `name`, `description`, `time_zone` (IANA timezone string), and `config` (a list of day-of-week schedule entries). Each config entry specifies the day, start hour, start minute, end hour, and end minute.

### FR-003 — Supported Days
The schedule must support all seven days of the week. Days not included in a schedule's config list are treated as closed by Connect. The days must be specified using the AWS Connect day name values: `MONDAY`, `TUESDAY`, `WEDNESDAY`, `THURSDAY`, `FRIDAY`, `SATURDAY`, `SUNDAY`.

### FR-004 — Time Zone Configuration
Each schedule must have an explicit `time_zone` attribute. The time zone must be a valid IANA timezone string (e.g., `America/New_York`, `America/Chicago`, `America/Los_Angeles`, `Europe/London`). No schedule may default to UTC without explicit documentation in the `description` field.

### FR-005 — Standard Schedule Templates
The platform tfvars files must include the following three schedule templates. These cover the most common business patterns. The `hours_of_operation` variable default is an empty map — schedules are supplied via tfvars, not variable defaults:

| Template Key | Description | Days | Hours |
|---|---|---|---|
| `standard-business` | Monday–Friday business hours | Mon–Fri | 08:00–18:00 local |
| `extended` | Extended hours including Saturday | Mon–Sat | 07:00–21:00 local |
| `twenty-four-seven` | 24/7 — always open | All 7 days | 00:00–23:59 local |

### FR-006 — Hours of Operation ID Export
All provisioned Hours of Operation IDs must be exported as a `map(string)` output keyed by the same identifier used in the input variable. PRD-13 iterates this map when assigning schedules to queues.

### FR-007 — Company-Specific Closure Table
The system must provision a DynamoDB table to store company-specific closure dates that are not US federal holidays. The table must use the `date` attribute (ISO 8601 format, e.g. `2026-12-26`) as the partition key. Each item must include `date`, `name` (e.g., "Company Holiday"), and `schedule_keys` (a string set of schedule keys from the `hours_of_operation` variable that this closure applies to — or `["ALL"]` to apply to all schedules). The table must be populated from the `holiday_closures` Terraform variable using `aws_dynamodb_table_item` resources. The table must be encrypted with the environment KMS key and must have point-in-time recovery enabled. DynamoDB Streams must be enabled on this table (NEW_IMAGE) to trigger the daily holiday check Lambda on writes (see FR-010).

### FR-008 — Holiday Closure Variable
The holiday closure inventory must be defined as a `list(object)` variable where each entry specifies `date` (ISO 8601), `name`, and `schedule_keys` (list of schedule keys or `["ALL"]`). The variable default is an empty list — company-specific closure dates are supplied via tfvars only when needed. US federal holidays are **not** included in this variable; they are computed dynamically by the daily Lambda.

Example company-specific closures that belong in this variable:
- Company-wide shutdown days (e.g., Dec 26, Dec 31)
- Office move or maintenance days
- Industry-specific holidays not covered by US federal holidays

For same-day emergency closures (weather, infrastructure), use the emergency closure SSM parameter (FR-011) instead of this variable. See runbook RB-12-01.

### FR-009 — Daily Holiday Check Lambda
The system must provision a Lambda function that runs daily at midnight (local time zone from the `standard-business` schedule) via an EventBridge scheduled rule. The Lambda must:

1. Compute whether today is a US federal holiday using algorithmic rules:
   - Fixed-date holidays: New Year's Day (Jan 1), Independence Day (Jul 4), Veterans Day (Nov 11), Christmas Day (Dec 25). When a fixed-date holiday falls on Saturday, the observed date is the preceding Friday. When it falls on Sunday, the observed date is the following Monday.
   - Nth-weekday holidays: MLK Day (3rd Monday in January), Presidents' Day (3rd Monday in February), Memorial Day (last Monday in May), Labor Day (1st Monday in September), Columbus Day (2nd Monday in October), Thanksgiving (4th Thursday in November), Day After Thanksgiving (4th Friday in November).
2. Query the company-specific closures DynamoDB table for today's date.
3. Write the result to the daily-status DynamoDB item with attributes: `date` (today, ISO 8601), `is_closure` (boolean), `closure_name` (string or null), `closure_source` (`federal`, `company`, or `none`).

The Lambda must be idempotent — multiple executions on the same day produce the same result. The Lambda must use the environment KMS key for any encrypted operations and must have CloudWatch log group with the platform log retention policy.

### FR-010 — DynamoDB Streams Trigger
The company-specific closures table (FR-007) must have DynamoDB Streams enabled with `NEW_IMAGE` stream view type. The daily holiday check Lambda (FR-009) must be configured as a stream consumer so that when a new closure item is written (via Terraform apply or direct CLI write), the Lambda re-executes immediately to recompute today's status. This ensures same-day company closure additions take effect without waiting for midnight.

### FR-011 — Emergency Closure SSM Parameter
The system must provision an SSM parameter at path `/{org_name}/{workspace}/emergency-closure` with a JSON string value. The default value must be:

```json
{"active": false, "message": "", "updated_by": "", "updated_at": ""}
```

When the operations manager activates an emergency closure, the parameter is updated to:

```json
{"active": true, "message": "Office closed due to weather", "updated_by": "ops-manager", "updated_at": "2026-03-22T06:00:00Z"}
```

Contact flows in PRD-14 check this parameter **first**, before any holiday logic. When `active` is `true`, all calls are routed to the closure message. The parameter is reset to `active: false` when the closure ends. See runbook RB-12-01 for the emergency closure procedure.

The SSM parameter must be encrypted with the environment KMS key (SecureString type).

### FR-012 — Daily-Status DynamoDB Item
The system must provision a DynamoDB table (`{org_name}-daily-closure-status-{workspace}`) with a single item that is updated daily by the Lambda (FR-009). The table uses `id` as the partition key with a fixed value of `today`. The item attributes are: `id` (S: "today"), `date` (S: ISO 8601), `is_closure` (BOOL), `closure_name` (S), `closure_source` (S: "federal", "company", or "none"). The table must be encrypted with the environment KMS key and use PAY_PER_REQUEST billing.

Contact flows in PRD-14 read this single item via a native DynamoDB contact flow block — no Lambda invocation in the call path.

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### Availability
Hours of Operation is a Connect configuration resource. Its availability is governed by the Connect instance SLA from PRD-10.

### Scale
Schedule count scales by adding entries to the `hours_of_operation` variable. Connect supports up to 100 hours of operation configurations per instance — sufficient for any foreseeable business unit structure.

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| SOC 2 CC6.1 | Schedule changes version-controlled and approved via pipeline | Git history, GitHub PR approval records |

---

## 7. ARCHITECTURE

### Component Diagram

```
┌────────────────────────────────────────────────────────────────┐
│               HOURS OF OPERATION                               │
│                                                                │
│  hours_of_operation variable (tfvars)                         │
│  ┌────────────────────────────────────────────────────────┐   │
│  │  standard-business: Mon-Fri 08:00-18:00 America/NY     │   │
│  │  extended:          Mon-Sat 07:00-21:00 America/NY     │   │
│  │  twenty-four-seven: All days 00:00-23:59               │   │
│  └────────────────────────────┬───────────────────────────┘   │
│                               │ for_each                       │
│                               ▼                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │     aws_connect_hours_of_operation (for_each)           │  │
│  │     Connected to: Connect Instance (PRD-10)             │  │
│  └──────────────────────────────┬───────────────────────────┘  │
│                                 │                              │
│              output: hours_of_operation_ids (map)             │
│                                 │                              │
│                                 ▼                              │
│       PRD-13 (Queue Architecture) — assigns schedule to queue  │
│       PRD-14 (Contact Flows) — CheckHoursOfOperation block     │
└────────────────────────────────────────────────────────────────┘
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| Connect instance (PRD-10) | Inbound | Instance ID for resource association |
| Account baseline (PRD-02) | Inbound | Environment KMS key for DynamoDB and SSM encryption |
| PRD-13 (Queue Architecture) | Outbound | Hours of Operation IDs assigned to queues |
| PRD-14 (Contact Flow Framework) | Outbound | Contact flow checks: (1) emergency closure SSM parameter, (2) daily-status DynamoDB item, (3) company closures DynamoDB table, (4) CheckHoursOfOperation block |

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `hours_of_operation_ids` | map(string) | Map of schedule key to Hours of Operation ID | PRD-13, PRD-14 |
| `hours_of_operation_arns` | map(string) | Map of schedule key to ARN | future migration readiness checks as needed |
| `holiday_closures_table_name` | string | DynamoDB company-specific closure table name | PRD-14 (contact flow fallback check for same-day additions) |
| `holiday_closures_table_arn` | string | DynamoDB company-specific closure table ARN | PRD-14 (contact flow IAM) |
| `daily_closure_status_table_name` | string | DynamoDB daily-status table name | PRD-14 (contact flow reads pre-computed closure status) |
| `daily_closure_status_table_arn` | string | DynamoDB daily-status table ARN | PRD-14 (contact flow IAM) |
| `emergency_closure_parameter_name` | string | SSM parameter path for emergency closures | PRD-14 (contact flow checks first) |
| `emergency_closure_parameter_arn` | string | SSM parameter ARN | PRD-14 (contact flow IAM) |

---

## 8. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-hours-of-operation/      # PRD-12
        ├── backend.tf
        ├── main.tf                 # Provider, remote state, hours of operation resources
        ├── variables.tf
        ├── outputs.tf
        ├── holidays.tf             # DynamoDB tables (company closures + daily status)
        ├── lambda.tf               # Daily holiday check Lambda, EventBridge schedule, DynamoDB Streams trigger
        ├── ssm.tf                  # Emergency closure SSM parameter
        └── lambda/
            └── holiday_check.py    # Daily holiday check Lambda source
```

### Key Resources Declared

```hcl
# main.tf

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Layer   = "L1"
      PRD     = "PRD-12"
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

data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  connect_instance_id = data.terraform_remote_state.connect_instance.outputs.connect_instance_id
  env_kms_key_arn     = data.terraform_remote_state.account_baseline.outputs.kms_key_arn

  common_tags = {
    Environment = terraform.workspace
    ManagedBy   = "terraform"
    OrgName     = var.org_name
    Layer       = "L1"
    PRD         = "PRD-12"
  }
}

resource "aws_connect_hours_of_operation" "schedules" {
  for_each = var.hours_of_operation

  instance_id = local.connect_instance_id
  name        = "${var.org_name}-${each.value.name}"
  description = each.value.description
  time_zone   = each.value.time_zone

  dynamic "config" {
    for_each = each.value.config
    content {
      day = config.value.day
      start_time {
        hours   = config.value.start_hour
        minutes = config.value.start_minute
      }
      end_time {
        hours   = config.value.end_hour
        minutes = config.value.end_minute
      }
    }
  }

  tags = merge(local.common_tags, {
    Schedule = each.key
  })
}
```

```hcl
# holidays.tf

resource "aws_dynamodb_table" "holiday_closures" {
  name             = "${var.org_name}-holiday-closures-${terraform.workspace}"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "date"
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"

  attribute {
    name = "date"
    type = "S"
  }

  server_side_encryption {
    enabled    = true
    kms_key_id = local.env_kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.common_tags

  # Protect user-configured holiday data from accidental destruction.
  # See Module Governance § Destroy / Retention Posture.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_dynamodb_table_item" "holidays" {
  for_each = { for h in var.holiday_closures : h.date => h }

  table_name = aws_dynamodb_table.holiday_closures.name
  hash_key   = "date"

  item = jsonencode({
    date          = { S = each.value.date }
    name          = { S = each.value.name }
    schedule_keys = { SS = each.value.schedule_keys }
  })
}

resource "aws_dynamodb_table" "daily_closure_status" {
  name         = "${var.org_name}-daily-closure-status-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled    = true
    kms_key_id = local.env_kms_key_arn
  }

  tags = local.common_tags
}
```

```hcl
# ssm.tf

resource "aws_ssm_parameter" "emergency_closure" {
  name  = "/${var.org_name}/${terraform.workspace}/emergency-closure"
  type  = "SecureString"
  key_id = local.env_kms_key_arn
  value = jsonencode({
    active     = false
    message    = ""
    updated_by = ""
    updated_at = ""
  })

  tags = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}
```

Note: The `ignore_changes = [value]` lifecycle rule on the SSM parameter ensures that Terraform does not reset the parameter to the default value on subsequent applies. The operations manager updates this parameter directly via CLI during emergency closures — Terraform only provisions the initial parameter.

```hcl
# lambda.tf

data "archive_file" "holiday_check" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda/holiday_check.zip"
}

resource "aws_lambda_function" "holiday_check" {
  function_name    = "${var.org_name}-holiday-check-${terraform.workspace}"
  runtime          = "python3.12"
  handler          = "holiday_check.handler"
  role             = aws_iam_role.holiday_check.arn
  filename         = data.archive_file.holiday_check.output_path
  source_code_hash = data.archive_file.holiday_check.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      CLOSURES_TABLE_NAME     = aws_dynamodb_table.holiday_closures.name
      DAILY_STATUS_TABLE_NAME = aws_dynamodb_table.daily_closure_status.name
      TIME_ZONE               = "America/New_York"
    }
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "holiday_check" {
  name              = "/aws/lambda/${aws_lambda_function.holiday_check.function_name}"
  retention_in_days = 365
  kms_key_id        = local.env_kms_key_arn

  tags = local.common_tags
}

resource "aws_iam_role" "holiday_check" {
  name = "${var.org_name}-holiday-check-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "holiday_check" {
  name = "holiday-check-policy"
  role = aws_iam_role.holiday_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.holiday_closures.arn,
          aws_dynamodb_table.daily_closure_status.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:DescribeStream", "dynamodb:ListStreams"]
        Resource = "${aws_dynamodb_table.holiday_closures.arn}/stream/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.holiday_check.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.env_kms_key_arn
      }
    ]
  })
}

# Daily midnight schedule
resource "aws_cloudwatch_event_rule" "daily_holiday_check" {
  name                = "${var.org_name}-daily-holiday-check-${terraform.workspace}"
  description         = "Triggers holiday check Lambda daily at midnight ET to pre-compute closure status"
  schedule_expression = "cron(0 5 * * ? *)"  # 05:00 UTC = midnight ET (adjust for DST manually or use America/New_York in Lambda)

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "daily_holiday_check" {
  rule = aws_cloudwatch_event_rule.daily_holiday_check.name
  arn  = aws_lambda_function.holiday_check.arn
}

resource "aws_lambda_permission" "daily_holiday_check" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.holiday_check.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_holiday_check.arn
}

# DynamoDB Streams trigger — re-compute on company closure table writes
resource "aws_lambda_event_source_mapping" "holiday_closures_stream" {
  event_source_arn  = aws_dynamodb_table.holiday_closures.stream_arn
  function_name     = aws_lambda_function.holiday_check.arn
  starting_position = "LATEST"
  batch_size        = 1
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

variable "hours_of_operation" {
  description = <<-EOT
    Hours of operation schedule inventory. Each key is a human-readable identifier
    (e.g. standard-business, extended, twenty-four-seven).

    IMPORTANT: default is empty map. The schedule inventory MUST be supplied via
    the platform tfvars (environments/dev.tfvars). Running apply without schedules
    provisions zero hours of operation resources. Standard schedule templates are
    provided in the tfvars files, not in the variable default.

    Three standard templates are recommended:
      standard-business: Mon-Fri 08:00-18:00 local time
      extended:          Mon-Sat 07:00-21:00 local time
      twenty-four-seven: All days 00:00-23:59
  EOT

  type = map(object({
    name        = string
    description = string
    time_zone   = string
    config = list(object({
      day          = string
      start_hour   = number
      start_minute = number
      end_hour     = number
      end_minute   = number
    }))
  }))

  default = {}

  validation {
    condition = alltrue([
      for k, v in var.hours_of_operation :
      alltrue([
        for c in v.config :
        contains([
          "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY",
          "FRIDAY", "SATURDAY", "SUNDAY"
        ], c.day)
      ])
    ])
    error_message = "Each config entry day must be a valid AWS Connect day name."
  }

  validation {
    condition = alltrue([
      for k, v in var.hours_of_operation :
      can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", k)) || length(k) == 1
    ])
    error_message = "Each hours_of_operation map key must be lowercase alphanumeric with hyphens only."
  }
}

variable "holiday_closures" {
  description = <<-EOT
    Company-specific closure dates. US federal holidays are computed dynamically
    by the PRD-14 Lambda and do NOT belong in this variable.

    Use this for company-specific closures only:
      - Company shutdown days (e.g., Dec 26, Dec 31)
      - Office move or maintenance days
      - Weather closures (added ad-hoc)
      - Industry-specific holidays not covered by US federal holidays

    Default is empty list. Most deployments will have zero or very few entries.
    Dates are absolute (ISO 8601) — each entry applies to a specific calendar date.
  EOT

  type = list(object({
    date          = string       # ISO 8601 date, e.g. "2026-12-25"
    name          = string       # Holiday name, e.g. "Christmas Day"
    schedule_keys = list(string) # Schedule keys this applies to, or ["ALL"]
  }))

  default = []

  validation {
    condition = alltrue([
      for h in var.holiday_closures :
      can(regex("^\\d{4}-\\d{2}-\\d{2}$", h.date))
    ])
    error_message = "Each holiday_closures date must be ISO 8601 format (YYYY-MM-DD)."
  }
}

# -----------------------------------------------------------------------
# deployment_profile — Platform-wide deployment profile contract.
#
# This variable is declared but NOT referenced by PRD-12. It exists for
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
  description = "Platform-wide deployment profile. Not consumed by PRD-12 — declared for contract consistency. See PRD-00 for authoritative schema."
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

output "hours_of_operation_ids" {
  description = "Map of schedule key to Hours of Operation ID. Consumed by PRD-13 and PRD-14."
  value = {
    for k, v in aws_connect_hours_of_operation.schedules :
    k => v.hours_of_operation_id
  }
}

output "hours_of_operation_arns" {
  description = "Map of schedule key to Hours of Operation ARN."
  value = {
    for k, v in aws_connect_hours_of_operation.schedules :
    k => v.arn
  }
}

output "holiday_closures_table_name" {
  description = "DynamoDB company-specific closure table name. Contact flow fallback check for same-day additions."
  value       = aws_dynamodb_table.holiday_closures.name
}

output "holiday_closures_table_arn" {
  description = "DynamoDB company-specific closure table ARN. Used in PRD-14 contact flow IAM."
  value       = aws_dynamodb_table.holiday_closures.arn
}

output "daily_closure_status_table_name" {
  description = "DynamoDB daily-status table name. Contact flow reads pre-computed closure status."
  value       = aws_dynamodb_table.daily_closure_status.name
}

output "daily_closure_status_table_arn" {
  description = "DynamoDB daily-status table ARN. Used in PRD-14 contact flow IAM."
  value       = aws_dynamodb_table.daily_closure_status.arn
}

output "emergency_closure_parameter_name" {
  description = "SSM parameter path for emergency closures. Contact flow checks this first."
  value       = aws_ssm_parameter.emergency_closure.name
}

output "emergency_closure_parameter_arn" {
  description = "SSM parameter ARN for emergency closures. Used in PRD-14 contact flow IAM."
  value       = aws_ssm_parameter.emergency_closure.arn
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

Note: The backend block is intentionally empty. The shared backend config (`backend-nevs-cloud-dev.hcl`) provides bucket, region, encryption, and lock table. The state key is supplied per-module at init time: `-backend-config="key=l1-hours-of-operation/terraform.tfstate"`. See the plan-apply runbook for the full init command pattern.

---

## 9. EVENT SCHEMA

PRD-12 produces no EventBridge events and consumes no EventBridge events.

---

## 10. API / INTERFACE CONTRACT

```hcl
# Standard downstream consumption pattern for PRD-13 and PRD-14
data "terraform_remote_state" "hours_of_operation" {
  backend   = "s3"
  workspace = terraform.workspace
  config = {
    bucket = var.state_bucket
    key    = "l1-hours-of-operation/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  hours_of_operation_ids    = data.terraform_remote_state.hours_of_operation.outputs.hours_of_operation_ids
  holiday_closures_table_name = data.terraform_remote_state.hours_of_operation.outputs.holiday_closures_table_name
}
```

---

## 11. DATA MODEL

### State File Location

```
s3://{org}-tfstate-{account_id}/
└── {workspace}/
    └── l1-hours-of-operation/
        └── terraform.tfstate
```

---

## 12. CI/CD SPECIFICATION

### Workflow Reference

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l1-hours-of-operation

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l1-hours-of-operation
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l1-hours-of-operation
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules/l1-hours-of-operation-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Init Command (local)

```bash
export AWS_PROFILE=nevs-cloud-dev
cd connect-pbx/modules/l1-hours-of-operation

terraform init -backend-config="${BOOTSTRAP_DIR}/backend-${PROFILE}.hcl" \
               -backend-config="key=l1-hours-of-operation/terraform.tfstate"
# Note: the repo's runner scripts inject backend config from the module catalog.
# BOOTSTRAP_DIR and PROFILE are set by the CI/CD runner environment.
terraform workspace select dev

terraform plan  -var-file="../../environments/dev.tfvars"
terraform apply -var-file="../../environments/dev.tfvars"
```

### Rollback Procedure

Hours of operation changes take effect immediately on the Connect instance. Rollback is a re-apply of the previous configuration. No data is lost on schedule changes.

---

## 13. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-12-01: Hours of Operation Mismatch**
- Source: Custom Lambda that compares Terraform state with live Connect configuration
- Schedule: Runs nightly as part of drift detection (PRD-01 tf-drift-detect.yml)
- Action: Drift detection alarm via PRD-01 mechanism
- Severity: Medium

**ALARM-12-02: Daily Holiday Check Lambda Failure**
- Source: CloudWatch Errors metric on `{org_name}-holiday-check-{workspace}` Lambda function
- Threshold: >= 1 error in 24-hour period (the Lambda runs once daily — any failure means today's closure status was not computed)
- Action: SNS notification to operations team. Manual fallback: contact flows still check the company closures table directly (step 3 in the contact flow check order), so federal holidays will be missed but company-specific closures still work.
- Severity: High

**ALARM-12-03: Emergency Closure Left Active**
- Source: Custom CloudWatch metric or scheduled Lambda that checks the SSM parameter value daily
- Threshold: Emergency closure `active=true` for more than 24 hours without being reset
- Action: SNS notification to operations manager — "Emergency closure still active, is this intentional?"
- Severity: Medium

### SOC 2 Evidence

| Artifact | Demonstrates |
|---|---|
| Terraform state (schedule history) | SOC 2 CC6.1 — configuration change management |
| Lambda CloudWatch logs (daily holiday check) | SOC 2 CC7.2 — automated monitoring of system configuration |
| SSM parameter change history (CloudTrail) | SOC 2 CC6.1 — emergency closure audit trail |

---

## 14. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-12-01 | All schedules in variable are provisioned | `aws connect list-hours-of-operations` returns all expected schedules |
| AC-12-02 | Schedule names follow naming convention | Names equal `{org_name}-{schedule.name}` |
| AC-12-03 | Time zones are correct for each schedule | `aws connect describe-hours-of-operation` returns correct time zone |
| AC-12-04 | hours_of_operation_ids output contains all schedules | `terraform output hours_of_operation_ids` returns map with one entry per schedule |
| AC-12-05 | Adding a schedule via tfvars provisions it | Add test entry, apply, confirm new schedule in Connect |
| AC-12-06 | Holiday closures DynamoDB table exists and is KMS encrypted | `aws dynamodb describe-table` returns table with SSE enabled using env KMS key |
| AC-12-07 | Company-specific closure items populated from variable | `aws dynamodb scan` returns one item per entry in `holiday_closures` variable (empty table is valid if no company-specific closures are configured) |
| AC-12-08 | Holiday table has point-in-time recovery enabled | `aws dynamodb describe-continuous-backups` returns PITR ENABLED |
| AC-12-09 | Adding a company-specific closure via tfvars populates the table | Add test entry, apply, confirm item appears in DynamoDB |
| AC-12-10 | Daily holiday check Lambda exists and runs on schedule | `aws lambda get-function` returns function; `aws events describe-rule` returns enabled schedule rule with `cron(0 5 * * ? *)` |
| AC-12-11 | Lambda correctly computes US federal holidays | Invoke Lambda on a known federal holiday date; verify daily-status item has `is_closure=true`, `closure_source=federal` |
| AC-12-12 | DynamoDB Streams triggers Lambda on company closure write | Add a test closure item to the company closures table; verify Lambda executes and updates daily-status within seconds |
| AC-12-13 | Emergency closure SSM parameter exists and is SecureString | `aws ssm get-parameter --with-decryption` returns JSON with `active=false` default |
| AC-12-14 | Emergency closure toggle works end-to-end | Set `active=true` via CLI (see RB-12-01); verify parameter updated; reset to `active=false` |
| AC-12-15 | Daily-status DynamoDB table exists and is KMS encrypted | `aws dynamodb describe-table` returns table with SSE enabled using env KMS key |
| AC-12-16 | Lambda IAM role has least-privilege permissions | IAM policy allows only DynamoDB read/write on the two tables, Streams on closures table, CloudWatch Logs, and KMS decrypt/generate |
| AC-12-17 | Lambda CloudWatch log group exists with correct retention | `aws logs describe-log-groups` returns log group with 365-day retention and KMS encryption |
| AC-12-18 | Terraform apply does not reset emergency closure parameter value | Set `active=true`, run `terraform apply`, verify parameter still has `active=true` (lifecycle ignore_changes) |
| AC-12-19 | tfsec passes with zero HIGH or CRITICAL findings | `tfsec modules/l1-hours-of-operation/` returns clean |
| AC-12-20 | checkov passes with zero HIGH or CRITICAL findings | `checkov -d modules/l1-hours-of-operation/` returns clean |

---

## 15. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Wrong time zone configured — callers reach agents outside intended hours | Medium | High | Time zone is an explicit required field with IANA string validation. Test by placing calls near schedule boundaries after apply. |
| Schedule deleted while assigned to a queue | Low | High | Connect API prevents deletion of a schedule that is in use by a queue. Terraform will error cleanly. |
| Holiday override not working as expected | Medium | Medium | After-hours routing logic tested via PRD-14 acceptance criteria using test calls placed at simulated off-hours times. Federal holidays are computed algorithmically (no stale data risk); company-specific closures are tested by adding a test entry and verifying routing. |
| Daily holiday check Lambda fails silently | Low | High | CloudWatch alarm (ALARM-12-02) triggers on any Lambda error. Contact flows have a fallback path: company closures table is checked directly (step 3 in check order). Federal holidays would be missed until Lambda recovers, but the system degrades gracefully. |
| Emergency closure SSM parameter left active indefinitely | Medium | High | ALARM-12-03 fires after 24 hours of continuous active state. Runbook RB-12-01 includes a checklist for deactivation. CloudTrail logs all SSM parameter changes for audit. |
| DynamoDB Streams lag delays same-day closure pickup | Low | Low | Streams typically deliver within seconds. If delayed, the midnight scheduled run catches up. Worst case: a same-day company closure added via Terraform is delayed by minutes, not hours. |
| Lambda timezone drift during DST transitions | Low | Medium | EventBridge cron runs at fixed UTC (05:00). Lambda uses `America/New_York` internally to compute the correct local date. The Lambda is idempotent — running at 05:00 UTC covers both EST (midnight) and EDT (1am, still correct date). |

---

## 16. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-12-01 | What are the actual business hours and time zones for this organization? The defaults use America/New_York. Are there multiple time zones (e.g., west coast teams)? | Open | Operations manager to confirm actual hours and time zones before prod apply. Update prod.tfvars accordingly. |
| OQ-12-02 | Are there company-specific closure days beyond US federal holidays? | Open | US federal holidays are now computed dynamically by the PRD-14 Lambda — no annual maintenance required. Only company-specific closures (shutdown days, office moves, etc.) need to be added to the `holiday_closures` tfvars variable. Operations manager to confirm if any company-specific closures exist. |

---

## 17. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Three standard schedule templates provided as defaults. |
| 1.1.0 | 2026-03-22 | — | Architectural alignment pass. Added PRD-02 dependency for DynamoDB KMS encryption. Added provider block with default_tags matching L1 module pattern. Added remote state data sources for PRD-10 and PRD-02. Added local.common_tags pattern. Fixed backend block to empty `backend "s3" {}` with key supplied at init. Fixed provider/Terraform versions to >= 1.14.0 and ~> 6.0. Fixed downstream consumption pattern (workspace attribute, removed workspace from key path). Changed hours_of_operation default to empty map — templates supplied via tfvars. Changed holiday_closures default to empty list — dates supplied via tfvars. Removed dead layer_id/prd_id variables. Added deployment_profile contract comment. Added map key validation. Added holiday date format validation. Added init command with key override to CI/CD section. Added backend.tf to module file list. Redesigned holiday system to three-tier architecture: (1) daily Lambda computes US federal holidays algorithmically at midnight — zero annual maintenance; (2) company-specific closures in DynamoDB table managed via tfvars with DynamoDB Streams trigger for immediate recomputation; (3) emergency closure SSM parameter for instant CLI toggle by operations manager. Added FR-009 through FR-012. Added daily-status DynamoDB table, Lambda, EventBridge schedule, DynamoDB Streams trigger, SSM parameter with ignore_changes lifecycle. Added ALARM-12-02 (Lambda failure) and ALARM-12-03 (stale emergency closure). Added AC-12-10 through AC-12-20 for new components. Added risks for Lambda failure, stale SSM parameter, Streams lag, DST transitions. Added runbook RB-12-01 (emergency closure procedure). |
| 1.2.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section. Normalized bootstrap path. Added lifecycle protection guidance for holiday closures DynamoDB table. |
