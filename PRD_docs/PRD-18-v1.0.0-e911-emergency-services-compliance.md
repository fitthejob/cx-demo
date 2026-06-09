# PRD-18 — E911 / Emergency Services Compliance

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-18 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-05 |
| **Layer** | 1 — Telephony Core |
| **Depends On** | PRD-10 (Connect instance), PRD-11 (phone number inventory) |
| **Blocks** | PRD-81 (alarm consolidation) |
| **Optional** | Required for PBX deployments that provide employee outbound calling or registered endpoints. Not applicable for pure inbound contact center deployments where agents do not use Connect DIDs as primary endpoints. |

---

## 2. MODULE GOVERNANCE

### Module Classification

| Field | Value |
|---|---|
| `classification` | `conditional-foundation` |
| `activation_condition` | `required when deployment includes employee direct-dial numbers (PBX profile with outbound DID assignment)` |
| `minimum_deployment_profile` | `standard` |
| `can_be_omitted_from_bare_bones` | `yes` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |

### Catalog Entry

| Field | Value |
|---|---|
| `path` | `modules/l1-e911-compliance` |
| `capability_packs` | `["number-governance"]` |
| `dependencies` | `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers"]` |
| `state_key` | `l1-e911-compliance/terraform.tfstate` |
| `workspace_scoped` | `true` |
| `domain_tfvars` | `e911-compliance.tfvars` |
| `supports_destroy` | `true` |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 | Audit bucket is optional for compliance artifacts via `audit_bucket_name`; alarm topic is optional via `alarm_action_arns`. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | `protected` |
| `retention_notes` | E911 location records have legal retention requirements. Agent re-confirmation is required after redeployment. Destruction requires explicit operator confirmation and compliance review. |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

### Operational Model

E911 integration uses a **mock-in-dev, manual-in-prod** model:

- **Dev / Staging:** All E911 Lambdas run in mock mode (`elin_assignment_mode = "mock"`). Emergency call triggers, ELIN assignments, and provider sync operations validate logic and data flow without contacting real E911 infrastructure. This prevents accidental 911 system interactions during development.
- **Production:** E911 provider integration (Intrado, Bandwidth, 911inform, etc.) is configured manually by the operations team after deployment. Emergency notification flows, ELIN management, and provider sync credentials are validated through the provider's test environment before going live.

This means the Terraform module provisions the infrastructure (DynamoDB tables, Lambda functions, IAM roles, CloudWatch alarms) but does **not** configure live E911 provider endpoints or trigger real emergency calls. Multi-instance iteration and real emergency call triggers are deferred to manual prod configuration and are not implementation gaps.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Legal Framework

Two federal statutes govern emergency calling for multi-line telephone systems (MLTS) in the United States. Non-compliance is not a configuration gap — it is a legal liability.

#### Kari's Law (47 USC § 1471, effective February 16, 2020)

Named after Kari Hunt, who was killed in 2013 while her daughter was unable to reach 911 because the hotel PBX required dialing "9" first for an outside line. Kari's Law requires:

1. Any MLTS manufactured, imported, sold, leased, or installed after February 16, 2020 must allow users to dial 911 directly without any prefix or access code
2. The MLTS must notify a front desk, security station, or building staff when a 911 call is placed, if the system is capable of doing so

**Amazon Connect status:** Kari's Law requirement (1) is satisfied natively — Connect does not require prefix dialing. Requirement (2) requires implementation of an internal notification flow, which this PRD provisions.

#### Ray Baum's Act (FCC 47 CFR § 9.16, phased compliance 2021–2022)

Requires MLTS to transmit "dispatchable location" with every 911 call. A dispatchable location is not just a building address — it must include the specific floor, room, or other location information that allows emergency responders to find the caller. For a multi-story office building, "123 Main St" is insufficient; "123 Main St, Floor 4, Room 412" is compliant.

**Compliance timeline:**
- Fixed (non-portable) endpoints: required since January 6, 2021
- Non-fixed (portable) endpoints: required since January 6, 2022
- Remote workers (off-premises softphone): required since January 6, 2022

Amazon Connect softphones are non-fixed and portable. Remote workers' home addresses must be registered and kept current.

### The Remote Worker Problem

Remote workers present the hardest compliance case. A home-office employee using a Connect softphone:
- Has a Connect DID associated with a corporate address by default
- If they call 911 from home, emergency services are dispatched to the corporate address — potentially a different city
- The employee's home address must be registered with an E911 service provider that maps the calling number's ELIN (Emergency Location Identification Number) to the correct dispatchable address

Amazon Connect does not manage E911 location registration. This requires integration with an E911 service provider such as:
- **Intrado** (formerly West Safety Services, now Lumen Safety Solutions)
- **Bandwidth Emergency Services**
- **911inform**
- **RedSky Technologies** (now part of Bandwidth)

### Scope for This Platform

This PRD covers both office-based and remote deployments. For small single-instance deployments with a single office location, implementation is straightforward. For enterprise multi-site deployments with remote workers, the full remote worker ELIN management flow is required.

---

## 4. GOALS

- Implement the Kari's Law internal notification flow: a Lambda that fires an SNS notification to the security station when 911 is dialed
- Provision a dispatchable location registry (DynamoDB) with records for all office locations and remote workers
- Implement E911 provider synchronization: location records are pushed to the E911 provider API on change and on a daily schedule
- Manage ELIN (Emergency Location Identification Number) assignment for remote workers
- Provide a compliance audit Lambda that verifies all active agents have a valid, non-stale location record
- Alert on compliance gaps (agents with no location record, stale records, provider sync failures)

### Non-Goals

- This PRD does not configure 911 routing at the carrier level — Amazon Connect routes 911 calls natively
- This PRD does not manage public safety answering point (PSAP) relationships
- This PRD is not required for pure inbound contact center deployments where agents do not use Connect DIDs as personal direct-dial lines and do not make outbound PSTN calls from permanent endpoints

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Kari's Law Notification Path
The module must implement the internal-notification side of Kari's Law without placing any logic in the emergency call path itself.

Normative v1 design:
1. Amazon Connect continues to route 911 natively with no prefix and no custom delay.
2. The platform provisions a dedicated Lambda (`{org_name}-emergency-notification-{environment}`) and SNS topic (`{org_name}-security-alerts`).
3. The Lambda is operator-invocable and automation-invocable. It supports:
   - `SEND_NOTIFICATION`
   - `SELF_TEST_NOTIFICATION`
4. `SEND_NOTIFICATION` accepts a normalized payload containing:
   - Agent name and ID
   - Registered dispatchable location
   - Timestamp
   - Connect instance ID
   - Source of notification evidence
   - `request_id`
   - `operator_identity` when manually invoked
5. The SNS topic delivers to the configured security station endpoint list (email, SMS, or paging system via `var.security_alert_endpoints`).
6. The exact trigger mechanism for production 911 notification must be validated against the selected Connect emergency-calling pattern during implementation readiness. If Connect exposes a supported emergency-call notification hook, that hook invokes this Lambda. If not, the deployment must document the alternate operational procedure used to satisfy notification-capable environments.

The PRD therefore defines the notification service contract now and leaves only the Connect-specific trigger validation as an implementation-readiness task. The emergency call itself must never depend on the Lambda succeeding.

### FR-002 — Location Registry Table
A DynamoDB table (`{org_name}-e911-location-registry-{environment}`, PAY_PER_REQUEST):

| Attribute | Type | Description |
|---|---|---|
| `agent_id` | String (PK) | Connect User ID (or `OFFICE_{location_id}` for office locations) |
| `location_type` | String | OFFICE / REMOTE |
| `street_address` | String | Street number and name |
| `city` | String | City |
| `state` | String | 2-letter state code |
| `zip` | String | 5-digit ZIP |
| `building` | String | Building name/number (optional for single-building offices) |
| `floor` | String | Floor number or description |
| `room` | String | Room/suite/desk number |
| `elin` | String | Emergency Location Identification Number (remote workers only) |
| `phone_number` | String | The Connect DID associated with this agent/location |
| `address_verified` | Boolean | True if agent has confirmed the address |
| `last_verified_date` | String | ISO 8601 date — re-verification required every 90 days |
| `provider_sync_status` | String | PENDING / SYNCED / FAILED |
| `provider_sync_date` | String | ISO 8601 timestamp of last successful provider sync |

### FR-003 — E911 Provider Sync Lambda
A Lambda function (`{org_name}-e911-provider-sync-{environment}`) is the authoritative provider-synchronization surface. It supports:

- `SYNC_PENDING`
- `SYNC_AGENT`
- `SYNC_FAILED`

For sync actions, the Lambda:
1. Reads the location registry table
2. For each selected record with `provider_sync_status = PENDING` or updated verification data:
   - Constructs the provider API request (provider-specific format — see FR-007)
   - Submits the location record to the E911 provider
   - Updates `provider_sync_status` and `provider_sync_date` on success
3. Records provider failure details in the registry item when sync fails
4. Runs on-demand (triggered by the registration workflow or operator invocation) and on an optional daily schedule (03:00 UTC)
5. Emits `E911ProviderSyncSuccess` and `E911ProviderSyncFailure` metrics

Mutating sync actions must be idempotent by `request_id`.

### FR-004 — Remote Worker ELIN Management
For agents with `location_type = REMOTE`:
1. An ELIN is assigned from the Connect phone number inventory — a DID number specifically reserved for E911 ELIN use per remote worker
2. The ELIN maps the remote worker's Connect DID to their registered home address at the E911 provider
3. The ELIN is provisioned via Terraform as a dedicated entry in the `l1-phone-numbers` module with `purpose = "e911-elin"` and `cost_center = "compliance"`
4. When the agent updates their home address, the E911 provider sync Lambda updates the ELIN-to-address mapping at the provider

### FR-005 — Remote Worker Registration Flow
When an operator designates an agent as `location_type = REMOTE`, the registration workflow is started explicitly through CLI or a future operator UI:
1. The registration Lambda is invoked directly with the agent identifier, email address, phone number, `request_id`, and `operator_identity`
2. The Lambda sends an email via SES to the agent's registered email address with a link to a secure address confirmation form
3. The agent confirms their home address including building, floor, and room/unit
4. The address is written to the location registry and the E911 provider sync is triggered
5. The agent must re-confirm every 90 days (configurable via `var.location_verification_interval_days`)

### FR-005A — Location Registry Mutation Contract
Location registry mutations must not be performed via raw DynamoDB operator writes. The registration workflow surface must support:

- `UPSERT_OFFICE_LOCATION`
- `START_REMOTE_REGISTRATION`
- `RECORD_REMOTE_CONFIRMATION`
- `MARK_LOCATION_REVERIFIED`

All mutating actions must include `request_id` and `operator_identity` and must be idempotent by `request_id`.

### FR-006 — Compliance Audit Lambda
A Lambda function (`{org_name}-e911-compliance-audit-{environment}`) that runs daily at 04:00 UTC:
1. Lists all active agents in Connect via `connect:ListUsers`
2. For each active agent, checks the location registry for a valid, non-stale record
3. Emits:
   - `AgentsWithNoE911Record` — agents with no location registry entry
   - `AgentsWithExpiredE911Record` — agents with `last_verified_date` older than `var.location_verification_interval_days`
   - `AgentsAwaitingRemoteConfirmation` — remote workers with `address_verified = false`
4. Logs the complete compliance status to CloudWatch Logs and optionally writes a daily JSON evidence artifact to `var.compliance_artifact_bucket_name` when that bucket is configured

PRD-03 audit storage is an optional integration path, not a hard prerequisite for E911 deployability.

### FR-007 — E911 Provider Abstraction
The sync Lambda must abstract the E911 provider behind a configurable interface via `var.e911_provider`:

| Provider | Protocol | Notes |
|---|---|---|
| `intrado` | SOAP/XML (ALI database format) | Legacy protocol; Intrado also supports REST in newer versions |
| `bandwidth` | REST/JSON | Bandwidth Emergency Services API |
| `911inform` | REST/JSON | 911inform Address Management API |
| `redsky` | REST/JSON | RedSky E911 Manager API (now Bandwidth) |

Provider credentials are stored in AWS Secrets Manager, referenced by `var.e911_provider_secret_arn`.

### FR-008 — Multi-Instance Support
When `deployment_profile.instance_count > 1`, the compliance audit Lambda must iterate over all Connect instance IDs and all agents across all instances. The location registry is shared (instance-agnostic) — an agent record is identified by Connect User ID regardless of which instance they belong to.

---

## 6. ARCHITECTURE

```
Validated emergency-call notification trigger OR
operator-invoked compliance test path
        ↓
  {org}-emergency-notification-{env} (Lambda)
        └── SNS Publish → {org}-security-alerts
              └── Security station endpoint (email/SMS/pager)

Operator-triggered remote-worker registration OR
Location Change Request
        ↓
  {org}-e911-registration-{env} (Lambda)
        ├── SES: Send address confirmation email to agent
        └── DynamoDB PutItem → {org}-e911-location-registry-{env}
                                        ↓
                              {org}-e911-provider-sync-{env} (Lambda)
                                        ├── E911 Provider API (Intrado / Bandwidth / etc.)
                                        └── DynamoDB UpdateItem → provider_sync_status

Operator / CI invoke OR Optional EventBridge Schedule (daily 04:00 UTC)
        ↓
  {org}-e911-compliance-audit-{env} (Lambda)
        ├── Connect ListUsers
        ├── DynamoDB Scan → location registry
        ├── Emit compliance metrics → CloudWatch
        └── Optional S3 PutObject → compliance evidence artifact

Operator / CI invoke OR Optional EventBridge Schedule (daily 03:00 UTC)
        ↓
  {org}-e911-provider-sync-{env} (Lambda)
        └── Sync all pending/updated records to E911 provider
```

---

## 7. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l1-e911-compliance/
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── backend.tf
        └── lambda/
            ├── emergency_notification.py
            ├── e911_registration.py
            ├── e911_provider_sync.py
            └── e911_compliance_audit.py
```

### Key Variables

```hcl
variable "e911_provider" {
  type        = string
  default     = "bandwidth"
  description = "E911 service provider. Options: intrado, bandwidth, 911inform, redsky."
  validation {
    condition     = contains(["intrado", "bandwidth", "911inform", "redsky"], var.e911_provider)
    error_message = "e911_provider must be intrado, bandwidth, 911inform, or redsky."
  }
}

variable "e911_provider_secret_arn" {
  type        = string
  description = "ARN of Secrets Manager secret containing E911 provider API credentials."
}

variable "security_alert_endpoints" {
  type        = list(string)
  description = "List of endpoints subscribed to the security alerts SNS topic. Supports email and SMS (E.164 format)."
}

variable "location_verification_interval_days" {
  type    = number
  default = 90
  description = "Number of days after which an agent must re-confirm their dispatchable location."
}

variable "office_locations" {
  description = "Map of office location records. Each entry is a fixed Terraform-managed location."
  type = map(object({
    street_address = string
    city           = string
    state          = string
    zip            = string
    building       = optional(string)
    floor          = string
    room           = optional(string)
    phone_number   = string  # The Connect DID associated with this location
  }))
  default = {}
}

variable "enable_daily_provider_sync_schedule" {
  type        = bool
  default     = true
  description = "When true, create the daily provider-sync schedule."
}

variable "enable_daily_compliance_audit_schedule" {
  type        = bool
  default     = true
  description = "When true, create the daily compliance-audit schedule."
}

variable "alarm_action_arns" {
  type        = list(string)
  default     = []
  description = "Optional CloudWatch alarm action ARNs. Empty list means alarms may exist without external actions."
}

variable "compliance_artifact_bucket_name" {
  type        = string
  default     = null
  description = "Optional S3 bucket name for compliance evidence artifacts. When null, audit evidence remains in logs/metrics only."
}
```

### outputs.tf

```hcl
output "location_registry_table_name" {
  description = "E911 location registry DynamoDB table name."
  value       = aws_dynamodb_table.location_registry.name
}

output "security_alerts_topic_arn" {
  description = "SNS topic ARN for security station emergency notifications."
  value       = aws_sns_topic.security_alerts.arn
}

output "emergency_notification_lambda_arn" {
  description = "Lambda ARN used by the validated emergency notification path."
  value       = aws_lambda_function.emergency_notification.arn
}

output "e911_registration_lambda_arn" {
  description = "Lambda ARN for office-location upserts and remote-worker registration workflows."
  value       = aws_lambda_function.e911_registration.arn
}

output "e911_provider_sync_lambda_arn" {
  description = "Lambda ARN for provider synchronization actions."
  value       = aws_lambda_function.e911_provider_sync.arn
}

output "e911_compliance_audit_lambda_arn" {
  description = "Lambda ARN for compliance audits."
  value       = aws_lambda_function.e911_compliance_audit.arn
}
```

---

## 8. ALARMS

**ALARM-18-01: Agents with No E911 Location Record**
- Metric: `ConnectPBX/{environment}/AgentsWithNoE911Record`
- Threshold: >= 1
- Action: configured `alarm_action_arns` when supplied
- Severity: Critical — legal compliance gap
- Note: This alarm must be suppressed during initial deployment while all agents complete registration. Set `alarm_suppression_end_date` variable to the go-live date.

**ALARM-18-02: E911 Provider Sync Failure**
- Metric: `ConnectPBX/{environment}/E911ProviderSyncFailure`
- Threshold: >= 1 for 3 consecutive periods (15 minutes each)
- Action: configured `alarm_action_arns` when supplied
- Severity: High — location data is stale at provider

**ALARM-18-03: Emergency Notification Execution Error**
- Metric: CloudWatch `Errors` metric for `{org_name}-emergency-notification-{environment}`
- Threshold: >= 1
- Action: configured `alarm_action_arns` when supplied
- Severity: Critical — emergency notification may not have been delivered

All alarms consolidated in PRD-81.

---

## 9. COMPLIANCE EVIDENCE ARTIFACTS

| Artifact | Schedule | Location | Demonstrates |
|---|---|---|---|
| Daily E911 compliance report | Daily | Optional: `s3://{compliance_artifact_bucket_name}/e911/compliance/YYYY-MM-DD.json` | Ray Baum's Act — all agents have dispatchable location on file |
| Provider sync log | Daily | Optional: `s3://{compliance_artifact_bucket_name}/e911/provider-sync/YYYY-MM-DD.json` | Location data is current at E911 provider |
| 911 notification execution log | On event | CloudTrail + Lambda logs | Kari's Law — notification fired on emergency call |

---

## 10. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-18-01 | Kari's Law: 911 call triggers security notification | Place test 911 call (coordinate with local PSAP or use test line); verify SNS notification received at security endpoint |
| AC-18-02 | Office location records sync to E911 provider | Apply module with office_locations variable; invoke sync Lambda; verify 200 response from provider API |
| AC-18-03 | Remote worker ELIN assigned and synced to provider | Onboard a test remote agent; complete address confirmation; verify ELIN assigned and location synced |
| AC-18-04 | ALARM-18-01 fires when an agent has no location record | Add a test agent without a location record; verify alarm |
| AC-18-05 | Stale record (>90 days) is surfaced by the compliance audit | Set last_verified_date to 91 days ago; run compliance audit Lambda; verify expired-record metric/output |
| AC-18-06 | Location updates are performed through guarded Lambda contracts, not direct table mutation | Invoke `UPSERT_OFFICE_LOCATION` and `START_REMOTE_REGISTRATION`; verify the registry updates correctly |
| AC-18-07 | Optional compliance artifact is written when `compliance_artifact_bucket_name` is configured | Run the compliance audit with an artifact bucket configured; verify the JSON artifact is written |
| AC-18-08 | Mutating registration and sync actions are idempotent by `request_id` | Re-submit the same `START_REMOTE_REGISTRATION` or `SYNC_PENDING` request twice; verify duplicate side effects are not produced |
| AC-18-09 | checkov passes with zero HIGH/CRITICAL findings | `checkov -d modules/l1-e911-compliance/` |

---

## 11. LEGAL NOTE

Ray Baum's Act and Kari's Law violations are subject to FCC enforcement under 47 USC § 503 (forfeiture penalties) and civil liability for damages. The FCC has issued advisory guidance that penalties can apply per-violation and per-day of non-compliance. This module addresses the technical implementation — the platform operator is responsible for:

1. Ensuring all agents complete the registration process before go-live
2. Establishing a process for agents to update their location when they change work sites
3. Maintaining provider contracts with the selected E911 service provider
4. Coordinating pre-go-live testing with the local PSAP (required by FCC guidance for MLTS deployments)

---

## 12. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-22 | — | Initial release. Covers Kari's Law notification flow, Ray Baum's Act dispatchable location registry, E911 provider integration (Intrado/Bandwidth/911inform/RedSky), ELIN management for remote workers, and daily compliance audit artifacts. |
| 1.1.0 | 2026-03-30 | Codex | Readiness pass: made registration/sync contracts CLI-first and idempotent, removed hidden PRD-50/Terraform trigger assumptions, made compliance-artifact storage optional instead of PRD-03-dependent, and aligned alarms/module metadata with the capability-pack model. |
| 1.2.0 | 2026-04-05 | Codex | Governance normalization. Promoted catalog metadata from recommended to mandatory. Reclassified as conditional-foundation with explicit activation_condition. Added Module Governance section with shared sink behavior, destroy posture, and control plane statement. |
