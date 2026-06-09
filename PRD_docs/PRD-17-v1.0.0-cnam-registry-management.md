# PRD-17 — CNAM Registry Management

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-17 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-11 (numbers must be claimed), PRD-16 (spam check gate before CNAM registration) |
| **Blocks** | PRD-51 v1.1.0 (disambiguation of CNAM vs. outbound caller ID), PRD-81 (alarm consolidation) |
| **Optional** | Optional feature. Strongly recommended for PBX deployments where outbound identity matters; optional for contact center deployments where CNAM accuracy is less critical. |

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
| `path` | `modules/l1-cnam-registry` |
| `capability_packs` | `["number-governance"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers", "modules/l1-spam-reputation"]` |
| `state_key` | `l1-cnam-registry/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `cnam-registry.tfvars` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Alarm topic is optional input via `alarm_action_arns`. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `destroyable` |
| `retention_notes` | CNAM history has TTL; records resubmitted on redeploy. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### What CNAM Is and Why It Matters

CNAM (Caller ID Name) is the text string that terminating carriers display alongside a phone number when a call arrives. It is stored in carrier-side databases — not in Amazon Connect, not in AWS, and not in Terraform state. Amazon Connect has no native capability to read or write CNAM records.

When a new DID is claimed from the Amazon Connect telephony pool, the CNAM for that number is one of:
- **Empty** — the number was recently introduced to the pool and has no CNAM record
- **Stale** — inherited from the prior holder (a business that released the number)
- **Incorrect** — a generic label from the prior carrier

For a **contact center** deployment, this is a presentability issue: outbound calls may display an unfamiliar company name or nothing. For a **PBX deployment** with employee direct-dial numbers, this is a business identity issue at scale. Hundreds of employee DIDs need CNAM records that display the company name — or optionally the individual employee name — on every outbound call. Without CNAM management, the enterprise has no control over what recipients see.

### How CNAM Works

CNAM is stored in two primary registries in the US:
- **Neustar CNAM** (now TransUnion): the dominant registry queried by AT&T, Verizon, and most tier-1 carriers on incoming calls
- **iconectiv**: used by some regional carriers

When a call arrives, the terminating carrier performs a "CNAM dip" — it queries the registry using the calling number as a key and retrieves the name record. The submitting party for a number's CNAM must be the number's carrier (Amazon Connect's underlying carrier) or an authorized CNAM provisioning partner (Bandwidth, Neustar Direct, etc.).

CNAM records are limited to **15 characters** (including spaces) per NANPA CNAM standard. This is a hard constraint.

### Relationship to PRD-51 (Outbound Caller ID)

PRD-51 configures which Connect phone number is presented as the outbound caller ID for each routing profile — this is the `E.164 number` that recipients see. PRD-17 manages the `name` that recipients see alongside that number. These are completely separate concerns managed in completely separate systems. See PRD-51 Section 3 for the explicit non-goal statement.

---

## 4. GOALS

- Provide a CNAM provisioning service that submits name records for all claimed DIDs to the carrier CNAM registry via an authorized provisioning partner
- Support two CNAM policies: company-name CNAM (all numbers show the same company name) and employee-name CNAM (each DID shows the individual employee's name)
- Verify that CNAM records propagated correctly after submission (24–72 hour propagation window)
- Detect drift between desired CNAM and actual registered CNAM on a weekly schedule
- Support bulk provisioning for PBX deployments with large DID inventories
- Block CNAM registration for any number with an unresolved SPAM reputation flag (PRD-16 gate)

### Non-Goals

- This PRD does not configure which number Connect presents as outbound caller ID — that is PRD-51
- This PRD does not manage CNAM for toll-free numbers in the same way — toll-free CNAM is set differently (via the RespOrg) and has different character limits
- This PRD does not apply to international numbers — CNAM is a US/Canada NANPA feature; international caller name display is carrier-dependent and not standardized

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — CNAM Policy Configuration
The module must support two CNAM policies configured via `var.cnam_policy`:

| Policy | Value | Description |
|---|---|---|
| Company Name | `company` | All DIDs display `var.cnam_company_name` (max 15 chars) |
| Employee Name | `employee` | Each DID displays the name from `var.phone_numbers[key].cnam_name` (max 15 chars per entry) |

For employee-name policy, the `cnam_name` attribute must be added to the `phone_numbers` map object in PRD-11 v1.2.0 as an optional field.

### FR-002 — CNAM Provisioning Operations Lambda
A Lambda function (`{org_name}-cnam-provisioner-{environment}`) is the authoritative operator/API surface for CNAM submission workflows. It supports the following actions:

- `SUBMIT_NUMBERS`: submit CNAM for an explicit list of numbers already present in the inventory table
- `SUBMIT_PENDING`: submit all eligible inventory records currently in `PENDING` state
- `UPSERT_DESIRED_RECORDS`: create or update desired CNAM records for direct invocation or bulk import workflows
- `REQUEUE_NUMBERS`: move records in `FAILED` or `DRIFT_DETECTED` back to `PENDING` for controlled retry

For submission actions, the Lambda must:
1. Read the desired CNAM string and policy per number from the CNAM inventory table
2. Validate each CNAM string is <= 15 characters
3. Check the PRD-16 `CURRENT` reputation record for each number and block submission when the current record is missing, stale, or indicates the number should not proceed
4. Submit CNAM records to the configured provider API in batches of 50
5. Write submission result (status, HTTP response code, timestamp, request id) to the CNAM inventory table
6. Emit `CNAMSubmissionSuccess` and `CNAMSubmissionFailure` metrics

CNAM gate blocking reason codes in v1:

- `MISSING_REPUTATION_CURRENT`
- `REPUTATION_CHECK_STALE`
- `SPAM_LABEL_SPAM`
- `REPLACEMENT_REQUIRED`
- `PROVIDER_DATA_INCOMPLETE`

The gate reads the authoritative PRD-16 `CURRENT` record only and does not scan historical reputation records.

### FR-003 — CNAM Inventory Table
A DynamoDB table (`{org_name}-cnam-inventory-{environment}`, PAY_PER_REQUEST):

| Attribute | Type | Description |
|---|---|---|
| `phone_number` | String (PK) | E.164 number |
| `desired_cnam` | String | Desired CNAM string (max 15 chars) |
| `actual_cnam` | String | CNAM as verified by lookup (populated after verification) |
| `cnam_policy` | String | company / employee |
| `submission_status` | String | PENDING / SUBMITTED / VERIFIED / FAILED / DRIFT_DETECTED |
| `submission_date` | String | ISO 8601 timestamp |
| `last_verified_date` | String | ISO 8601 timestamp of last verification lookup |
| `provider` | String | CNAM provisioning provider used (bandwidth, neustar) |
| `error_message` | String | Provider error message if submission failed |
| `last_request_id` | String | Idempotency key of the last successful mutation request |
| `last_submission_http_status` | Number | Provider API HTTP status code from the most recent submission attempt |
| `reputation_gate_reason` | String | Machine-readable PRD-16 gate reason when a submission is blocked |

Operator workflows must not discover records of interest by scanning the full table. The module must include a sparse GSI for status-driven operations:

- `status_scope = <submission_status>` on active records
- GSI partition key: `status_scope`
- GSI sort key: `phone_number`

The module must also define allowed status transitions:

- `PENDING -> SUBMITTED`
- `PENDING -> FAILED`
- `SUBMITTED -> VERIFIED`
- `SUBMITTED -> DRIFT_DETECTED`
- `SUBMITTED -> FAILED`
- `FAILED -> PENDING`
- `DRIFT_DETECTED -> PENDING`

### FR-004 — CNAM Verification Lambda
A Lambda function (`{org_name}-cnam-verifier-{environment}`) verifies registered CNAM against desired state. It supports:

- on-demand operator/CLI invocation for explicit numbers
- optional weekly EventBridge scheduling for continuous drift detection

For verification runs, the Lambda:
1. Reads numbers in the CNAM inventory table with `submission_status = SUBMITTED` or `VERIFIED`
2. Queries the CNAM lookup API to retrieve the currently registered CNAM
3. Compares actual CNAM to desired CNAM
4. If they match: sets `submission_status = VERIFIED`, updates `last_verified_date`
5. If they differ: sets `submission_status = DRIFT_DETECTED`, emits `CNAMDriftDetected` metric
6. CNAM propagation takes 24–72 hours after submission; numbers submitted within the last 72 hours are skipped in the drift check

### FR-005 — Bulk Import for PBX Scale
For deployments with large DID inventories, the Lambda must accept a CSV payload (via direct invocation or optional S3 trigger) in the format:

```
+12125550100,ACME CORP
+12125550101,J SMITH
+12125550102,SALES DEPT
```

The Lambda processes the CSV by invoking `UPSERT_DESIRED_RECORDS` semantics against the CNAM inventory table. The CI/CD pipeline includes a pre-apply step that validates all CNAM strings in the inventory are <= 15 characters.

### FR-006 — Terraform-Managed CNAM Records
For small deployments (company-name policy or employee-name policy with <20 numbers), CNAM records are managed as Terraform variables, not CSV bulk import. The `phone_numbers` map in environment tfvars includes an optional `cnam_name` field. Terraform is responsible for defining the desired inventory state; CNAM submission itself is an explicit CLI/pipeline action and must not be hidden behind `null_resource` apply-time side effects.

### FR-007 — Request Contract and Idempotency
Mutating PRD-17 operations must include:

- `request_id`
- `operator_identity`
- `operation`

`UPSERT_DESIRED_RECORDS`, `SUBMIT_NUMBERS`, `SUBMIT_PENDING`, and `REQUEUE_NUMBERS` must be idempotent by `request_id`. Repeated requests with the same `request_id` must not produce duplicate provider submissions.

---

## 6. ARCHITECTURE

```
Terraform-managed desired inventory OR
Manual / CI Lambda invocation (RB-11-06) OR
Optional S3 CSV upload (bulk import trigger)
        ↓
  {org}-cnam-provisioner-{env} (Lambda)
        ├── PRD-16 CURRENT reputation record check (gate)
        ├── CNAM string validation (≤15 chars)
        ├── Provider API (Bandwidth / Neustar CNAM)
        │     └── Submit CNAM record per number
        └── DynamoDB PutItem / UpdateItem → {org}-cnam-inventory-{env}
                                        ↓
                              DynamoDB GSI query by status
                                        ↓
                              CloudWatch metrics

Optional EventBridge Schedule (weekly, Wed 07:00 UTC)
        ↓
  {org}-cnam-verifier-{env} (Lambda)
        ├── CNAM Lookup API (verify actual CNAM)
        └── DynamoDB UpdateItem → submission_status
                                        ↓
                              CNAMDriftDetected metric
                              → PRD-81 ALARM-17-02
```

---

## 7. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-cnam-registry/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── backend.tf
        └── lambda/
            ├── cnam_provisioner.py
            └── cnam_verifier.py
```

### Key Variables

```hcl
variable "cnam_policy" {
  type        = string
  default     = "company"
  description = "CNAM policy. 'company' applies cnam_company_name to all DIDs. 'employee' uses per-number cnam_name from phone_numbers map."
  validation {
    condition     = contains(["company", "employee"], var.cnam_policy)
    error_message = "cnam_policy must be company or employee."
  }
}

variable "cnam_company_name" {
  type        = string
  description = "Company name for CNAM (max 15 characters). Used when cnam_policy = company."
  validation {
    condition     = length(var.cnam_company_name) <= 15
    error_message = "cnam_company_name must be 15 characters or fewer (NANPA CNAM standard)."
  }
}

variable "cnam_provider" {
  type        = string
  default     = "bandwidth"
  description = "CNAM provisioning provider. Options: bandwidth, neustar."
  validation {
    condition     = contains(["bandwidth", "neustar"], var.cnam_provider)
    error_message = "cnam_provider must be bandwidth or neustar."
  }
}

variable "cnam_provider_secret_arn" {
  type        = string
  description = "ARN of Secrets Manager secret containing CNAM provider API credentials."
}

variable "reputation_table_name" {
  type        = string
  description = "PRD-16 DynamoDB reputation table name. Used for spam gate check before CNAM submission."
}

variable "enable_weekly_verification_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional weekly EventBridge schedule for CNAM verification."
}

variable "enable_submission_failure_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-17-01."
}

variable "enable_drift_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-17-02."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs. Empty list means alarms may exist without external actions."
}
```

### outputs.tf

```hcl
output "cnam_inventory_table_name" {
  description = "CNAM inventory DynamoDB table name."
  value       = aws_dynamodb_table.cnam_inventory.name
}

output "cnam_status_gsi_name" {
  description = "Sparse GSI exposing inventory records by submission status for operator workflows."
  value       = "status-by-scope"
}

output "cnam_provisioner_lambda_arn" {
  description = "CNAM provisioner Lambda ARN. Invoked on-demand after number claiming or porting."
  value       = aws_lambda_function.cnam_provisioner.arn
}

output "cnam_verifier_lambda_arn" {
  description = "CNAM verifier Lambda ARN. Invoked on-demand or by optional schedule."
  value       = aws_lambda_function.cnam_verifier.arn
}
```

---

## 8. COST MODEL

CNAM registry fees are not managed by Terraform but must be accounted for in the PRD-83 FinOps dashboard. Costs are per-number per-month from the provisioning provider, plus per-dip fees charged to terminating carriers (not directly billed to the platform).

| Provider | Registration Fee | Per-Dip Fee (to terminating carrier) |
|---|---|---|
| Bandwidth CNAM | ~$0.002–$0.005/number/month | Billed to terminating carrier |
| Neustar Direct | ~$0.003–$0.006/number/month | Billed to terminating carrier |

At 100 DIDs: approximately $0.20–$0.60/month for registry fees. At 500 DIDs: approximately $1.00–$3.00/month. Negligible at PBX scale but should appear in the PRD-83 cost breakdown.

---

## 9. ALARMS

**ALARM-17-01: CNAM Submission Failure Rate**
- Metric: `ConnectPBX/{environment}/CNAMSubmissionFailure`
- Threshold: >= 3 failures in 10 minutes
- Action: configured `alarm_action_arns` when supplied
- Severity: Medium

**ALARM-17-02: CNAM Drift Detected**
- Metric: `ConnectPBX/{environment}/CNAMDriftDetected`
- Threshold: >= 1
- Action: configured `alarm_action_arns` when supplied
- Severity: Medium — actual caller name display does not match desired

Both alarms consolidated in PRD-81.

---

## 10. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-17-01 | Company-name CNAM submitted successfully for a newly claimed DID | Invoke `SUBMIT_NUMBERS`; verify CNAM inventory table shows SUBMITTED status; verify with CNAM lookup after 72 hours |
| AC-17-02 | Employee-name CNAM submitted for each DID when cnam_policy = employee | Set cnam_policy=employee with per-number cnam_name, sync desired inventory, invoke `SUBMIT_PENDING`; verify each number has individual CNAM record |
| AC-17-03 | Provisioner rejects CNAM strings > 15 characters | Pass 16-char CNAM string; verify Lambda returns validation error, no submission made |
| AC-17-04 | Provisioner blocks numbers whose PRD-16 `CURRENT` record is not submission-eligible | Insert or update `CURRENT` records representing SPAM, stale, and missing-current cases; verify provisioner skips those numbers and returns machine-readable gate reasons |
| AC-17-05 | ALARM-17-02 fires when CNAM drift detected | Manually change CNAM at provider to a different string; run verifier Lambda; verify alarm |
| AC-17-06 | Bulk CSV import processes >50 numbers correctly | Upload or invoke with a 60-number CSV payload; verify all records appear in CNAM inventory table |
| AC-17-07 | Operator workflows can query status cohorts without scanning the full table | Query the sparse GSI for `status_scope = FAILED` and `status_scope = DRIFT_DETECTED`; verify only matching records are returned |
| AC-17-08 | Mutating operations are idempotent by `request_id` | Re-submit the same `SUBMIT_NUMBERS` or `REQUEUE_NUMBERS` request twice; verify provider submission is not duplicated |
| AC-17-09 | checkov passes with zero HIGH/CRITICAL findings | `checkov -d modules/l1-cnam-registry/` |

---

## 11. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-22 | — | Initial release. Covers both company-name and employee-name CNAM policies for contact center and PBX deployment profiles. Includes PRD-16 spam reputation gate and PRD-83 cost model reference. |
| 1.1.0 | 2026-03-30 | Codex | Readiness pass: made CNAM operations CLI-first and idempotent, removed apply-time `null_resource` submission assumptions, defined PRD-16 current-record gate reasons, added status-query GSI, and aligned alarms/module metadata with the capability-pack model. |
| 1.2.0 | 2026-04-05 | Codex | Governance normalization. Promoted catalog metadata from recommended to mandatory. Added Module Governance section with shared sink behavior, destroy posture, and control plane statement. |
