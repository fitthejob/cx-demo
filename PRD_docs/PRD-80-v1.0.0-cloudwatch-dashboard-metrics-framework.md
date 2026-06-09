# PRD-80 — CloudWatch Dashboard & Metrics Framework

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-80 |
| **Version** | 1.3.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-08 |
| **Layer** | 8 — Observability |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-10 (Connect instance ID), PRD-13 (queue names), optional integrations: PRD-20 (event bus), PRD-31 (shared state), PRD-60 (voicemail), PRD-70/73 (Lex metrics) |
| **Blocks** | PRD-81 (Alerting), PRD-83 (FinOps) |
| **Optional Shared Sinks** | None |
| **Destroy / Retention Posture** | destroyable / dashboards, queries, and optional scheduled metrics only |
| **Optional** | Yes — conditional foundation for operations-heavy profiles |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable dashboards, Lex widgets, or KPI aggregation.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l8-cloudwatch-dashboards`
- `capability_packs`: `["observability"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture"]`
- `state_key`: `l8-cloudwatch-dashboards/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `cloudwatch-dashboards.tfvars`
- `supports_destroy`: `true`
- `activation`: `enabled_capability_packs` should include `observability` once the module is cataloged; direct `enabled_modules` staging is acceptable only during pre-catalog rollout

### Shared Sink Behavior

- `optional_shared_sinks`: none
- `sink_behavior`: EventBridge, voicemail, Lex, and shared-state widget sets are optional data inputs rather than activation conditions.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: this module owns dashboards, saved queries, and an optional scheduled metrics Lambda. It owns no retained application data.

### Control Plane Statement

The base dashboard surface should remain deployable with native Connect and Lambda metrics only. Optional EventBridge, shared-state, voicemail, and Lex views may light up when those modules are enabled, but they must not become hidden prerequisites for the dashboard module itself.

## 3. CONTEXT & PURPOSE

Provisions the primary CloudWatch operations dashboard, the `ConnectPBX/{environment}` custom metric namespace, and an optional metrics aggregator Lambda that publishes composite metrics not natively available from Connect. Makes platform health visible at a glance for operations teams managing 100-500 agents at high call volume.

**Non-Goals:** Real-time agent status (future workforce or contact analytics layer), cost dashboards (PRD-83), alerting rules (PRD-81).

---

## 4. FUNCTIONAL REQUIREMENTS

### FR-001 — Operations Dashboard
Provision `aws_cloudwatch_dashboard` named `ConnectPBX-Operations-{environment}` with widgets covering:
- Queue depth per queue (QueueSize metric from `AWS/Connect`)
- Oldest contact age per queue (OldestContactAge)
- Agents available vs on-contact per queue
- Lambda error rates for all platform functions (grouped by layer)
- EventBridge custom bus invocation count and failure count when PRD-20 is enabled
- Voicemail received count when PRD-60 and optional event or custom-metric publication exists
- Lex fallback rate when PRD-73 logging or optional event publication exists
- DynamoDB consumed capacity when PRD-31 is enabled

### FR-002 — Custom Metric Namespace
All platform-published custom metrics must use namespace `ConnectPBX/{environment}`. Metric dimensions: `QueueName`, `Department`, `Environment`.

### FR-003 — Metrics Aggregator Lambda
Provision Lambda `{org_name}-metrics-aggregator-{environment}` on a 1-minute EventBridge schedule only when `enable_custom_kpi_aggregation = true`. The base implementation must publish only KPIs with an explicit source contract available from the enabled modules. In the initial implementation, that required base set is:

| Metric Name | Calculation | Unit |
|---|---|---|
| `AnswerRate` | ContactsHandled / (ContactsHandled + ContactsAbandoned) | Percent |
| `AbandonmentRate` | ContactsAbandoned / (ContactsHandled + ContactsAbandoned) | Percent |
| `AvgHandleTime` | Average contact duration from CTRs | Seconds |

Optional extension KPIs may be published only when their source contract is explicitly enabled and wired into this module:

| Optional Metric Name | Required Source Contract |
|---|---|
| `VoicemailRate` | PRD-60 exposes a declared voicemail-count metric or event-derived input compatible with scheduled aggregation |
| `LexFallbackRate` | PRD-73 exposes a declared fallback-count metric or event-derived input compatible with scheduled aggregation |

### FR-004 — Lex Metrics Integration
Provision a second dashboard widget set `ConnectPBX-Lex-{environment}` only when the Lex foundation modules are enabled and `enable_lex_widgets = true`, covering Lex bot metrics from the `AWS/Lex` namespace: `MissedUtterances`, `RuntimeSuccessfulRequests`, `RuntimeThrottledEvents`.

### FR-005 — Log Insights Queries
Pre-provision a base CloudWatch Logs Insights query set plus optional query families when the corresponding log groups are explicitly supplied to the module:
- Required base query: all Lambda errors in the last hour across all platform log groups
- Optional query: contact flow fatal errors with contact IDs when a contact-flow log group is provided
- Optional query: Lex fallback utterances from the last 7 days when the Lex fallback logger log group is provided
- Optional query: voicemail processing failures when the voicemail processor log group is provided

---

## 5. ARCHITECTURE

```
CloudWatch Dashboards
├── ConnectPBX-Operations-{env}
│   ├── Connect Queue Metrics (AWS/Connect namespace)
│   ├── Lambda Error Rates (AWS/Lambda namespace)
│   ├── EventBridge Throughput (AWS/Events namespace)
│   └── Custom Metrics (ConnectPBX/{env} namespace)
│
└── ConnectPBX-Lex-{env}      (optional when Lex widgets are enabled)
    └── Lex Bot Metrics (AWS/Lex namespace)

Metrics Aggregator Lambda (optional 1-minute schedule)
└── Publishes AnswerRate, AbandonmentRate, AvgHandleTime,
    and optional extension KPIs to ConnectPBX/{env}
```

---

## 6. TERRAFORM SPECIFICATION

### Module Path
`modules/l8-cloudwatch-dashboards/`

### Key Resources

```hcl
# main.tf

locals {
  base_widgets = concat(
    # Queue depth widgets — one per enabled queue
    [for queue_name in var.queue_names : {
      type   = "metric"
      width  = 4
      height = 4
      properties = {
        title   = "Queue Depth — ${queue_name}"
        metrics = [["AWS/Connect", "QueueSize", "InstanceId", local.connect_instance_id, "Queue", "${var.org_name}-${queue_name}"]]
        period  = 60
        stat    = "Maximum"
        view    = "timeSeries"
      }
    }],
    # Lambda error rate — all platform functions
    [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = "Lambda Error Rates"
        metrics = [for fn in var.platform_lambda_names : ["AWS/Lambda", "Errors", "FunctionName", fn, { stat = "Sum", period = 300 }]]
        view    = "timeSeries"
      }
    }]
  )

  eventbridge_widgets = var.event_bus_name != "" ? [{
    type   = "metric"
    width  = 12
    height = 4
    properties = {
      title   = "EventBridge — Platform Bus"
      metrics = [
        ["AWS/Events", "Invocations",      "EventBusName", var.event_bus_name],
        ["AWS/Events", "FailedInvocations", "EventBusName", var.event_bus_name]
      ]
      period = 60
      stat   = "Sum"
    }
  }] : []

  kpi_widgets = var.enable_custom_kpi_aggregation ? [{
    type   = "metric"
    width  = 12
    height = 4
    properties = {
      title   = "Platform KPIs"
      metrics = [
        ["ConnectPBX/${terraform.workspace}", "AnswerRate",      "Environment", terraform.workspace],
        ["ConnectPBX/${terraform.workspace}", "AbandonmentRate", "Environment", terraform.workspace],
        ["ConnectPBX/${terraform.workspace}", "AvgHandleTime",   "Environment", terraform.workspace]
      ]
      period = 300
      stat   = "Average"
    }
  }] : []

  optional_kpi_widgets = concat(
    var.enable_custom_kpi_aggregation && var.enable_voicemail_kpi_widgets ? [{
      type   = "metric"
      width  = 12
      height = 4
      properties = {
        title   = "Voicemail KPIs"
        metrics = [["ConnectPBX/${terraform.workspace}", "VoicemailRate", "Environment", terraform.workspace]]
        period  = 300
        stat    = "Average"
      }
    }] : [],
    var.enable_custom_kpi_aggregation && var.enable_lex_fallback_kpi_widgets ? [{
      type   = "metric"
      width  = 12
      height = 4
      properties = {
        title   = "Lex Fallback KPIs"
        metrics = [["ConnectPBX/${terraform.workspace}", "LexFallbackRate", "Environment", terraform.workspace]]
        period  = 300
        stat    = "Average"
      }
    }] : []
  )
}

resource "aws_cloudwatch_dashboard" "operations" {
  dashboard_name = "ConnectPBX-Operations-${terraform.workspace}"

  dashboard_body = jsonencode({
    widgets = concat(local.base_widgets, local.eventbridge_widgets, local.kpi_widgets, local.optional_kpi_widgets)
  })
}

resource "aws_cloudwatch_dashboard" "lex" {
  count          = var.enable_lex_widgets ? 1 : 0
  dashboard_name = "ConnectPBX-Lex-${terraform.workspace}"

  dashboard_body = jsonencode({
    widgets = [{
      type   = "metric"
      width  = 24
      height = 6
      properties = {
        title   = "Lex Bot Performance"
        metrics = [
          ["AWS/Lex", "RuntimeSuccessfulRequests", "BotName", "${var.org_name}-auto-attendant-${terraform.workspace}"],
          ["AWS/Lex", "MissedUtterances",           "BotName", "${var.org_name}-auto-attendant-${terraform.workspace}"],
          ["AWS/Lex", "RuntimeThrottledEvents",     "BotName", "${var.org_name}-auto-attendant-${terraform.workspace}"]
        ]
        period = 300
        stat   = "Sum"
      }
    }]
  })
}

# iam.tf

resource "aws_iam_role" "metrics_aggregator" {
  count = var.enable_custom_kpi_aggregation ? 1 : 0
  name = "${var.org_name}-metrics-aggregator-${terraform.workspace}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
  permissions_boundary = local.permission_boundary_arn
  tags = { Layer = "L8", PRD = "PRD-80" }
}

resource "aws_iam_role_policy_attachment" "metrics_aggregator_logging" {
  count      = var.enable_custom_kpi_aggregation ? 1 : 0
  role       = aws_iam_role.metrics_aggregator[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "metrics_aggregator_service" {
  count = var.enable_custom_kpi_aggregation ? 1 : 0
  name = "metrics-aggregator-service"
  role = aws_iam_role.metrics_aggregator[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConnectGetMetrics"
        Effect = "Allow"
        Action = ["connect:GetMetricDataV2"]
        Resource = "${local.connect_instance_arn}"
      },
      {
        Sid    = "CloudWatchPutMetrics"
        Effect = "Allow"
        Action = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "ConnectPBX/${terraform.workspace}" }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "metrics_aggregator" {
  count             = var.enable_custom_kpi_aggregation ? 1 : 0
  name              = "/aws/lambda/${var.org_name}-metrics-aggregator-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = local.kms_key_arn
  tags = { Layer = "L8", PRD = "PRD-80" }
}

resource "aws_lambda_function" "metrics_aggregator" {
  count         = var.enable_custom_kpi_aggregation ? 1 : 0
  function_name = "${var.org_name}-metrics-aggregator-${terraform.workspace}"
  role          = aws_iam_role.metrics_aggregator[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.metrics_aggregator.output_path
  source_code_hash = data.archive_file.metrics_aggregator.output_base64sha256

  environment {
    variables = {
      CONNECT_INSTANCE_ID = local.connect_instance_id
      METRIC_NAMESPACE    = "ConnectPBX/${terraform.workspace}"
      ENVIRONMENT         = terraform.workspace
      ENABLE_VOICEMAIL_KPI = tostring(var.enable_voicemail_kpi_source)
      ENABLE_LEX_FALLBACK_KPI = tostring(var.enable_lex_fallback_kpi_source)
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L8", PRD = "PRD-80" }
}

resource "aws_lambda_alias" "metrics_aggregator_live" {
  count            = var.enable_custom_kpi_aggregation ? 1 : 0
  name             = "LIVE"
  function_name    = aws_lambda_function.metrics_aggregator[0].function_name
  function_version = aws_lambda_function.metrics_aggregator[0].version
  lifecycle { ignore_changes = [function_version, routing_config] }
}

resource "aws_cloudwatch_event_rule" "metrics_aggregator_schedule" {
  count               = var.enable_custom_kpi_aggregation ? 1 : 0
  name                = "${var.org_name}-metrics-aggregator-${terraform.workspace}"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "metrics_aggregator" {
  count     = var.enable_custom_kpi_aggregation ? 1 : 0
  rule      = aws_cloudwatch_event_rule.metrics_aggregator_schedule[0].name
  target_id = "metrics-aggregator-lambda"
  arn       = "${aws_lambda_function.metrics_aggregator[0].arn}:LIVE"
}

resource "aws_lambda_permission" "metrics_aggregator_events" {
  count         = var.enable_custom_kpi_aggregation ? 1 : 0
  statement_id  = "AllowCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.metrics_aggregator[0].function_name
  qualifier     = "LIVE"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.metrics_aggregator_schedule[0].arn
}

# Saved Log Insights queries
resource "aws_cloudwatch_query_definition" "lambda_errors" {
  name = "ConnectPBX/${terraform.workspace}/Lambda-Errors-Last-Hour"
  log_group_names = [for name in var.platform_lambda_names : "/aws/lambda/${name}"]
  query_string = <<-EOQ
    fields @timestamp, @message, @logStream
    | filter @message like /ERROR/
    | sort @timestamp desc
    | limit 100
  EOQ
}

resource "aws_cloudwatch_query_definition" "contact_flow_fatal_errors" {
  count = var.contact_flow_log_group_name != "" ? 1 : 0
  name  = "ConnectPBX/${terraform.workspace}/Contact-Flow-Fatal-Errors"
  log_group_names = [var.contact_flow_log_group_name]
  query_string = <<-EOQ
    fields @timestamp, ContactId, @message
    | filter @message like /Fatal/ or @message like /ERROR/
    | sort @timestamp desc
    | limit 100
  EOQ
}

resource "aws_cloudwatch_query_definition" "lex_fallback_utterances" {
  count = var.lex_fallback_log_group_name != "" ? 1 : 0
  name = "ConnectPBX/${terraform.workspace}/Lex-Fallback-Utterances-7d"
  log_group_names = [var.lex_fallback_log_group_name]
  query_string = <<-EOQ
    fields @timestamp, unrecognized_text, contact_id
    | filter ispresent(unrecognized_text)
    | stats count() as occurrences by unrecognized_text
    | sort occurrences desc
    | limit 50
  EOQ
}

resource "aws_cloudwatch_query_definition" "voicemail_processing_failures" {
  count = var.voicemail_failure_log_group_name != "" ? 1 : 0
  name  = "ConnectPBX/${terraform.workspace}/Voicemail-Processing-Failures"
  log_group_names = [var.voicemail_failure_log_group_name]
  query_string = <<-EOQ
    fields @timestamp, contact_id, @message
    | filter @message like /ERROR/ or @message like /failed/
    | sort @timestamp desc
    | limit 100
  EOQ
}
```

### Lambda Source — Metrics Aggregator

```python
# lambda-src/metrics-aggregator/index.py
import logging
import os
from datetime import datetime, timezone, timedelta

import boto3

connect_client = boto3.client('connect')
cloudwatch     = boto3.client('cloudwatch')
CONNECT_INSTANCE_ID = os.environ['CONNECT_INSTANCE_ID']
METRIC_NAMESPACE    = os.environ['METRIC_NAMESPACE']
ENVIRONMENT         = os.environ['ENVIRONMENT']
LOGGER              = logging.getLogger()
LOGGER.setLevel(logging.INFO)

def handler(event, context):
    now = datetime.now(timezone.utc)
    end = now
    start = now - timedelta(minutes=15)

    try:
        metrics_resp = connect_client.get_metric_data_v2(
            ResourceArns=[f"arn:aws:connect:{os.environ['AWS_REGION']}:{boto3.client('sts').get_caller_identity()['Account']}:instance/{CONNECT_INSTANCE_ID}"],
            StartTime=start,
            EndTime=end,
            Interval={'TimeZone': 'UTC', 'IntervalPeriod': 'FIFTEEN_MIN'},
            Metrics=[
                {'Name': 'CONTACTS_HANDLED'},
                {'Name': 'CONTACTS_ABANDONED'},
                {'Name': 'AVG_HANDLE_TIME'}
            ],
            Filters=[{'FilterKey': 'CHANNEL', 'FilterValues': ['VOICE']}]
        )

        handled   = 0
        abandoned = 0
        avg_ht    = 0
        for result in metrics_resp.get('MetricResults', []):
            for col in result.get('Collections', []):
                name = col['Metric']['Name']
                val  = col.get('Value', 0) or 0
                if name == 'CONTACTS_HANDLED':   handled   = val
                if name == 'CONTACTS_ABANDONED': abandoned = val
                if name == 'AVG_HANDLE_TIME':    avg_ht    = val

        total        = handled + abandoned
        answer_rate  = (handled   / total * 100) if total > 0 else 100.0
        abandon_rate = (abandoned / total * 100) if total > 0 else 0.0

        metric_data = [
            {'MetricName': 'AnswerRate',     'Value': answer_rate,  'Unit': 'Percent',  'Dimensions': [{'Name': 'Environment', 'Value': ENVIRONMENT}]},
            {'MetricName': 'AbandonmentRate','Value': abandon_rate, 'Unit': 'Percent',  'Dimensions': [{'Name': 'Environment', 'Value': ENVIRONMENT}]},
            {'MetricName': 'AvgHandleTime',  'Value': avg_ht,       'Unit': 'Seconds',  'Dimensions': [{'Name': 'Environment', 'Value': ENVIRONMENT}]},
        ]

        # Extension KPI publication is added only alongside the corresponding
        # source readers. The base sample intentionally omits placeholder values.

        cloudwatch.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=metric_data
        )
        LOGGER.info("Metrics published", extra={"answer_rate": answer_rate, "abandon_rate": abandon_rate})
    except Exception as e:
        LOGGER.exception("Metrics aggregation failed: %s", str(e))

    return {'statusCode': 200}
```

### Variables

```hcl
variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "layer_id"    { type = string; default = "L8" }
variable "prd_id"      { type = string; default = "PRD-80" }

variable "queue_names" {
  type    = list(string)
  default = ["General-Inbound", "Sales", "Customer-Support", "Billing", "Technical-Support", "Escalations-Tier2"]
}

variable "platform_lambda_names" {
  type        = list(string)
  description = "List of all platform Lambda function names. Updated as each service PRD is deployed."
  default     = []
}

variable "cloudwatch_dashboards_state_key" {
  type        = string
  default     = "l8-cloudwatch-dashboards/terraform.tfstate"
  description = "Catalog-declared state key for this module."
}

variable "event_bus_name" {
  type        = string
  default     = ""
  description = "Optional EventBridge bus name for EventBridge widgets."
}

variable "enable_custom_kpi_aggregation" {
  type        = bool
  default     = false
  description = "When true, provisions the scheduled metrics aggregator Lambda and KPI widgets."
}

variable "enable_lex_widgets" {
  type        = bool
  default     = false
  description = "When true, provisions the optional Lex dashboard."
}

variable "contact_flow_log_group_name" {
  type        = string
  default     = ""
  description = "Optional CloudWatch log group name for contact-flow error queries."
}

variable "lex_fallback_log_group_name" {
  type        = string
  default     = ""
  description = "Optional CloudWatch log group name for Lex fallback queries."
}

variable "voicemail_failure_log_group_name" {
  type        = string
  default     = ""
  description = "Optional CloudWatch log group name for voicemail failure queries."
}

variable "enable_voicemail_kpi_source" {
  type        = bool
  default     = false
  description = "Enable only when an upstream voicemail metric or event-derived count contract is wired into the aggregator."
}

variable "enable_lex_fallback_kpi_source" {
  type        = bool
  default     = false
  description = "Enable only when an upstream Lex fallback metric or event-derived count contract is wired into the aggregator."
}

variable "enable_voicemail_kpi_widgets" {
  type        = bool
  default     = false
  description = "Show voicemail KPI widgets only when the voicemail KPI source contract is enabled."
}

variable "enable_lex_fallback_kpi_widgets" {
  type        = bool
  default     = false
  description = "Show Lex fallback KPI widgets only when the Lex fallback KPI source contract is enabled."
}
```

### Outputs

```hcl
output "operations_dashboard_name"      { value = aws_cloudwatch_dashboard.operations.dashboard_name }
output "lex_dashboard_name"             { value = try(aws_cloudwatch_dashboard.lex[0].dashboard_name, null) }
output "custom_metric_namespace"        { value = "ConnectPBX/${terraform.workspace}" }
output "metrics_aggregator_lambda_name" { value = try(aws_lambda_function.metrics_aggregator[0].function_name, null) }
```

### Backend

```hcl
terraform {
  required_version = ">= 1.14.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 6.0" } }
  backend "s3" {}
}
```

Plan/apply injects the catalog-declared `state_key` for this module rather than hardcoding environment paths in the PRD sample.

---

## 7. EVENT SCHEMA

PRD-80 produces no EventBridge events. Custom metrics published to CloudWatch namespace `ConnectPBX/{environment}`.

---

## 8. CI/CD

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l8-cloudwatch-dashboards }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l8-cloudwatch-dashboards, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l8-cloudwatch-dashboards
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l8-cloudwatch-dashboards-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 9. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-80-01 | Operations dashboard exists and loads | `aws cloudwatch list-dashboards` returns dashboard; open in AWS console |
| AC-80-02 | Lex dashboard exists only when `enable_lex_widgets = true` | Same verification |
| AC-80-03 | Metrics aggregator Lambda runs on 1-minute schedule only when `enable_custom_kpi_aggregation = true` | EventBridge rule active; Lambda invoked in logs |
| AC-80-04 | Base custom metrics appear in ConnectPBX/{env} namespace when custom KPI aggregation is enabled | `aws cloudwatch list-metrics --namespace ConnectPBX/{env}` returns `AnswerRate`, `AbandonmentRate`, and `AvgHandleTime` |
| AC-80-05 | Optional voicemail and Lex KPI widgets render only when their source contracts are explicitly enabled | Verify widget presence and confirm corresponding custom metrics exist before enablement |
| AC-80-06 | Base and enabled optional Log Insights queries exist | `aws logs describe-query-definitions` returns the required Lambda error query and only the optional query definitions backed by supplied log groups |
| AC-80-07 | tfsec and checkov pass | Clean scan |

---

## 10. RISKS

Metrics aggregator Lambda running every minute adds ~44,000 Lambda invocations/month — negligible cost. Dashboard JSON must be valid — Terraform plan will fail on malformed dashboard body; validate JSON before apply.

---

## 11. REVISION HISTORY

| Version | Date | Notes |
|---|---|---|
| 1.3.0 | 2026-04-08 | Narrowed the KPI contract to metrics with declared sources, moved voicemail and Lex KPIs to explicit extension inputs, removed hidden PRD-40 Lambda sample coupling, and normalized the plan artifact naming example. |
| 1.2.0 | 2026-04-06 | Added the repo-owned governance section, removed `deployment_profile` activation drift, normalized backend and module-path examples to current repo conventions, and made KPI/Lex widgets explicit opt-in inputs instead of hidden profile behavior. |
| 1.1.0 | 2026-03-30 | Reclassified as a conditional observability foundation. Base dashboards remain available for native Connect and Lambda metrics, while EventBridge, shared-state, voicemail, and Lex-specific views are now explicitly profile-scoped enhancements. |
| 1.0.0 | 2026-03-16 | Initial release. Operations and Lex dashboards. Custom metric namespace. Aggregator Lambda. Saved Insights queries. |
