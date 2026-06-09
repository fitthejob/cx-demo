# PRD-16 — Spam Reputation & STIR/SHAKEN Monitoring

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-16 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-11 (phone number inventory) |
| **Blocks** | PRD-17 (spam check is a gate before CNAM registration), PRD-81 (alarm consolidation) |
| **Optional** | Optional feature. Strongly recommended for PBX deployments that assign individual DIDs; lower priority for pure contact center deployments where all outbound is agent-initiated and numbers are published proactively. |

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
| `path` | `modules/l1-spam-reputation` |
| `capability_packs` | `["number-governance"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers"]` |
| `state_key` | `l1-spam-reputation/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `spam-reputation.tfvars` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Alarm topic is optional input via `alarm_action_arns`. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `destroyable` |
| `retention_notes` | History records have TTL; no manual retention boundary. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Newly claimed Amazon Connect DID numbers are drawn from AWS's telephony pool. AWS does not certify the reputation history of reclaimed numbers — a number that was previously used for robocalling, debt collection, or telemarketing spam may carry that history in third-party reputation databases long after the original holder released it.

For a **contact center** deployment, this matters moderately: outbound agent calls are expected by recipients, and a "Scam Likely" label is a negative signal that can be overcome by agent identification. For a **PBX deployment** where employees use Connect DIDs as their direct-dial business lines, this is a material problem. When an executive calls a client and the recipient's iPhone displays "Spam Risk" or "Scam Likely," it is professionally damaging and potentially affects business outcomes. At scale, hundreds of employee DIDs must each be individually verified before assignment.

STIR/SHAKEN (Secure Telephone Identity Revisited / Signature-based Handling of Asserted Information Using toKENs) is the FCC-mandated call authentication framework (47 CFR Part 64, effective June 2021). Amazon Connect is STIR/SHAKEN compliant and signs outbound calls. However:

- Numbers ported into Connect from carriers that provided B or C attestation may carry lower attestation in the SHAKEN certificate database until the new ownership propagates (typically 24–72 hours post-port)
- Attestation level A (full attestation) means the originating carrier (AWS) fully vouches for the calling number and the call's origin — this is what terminating carriers use to decide whether to display "Verified Caller" indicators
- If a number's attestation drops below A (possible due to database propagation delay or mis-configuration), terminating carriers may apply spam risk scores

This PRD implements a monitoring and remediation service for both concerns.

### Reputation Databases Covered

| Database | Operator | Consumer Impact |
|---|---|---|
| Hiya Insights | Hiya Inc. | iOS Siri, Samsung, various MVNO default dialers |
| First Orion / CNAM+ | First Orion | T-Mobile (default spam detection), Metro PCS |
| YouMail Robocall Index | YouMail Inc. | Various third-party dialer apps |
| TNS Call Guardian | Transaction Network Services | AT&T default spam detection |
| Nomorobo | Nomorobo LLC | VOIP.ms, various landline providers |

---

## 4. GOALS

- Check the spam reputation of all claimed DIDs against major reputation databases after claiming and on a weekly schedule
- Surface numbers that exceed a configurable spam risk threshold before they are assigned to employee direct-dial use
- Track STIR/SHAKEN attestation level per number and alert when attestation drops below A
- Provide a structured remediation path for flagged numbers (dispute submission or number replacement)
- Block CNAM registration (PRD-17) for any number with unresolved spam flags above threshold

### Non-Goals

- This PRD does not manage CNAM records — that is PRD-17
- This PRD does not prevent outbound calls from spam-flagged numbers — it monitors and alerts; call blocking is a policy decision
- This PRD does not manage STIR/SHAKEN signing configuration — Amazon Connect handles signing at the carrier layer automatically

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Reputation Operations Lambda
A Lambda function (`{org_name}-spam-reputation-check-{environment}`) is the authoritative operator/API surface for spam reputation checks. It supports the following invocation modes:

- `CHECK_NUMBERS`: accepts an explicit list of E.164 numbers supplied by an operator or pipeline
- `CHECK_INVENTORY`: resolves the currently managed number inventory from PRD-11 and checks all eligible numbers without requiring an explicit list
- `VALIDATE_ASSIGNMENT_ELIGIBILITY`: reads the authoritative `CURRENT` record for one or more numbers and returns eligibility status plus machine-readable reason codes without mutating state

For `CHECK_NUMBERS` and `CHECK_INVENTORY`, the Lambda must for each number:
1. Queries configured reputation providers (Hiya Score API, First Orion Number Intelligence, TNS Call Guardian) in priority order
2. Aggregates results into a composite spam score (0–100) using a configurable weighting
3. Assigns a spam label: `CLEAN` (0–29), `RISK` (30–69), `SPAM` (70–100)
4. Writes the result to the reputation DynamoDB table as both an immutable history record and an updated authoritative `CURRENT` record
5. Returns the results in the Lambda response payload

Operator- and pipeline-driven invocation is the authoritative execution path. An EventBridge weekly schedule is an optional enhancement for teams that want continuous monitoring, but the module must remain deployable with scheduled scans disabled.

### FR-002 — Reputation Inventory Table
A DynamoDB table (`{org_name}-number-reputation-{environment}`, PAY_PER_REQUEST) stores both immutable historical check records and a single authoritative `CURRENT` record per number. The module must support the following contract:

- History record: `phone_number = <E.164>`, `check_date = <ISO8601 timestamp>`
- Current record: `phone_number = <E.164>`, `check_date = CURRENT`

Downstream modules such as PRD-17 must read only the `CURRENT` record and must not scan historical records to infer current reputation state.

Current-state operator workflows must not scan the full table to discover active reputation state. The module must include a sparse GSI that exposes only `CURRENT` records:

- `record_scope = CURRENT` on authoritative current records only
- GSI partition key: `record_scope`
- GSI sort key: `phone_number`

| Attribute | Type | Description |
|---|---|---|
| `phone_number` | String (PK) | E.164 number |
| `check_date` | String (SK) | ISO 8601 timestamp for history records, or `CURRENT` for the authoritative current record |
| `record_scope` | String | `CURRENT` for authoritative current records; omitted on history records |
| `spam_score` | Number | 0–100 composite score |
| `spam_label` | String | CLEAN / RISK / SPAM |
| `hiya_score` | Number | Raw Hiya score (null if unavailable) |
| `first_orion_score` | Number | Raw First Orion score (null if unavailable) |
| `tns_score` | Number | Raw TNS score (null if unavailable) |
| `stir_shaken_attestation` | String | A / B / C / UNKNOWN |
| `attestation_check_date` | String | ISO 8601 timestamp of last attestation check |
| `remediation_status` | String | NONE / DISPUTE_SUBMITTED / REPLACEMENT_REQUIRED / REPLACED |
| `dispute_submitted_date` | String | ISO 8601 date if dispute submitted |
| `assigned_to` | String | Employee/purpose key from phone_numbers tfvars (null if unassigned) |
| `current_ref` | String | For `CURRENT` records, the immutable history record key this state was derived from |

TTL: 365 days on immutable history records only. The `CURRENT` record is not TTL-managed.

### FR-003 — Assignment Gate
A number may not be added to the `phone_numbers` variable as a PBX employee DID unless its `CURRENT` reputation record is assignment-eligible. The eligibility check is performed by invoking `VALIDATE_ASSIGNMENT_ELIGIBILITY` on the PRD-16 operations Lambda. That action reads only the `CURRENT` record and returns `ELIGIBLE` or `NOT_ELIGIBLE` with machine-readable reason codes.

Hard-blocking reason codes in v1:

- `MISSING_CURRENT_RECORD`
- `REPUTATION_CHECK_STALE`
- `SPAM_LABEL_RISK`
- `SPAM_LABEL_SPAM`
- `REMEDIATION_IN_PROGRESS`
- `REPLACEMENT_REQUIRED`
- `PROVIDER_DATA_INCOMPLETE`

Attestation degradation does not by itself block assignment in v1; it is surfaced as an operator warning because newly claimed or recently ported numbers may temporarily report B/C attestation during propagation windows.

The gate is enforced procedurally (runbook RB-11-05) and by a CI/CD pre-apply invocation of `VALIDATE_ASSIGNMENT_ELIGIBILITY`. A Terraform `precondition` is not technically feasible for this check because it depends on external state.

### FR-004 — STIR/SHAKEN Attestation Monitoring
A separate Lambda function (`{org_name}-stir-shaken-check-{environment}`) performs periodic STIR/SHAKEN attestation verification:
1. Places a test call from the Connect instance to a verification endpoint (a dedicated test DID or a third-party verification service)
2. The verification endpoint captures the PASSporT token from the SIP IDENTITY header and returns the attestation level
3. The attestation level is written to the reputation table for the originating number
4. If attestation is B or C, the Lambda publishes `STIRSHAKENAttestationDegraded` metric and updates the `CURRENT` record for the number

This check may be run on-demand by operators and may also be wired to an optional weekly schedule. Note: attestation-level testing requires a third-party verification service with SIP header inspection capability (e.g., TransNexus STIR/SHAKEN Analytics, Bandwidth Verification).

### FR-005 — Batch Processing for PBX Scale
When the number inventory exceeds 50 numbers, the reputation check Lambda must process numbers in batches of 50 with 100ms delay between batches to respect third-party API rate limits. The Lambda emits `ReputationBatchProgress` (count of numbers checked) and `ReputationBatchErrors` (count of API failures) metrics during bulk scans.

### FR-006 — Remediation State Mutation Contract
Operator-initiated changes to `remediation_status` must go through a guarded mutation action on the PRD-16 operations Lambda rather than direct DynamoDB writes from the runbook. The action contract is:

- `operation = RECORD_REMEDIATION_ACTION`
- required inputs: `phone_number`, `target_status`, `operator_identity`, `request_id`
- optional inputs: `provider`, `ticket_ref`, `notes`, `effective_date`

Allowed status transitions in v1:

- `NONE -> DISPUTE_SUBMITTED`
- `DISPUTE_SUBMITTED -> NONE`
- `NONE -> REPLACEMENT_REQUIRED`
- `DISPUTE_SUBMITTED -> REPLACEMENT_REQUIRED`
- `REPLACEMENT_REQUIRED -> REPLACED`

The Lambda must reject invalid transitions and return machine-readable reason codes.

---

## 6. ARCHITECTURE

```
Operator CLI / CI invoke
        ↓
  {org}-spam-reputation-check-{env} (Lambda: CHECK_NUMBERS / CHECK_INVENTORY / VALIDATE_ASSIGNMENT_ELIGIBILITY / RECORD_REMEDIATION_ACTION)
        ├── Hiya Score API
        ├── First Orion Number Intelligence API
        ├── TNS Call Guardian API
        ├── Score aggregation (configurable weights)
        ├── DynamoDB PutItem → immutable history record
        └── DynamoDB PutItem → CURRENT record
                                        ↓
                              DynamoDB GSI query → CURRENT records only
                                        ↓
                              CloudWatch PutMetricData
                              → NumbersWithHighSpamRisk
                              → NumbersClean
                              → NumbersNeedingRemediation
                                        ↓
                              PRD-81 ALARM-16-01, ALARM-16-02

Optional EventBridge Schedule (weekly)
        ↓
  {org}-stir-shaken-check-{env} (Lambda)
        ├── Connect outbound test call
        ├── Third-party SIP attestation endpoint
        └── DynamoDB UpdateItem → CURRENT + latest history record
                                        ↓
                              CloudWatch PutMetricData
                              → STIRSHAKENAttestationDegraded
                                        ↓
                              PRD-81 ALARM-16-02
```

---

## 7. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-spam-reputation/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── backend.tf
        └── lambda/
            ├── reputation_check.py
            └── stir_shaken_check.py
```

### Key Variables

```hcl
variable "spam_threshold_risk" {
  type        = number
  default     = 30
  description = "Spam score at or above which a number is labeled RISK (0-100)."
}

variable "spam_threshold_spam" {
  type        = number
  default     = 70
  description = "Spam score at or above which a number is labeled SPAM and ALARM-16-01 fires (0-100)."
}

variable "reputation_providers" {
  type    = list(string)
  default = ["hiya", "first_orion"]
  description = "Ordered list of reputation providers to query. First available provider result is primary."
  validation {
    condition = alltrue([
      for p in var.reputation_providers :
      contains(["hiya", "first_orion", "tns"], p)
    ])
    error_message = "reputation_providers entries must be hiya, first_orion, or tns."
  }
}

variable "reputation_api_secrets" {
  type        = map(string)
  description = "Map of provider name to Secrets Manager secret ARN containing API credentials."
}

variable "enable_weekly_reputation_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional weekly EventBridge schedule for inventory-wide reputation checks."
}

variable "enable_weekly_attestation_schedule" {
  type        = bool
  default     = false
  description = "When true, create the optional weekly EventBridge schedule for STIR/SHAKEN attestation checks."
}

variable "enable_high_spam_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-16-01 for current records with spam_label=SPAM."
}

variable "enable_attestation_alarm" {
  type        = bool
  default     = true
  description = "When true, create ALARM-16-02 for degraded attestation signals."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs. Empty list means alarms may exist without external actions."
}
```

### Outputs

```hcl
output "reputation_table_name" {
  description = "DynamoDB reputation table name. Read by PRD-17 CNAM assignment gate and RB-11-05."
  value       = aws_dynamodb_table.reputation.name
}

output "current_records_gsi_name" {
  description = "Name of the sparse GSI that exposes only CURRENT records for operator workflows."
  value       = "current-by-scope"
}

output "reputation_operations_lambda_arn" {
  description = "Reputation operations Lambda ARN. Invoked on-demand after new numbers are claimed and for assignment gate / remediation actions."
  value       = aws_lambda_function.reputation_check.arn
}
```

---

## 8. ALARMS

**ALARM-16-01: High Spam Risk Number in Inventory**
- Metric: `ConnectPBX/{environment}/NumbersWithHighSpamRisk`
- Threshold: >= 1
- Action: configured `alarm_action_arns` when supplied
- Severity: High for PBX deployments (employee DID affected); Medium for contact center only
- Note: Any number with `spam_label = SPAM` triggers this alarm. `RISK` numbers are logged but do not trigger the alarm by default (configurable via `alarm_on_risk_label` variable).

**ALARM-16-02: STIR/SHAKEN Attestation Degraded**
- Metric: `ConnectPBX/{environment}/STIRSHAKENAttestationDegraded`
- Threshold: >= 1
- Action: configured `alarm_action_arns` when supplied
- Severity: Medium — calls may be flagged as unverified by terminating carriers

Both alarms consolidated in PRD-81.

---

## 9. REMEDIATION PATHS

### Path A: Dispute (spam_label = RISK, score 30–69)

1. Navigate to the Hiya Business Portal (`hiya.com/business`) and submit a business verification request for the flagged number
2. For First Orion: contact First Orion via their business registration portal
3. Record `remediation_status = DISPUTE_SUBMITTED` through the guarded `RECORD_REMEDIATION_ACTION` Lambda contract
4. Re-run the reputation check Lambda after 14 days — most disputes resolve within 7–14 days
5. If score does not improve after 30 days, escalate to Path B

### Path B: Number Replacement (spam_label = SPAM, score >= 70)

1. Record `remediation_status = REPLACEMENT_REQUIRED` through the guarded `RECORD_REMEDIATION_ACTION` Lambda contract
2. Execute the two-step number release procedure (RB-11-01 Section "Removing a Number")
3. Claim a replacement number via tfvars (RB-11-01)
4. Immediately invoke the reputation check Lambda on the new number before assigning to any employee DID
5. Update the phone-numbers tfvars with the replacement number entry
6. Trigger PRD-17 CNAM re-registration for the replacement number (RB-11-06)

---

## 10. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-16-01 | Reputation check Lambda returns spam_label for each number | Invoke with test numbers of known reputation; verify DynamoDB record |
| AC-16-02 | ALARM-16-01 fires when a number exceeds spam threshold | Insert a test record with spam_label=SPAM; verify alarm transitions to ALARM state |
| AC-16-03 | Inventory-wide reputation scan covers all managed numbers when invoked in `CHECK_INVENTORY` mode | Invoke the Lambda in `CHECK_INVENTORY` mode; verify all numbers in phone_numbers tfvars appear in the scan output |
| AC-16-04 | Batch processing handles >50 numbers without API rate limit errors | Load 60+ test numbers into inventory; verify scan completes without throttling errors |
| AC-16-05 | STIR/SHAKEN check records attestation level | Invoke stir_shaken_check Lambda; verify attestation field populated in reputation table |
| AC-16-06 | `VALIDATE_ASSIGNMENT_ELIGIBILITY` returns machine-readable reason codes based only on `CURRENT` record state | Invoke the Lambda for numbers with stale, RISK, and CLEAN current records; verify `ELIGIBLE` / `NOT_ELIGIBLE` output and reason codes |
| AC-16-07 | Operator workflows can read current state without scanning the history table | Query the sparse GSI for `record_scope = CURRENT`; verify only authoritative current records are returned |
| AC-16-08 | Remediation state mutation rejects invalid transitions | Invoke `RECORD_REMEDIATION_ACTION` with invalid status transitions; verify request is rejected with reason code |
| AC-16-09 | checkov passes with zero HIGH/CRITICAL findings | `checkov -d modules/l1-spam-reputation/` |

---

## 11. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-22 | — | Initial release. Covers spam reputation monitoring for both contact center and PBX deployment profiles, and STIR/SHAKEN attestation level tracking. |
| 1.1.0 | 2026-03-30 | Codex | Readiness pass: made operator/API contract implementation-defining, added `CURRENT`-records GSI requirement, defined assignment eligibility reason codes, made schedules optional, and replaced direct remediation-table mutation with a guarded Lambda contract. |
| 1.2.0 | 2026-04-05 | Codex | Governance normalization. Promoted catalog metadata from recommended to mandatory. Added Module Governance section with shared sink behavior, destroy posture, and control plane statement. |
