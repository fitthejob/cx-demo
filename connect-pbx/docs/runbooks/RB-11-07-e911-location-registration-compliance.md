# RB-11-07 — E911 Location Registration & Compliance Audit

**Runbook ID:** RB-11-07
**Module:** l1-e911-compliance (PRD-18)
**Audience:** Platform Engineer, IT/HR (remote worker registration), Facilities/Security
**Last Updated:** 2026-03-30

---

## Overview

This runbook covers E911 location registration for Amazon Connect PBX deployments. It is required for any deployment where employees use Connect DIDs as primary direct-dial endpoints.

Current implementation note:
- PRD-18 is implemented and validated in `dev` in a safe mock-first profile.
- `dev` does not send live security notifications, live registration emails, or live E911 provider updates.
- The live provider, email, and notification hooks are present for future rollout, but they remain explicitly gated off in `dev`.
- Office-location updates, remote-worker onboarding, and provider-sync retries should go through guarded Lambda workflows rather than raw DynamoDB operator edits.
- If you are operating in `dev` or performing initial system setup, jump to [Part E — Dev Mock Mode & Mock-to-Live Cutover](#dev-mock-mode).

Two federal laws govern emergency calling:
- **Kari's Law** — direct 911 dialing and internal security notification (the notification service contract is defined in PRD-18; the exact production trigger must be validated during implementation)
- **Ray Baum's Act** — dispatchable location (specific floor and room, not just building address) transmitted with every 911 call

This runbook covers three operational scenarios:
1. **Initial deployment** — registering all office locations and onboarding remote workers before go-live
2. **Ongoing maintenance** — new employee onboarding, location changes, annual re-verification
3. **Compliance audit response** — investigating and resolving ALARM-18-01 and ALARM-18-02

All new PRD-18 deployments must start in the safe `dev` mock posture first. Do not enable live provider synchronization, live security notifications, or live registration-email delivery until the mock workflow has been validated end to end and the explicit live flags have been reviewed and approved.

---

## Prerequisites

| Requirement | Verification |
|---|---|
| PRD-18 (l1-e911-compliance) is deployed | `terraform state list` shows location registry table, Lambda functions, security alerts SNS topic |
| E911 provider account is active | Provider API credentials stored in Secrets Manager: `{org}-e911-provider-creds` |
| Security alerts SNS topic has subscriptions | `aws sns list-subscriptions-by-topic --topic-arn {security_alerts_topic_arn}` returns security station endpoints |
| Office floor plans / room numbering is documented | Required for Ray Baum's Act dispatchable location accuracy |

For `dev` and initial system setup:
- Start with [Part E — Dev Mock Mode & Mock-to-Live Cutover](#dev-mock-mode).
- Do not begin with live PSAP coordination or live provider validation.
- Treat live rollout as a later, separate manual transition after mock validation passes.

---

## Part A — Initial Deployment (Before Go-Live)

### A1 — Compile office location data

Gather the following for every office location where employees will use Connect DIDs:

```
OFFICE LOCATION DATA COLLECTION TEMPLATE
=========================================
Location ID:      [human-readable key, e.g., "hq-floor4", "chicago-office"]
Street Address:   [number + street name]
City:             [city]
State:            [2-letter state code]
ZIP:              [5-digit ZIP]
Building:         [building name or number, if multiple buildings on campus]
Floor:            [floor number — "4" not "fourth floor"]
Room/Suite:       [room number, suite, or area — "412" or "Suite 400"]
Connect DID:      [the phone number associated with this location]
```

Ray Baum's Act requires that "floor" and "room" (or equivalent sub-building location) be present. A street address alone is not compliant for multi-story or multi-unit buildings.

### A2 — Configure office locations in Terraform

Add all office locations to the `l1-e911-compliance` environment config for the target environment:

```hcl
# target environment E911 config
office_locations = {
  hq-floor4 = {
    street_address = "123 Main Street"
    city           = "New York"
    state          = "NY"
    zip            = "10001"
    building       = "Tower A"
    floor          = "4"
    room           = "412"
    phone_number   = "+12125550100"
  }
  chicago-office = {
    street_address = "456 Wacker Drive"
    city           = "Chicago"
    state          = "IL"
    zip            = "60601"
    building       = null   # single building
    floor          = "12"
    room           = "Suite 1200"
    phone_number   = "+13125550200"
  }
}
```

Apply via the standard CI/CD pipeline. Terraform establishes the desired office-location configuration; provider synchronization is an explicit follow-up action.

### A3 — Verify office location sync to E911 provider

```bash
export AWS_PROFILE=<aws_profile_dev>

# Invoke sync Lambda manually after apply to confirm
aws lambda invoke \
  --function-name <org_prefix>-e911-provider-sync-<env> \
  --payload '{"operation":"SYNC_PENDING","request_id":"e911-sync-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  e911-sync-results.json

cat e911-sync-results.json | jq '.'

# Check sync status in DynamoDB
TABLE_NAME="<org_prefix>-e911-location-registry-<env>"

aws dynamodb scan \
  --table-name ${TABLE_NAME} \
  --filter-expression "location_type = :office" \
  --expression-attribute-values '{":office": {"S": "OFFICE"}}' \
  --query "Items[*].{ID:agent_id.S, Address:street_address.S, Floor:floor.S, Room:room.S, SyncStatus:provider_sync_status.S}" \
  --output table
```

All office records must show `provider_sync_status = SYNCED` before go-live.

### A4 — Onboard remote workers

For each employee who will work remotely:

1. Identify the employee's Connect User ID:

```bash
INSTANCE_ID="<connect_instance_id>"

aws connect list-users \
  --instance-id ${INSTANCE_ID} \
  --query "UserSummaryList[?Username=='<employee_email>'].{ID:Id, Username:Username}" \
  --output table
```

2. Start the registration workflow explicitly:

```bash
aws lambda invoke \
  --function-name <org_prefix>-e911-registration-<env> \
  --payload '{
    "operation": "START_REMOTE_REGISTRATION",
    "agent_id": "<connect_user_id>",
    "location_type": "REMOTE",
    "phone_number": "+12125550101",
    "agent_email": "<employee_email>",
    "request_id": "e911-remote-start-2026-03-30-01",
    "operator_identity": "<operator_email>"
  }' \
  --cli-binary-format raw-in-base64-out \
  registration-result.json
```

The Lambda sends a confirmation email to the employee's registered email address with a link to confirm their home address.

3. Monitor remote worker registration status:

```bash
aws dynamodb scan \
  --table-name ${TABLE_NAME} \
  --filter-expression "location_type = :remote" \
  --expression-attribute-values '{":remote": {"S": "REMOTE"}}' \
  --query "Items[*].{AgentID:agent_id.S, Phone:phone_number.S, Verified:address_verified.BOOL, SyncStatus:provider_sync_status.S}" \
  --output table
```

All remote workers must have `address_verified = true` and `provider_sync_status = SYNCED` before go-live.

### A5 — Test Kari's Law notification (pre-go-live test)

For the current `dev` implementation, only the self-test path should be used. Do not place a real 911 or PSAP-coordinated test call from `dev`.

**Coordinate with the local PSAP before conducting this test.** Many US jurisdictions have a dedicated non-emergency test process for MLTS compliance testing. Call the local PSAP's administrative line (not 911) and ask for the process to conduct a test 911 call for MLTS compliance verification.

In some jurisdictions, you can dial 911 and immediately say "This is a MLTS test call" — the PSAP will note it and disconnect. In others, you must schedule the test in advance. When in doubt, schedule in advance.

Verification:
1. Place the test 911 call from a Connect softphone
2. Confirm the PSAP receives the call with the correct dispatchable location
3. Confirm the security station receives the SNS notification (email/SMS) within 60 seconds
4. Check CloudWatch Logs for the emergency notification Lambda execution

Optional non-PSAP self-test:

```bash
aws lambda invoke \
  --function-name <org_prefix>-emergency-notification-<env> \
  --payload '{
    "operation": "SELF_TEST_NOTIFICATION",
    "request_id": "e911-self-test-2026-03-30-01",
    "operator_identity": "<operator_email>",
    "agent_id": "<test_agent_id>",
    "agent_name": "E911 Test User",
    "registered_location": "123 Main Street, Floor 4, Room 412",
    "timestamp": "2026-03-30T15:00:00Z",
    "connect_instance_id": "<connect_instance_id>",
    "source_of_notification_evidence": "operator-self-test"
  }' \
  --cli-binary-format raw-in-base64-out \
  emergency-self-test.json
```

---

## Part B — Ongoing Maintenance

### B1 — New Employee Onboarding

When a new employee receives a Connect DID (PBX deployment):

```
NEW EMPLOYEE E911 CHECKLIST
============================
[ ] Employee added to Connect (PRD-50 procedure)
[ ] Location type determined: OFFICE or REMOTE
[ ] For OFFICE: confirm which office_locations entry covers their desk
[ ] For REMOTE: registration email sent (verify in Lambda logs or SES sent-items)
[ ] For REMOTE: employee completed address confirmation (address_verified = true)
[ ] For REMOTE: ELIN assigned (elin field populated in location registry)
[ ] Provider sync completed (provider_sync_status = SYNCED)
Completed by:  [name]
Date:          [YYYY-MM-DD]
```

### B2 — Employee Location Change

When an employee changes work locations (moves offices, goes from office to remote, or changes home address):

```bash
# Office-location update through the guarded registration workflow
aws lambda invoke \
  --function-name <org_prefix>-e911-registration-<env> \
  --payload '{
    "operation": "UPSERT_OFFICE_LOCATION",
    "agent_id": "<connect_user_id>",
    "location_type": "OFFICE",
    "street_address": "789 New Street",
    "city": "New York",
    "state": "NY",
    "zip": "10002",
    "floor": "2",
    "room": "201",
    "phone_number": "+12125550101",
    "request_id": "e911-office-move-2026-03-30-01",
    "operator_identity": "<operator_email>"
  }' \
  --cli-binary-format raw-in-base64-out \
  office-update-result.json

# Trigger sync Lambda to push update to E911 provider
aws lambda invoke \
  --function-name <org_prefix>-e911-provider-sync-<env> \
  --payload '{"operation":"SYNC_AGENT","agent_id":"<connect_user_id>","request_id":"e911-agent-sync-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  sync-result.json
```

For remote workers changing home address: re-trigger the registration Lambda (same as onboarding). The employee receives a new confirmation email with the updated address for review.

### B3 — 90-Day Re-Verification

The compliance audit Lambda surfaces expired records. Re-verification outreach and record refresh are then completed through the registration workflow.

```bash
# Check for expired records
aws dynamodb scan \
  --table-name ${TABLE_NAME} \
  --query "Items[?last_verified_date <= '$(date -d '90 days ago' +%Y-%m-%d)'].{AgentID:agent_id.S, LastVerified:last_verified_date.S, Phone:phone_number.S}" \
  --output table
```

For office workers with expired records: update `last_verified_date` after confirming with the employee that their desk location has not changed.
Use `MARK_LOCATION_REVERIFIED` rather than editing the table directly.

---

## Part C — Compliance Audit Response

### C1 — ALARM-18-01: Agents with No E911 Record

This alarm fires when an active Connect agent has no entry in the location registry.

```bash
# Run the compliance audit Lambda immediately
aws lambda invoke \
  --function-name <org_prefix>-e911-compliance-audit-<env> \
  --payload '{"request_id":"e911-audit-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  audit-result.json

cat audit-result.json | jq '.agents_without_record'
```

For each agent without a record:
1. Determine their location type (office or remote)
2. Initiate onboarding per Part B Step B1
3. For remote workers: this is urgent — send the registration email immediately and follow up directly with the employee

**Target resolution time:** 24 hours from alarm. Each day of non-compliance is a potential FCC violation.

### C2 — ALARM-18-02: E911 Provider Sync Failure

```bash
# Check sync Lambda logs for error details
aws logs filter-log-events \
  --log-group-name "/aws/lambda/<org_prefix>-e911-provider-sync-<env>" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern "ERROR" \
  --query "events[*].message" \
  --output text
```

Common causes:
- Provider API outage — check provider status page; retry after 30 minutes
- Credentials expired — rotate in Secrets Manager; redeploy Lambda
- Network connectivity — verify Lambda VPC config (if applicable) and security group egress rules
- Provider rejected a specific address format — check the error message for the specific record; correct the address format per provider's API documentation

Pending records that failed sync remain in `provider_sync_status = FAILED` state and are retried on the daily schedule. For urgent resolution:

```bash
# Requeue failed records and invoke sync
aws lambda invoke \
  --function-name <org_prefix>-e911-provider-sync-<env> \
  --payload '{"operation":"SYNC_FAILED","request_id":"e911-sync-failed-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  forced-sync-result.json
```

---

## Part D — Annual Compliance Review

Conduct annually, or before any significant change to the office layout or remote work policy.

```
ANNUAL E911 COMPLIANCE REVIEW CHECKLIST
=========================================
[ ] Run compliance audit Lambda; verify zero agents without records
[ ] Verify all office_locations in Terraform match current office layouts
[ ] Confirm floor/room information is current (floor renumbering, remodeling)
[ ] Verify E911 provider contract is current (not expired)
[ ] Verify provider API credentials in Secrets Manager are valid
[ ] Review security alerts SNS subscriptions — all still current endpoints?
[ ] Test Kari's Law notification (coordinate with PSAP)
[ ] Review evidence artifacts in the configured compliance bucket if enabled
[ ] Confirm provider has correct address for all remote workers
Completed by:  [name]
Review date:   [YYYY-MM-DD]
Next review:   [YYYY-MM-DD]
```

---

<a id="dev-mock-mode"></a>

## Part E — Dev Mock Mode & Mock-to-Live Cutover

This section is the authoritative operator guide for:
- all initial PRD-18 deployments
- all `dev` deployments
- all pre-live validation
- the eventual transition from mock-safe behavior to live E911 behavior

Every new PRD-18 deployment must start here.

### E1 — Purpose of the safe dev shape

The `dev` implementation is intentionally designed so that it can exercise:
- the DynamoDB location registry
- guarded Lambda mutation workflows
- mock remote-worker registration
- mock ELIN assignment
- mock provider synchronization
- compliance auditing against the real Connect instance

while **not** doing any of the following:
- sending real emergency security notifications
- sending real registration emails to end users
- calling a live E911 provider API
- placing or requiring a live 911 test call
- creating live SNS endpoint subscriptions by default

This is enforced both by environment configuration and by Lambda runtime guardrails.

### E2 — Required `dev` mock configuration

The safe `dev` baseline is defined in `environments/dev/e911-compliance.tfvars` and must remain in place for initial deployment:

```hcl
e911_provider_mode       = "mock"
allow_live_provider_sync = false

notification_delivery_mode        = "mock"
registration_email_delivery_mode  = "mock"
allow_live_external_notifications = false

security_alert_endpoints                     = []
enable_security_alert_endpoint_subscriptions = false

elin_assignment_mode = "mock"

enable_daily_provider_sync_schedule    = false
enable_daily_compliance_audit_schedule = false
```

Meaning of those settings:
- `e911_provider_mode = "mock"`: provider sync writes internal state only and does not call a real vendor API
- `allow_live_provider_sync = false`: even if someone attempted to switch the provider mode later, the explicit live gate is still closed
- `notification_delivery_mode = "mock"`: emergency notification self-tests do not publish to real SNS subscribers
- `registration_email_delivery_mode = "mock"`: remote-worker registration creates a mock confirmation token and preview URL instead of sending email
- `allow_live_external_notifications = false`: blocks live SNS delivery and live SES delivery at runtime
- `security_alert_endpoints = []`: no security contacts are configured in `dev`
- `enable_security_alert_endpoint_subscriptions = false`: no SNS subscriptions are created in `dev`
- `elin_assignment_mode = "mock"`: remote-worker confirmations get mock ELIN values instead of consuming real ELIN inventory
- schedules off: no hidden daily activity runs in `dev`

### E3 — Validate the configuration before first deploy

1. Confirm the manifest enables `number-governance` and includes `modules/l1-e911-compliance` in the eligible plan list.

```bash
cd ~/Desktop/SANDBOX-MEGA-TELCOGO/connect-pbx
export AWS_PROFILE=<aws_profile_dev>

python scripts/module_manifest.py validate \
  --catalog modules/dependency-order.json \
  --manifest environments/dev/deployment-manifest.json

python scripts/module_manifest.py eligible-modules \
  --catalog modules/dependency-order.json \
  --manifest environments/dev/deployment-manifest.json \
  --action plan
```

2. Verify the `dev` tfvars still show the mock-only posture.

```bash
cat environments/dev/e911-compliance.tfvars
```

3. Optional Terraform preflight:

```bash
terraform -chdir=modules/l1-e911-compliance init -backend=false
terraform -chdir=modules/l1-e911-compliance validate
```

If the provider registry is unreachable in your shell, continue with the repo runner plan/apply flow and note the validation limitation in the change record.

### E4 — Deploy PRD-18 in safe dev mode

Run:

```bash
bash scripts/tf-run.sh plan dev modules/l1-e911-compliance
bash scripts/tf-run.sh apply dev modules/l1-e911-compliance
```

Review the plan carefully. In the safe `dev` shape:
- the SNS topic may be created
- Lambda functions may be created
- the DynamoDB table may be created
- alarms may be created
- schedule resources should **not** be created
- SNS subscriptions should **not** be created
- no real provider credentials should be required

### E5 — Post-deploy validation: prove that `dev` does not touch live systems

This is the minimum validation set before any deeper workflow testing.

#### E5.1 — Confirm no SNS subscriptions were created

1. Obtain the topic ARN from Terraform output or the module outputs.
2. Verify the subscription list is empty:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn <security_alerts_topic_arn>
```

Expected result:
- zero subscriptions in `dev`

#### E5.2 — Confirm no schedules were created

```bash
aws events list-rules \
  --name-prefix <org_prefix>-e911-
```

Expected result in `dev`:
- no daily provider-sync schedule
- no daily compliance-audit schedule

#### E5.3 — Confirm notification self-test stays mock-only

```bash
aws lambda invoke \
  --function-name <org_prefix>-emergency-notification-<env> \
  --cli-binary-format raw-in-base64-out \
  --payload '{
    "operation": "SELF_TEST_NOTIFICATION",
    "request_id": "e911-self-test-dev-001",
    "operator_identity": "<operator_alias>",
    "agent_id": "<test_agent_id>",
    "agent_name": "E911 Test User",
    "registered_location": "123 Main Street, Floor 4, Room 412",
    "timestamp": "2026-03-30T15:00:00Z",
    "connect_instance_id": "<connect_instance_id>",
    "source_of_notification_evidence": "operator-self-test"
  }' \
  --cli-binary-format raw-in-base64-out \
  prd18-self-test.json

cat prd18-self-test.json
```

Expected result:
- `delivery_mode = mock`
- `published = false`
- no external notification endpoint receives anything

#### E5.4 — Confirm remote registration stays mock-only

```bash
aws lambda invoke \
  --function-name <org_prefix>-e911-registration-<env> \
  --payload '{
    "operation": "START_REMOTE_REGISTRATION",
    "agent_id": "<test_remote_agent_id>",
    "phone_number": "+13123246200",
    "agent_email": "<employee_email>",
    "request_id": "e911-remote-start-dev-001",
    "operator_identity": "<operator_alias>"
  }' \
  --cli-binary-format raw-in-base64-out \
  prd18-start.json

cat prd18-start.json
```

Expected result:
- `email_delivery_mode = mock`
- `email_sent = false`
- a `confirmation_token` and preview URL are returned
- no real email is sent

#### E5.5 — Confirm remote confirmation writes registry state but still does not touch a live provider

Take the token from the previous step and run:

```bash
aws lambda invoke \
  --function-name <org_prefix>-e911-registration-<env> \
  --payload '{
    "operation": "RECORD_REMOTE_CONFIRMATION",
    "agent_id": "<test_remote_agent_id>",
    "confirmation_token": "REPLACE_WITH_TOKEN",
    "street_address": "123 Main Street",
    "city": "Chicago",
    "state": "IL",
    "zip": "60601",
    "floor": "4",
    "room": "412",
    "phone_number": "+13123246200",
    "request_id": "e911-remote-confirm-dev-001",
    "operator_identity": "<operator_alias>"
  }' \
  --cli-binary-format raw-in-base64-out \
  prd18-confirm.json

cat prd18-confirm.json
```

Expected result:
- the record transitions to `PENDING`
- no provider sync happens automatically

#### E5.6 — Confirm provider sync stays mock-only

```bash
aws lambda invoke \
  --function-name <org_prefix>-e911-provider-sync-<env> \
  --payload '{
    "operation": "SYNC_AGENT",
    "agent_id": "<test_remote_agent_id>",
    "request_id": "e911-sync-dev-001",
    "operator_identity": "<operator_alias>"
  }' \
  --cli-binary-format raw-in-base64-out \
  prd18-sync.json

cat prd18-sync.json
```

Expected result:
- `provider_mode = mock`
- `status = SYNCED`
- a mock ELIN is assigned if needed
- no live provider API request is made

#### E5.7 — Confirm compliance audit works safely against the real dev Connect instance

```bash
aws lambda invoke \
  --function-name <org_prefix>-e911-compliance-audit-<env> \
  --payload '{
    "request_id": "e911-audit-dev-001",
    "operator_identity": "<operator_alias>"
  }' \
  --cli-binary-format raw-in-base64-out \
  prd18-audit.json

cat prd18-audit.json
```

Expected result:
- audit runs successfully
- it may report missing or expired records in `dev`
- no external notifications or provider calls are triggered by the audit itself

### E6 — Cleanup after dev validation

After validation, remove test records unless you intentionally want to keep them for additional workflow testing.

Typical cleanup targets:
- `<test_remote_agent_id>` registry item
- local JSON output files such as `prd18-self-test.json`, `prd18-start.json`, `prd18-confirm.json`, `prd18-sync.json`, `prd18-audit.json`

If you keep the DDB record temporarily, document that it is a mock validation artifact.

### E7 — Rules for moving from mock to live

Do **not** move from mock to live in one step.

Required order:
1. Keep provider sync in mock mode while validating registration and compliance audit.
2. Enable live external notifications only after confirming the real security endpoints and sender identity.
3. Enable live provider sync only after confirming provider credentials, contract readiness, and real office/remote location data.
4. Only after the above is stable should you consider coordinated PSAP testing for Kari's Law / Ray Baum's Act acceptance.

### E8 — Mock-to-live transition checklist

Before changing any flags:

```text
[ ] Security endpoints are approved and confirmed
[ ] SES sender identity is verified and approved for live use
[ ] E911 provider contract is active
[ ] Provider credentials are stored in Secrets Manager
[ ] Office location data is complete and legally accurate
[ ] Remote worker process is defined and approved
[ ] ELIN inventory strategy is selected (mock vs inventory-backed)
[ ] Daily schedules are approved
[ ] PSAP coordination plan exists for live acceptance testing
[ ] Change window and rollback owner are assigned
```

### E9 — Step-by-step transition from mock to live

#### Step 1 — Keep all behavior mock, but populate live prerequisites

Prepare without enabling live behavior yet:
- create the provider secret in Secrets Manager
- determine the real `security_alert_endpoints`
- verify the SES sender identity
- decide whether ELIN assignment remains mock for early rollout or moves to inventory-backed assignment

At the end of this step:
- leave all live flags off
- do not enable subscriptions
- do not enable schedules

#### Step 2 — Enable live notifications and live registration email only

Update the environment tfvars:

```hcl
notification_delivery_mode        = "live"
registration_email_delivery_mode  = "live"
allow_live_external_notifications = true

remote_registration_sender_email  = "<sender_email>"
security_alert_endpoints = [
  "<security_contact_email>"
]
enable_security_alert_endpoint_subscriptions = true

e911_provider_mode       = "mock"
allow_live_provider_sync = false
```

Apply PRD-18 again.

Validation after Step 2:
1. `aws sns list-subscriptions-by-topic` shows the expected confirmed endpoints
2. `SELF_TEST_NOTIFICATION` produces a real delivered notification to the approved test endpoint
3. `START_REMOTE_REGISTRATION` sends a real email to an approved test mailbox
4. `SYNC_AGENT` still returns mock provider behavior

#### Step 3 — Enable live provider sync

Update the environment tfvars again:

```hcl
e911_provider_mode       = "live"
e911_provider_secret_arn = "<e911_provider_secret_arn>"
allow_live_provider_sync = true
```

Keep schedules off during this step.

Apply PRD-18 again.

Validation after Step 3:
1. Run `SYNC_AGENT` for a controlled test record only
2. Verify provider-side acceptance using the provider’s test or non-production validation workflow when available
3. Confirm the registry records `provider_sync_status = SYNCED`
4. Confirm no unexpected failures appear in the provider-sync Lambda log group

If your selected provider does not offer a safe non-production validation path, stop here and obtain explicit go-live approval before using real production records.

#### Step 4 — Enable inventory-backed ELIN assignment, if desired

If moving from mock ELINs to actual platform-managed ELIN numbers:

1. Add one or more PRD-11 phone numbers with `purpose = "e911-elin"`
2. Apply PRD-11
3. Update PRD-18:

```hcl
elin_assignment_mode = "inventory"
```

4. Apply PRD-18
5. Validate that a controlled remote-worker sync consumes a real ELIN from the dedicated pool

#### Step 5 — Enable daily schedules

Only after live notifications, live email delivery, and live provider sync all validate successfully:

```hcl
enable_daily_provider_sync_schedule    = true
enable_daily_compliance_audit_schedule = true
```

Apply PRD-18 again.

Validation after Step 5:
1. `aws events list-rules --name-prefix <org_prefix>-e911-` shows the expected rules
2. EventBridge targets are attached to the correct Lambdas
3. A scheduled manual dry-run window confirms expected audit/sync behavior

#### Step 6 — Perform live acceptance activities

Only after all prior steps succeed:
- coordinate with the provider for final live data verification
- coordinate with the security team for notification validation
- coordinate with the PSAP for any real 911 compliance testing required by policy or law

Do not treat `dev` self-test as a substitute for coordinated live acceptance.

### E10 — Rollback guidance

If any live step produces unexpected behavior:

1. Immediately revert the environment tfvars to the previous safe state
2. Re-apply PRD-18
3. Confirm the affected live flags are back to:

```hcl
e911_provider_mode       = "mock"
allow_live_provider_sync = false

notification_delivery_mode        = "mock"
registration_email_delivery_mode  = "mock"
allow_live_external_notifications = false

enable_security_alert_endpoint_subscriptions = false
enable_daily_provider_sync_schedule          = false
enable_daily_compliance_audit_schedule       = false
```

4. Re-run the `SELF_TEST_NOTIFICATION`, `START_REMOTE_REGISTRATION`, `SYNC_AGENT`, and compliance audit commands from this section to prove the environment is back in safe mock behavior.

### E11 — Operator sign-off record

Record the following after each stage:

```text
PRD-18 rollout stage:
Environment:
Date:
Operator:
Current provider mode:
Current notification mode:
Current registration email mode:
Current ELIN assignment mode:
Schedules enabled: yes/no
Security subscriptions enabled: yes/no
Validation commands completed:
Observed results:
Approval to proceed to next stage:
```

---

## Troubleshooting

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)

| Problem | Likely Cause | Resolution |
|---|---|---|
| Security notification not received after 911 test | SNS subscription inactive or endpoint wrong | Check SNS topic subscriptions; verify email/SMS endpoint is confirmed (SNS requires subscription confirmation) |
| Provider sync succeeds but 911 routes to wrong address | E911 provider database propagation delay | Allow 24 hours for provider database to propagate; re-test |
| Remote worker confirmation email not received | SES sending quota, wrong email address, or spam filter | Check SES send logs; verify agent email in Connect user record; check employee's spam folder |
| ELIN not assigned for remote worker | ELIN pool exhausted (no available DIDs with purpose=e911-elin) | Add additional ELIN DID entries to phone-numbers tfvars |
| Compliance audit shows expired records for all employees | First run after deployment — all records show original creation date | Update `last_verified_date` for all records after confirming locations are correct |
