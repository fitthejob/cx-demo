# PRD-19 — Routing Drift Detection

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-19 |
| **Version** | 1.3.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-00 (state bucket), PRD-10 (Connect instance), PRD-11 (phone number inventory), PRD-14 (contact flows define expected routing) |
| **Blocks** | PRD-81 (alarm consolidation references ALARM-19-01 and ALARM-19-02) |
| **Optional** | Optional feature. Strongly recommended for environments that want continuous routing integrity monitoring and faster drift response; deployable separately from bare-bones core telephony. |

---

## 2. MODULE GOVERNANCE

### Module Classification

| Field | Value |
|---|---|
| `classification` | `optional-feature` |
| `minimum_deployment_profile` | `standard` |
| `can_be_omitted_from_bare_bones` | `yes` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |

### Catalog Entry

| Field | Value |
|---|---|
| `path` | `modules/l1-routing-drift` |
| `capability_packs` | `["number-governance"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers", "modules/l1-contact-flow-framework"]` |
| `state_key` | `l1-routing-drift/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `routing-drift.tfvars` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Alarm topic is optional input via `alarm_action_arns`. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `destroyable` |
| `retention_notes` | Drift records have TTL; detector restarts fresh after redeploy. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Amazon Connect allows phone numbers to be manually reassociated with contact flows via the AWS console. When a platform engineer or administrator makes a console change, Terraform state is not updated. The result is silent drift: Terraform believes number X routes to flow Y, but Connect is routing calls to flow Z. This misconfiguration persists until the next `terraform apply`, which silently corrects it — or until a caller reports wrong behavior, which could be hours or days later.

ALARM-11-01 (defined in PRD-11, deferred implementation) addresses only one manifestation of this problem: numbers with no flow association at all. It does not detect active misrouting — numbers that have a flow associated, but the wrong one.

Amazon Connect's current phone-number read APIs do not expose the associated contact flow ARN or ID. `ListPhoneNumbersV2` and `DescribePhoneNumber` return the Connect instance ARN as `TargetArn`, not the phone number's contact-flow association. That means a v1 detector cannot truthfully perform point-in-time "actual flow versus expected flow" reconciliation from the Connect API alone.

This PRD therefore defines a corrected v1 model:

- expected routing state is still sourced from Terraform state in S3
- `UNEXPECTED_NUMBER` is detected by reconciling Connect phone inventory against Terraform inventory
- `WRONG_FLOW` and `NO_FLOW` are detected from CloudTrail management events for phone-number association changes, compared against the Terraform-expected route map

This still provides timely detection of unauthorized console routing changes after the detector is enabled, while avoiding false precision about API capabilities that do not exist.

### Scope of Drift Detected

| Drift Type | Description |
|---|---|
| `WRONG_FLOW` | CloudTrail shows a phone number was associated to a contact flow that differs from the Terraform-expected route |
| `NO_FLOW` | CloudTrail shows a phone number was explicitly disassociated from its contact flow (supersedes ALARM-11-01) |
| `UNEXPECTED_NUMBER` | Number exists in Connect but is not in Terraform state (console-claimed or imported but not committed) |

---

## 4. GOALS

- Detect unauthorized or out-of-band routing mutations within one 15-minute scan window
- Detect unexpected numbers in Connect inventory that are not represented in Terraform state
- Persist drift records in DynamoDB for investigation and audit
- Emit CloudWatch metrics consumed by PRD-81 alarms
- Support multi-instance deployments — iterate over all Connect instances in state when `deployment_profile.instance_count > 1`
- Alert after two consecutive periods to avoid false positives during legitimate Terraform applies that temporarily disassociate and then reassociate numbers

### Non-Goals

- This PRD does not correct drift — correction is performed by the on-call engineer via the standard CI/CD pipeline per RB-11-08
- This PRD does not perform a full point-in-time reconciliation of live phone number → contact flow associations from the Connect API; that API surface is not currently available
- This PRD does not detect drift in contact flow definitions — it detects only number-to-flow association mutation drift and unexpected-number inventory drift
- This PRD does not enforce IAM restrictions on console access — that hardening is documented as an option in RB-11-08

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Drift Detection Lambda
A Lambda function (`{org_name}-routing-drift-detector-{environment}`) is the authoritative detection surface for routing drift. It supports:

- `SCAN_ALL`: inventory-wide drift detection, used by the optional 15-minute schedule
- `SCAN_NUMBERS`: operator-invoked validation of explicit phone numbers during investigation or post-remediation verification

On each execution it must:
1. Read the authoritative module-state resolution contract for the environment to determine which modules and state keys are authoritative
2. Read the `l1-phone-numbers` Terraform state from S3 to extract the expected phone inventory
3. Read the `l1-contact-flow-framework` (PRD-14) Terraform state from S3 and consume its explicit `expected_number_flow_routes` output as the authoritative expected route map
4. Call `connect:ListPhoneNumbersV2` to retrieve the actual current phone inventory for `UNEXPECTED_NUMBER` detection only
5. Call `cloudtrail:LookupEvents` for recent `AssociatePhoneNumberContactFlow`, `DisassociatePhoneNumberContactFlow`, `ClaimPhoneNumber`, and `ReleasePhoneNumber` management events
6. Compute event-driven `WRONG_FLOW` / `NO_FLOW` drift findings and inventory-driven `UNEXPECTED_NUMBER` findings
7. Write any new drift records to the drift DynamoDB table
8. Mark previously detected drift records as resolved when a later event or inventory state shows the number back in the expected managed state
9. Publish `RoutingDriftCount` metric to CloudWatch namespace `ConnectPBX/{environment}`

Operator-triggered on-demand invocation is required for investigation and validation. The 15-minute EventBridge schedule is the normal continuous-monitoring path, but the module must remain explicit about its manual invocation contract.

### FR-002 — Drift Record Table
A DynamoDB table (`{org_name}-routing-drift-{environment}`, PAY_PER_REQUEST) must persist drift records with the following schema:

| Attribute | Type | Description |
|---|---|---|
| `phone_number` | String (PK) | E.164 number |
| `drift_type` | String (SK) | WRONG_FLOW / NO_FLOW / UNEXPECTED_NUMBER |
| `instance_id` | String | Connect instance where the drift was detected |
| `expected_flow_arn` | String | Flow ARN from Terraform state (null for UNEXPECTED_NUMBER) |
| `actual_flow_arn` | String | Flow ARN reconstructed from the CloudTrail mutation event when available (null for NO_FLOW) |
| `first_detected_at` | String | ISO 8601 timestamp of first detection |
| `last_detected_at` | String | ISO 8601 timestamp of most recent detection |
| `consecutive_detections` | Number | How many consecutive Lambda executions detected this drift |
| `record_status` | String | OPEN / RESOLVED |
| `status_scope` | String | Mirrors `record_status` for GSI-based operator workflows |
| `resolved_at` | String | ISO 8601 timestamp when drift resolved (null if unresolved) |
| `resolved_by` | String | "terraform-apply" or "manual" — populated by remediation |
| `source_event_name` | String | CloudTrail event that introduced or most recently refreshed the drift |
| `source_event_time` | String | CloudTrail event time or inventory scan time for `UNEXPECTED_NUMBER` |
| `source_principal_arn` | String | IAM principal observed in CloudTrail for routing mutation events (null for inventory-only records) |
| `last_source_event_id` | String | CloudTrail event ID used to avoid duplicate consecutive detection inflation |

TTL: 90 days on `resolved_at` records to prevent unbounded table growth.

Operator workflows must not discover open drift records by scanning the full table. The module must include a sparse GSI with:

- GSI partition key: `status_scope`
- GSI sort key: `phone_number`

Record lifecycle in v1:

- new drift: `OPEN`
- repeated detection: remains `OPEN`, increments `consecutive_detections`
- resolved drift: `RESOLVED`, sets `resolved_at`
- reintroduced drift after resolution: reopens the same `(phone_number, drift_type)` item as `OPEN`

### FR-003 — CloudWatch Metrics
The Lambda must publish the following metrics to `ConnectPBX/{environment}` on every execution:

| Metric | Unit | Description |
|---|---|---|
| `RoutingDriftCount` | Count | Total unresolved drift records |
| `WrongFlowDriftCount` | Count | Unresolved WRONG_FLOW records |
| `NoFlowDriftCount` | Count | Unresolved NO_FLOW records |
| `UnexpectedNumberCount` | Count | Unresolved UNEXPECTED_NUMBER records |
| `DriftDetectionExecutionSuccess` | Count | 1 on successful execution, 0 on failure |

### FR-004 — Multi-Instance Support
When `deployment_profile.instance_count > 1`, the Lambda must iterate over all Connect instance IDs sourced from the environment deployment manifest / module catalog state resolution output. The drift detector must not hardcode state-key naming conventions such as `{workspace}/l1-connect-instance-{n}/terraform.tfstate`; it must use the same resolved module-state contract as the repo's deploy tooling. The drift table is shared across all instances; the `instance_id` field distinguishes records.

### FR-005 — State Resolution Contract
The Lambda does not discover state objects by convention. It consumes a pre-resolved module-state contract supplied by the module configuration, with at minimum:

- `phone_numbers_state_key`
- `contact_flow_state_key`
- `connect_instance_ids`
- `state_bucket`

This contract is derived from the authoritative deployment manifest / module catalog model and must match the same environment/module resolution used by repo deploy tooling.

### FR-006 — Expected Route Parsing
The Lambda reads Terraform state JSON from S3. The authoritative expected route map is taken from the PRD-14 output:
```
outputs.expected_number_flow_routes.value
```
If that output is missing, the Lambda may fall back to Terraform resource parsing for backward compatibility, but the implementation contract is that PRD-14 must publish explicit expected routes for PRD-19 consumption.

If a required state file cannot be read (permissions error, file not found), the Lambda must not write false drift records — it must emit `DriftDetectionExecutionSuccess = 0` and exit cleanly.

The list of state objects to read is not hardcoded in the module. It is resolved from the authoritative deployment manifest / module catalog for the target environment.

### FR-007 — CloudTrail Event Interpretation
The Lambda is event-driven for routing-mutation drift. It must inspect recent CloudTrail management events and interpret them as follows:

| Event | Interpretation |
|---|---|
| `AssociatePhoneNumberContactFlow` | If the associated contact flow differs from the Terraform-expected route for that phone number, open or refresh a `WRONG_FLOW` record |
| `DisassociatePhoneNumberContactFlow` | If the phone number is Terraform-managed, open or refresh a `NO_FLOW` record |
| `ClaimPhoneNumber` | If the claimed number is not present in Terraform-managed inventory, open or refresh an `UNEXPECTED_NUMBER` record |
| `ReleasePhoneNumber` | If the released number previously had an `UNEXPECTED_NUMBER` record, resolve it |

Repeated scans over the same CloudTrail event must not artificially increment `consecutive_detections`. The implementation must track the most recent processed event identifier per drift record.

---

## 6. ARCHITECTURE

### Component Diagram

```
Operator / CI invoke OR Optional EventBridge Schedule (15 min)
        ↓
  {org}-routing-drift-detector-{env} (Lambda)
        ├── Resolved module-state contract
        ├── S3 GetObject → l1-phone-numbers state
        ├── S3 GetObject → l1-contact-flow-framework state
        ├── Connect ListPhoneNumbersV2 (inventory only)
        ├── CloudTrail LookupEvents
        │     ├── AssociatePhoneNumberContactFlow
        │     ├── DisassociatePhoneNumberContactFlow
        │     ├── ClaimPhoneNumber
        │     └── ReleasePhoneNumber
        │
        ├── DynamoDB PutItem / UpdateItem → {org}-routing-drift-{env}
        ├── DynamoDB GSI query → OPEN records
        └── CloudWatch PutMetricData → ConnectPBX/{env}
                                             ↓
                                    PRD-81 Alarms
                                    ALARM-19-01 (drift detected)
                                    ALARM-19-02 (drift persists > 4h)
```

---

## 7. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-routing-drift/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── backend.tf
        └── lambda/
            └── drift_detector.py
```

### Key Resources

```hcl
# main.tf

resource "aws_dynamodb_table" "routing_drift" {
  name         = "${var.org_name}-routing-drift-${terraform.workspace}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "phone_number"
  range_key    = "drift_type"

  attribute {
    name = "phone_number"
    type = "S"
  }

  attribute {
    name = "drift_type"
    type = "S"
  }

  attribute {
    name = "status_scope"
    type = "S"
  }

  global_secondary_index {
    name            = "status-by-scope"
    hash_key        = "status_scope"
    range_key       = "phone_number"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_key_arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = local.standard_tags
}

resource "aws_lambda_function" "drift_detector" {
  function_name = "${var.org_name}-routing-drift-detector-${terraform.workspace}"
  runtime       = "python3.12"
  handler       = "drift_detector.handler"
  timeout       = 120
  memory_size   = 256

  role = aws_iam_role.drift_detector.arn

  environment {
    variables = {
      MODULE_STATE_RESOLUTION_JSON = jsonencode(var.module_state_resolution)
      DRIFT_TABLE                  = aws_dynamodb_table.routing_drift.name
      METRIC_NAMESPACE             = "ConnectPBX/${terraform.workspace}"
      ENVIRONMENT                  = terraform.workspace
      LOOKBACK_MINUTES             = "30"
    }
  }

  tags = local.standard_tags
}

resource "aws_cloudwatch_event_rule" "drift_schedule" {
  count               = var.enable_schedule ? 1 : 0
  name                = "${var.org_name}-routing-drift-schedule-${terraform.workspace}"
  description         = "Triggers routing drift detection every 15 minutes"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "drift_detector" {
  count     = var.enable_schedule ? 1 : 0
  rule      = aws_cloudwatch_event_rule.drift_schedule[0].name
  target_id = "RoutingDriftDetector"
  arn       = aws_lambda_function.drift_detector.arn
}
```

### Key Variables

```hcl
variable "enable_schedule" {
  type        = bool
  default     = true
  description = "When true, create the 15-minute EventBridge schedule for continuous drift detection."
}

variable "module_state_resolution" {
  type = object({
    state_bucket            = string
    phone_numbers_state_key = string
    contact_flow_state_key  = string
    connect_instance_ids    = list(string)
  })
  description = "Resolved state contract derived from the deployment manifest / module catalog model."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs. Empty list means alarms may exist without external actions."
}
```

### Outputs

```hcl
output "routing_drift_table_name" {
  description = "Routing drift DynamoDB table name."
  value       = aws_dynamodb_table.routing_drift.name
}

output "routing_drift_status_gsi_name" {
  description = "Sparse GSI exposing drift records by record_status for operator workflows."
  value       = "status-by-scope"
}

output "routing_drift_detector_lambda_arn" {
  description = "Routing drift detector Lambda ARN."
  value       = aws_lambda_function.drift_detector.arn
}
```

### IAM Role Policy

```hcl
resource "aws_iam_role_policy" "drift_detector" {
  name = "${var.org_name}-routing-drift-detector-policy"
  role = aws_iam_role.drift_detector.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadTerraformState"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "arn:aws:s3:::${var.module_state_resolution.state_bucket}/${var.module_state_resolution.phone_numbers_state_key}",
          "arn:aws:s3:::${var.module_state_resolution.state_bucket}/${var.module_state_resolution.contact_flow_state_key}"
        ]
      },
      {
        Sid    = "ConnectRead"
        Effect = "Allow"
        Action = [
          "connect:ListPhoneNumbersV2"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudTrailRead"
        Effect = "Allow"
        Action = ["cloudtrail:LookupEvents"]
        Resource = "*"
      },
      {
        Sid    = "DriftTable"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.routing_drift.arn,
          "${aws_dynamodb_table.routing_drift.arn}/index/status-by-scope"
        ]
      },
      {
        Sid      = "Metrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "ConnectPBX/${terraform.workspace}"
          }
        }
      },
      {
        Sid    = "KMS"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
        Resource = [local.kms_key_arn]
      }
    ]
  })
}
```

---

## 8. ALARMS

**ALARM-19-01: Routing Drift Detected**
- Metric: `ConnectPBX/{environment}/RoutingDriftCount`
- Threshold: >= 1 for 2 consecutive 15-minute periods
- Rationale: Single period may be transient during a legitimate Terraform apply (apply takes up to 15 minutes). Two consecutive periods indicates drift is not from an in-progress apply.
- Action: configured `alarm_action_arns` when supplied
- Severity: High

**ALARM-19-02: Routing Drift Persists**
- Metric: `ConnectPBX/{environment}/RoutingDriftCount`
- Threshold: >= 1 for 16 consecutive 15-minute periods (4 hours)
- Rationale: Drift that persists for 4 hours has not been corrected by any apply. Escalation required.
- Action: configured `alarm_action_arns` when supplied
- Severity: Critical

Both alarms are consolidated in PRD-81.

---

## 9. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-19-01 | Lambda runs on 15-minute schedule | CloudWatch Logs show executions at 15-minute intervals |
| AC-19-02 | Drift detected when a number is manually reassociated via console | Manually change a number's flow in Connect console; verify CloudTrail event results in a `WRONG_FLOW` record within 15 minutes |
| AC-19-03 | `NO_FLOW` detected when a number is manually disassociated | Manually disassociate a number in dev; verify a `NO_FLOW` record appears |
| AC-19-04 | `UNEXPECTED_NUMBER` detected when a number exists in Connect but not Terraform state | Introduce a console-claimed number in dev; verify `UNEXPECTED_NUMBER` appears |
| AC-19-05 | Drift record resolves after terraform apply corrects the routing | Run `terraform apply` after AC-19-02 or AC-19-03; verify `resolved_at` is populated |
| AC-19-06 | No false persistent drift alarms during a legitimate Terraform apply | Run a full apply; verify no ALARM-19-01 persists across two periods |
| AC-19-07 | Lambda fails gracefully when state file is inaccessible | Remove S3 permissions temporarily; verify `DriftDetectionExecutionSuccess = 0` emitted, no false drift records written |
| AC-19-08 | Multi-instance: all instances checked when instance_count > 1 | Deploy with instance_count=2 in dev; verify drift records include instance_id field for both instances |
| AC-19-09 | Operator workflows can query OPEN drift records without scanning the full table | Query the sparse GSI for `status_scope = OPEN`; verify only unresolved records are returned |
| AC-19-10 | `SCAN_NUMBERS` supports explicit post-remediation validation | Invoke the Lambda with a specific number after remediation; verify only that number is checked and unrelated records are not reopened |
| AC-19-11 | Repeated scans of the same CloudTrail event do not inflate `consecutive_detections` | Re-run the detector without new events; verify `consecutive_detections` does not increase for the same `last_source_event_id` |
| AC-19-12 | checkov passes with zero HIGH/CRITICAL findings | `checkov -d modules/l1-routing-drift/` |

---

## 10. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-22 | — | Initial release. Supersedes deferred ALARM-11-01 (no-flow-association check) by including NO_FLOW as a drift type in the broader reconciliation scan. |
| 1.1.0 | 2026-03-30 | Codex | Readiness pass: defined explicit state-resolution contract, added multi-instance record fields and status-query GSI, made alarm actions configurable, and aligned operator workflows to the manifest-driven deployment model. |
| 1.2.0 | 2026-03-30 | Codex | Correction pass: replaced impossible API-based live flow reconciliation with a CloudTrail-plus-state detection model, made PRD-14 expected route output authoritative, and documented the actual AWS API limitation around phone-number target visibility. |
| 1.3.0 | 2026-04-05 | Codex | Governance normalization. Promoted catalog metadata from recommended to mandatory. Added Module Governance section with shared sink behavior, destroy posture, and control plane statement. |
