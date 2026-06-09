# PRD-15 — Number Portability Verification

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-15 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-11 (number inventory format and import procedure), PRD-40 (Lambda baseline) |
| **Blocks** | PRD-90 v1.0.0 (LOA submission gate depends on PRD-15 current eligibility state) |
| **Optional** | No — required before any LOA submission |

---

## 2. MODULE GOVERNANCE

### Module Classification

| Field | Value |
|---|---|
| `classification` | `migration-only` |
| `minimum_deployment_profile` | `migration-program` |
| `can_be_omitted_from_bare_bones` | `yes` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |

### Catalog Entry

| Field | Value |
|---|---|
| `path` | `modules/l1-number-portability-check` |
| `capability_packs` | `["migration"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers"]` |
| `state_key` | `l1-number-portability-check/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `portability.tfvars` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Not consumed. PRD-15 does not depend on audit or alarm sinks. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `destroyable` |
| `retention_notes` | Portability check results are ephemeral. DynamoDB audit table uses TTL. Module can be safely destroyed after migration completes. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

A porting request (LOA) submitted to AWS without verifying that the number is eligible to port is a common and costly mistake. When a porting attempt fails, the FOC date is missed, the client's migration timeline slips 2–4 weeks, and the LOA process restarts from scratch. Numbers can fail porting for several reasons that are discoverable in advance:

- **Wrong losing carrier identified** — the business believes their numbers are on RingCentral but those numbers are actually on the underlying carrier (Lumen, Bandwidth, Zayo) that RingCentral resells
- **Number on a porting freeze** — carriers place temporary porting freezes on numbers involved in disputes or active contracts
- **VoIP number masquerading as POTS** — some VoIP-hosted numbers cannot be ported to Amazon Connect because they are not in the NANPA DID inventory; Connect only accepts true POTS DIDs and RespOrg toll-free transfers
- **Number in a do-not-port registry** — regulatory holds or court orders
- **RespOrg mismatch for toll-free** — toll-free numbers have a separate porting authority (Responsible Organization / RespOrg); the current RespOrg must initiate the transfer

This PRD provisions a pre-LOA verification service that performs a structured portability audit for each number before it advances to LOA submission in the porting state machine (PRD-90).

### System-Level Purpose

PRD-15 is the platform's **pre-port validation and eligibility gate**. It does not manage live routing and it does not submit LOAs. At the system level, it provides:

- a Lambda-invocable portability verification service
- a single authoritative current eligibility state per number
- immutable historical audit records per check or override
- a machine-readable contract that PRD-90 can enforce before allowing `LOA_SUBMITTED`

### Integration with PRD-90

PRD-90 (Migration State, Layer 9) tracks migration workflow state. PRD-15 is the **single source of truth** for portability eligibility. PRD-90 must read PRD-15's current record for a number when deciding whether a transition to `LOA_SUBMITTED` is allowed.

PRD-90 must **not** maintain an independent, conflicting portability truth model. It may cache or echo state for display if needed, but the authoritative decision comes from PRD-15.

---

## 4. GOALS

- Perform structured pre-LOA portability verification for every number in a porting request
- Persist both the **current authoritative eligibility state** and **historical audit records** in one DynamoDB table
- Support DID/POTS numbers and toll-free numbers via separate verification paths under one service
- Provide a Lambda-invocable verification function usable both on-demand and via the PRD-90 state machine
- Surface the losing carrier identity for each number — required for accurate LOA completion
- Support explicit operator overrides with guardrails and audit logging

### Non-Goals

- This PRD does not submit LOAs — that is a manual process via the AWS Connect console (see RB-11-02 and PRD-90)
- This PRD does not perform spam reputation checks — that is PRD-16
- This PRD does not manage the porting workflow state machine — that is PRD-90
- This PRD does not guarantee that a number marked `ELIGIBLE` will successfully port — eligibility is a pre-condition, not a guarantee
- This PRD does not require scheduled rechecks in v1 — checks are on-demand, and freshness is enforced at read time

---

## 5. ARCHITECTURE DECISIONS

### 4.1 PRD-15 Owns The Authoritative Eligibility State

PRD-15 owns:

- the provider lookup
- eligibility evaluation
- current effective status
- historical audit trail
- operator override records

PRD-90 consumes PRD-15 state. It must not define a second, independent portability truth.

### 4.2 One DynamoDB Table, Two Record Types

PRD-15 uses one DynamoDB table with:

- one **current** record per phone number
- many immutable **history** records per phone number

Recommended key shape:

- `PK = phone_number`
- `SK = CURRENT`
- `SK = CHECK#<ISO8601 timestamp>`
- `SK = OVERRIDE#<ISO8601 timestamp>`

This keeps:

- current state easy to fetch with `GetItem`
- history in the same table
- no second table required

### 4.3 No Scheduler Required In v1

PRD-15 does not need a periodic Lambda schedule in v1. Freshness is enforced when a consumer reads the current state.

The check flow is:

1. Operator or PRD-90 invokes PRD-15
2. PRD-15 writes one history record and updates the `CURRENT` record
3. PRD-90 reads `CURRENT`
4. If the record is older than `check_expiry_days`, PRD-90 rejects advancement and treats the state as expired

### 4.4 Providers In v1

Supported providers in v1:

- `mock`
- `bandwidth`

Future-compatible provider names may remain in design notes, but v1 only claims implementation support for `mock` and `bandwidth`.

### 4.5 Split DID And Toll-Free Lookup Paths

PRD-15 remains one service, but internally the provider interface must expose separate operations for:

- DID portability lookup
- toll-free / RespOrg lookup

These are different telecom workflows and should not be forced into a single provider call contract.

### 4.6 Toll-Free In v1

v1 fully automates the DID path.

For toll-free numbers, v1 may return `MANUAL_VERIFICATION_REQUIRED` if automated RespOrg lookup is not cleanly available through the selected provider. This is acceptable and preferable to claiming false automation support.

### 4.7 Operator Override Is Supported

PRD-15 must support operator override with guardrails, logging, and immutable audit records. Raw provider output must never be silently overwritten.

### 4.8 Explicit Status Model

PRD-15 uses explicit statuses, not a simple boolean.

Persisted fields:

- `provider_status`
- `effective_status`

Allowed status values:

- `ELIGIBLE`
- `INELIGIBLE`
- `MANUAL_VERIFICATION_REQUIRED`
- `CHECK_FAILED`

`EXPIRED` is not persisted by background mutation in v1. Expiry is computed on read from timestamps and `check_expiry_days`.

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Portability Check Lambda

A Lambda function (`{org_name}-number-portability-check-{environment}`) must accept one or more E.164 numbers and for each number:

1. Determine whether the number is:
   - DID/POTS path
   - toll-free / RespOrg path
2. Execute the correct provider operation for the selected provider
3. Normalize the provider result into the PRD-15 status contract
4. Evaluate Connect portability eligibility rules (see FR-004)
5. Write:
   - one immutable history record (`CHECK#...`)
   - one updated current record (`CURRENT`)
6. Return the result payload to the caller

The Lambda runs in AWS. Operators may invoke it from local CLI, CloudShell, or a downstream service, but the lookup itself executes in Lambda.

### FR-002 — Provider Interface

The Lambda must abstract the lookup provider behind two internal operations:

- `lookup_did_portability(number)`
- `lookup_tollfree_resporg(number)`

v1 provider implementations:

- `mock`
- `bandwidth`

The active provider is selected via environment variable `LOOKUP_PROVIDER`.

### FR-003 — Provider Secret Contract

Each real provider has one Secrets Manager secret containing all credentials/config needed for both DID and toll-free operations for that provider.

v1 secret contract:

- one secret per active provider
- `mock` does not require a real secret
- `bandwidth` requires one secret

The PRD must document the secret JSON schema explicitly in implementation notes. Example fields may include:

- `api_key`
- `api_secret` or token
- `base_url`
- provider-specific toll-free lookup config if applicable

The Lambda must fail with `CHECK_FAILED` if:

- the configured provider requires a secret and it is missing
- the secret is malformed
- the provider credentials are rejected

### FR-004 — Eligibility Evaluation

A provider result is normalized into an eligibility decision.

#### DID path

A DID number is `ELIGIBLE` only if all of the following are true:

| Condition | Eligible | Ineligible |
|---|---|---|
| Line type | POTS / DID | VOIP, MOBILE, UNKNOWN |
| Porting freeze | False | True |
| OCN identifiable | True | False |

#### Toll-free path

A toll-free number is `ELIGIBLE` only if all of the following are true:

| Condition | Eligible | Ineligible |
|---|---|---|
| Line type | TOLL_FREE | UNKNOWN or non-toll-free |
| RespOrg identified | True | False |
| Porting freeze | False | True |

If the selected provider cannot determine toll-free eligibility automatically in v1, the result must be:

- `provider_status = MANUAL_VERIFICATION_REQUIRED`
- `effective_status = MANUAL_VERIFICATION_REQUIRED`

### FR-005 — Explicit Status Fields

Each result must include:

| Field | Description |
|---|---|
| `provider_status` | Raw normalized result from provider processing |
| `effective_status` | Authoritative status after applying any override logic |
| `checked_at` | ISO 8601 timestamp of provider check |
| `expires_at` | Computed expiration timestamp derived from `checked_at + check_expiry_days` |
| `ineligibility_reason` | Human-readable reason when not eligible |
| `losing_carrier_name` | Carrier name if known |
| `ocn` | OCN if known |
| `line_type` | POTS / VOIP / TOLL_FREE / MOBILE / UNKNOWN |
| `resp_org` | Toll-free only |
| `porting_freeze` | Boolean or null if unknown |
| `verified_by` | Lambda ARN for checks, operator identity for overrides |

### FR-006 — Current Record

The table must maintain one `CURRENT` item per number containing the latest authoritative state.

The `CURRENT` item must include:

- `provider_status`
- `effective_status`
- `checked_at`
- `expires_at`
- `effective_source` (`PROVIDER` or `OPERATOR_OVERRIDE`)
- latest carrier/line type fields
- override metadata if applicable

PRD-90 must read only the `CURRENT` item when enforcing eligibility.

### FR-007 — Immutable History

Each check invocation must write an immutable `CHECK#<timestamp>` history record.

Each operator override must write an immutable `OVERRIDE#<timestamp>` history record.

History records must preserve the raw provider-derived result, even if the current effective state later changes.

### FR-008 — Operator Override

PRD-15 must provide an explicit operator override action that can set the effective state for a number.

Override guardrails:

- requires operator identity
- requires reason code
- requires free-text justification
- writes immutable override history
- updates `CURRENT`
- never deletes or mutates prior check history

Suggested reason codes:

- `TF_RESPORG_VERIFIED_MANUALLY`
- `CARRIER_CONFIRMED_ELIGIBLE`
- `CARRIER_CONFIRMED_INELIGIBLE`
- `PROVIDER_RESULT_DISPUTED`
- `TEMPORARY_PROVIDER_LIMITATION`

Override metadata on `CURRENT`:

- `override_reason_code`
- `override_justification`
- `override_by`
- `override_at`
- optional `override_review_by`

### FR-009 — Stale Check Guard

If a number's `CURRENT.checked_at` is older than `check_expiry_days` when PRD-90 attempts to advance it to `LOA_SUBMITTED`, PRD-90 must reject the transition.

Expiry is computed on read. PRD-15 does not need a background process that rewrites records to `EXPIRED`.

### FR-010 — Mock Provider For Dev/Test

PRD-15 must support a mock provider that returns deterministic lookup outcomes without external calls.

The mock provider must support at least these scenarios:

- eligible DID
- ineligible VOIP
- toll-free requiring manual verification
- provider failure
- porting freeze

This is required so dev and CI can validate Lambda behavior, DynamoDB writes, and PRD-90 integration without live vendor credentials.

---

## 7. DATA MODEL

### DynamoDB Table

A DynamoDB table (`{org_name}-number-portability-audit-{environment}`, PAY_PER_REQUEST) with:

| Attribute | Type | Description |
|---|---|---|
| `phone_number` | String (PK) | E.164 number |
| `record_type` | String (SK) | `CURRENT`, `CHECK#...`, or `OVERRIDE#...` |
| `provider_status` | String | Raw provider-normalized status |
| `effective_status` | String | Authoritative effective status |
| `effective_source` | String | `PROVIDER` or `OPERATOR_OVERRIDE` |
| `line_type` | String | POTS / VOIP / TOLL_FREE / MOBILE / UNKNOWN |
| `ocn` | String | OCN of losing carrier |
| `losing_carrier_name` | String | Human-readable carrier name |
| `resp_org` | String | RespOrg ID (toll-free only) |
| `porting_freeze` | Boolean | True if provider reports a freeze |
| `ineligibility_reason` | String | Human-readable reason |
| `checked_at` | String | ISO 8601 provider check time |
| `expires_at` | String | ISO 8601 computed expiry time |
| `verified_by` | String | Lambda ARN or operator identity |
| `override_reason_code` | String | Override reason code |
| `override_justification` | String | Required for overrides |
| `override_at` | String | Override timestamp |
| `override_review_by` | String | Optional review/expiry hint |
| `lookup_provider` | String | `mock` or `bandwidth` |

TTL:

- history records may use TTL of 365 days if desired
- `CURRENT` records must not expire automatically

### Read Contract

Current status lookup:

- `GetItem(PK=phone_number, SK=CURRENT)`

History lookup:

- `Query(PK=phone_number)` and inspect `CHECK#...` / `OVERRIDE#...` items

No separate table is required for current state.

---

## 8. ARCHITECTURE

```
Operator / CloudShell / Local CLI / PRD-90
                  ↓ invoke
   {org}-number-portability-check-{env} (Lambda)
                  ├── classify number: DID vs toll-free
                  ├── provider interface
                  │     ├── lookup_did_portability(number)
                  │     └── lookup_tollfree_resporg(number)
                  ├── normalize provider result
                  ├── evaluate eligibility
                  ├── write CHECK#timestamp history record
                  ├── update CURRENT record
                  └── return result payload
                               ↓
      DynamoDB: {org}-number-portability-audit-{env}
                  ├── CURRENT
                  ├── CHECK#...
                  └── OVERRIDE#...
                               ↑
                    PRD-90 reads CURRENT only
                    and computes freshness at gate time
```

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-number-portability-check/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── backend.tf
        └── lambda/
            └── portability_check.py
```

### Environment Configuration

This repo now uses centralized environment folders. PRD-15 must align with that pattern.

Recommended env file:

```
connect-pbx/environments/<env>/portability.tfvars
```

Suggested env-scoped inputs:

- `lookup_provider`
- `lookup_provider_secret_arn`
- `check_expiry_days`

### Key Variables

```hcl
variable "lookup_provider" {
  type        = string
  default     = "mock"
  description = "Active lookup provider. v1 supports: mock, bandwidth."
  validation {
    condition     = contains(["mock", "bandwidth"], var.lookup_provider)
    error_message = "lookup_provider must be mock or bandwidth."
  }
}

variable "lookup_provider_secret_arn" {
  type        = string
  default     = ""
  description = "Secrets Manager ARN for the active provider. Leave empty only when lookup_provider=mock."
}

variable "check_expiry_days" {
  type        = number
  default     = 30
  description = "Number of days after which a portability check result is considered stale at read time."
}
```

### Outputs

```hcl
output "portability_check_lambda_arn" {
  description = "ARN of the portability check Lambda. Invoked by PRD-90 state machine and migration engineers."
  value       = aws_lambda_function.portability_check.arn
}

output "portability_audit_table_name" {
  description = "DynamoDB table name for portability audit records. Read by PRD-90."
  value       = aws_dynamodb_table.portability_audit.name
}

output "portability_audit_table_arn" {
  description = "DynamoDB table ARN. Used in PRD-90 IAM policy."
  value       = aws_dynamodb_table.portability_audit.arn
}
```

### Lambda Environment Variables

Expected Lambda env vars:

- `LOOKUP_PROVIDER`
- `LOOKUP_PROVIDER_SECRET_ARN`
- `CHECK_EXPIRY_DAYS`

### IAM Expectations

The Lambda execution role must have:

- `dynamodb:PutItem`
- `dynamodb:UpdateItem`
- `dynamodb:GetItem`
- `dynamodb:Query`
- `secretsmanager:GetSecretValue` for the active provider secret
- `kms:Decrypt` for the environment KMS key
- standard CloudWatch Logs permissions

---

## 10. ALARMS

**ALARM-15-01: Portability Check Lambda Error Rate**
- Metric: Lambda `Errors` for `{org_name}-number-portability-check-{environment}`
- Threshold: >= 3 errors in 5 minutes
- Action: SNS platform alert topic
- Severity: Medium — check failures block LOA submission but do not affect live calls
- Consolidated in PRD-81

Optional future alarm:

**ALARM-15-02: Repeated Manual Verification Required**
- Trigger when a high number of checks result in `MANUAL_VERIFICATION_REQUIRED`
- Purpose: indicates provider limitations or missing toll-free automation

---

## 11. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-15-01 | Lambda returns `ELIGIBLE` for a valid mock DID scenario | Invoke with mock payload; verify `CURRENT` and `CHECK#...` records |
| AC-15-02 | Lambda returns `INELIGIBLE` with reason for a mock VOIP scenario | Invoke with mock payload; verify `ineligibility_reason` |
| AC-15-03 | Toll-free numbers can return `MANUAL_VERIFICATION_REQUIRED` in v1 | Invoke toll-free path; verify status and reason |
| AC-15-04 | PRD-90 can read `CURRENT` and block LOA submission when status is not `ELIGIBLE` | Integration test with PRD-90 gate |
| AC-15-05 | PRD-90 blocks stale checks using `checked_at` and `check_expiry_days` | Set old timestamp; confirm gate rejection |
| AC-15-06 | Operator override writes immutable history and updates `CURRENT` | Invoke override action; verify `OVERRIDE#...` record and updated current state |
| AC-15-07 | Lambda gracefully handles provider/secret failure with `CHECK_FAILED` | Simulate invalid secret or provider outage |
| AC-15-08 | checkov passes with zero HIGH/CRITICAL findings | `checkov -d modules/l1-number-portability-check/` |

---

## 12. OPEN IMPLEMENTATION NOTES

- v1 should not claim full direct NPAC or SOMOS support unless those integrations are actually implemented
- the `mock` provider must be treated as first-class for dev and CI
- the runbook must document both normal check invocation and operator override invocation
- PRD-90 should be revised, if needed, so it references PRD-15 `CURRENT` instead of owning duplicate portability truth fields

---

## 13. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-22 | — | Initial release. Established portability verification gate integrated with PRD-90. |
| 1.1.0 | 2026-03-30 | — | Architectural refinement. PRD-15 is now the single source of truth; one-table `CURRENT` + history design; explicit status model; `mock` + `bandwidth` provider scope; DID/toll-free split; operator override with audit trail; expiry computed on read. |
| 1.2.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section with catalog entry, shared sink behavior, destroy posture, and control plane statement. |
