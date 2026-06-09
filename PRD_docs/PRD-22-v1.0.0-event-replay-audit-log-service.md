# PRD-22 - Event Replay & Audit Log Service

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-22 |
| **Version** | 1.2.1 |
| **Status** | Draft |
| **Author** | - |
| **Last Updated** | 2026-04-06 |
| **Layer** | 2 - Event Bus |
| **Depends On** | PRD-02 (KMS keys), PRD-20 (event bus, archive ARN) |
| **Blocks** | None - this is an optional operational utility |
| **Optional** | Yes - optional feature for mature event-driven operations |

---

## 2. GOVERNANCE & MODULARITY

### Control Plane Statement

This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

### Module Classification

| Field | Value |
|---|---|
| `classification` | `optional-feature` |
| `minimum_deployment_profile` | `standard` |
| `can_be_omitted_from_bare_bones` | `yes` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |
| `readiness_posture` | `Yellow` |

### Intended Catalog Entry

| Field | Value |
|---|---|
| `path` | `modules/l2-event-replay` |
| `capability_packs` | `["eventing"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l2-event-bus"]` |
| `state_key` | `l2-event-replay/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `event-replay.tfvars` |
| `supports_destroy` | `true` |

### Optional Shared Sinks

| Sink | Behavior |
|---|---|
| `audit_bucket_name` | Optional input. When supplied, the audit listener persists NDJSON records to the approved S3 sink. When omitted, replay remains available and the audit listener is not activated. |
| `alarm_action_arns` | Optional input. When supplied, the module attaches the ARNs to CloudWatch alarm actions. When omitted, the module still publishes metrics and logs locally without routing notifications. |
| `eventbridge_dlq_arn` | Optional input. When supplied, the EventBridge target uses a dead-letter queue. When omitted, the module does not backfill PRD-21 as a hard prerequisite. |

The sample Terraform below uses `count` and conditional blocks so that omitted sinks are skipped cleanly instead of being stubbed with placeholder ARNs.

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `conditional` |
| `retention_notes` | The module itself does not own the shared audit bucket or alarm sinks. Replay records and audit objects, if enabled, are retained by the approved sink's lifecycle policy rather than by this module. |

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Operational incidents can create gaps between what EventBridge published and what downstream consumers successfully processed. Replay closes that gap by re-publishing archive events back onto the custom bus so consumers can re-run their normal handlers.

Audit logging is an optional operational adjunct, not a lower-layer prerequisite. When an approved audit sink is enabled, the service can persist a searchable event trail in S3. When no approved sink is supplied, the module still supports replay and does not force PRD-03 or any other shared audit foundation into the dependency graph.

### What Problem It Solves

- Provides a Lambda-based replay tool that triggers EventBridge archive replay for a specified window and optional event pattern
- Persists event records to an approved S3 sink when that sink is explicitly enabled
- Records replay provenance, including `requested_by`, in CloudWatch and in the optional replay record sink
- Avoids hidden lower-layer backflow by keeping shared audit and alarm sinks optional inputs

---

## 4. GOALS

### Goals

- Provision a replay Lambda that invokes EventBridge archive replay for a specified time window and optional event pattern
- Provision an audit listener that writes NDJSON event records only when an approved audit bucket is configured
- Keep replay provenance explicit by logging `requested_by`, the replay window, and the applied event pattern
- Make alarm routing opt-in rather than a hidden PRD-03 prerequisite

### Non-Goals

- This PRD does not modify event consumers; replay sends events to the same bus and consumers process them normally
- This PRD does not implement event transformation during replay
- This PRD does not implement Athena querying of the audit log
- This PRD does not require PRD-03 to be enabled just to deploy the module

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 - Replay Lambda

Provision a Lambda function `{org_name}-event-replay` invocable via AWS CLI or the AWS console. The function accepts a JSON payload specifying:

- `start_time` in ISO 8601
- `end_time` in ISO 8601
- optional `event_pattern`
- optional `requested_by`

The function calls the EventBridge `StartReplay` API against the archive provisioned in PRD-20 and returns the replay ID or ARN. If `event_pattern` is supplied, the function passes it to `StartReplay` rather than storing it as an unused field. The target bus is always the platform custom bus.

### FR-002 - Audit Log Lambda

Provision an audit log Lambda that is triggered by an EventBridge rule matching all `connect-pbx.*` events. When an approved `audit_bucket_name` is configured, the Lambda writes each event as a single NDJSON record to S3 under the prefix `event-audit/{YYYY}/{MM}/{DD}/{event_type}/`.

The implementation must be honest about sink behavior:

- if an approved audit bucket is configured, the audit path writes to that sink
- if no approved audit bucket is configured, the module remains replay-capable and does not pretend that PRD-03 exists as a hidden requirement

### FR-003 - Replay Provenance

The replay Lambda must log the replay request to CloudWatch with the replay window, the optional event pattern, and `requested_by`. If an approved audit bucket is configured, it must also write a replay record under `event-audit/replays/`.

### FR-004 - Replay Safety Check

The replay Lambda must refuse to replay events if the target time window ends within the last 5 minutes to prevent replaying in-flight events that may still be processing.

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### Availability

Replay is an operational tool, not part of the critical telephony path. Audit logging is best-effort and optional when a sink is not configured. Both tolerate cold starts.

### Scale

EventBridge invokes the audit listener once per event. The implementation must therefore write a single NDJSON record per invocation and avoid documenting fake batch semantics that the source does not actually provide.

### Security

- Audit and replay writes use the environment KMS key from PRD-02 when an approved sink is enabled
- Replay Lambda execution role is scoped to `events:StartReplay` and `events:DescribeReplay` on the archive ARN only
- Optional sinks are explicit inputs, not hidden cross-module assumptions

---

## 7. ARCHITECTURE

```
EventBridge Custom Bus (PRD-20)
          |
          +-- Rule: all connect-pbx.* events
          |         |
          |         +--> Audit Log Lambda (optional sink-enabled path)
          |                   |
          |                   +--> Approved S3 audit bucket
          |
          +-- EventBridge Archive (PRD-20)
                    |
                    +-- Replay Lambda (invoked manually)
                              |
                              +--> EventBridge StartReplay API
                                        |
                                        +--> Events re-published to custom bus
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `replay_function_arn` | string | Replay Lambda ARN for incident recovery | Operations runbooks |
| `audit_log_s3_prefix` | string | S3 prefix used when an approved audit sink is enabled | Explicitly-enabled audit tooling |

---

## 8. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l2-event-replay/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            ├── event-replay/
            │   └── index.py
            └── audit-log/
                └── index.py
```

### Current Repo Conventions

- use the partial S3 backend config pattern from PRD-00
- do not hardcode environment-specific backend keys in the PRD
- let the catalog own `state_key`
- keep provider examples aligned with the current repo standard
- do not model module activation through `deployment_profile.optional_layers`

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

### Shared Terraform Context

```hcl
data "terraform_remote_state" "account_baseline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "env:/${terraform.workspace}/l0-account-baseline/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  env_kms_key_arn         = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
  permission_boundary_arn = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
}

data "aws_caller_identity" "current" {}

data "archive_file" "audit_log" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/audit-log"
  output_path = "${path.module}/.terraform-build/audit-log.zip"
}

data "archive_file" "event_replay" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/event-replay"
  output_path = "${path.module}/.terraform-build/event-replay.zip"
}
```

### Key Resources Declared

```hcl
resource "aws_cloudwatch_event_rule" "audit_all" {
  name           = "${var.org_name}-event-audit-all-${terraform.workspace}"
  event_bus_name = var.event_bus_name
  description    = "Catches all connect-pbx events for optional audit logging"

  event_pattern = jsonencode({
    source = [{ prefix = "connect-pbx" }]
  })
}

resource "aws_cloudwatch_event_target" "audit_log" {
  count          = var.audit_bucket_name == null ? 0 : 1
  rule           = aws_cloudwatch_event_rule.audit_all.name
  event_bus_name = var.event_bus_name
  target_id      = "audit-log-lambda"
  arn            = aws_lambda_function.audit_log[0].arn

  dynamic "dead_letter_config" {
    for_each = var.eventbridge_dlq_arn == null ? [] : [var.eventbridge_dlq_arn]
    content {
      arn = dead_letter_config.value
    }
  }
}

resource "aws_lambda_function" "audit_log" {
  count         = var.audit_bucket_name == null ? 0 : 1
  function_name = "${var.org_name}-event-audit-log-${terraform.workspace}"
  role          = aws_iam_role.audit_log[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.audit_log.output_path
  source_code_hash = data.archive_file.audit_log.output_base64sha256

  environment {
    variables = {
      AUDIT_BUCKET_NAME = var.audit_bucket_name == null ? "" : var.audit_bucket_name
      KMS_KEY_ARN       = local.env_kms_key_arn
    }
  }
}

resource "aws_lambda_function" "event_replay" {
  function_name = "${var.org_name}-event-replay-${terraform.workspace}"
  role          = aws_iam_role.event_replay.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60

  filename         = data.archive_file.event_replay.output_path
  source_code_hash = data.archive_file.event_replay.output_base64sha256

  environment {
    variables = {
      ARCHIVE_ARN       = var.archive_arn
      EVENT_BUS_ARN     = var.event_bus_arn
      AUDIT_BUCKET_NAME = var.audit_bucket_name == null ? "" : var.audit_bucket_name
      ALARM_ACTION_ARNS = jsonencode(var.alarm_action_arns)
      KMS_KEY_ARN       = local.env_kms_key_arn
    }
  }
}

resource "aws_lambda_permission" "allow_eventbridge_audit_log" {
  count         = var.audit_bucket_name == null ? 0 : 1
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_log[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.audit_all.arn
}

resource "aws_cloudwatch_metric_alarm" "audit_log_errors" {
  count               = var.audit_bucket_name == null ? 0 : 1
  alarm_name          = "${var.org_name}-event-audit-log-errors-${terraform.workspace}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    FunctionName = aws_lambda_function.audit_log[0].function_name
  }

  alarm_actions = var.alarm_action_arns
  ok_actions    = var.alarm_action_arns
}

resource "aws_cloudwatch_metric_alarm" "event_replay_duration" {
  alarm_name          = "${var.org_name}-event-replay-duration-${terraform.workspace}"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 45000
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    FunctionName = aws_lambda_function.event_replay.function_name
  }

  alarm_actions = var.alarm_action_arns
  ok_actions    = var.alarm_action_arns
}
```

### IAM Roles And Policies

```hcl
resource "aws_iam_role" "audit_log" {
  count = var.audit_bucket_name == null ? 0 : 1
  name  = "${var.org_name}-event-audit-log-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = local.permission_boundary_arn
}

resource "aws_iam_role_policy" "audit_log" {
  count = var.audit_bucket_name == null ? 0 : 1
  name  = "event-audit-log-policy"
  role  = aws_iam_role.audit_log[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteAuditObjects"
        Effect = "Allow"
        Action = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.audit_bucket_name}/event-audit/*"
      },
      {
        Sid    = "EncryptAuditObjects"
        Effect = "Allow"
        Action = ["kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = local.env_kms_key_arn
      },
      {
        Sid    = "WriteLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-event-audit-log-${terraform.workspace}:*"
      }
    ]
  })
}

resource "aws_iam_role" "event_replay" {
  name = "${var.org_name}-event-replay-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = local.permission_boundary_arn
}

resource "aws_iam_role_policy" "event_replay" {
  name = "event-replay-policy"
  role = aws_iam_role.event_replay.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "StartAndDescribeReplay"
          Effect = "Allow"
          Action = ["events:StartReplay", "events:DescribeReplay"]
          Resource = var.archive_arn
        },
        {
          Sid    = "WriteLogs"
          Effect = "Allow"
          Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.org_name}-event-replay-${terraform.workspace}:*"
        }
      ],
      var.audit_bucket_name == null ? [] : [
        {
          Sid    = "WriteReplayProvenance"
          Effect = "Allow"
          Action = ["s3:PutObject"]
          Resource = "arn:aws:s3:::${var.audit_bucket_name}/event-audit/replays/*"
        },
        {
          Sid    = "EncryptReplayProvenance"
          Effect = "Allow"
          Action = ["kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
          Resource = local.env_kms_key_arn
        }
      ]
    )
  })
}
```

### Lambda Source - Audit Log

```python
import json
import os
from datetime import datetime, timezone

import boto3

s3 = boto3.client("s3")
AUDIT_BUCKET_NAME = os.getenv("AUDIT_BUCKET_NAME")
KMS_KEY_ARN = os.getenv("KMS_KEY_ARN")


def handler(event, context):
    if not AUDIT_BUCKET_NAME:
        return {"statusCode": 204, "audit_enabled": False}

    now = datetime.now(timezone.utc)
    date_prefix = now.strftime("%Y/%m/%d")
    event_type = event.get("detail-type", "Unknown").replace(".", "-")
    record = {
        "observed_at": now.isoformat(),
        "request_id": context.aws_request_id,
        "event_type": event_type,
        "event": event,
    }
    key = f"event-audit/{date_prefix}/{event_type}/{context.aws_request_id}.ndjson"

    s3.put_object(
        Bucket=AUDIT_BUCKET_NAME,
        Key=key,
        Body=(json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8"),
        ContentType="application/x-ndjson",
        ServerSideEncryption="aws:kms",
        SSEKMSKeyId=KMS_KEY_ARN,
    )
    return {"statusCode": 200, "key": key}
```

### Lambda Source - Event Replay

```python
import json
import os
from datetime import datetime, timedelta, timezone

import boto3

events_client = boto3.client("events")
s3 = boto3.client("s3")

ARCHIVE_ARN = os.environ["ARCHIVE_ARN"]
EVENT_BUS_ARN = os.environ["EVENT_BUS_ARN"]
AUDIT_BUCKET_NAME = os.getenv("AUDIT_BUCKET_NAME")


def _parse_iso8601(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def handler(event, context):
    start_time = event["start_time"]
    end_time = event["end_time"]
    event_pattern = event.get("event_pattern")
    requested_by = event.get("requested_by", "unspecified")

    end_dt = _parse_iso8601(end_time)
    if (datetime.now(timezone.utc) - end_dt) < timedelta(minutes=5):
        raise ValueError("Cannot replay events from the last 5 minutes.")

    replay_name = f"replay-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}"
    replay_request = {
        "ReplayName": replay_name,
        "EventSourceArn": ARCHIVE_ARN,
        "EventStartTime": _parse_iso8601(start_time),
        "EventEndTime": end_dt,
        "Destination": {"Arn": EVENT_BUS_ARN},
    }

    if event_pattern is not None:
        replay_request["EventPattern"] = (
            event_pattern if isinstance(event_pattern, str) else json.dumps(event_pattern)
        )

    response = events_client.start_replay(**replay_request)

    record = {
        "replay_name": replay_name,
        "replay_arn": response.get("ReplayArn"),
        "start_time": start_time,
        "end_time": end_time,
        "event_pattern": event_pattern,
        "requested_by": requested_by,
        "invoked_at": datetime.now(timezone.utc).isoformat(),
        "lambda_request_id": context.aws_request_id,
    }

    print(json.dumps(record, separators=(",", ":")))

    if AUDIT_BUCKET_NAME:
        date_prefix = datetime.now(timezone.utc).strftime("%Y/%m/%d")
        s3.put_object(
            Bucket=AUDIT_BUCKET_NAME,
            Key=f"event-audit/replays/{date_prefix}/{replay_name}.ndjson",
            Body=(json.dumps(record, separators=(",", ":")) + "\n").encode("utf-8"),
            ContentType="application/x-ndjson",
            ServerSideEncryption="aws:kms",
            SSEKMSKeyId=os.environ["KMS_KEY_ARN"],
        )

    return record
```

### Variables, Outputs, Backend

```hcl
variable "org_name" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "Terraform state bucket name from PRD-00."
}

variable "layer_id" {
  type    = string
  default = "L2"
}

variable "prd_id" {
  type    = string
  default = "PRD-22"
}

variable "event_bus_name" {
  type = string
}

variable "event_bus_arn" {
  type = string
}

variable "archive_arn" {
  type = string
}

variable "audit_bucket_name" {
  type    = string
  default = null
}

variable "alarm_action_arns" {
  type    = list(string)
  default = []
}

variable "eventbridge_dlq_arn" {
  type    = string
  default = null
}

output "replay_function_arn" {
  value = aws_lambda_function.event_replay.arn
}

output "audit_log_s3_prefix" {
  value = var.audit_bucket_name == null ? null : "event-audit/"
}
```

---

## 9. EVENT SCHEMA

PRD-22 publishes no new events. It consumes events from the custom bus and optionally writes audit records to S3.

---

## 10. API / INTERFACE CONTRACT

### Replay Invocation (CLI)

```bash
aws lambda invoke \
  --function-name {org_name}-event-replay-prod \
  --payload '{"start_time":"2026-03-16T10:00:00Z","end_time":"2026-03-16T12:00:00Z","event_pattern":{"source":[{"prefix":"connect-pbx"}]},"requested_by":"ops@example.com"}' \
  --cli-binary-format raw-in-base64-out \
  response.json

cat response.json
```

---

## 11. DATA MODEL

### Audit Log S3 Structure

```
s3://{approved-audit-bucket}/
└── event-audit/
    ├── {YYYY}/{MM}/{DD}/
    │   ├── {EventType}/
    │   │   └── {lambda_request_id}.ndjson
    │   └── ...
    └── replays/
        └── {YYYY}/{MM}/{DD}/
            └── {replay_name}.ndjson
```

---

## 12. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l2-event-replay }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l2-event-replay, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l2-event-replay
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l2-event-replay-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 13. OBSERVABILITY SPECIFICATION

### Alarms

- `ALARM-22-01`: audit listener errors when the optional audit sink is enabled
- `ALARM-22-02`: replay Lambda duration approaching timeout

Alarm routing is an optional sink input. If `alarm_action_arns` is empty, the module records metrics and logs locally without assuming PRD-03.

---

## 14. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-22-01 | Replay Lambda invocable via CLI | Invoke with a test time window and confirm replay metadata is returned |
| AC-22-02 | `event_pattern` is passed through when supplied | Invoke with a pattern and confirm the replay request includes it |
| AC-22-03 | Replay refused for last 5 minutes | Invoke with `end_time` within 5 minutes; confirm a validation error is raised |
| AC-22-04 | `requested_by` is logged | Inspect CloudWatch logs and replay record output |
| AC-22-05 | Audit listener writes NDJSON only when an approved sink is configured | Enable the sink and confirm the S3 object layout and content |
| AC-22-06 | Replay provenance writes use SSE-KMS when the sink is enabled | Enable the sink and confirm the replay provenance object is encrypted with the environment KMS key |
| AC-22-07 | Module remains deployable without PRD-03 alarm or audit sinks | Validate a manifest that excludes those sinks and confirm the module still plans cleanly |
| AC-22-08 | tfsec and checkov pass | Clean scan output |

---

## 15. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Replay can re-drive a large number of events | Low | Medium | Use the archive window carefully and keep idempotency in downstream consumers |
| Optional sinks can be omitted, leaving fewer artifacts | Medium | Medium | Treat sink enablement as an explicit operator choice in the manifest |
| Per-event NDJSON objects can create many S3 objects at high volume | Medium | Medium | Keep the layout partitioned by date and event type; revisit only if volume warrants a buffering layer |

---

## 16. OPEN QUESTIONS

The remaining implementation work is catalog entry staging and code delivery. The operator choices left open are whether an environment supplies `eventbridge_dlq_arn` and whether it attaches `alarm_action_arns`; both are explicit catalog inputs rather than architectural blockers.

---

## 17. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | - | Initial release. Layer 2 Event Bus complete with PRD-20, PRD-21, PRD-22. |
| 1.1.0 | 2026-04-05 | - | Normalized PRD-22 to the current manifest/catalog model, removed the hidden PRD-03 dependency, made shared alarm and audit sinks optional inputs, aligned the sample code with `event_pattern`, `requested_by`, and NDJSON behavior, and added explicit EventBridge invoke permission plus conditional DLQ/alarm wiring in the sample resources. |
| 1.2.0 | 2026-04-06 | - | Implementation-readiness hardening. Added the missing remote-state, archive-file, IAM, and permission-boundary sample contracts, wired replay provenance writes to SSE-KMS when the audit sink is enabled, added the missing state bucket and module metadata inputs, and toned down the remaining-work language to match the still-explicit catalog staging work. |
| 1.2.1 | 2026-04-06 | - | Follow-up hardening. Made the replay Lambda's optional audit-sink environment variable explicit so the sink can be omitted without a null env contract. |
