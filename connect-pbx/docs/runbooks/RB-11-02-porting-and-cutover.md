# RB-11-02 — Number Porting & Cutover

**Runbook ID:** RB-11-02
**Module:** l1-phone-numbers (PRD-11)
**Audience:** Platform Engineer, Migration Lead
**Last Updated:** 2026-03-30

---

## Overview

This runbook covers the full lifecycle for migrating existing client phone numbers from a legacy system (RingCentral, 8x8, Cisco, Avaya, Asterisk, or any SIP carrier) to Amazon Connect. It includes:

- **Pre-porting:** Contact flow readiness gate and interim call forwarding setup
- **Porting:** LOA submission, carrier coordination, FOC date management
- **Cutover:** FOC day procedure, immediate flow association, verification
- **Post-cutover:** Removing interim forwarding, importing to Terraform state, decommissioning legacy system

Porting is a carrier-level process that takes 2–4 weeks and cannot be automated by Terraform. The Terraform work (import into state) is the final step, not the first.

Current implementation note:
- The repo does not implement PRD-91 yet.
- The FOC-day procedure below is therefore still console-driven for live cutover.
- The "Future PRD-91 operator sequence" section later in this runbook defines the intended CLI execution contract once PRD-91 is built.

---

## Critical Sequencing Requirements

The following gates must be satisfied **before** an LOA is submitted to AWS. Skipping these causes a production outage at the FOC cutover date.

| Gate | Why It Matters |
|---|---|
| **PRD-15 portability check completed (ELIGIBLE)** | Numbers must be verified eligible for porting before any LOA is submitted. VoIP numbers, numbers under porting freeze, and toll-free numbers without an identified RespOrg will fail mid-process. Run RB-11-04 and confirm ELIGIBLE status. |
| PRD-14 (contact flows) is deployed and tested | When porting completes, the number goes live in Connect immediately. If no flow is associated, callers hear a dead disconnect tone. |
| Interim call forwarding is active | The legacy number must forward to a Connect DID during the porting window so callers are never disrupted while the port is in progress. |
| FOC day on-call coverage is arranged | The FOC cutover can happen within a time window, not at an exact minute. Someone must be available to complete the association step. |

---

## Phase 0 — Pre-LOA Portability Gate (RB-11-04)

Before performing any steps in this runbook, verify that every number being ported has passed the pre-LOA portability check. This is a hard gate.

Primary procedure:

- execute [RB-11-04-pre-loa-portability-verification.md](RB-11-04-pre-loa-portability-verification.md)
- confirm each number has a valid `CURRENT` record before proceeding here

Required outcome before proceeding:
- `effective_status = ELIGIBLE`
- `line_type` is `POTS` or `TOLL_FREE` (not VoIP)
- `expires_at` is still in the future

If any number shows `INELIGIBLE`, `MANUAL_VERIFICATION_REQUIRED`, `CHECK_FAILED`, or an expired result, do not proceed. Run RB-11-04 to resolve the eligibility issue first. See PRD-15 for eligibility and override paths.

After all numbers are confirmed ELIGIBLE, do not invent ad-hoc PRD-90 status payloads. PRD-90 is not implemented in the repo yet, and the future guarded contract is operation-based rather than raw `status` writes.

When PRD-90 is deployed, the expected sequence is:

1. create the porting record as `DISCOVERED`
2. transition to `PORTABILITY_CHECK_PENDING`
3. run PRD-15 and confirm the `CURRENT` record is still fresh
4. transition to `PORTABILITY_ELIGIBLE` or `PORTABILITY_BLOCKED`
5. transition to `LOA_READY`
6. transition to `LOA_SUBMITTED`

Use the guarded PRD-90 operations from the module runbook once that module exists. Until then, PRD-15 remains the only implemented source of truth for the pre-LOA gate in this repo.

---

## Phase 1 — Pre-Porting Preparation

### 1.1 — Audit the legacy number inventory

Collect the following for every number being ported:

| Field | Description |
|---|---|
| E.164 number | Full number in +1XXXXXXXXXX format |
| Current carrier/system | RingCentral, 8x8, Cisco UCM, Avaya, etc. |
| Account number at current carrier | Required for LOA |
| Authorized contact name | Name on the carrier account — must match LOA exactly |
| Service address | Address on file with the carrier — must match LOA exactly |
| Number type | DID or toll-free |
| Business purpose | What this number does today (main line, sales, support, etc.) |
| Target contact flow in Connect | Which PRD-14 flow should handle calls after cutover |

Do not submit an LOA without this information. Carrier mismatches on the LOA are the most common cause of porting rejections and delays.

### 1.2 — Confirm PRD-14 readiness

Before proceeding, verify that the contact flows intended for the ported numbers are deployed and tested:

```bash
export AWS_PROFILE=<aws_profile_dev>

INSTANCE_ID=$(aws connect list-instances \
  --query "InstanceSummaryList[0].Id" --output text)

# List deployed contact flows
aws connect list-contact-flows \
  --instance-id ${INSTANCE_ID} \
  --query "ContactFlowSummaryList[*].{Name:Name,Type:ContactFlowType,Id:Id}" \
  --output table
```

Confirm the target flows are present and have been tested with at least one inbound call. A flow that has never handled a live call should not be the target for a ported number cutover.

### 1.3 — Claim an interim Connect DID

Claim a new Connect DID specifically to serve as the forwarding target during the porting window. This number is temporary — it will be released after the port completes and forwarding is removed.

Add an entry to `environments/dev/phone-numbers.tfvars`:

```hcl
# Interim forwarding target for porting of +1XXXXXXXXXX
# Remove after port completes and forwarding is removed.
port-interim-XXXXXXXXXX = {
  description  = "Interim forwarding target — porting +1XXXXXXXXXX. Remove after cutover."
  type         = "DID"
  country_code = "US"
  prefix       = null
  purpose      = "port-interim"
  cost_center  = "operations"
}
```

Apply via the standard PR process (see RB-11-01). Record the E.164 digits assigned — this is the number you will forward the legacy number to.

```bash
terraform output phone_number_inventory
# Note the phone_number value for port-interim-XXXXXXXXXX
```

Also associate this interim number with the target contact flow in PRD-14 now, before forwarding is active. This ensures callers forwarded to the interim DID reach the correct flow immediately.

### 1.4 — Configure interim call forwarding on the legacy system

Set up unconditional call forwarding on the legacy system so the existing number forwards all calls to the interim Connect DID. The exact procedure depends on the legacy system:

#### RingCentral

1. Log in to the RingCentral Admin Portal
2. Navigate to **Phone System → Groups → Call Queues** (or the specific user/number)
3. Select the number being ported
4. Under **Call Handling & Forwarding**, set unconditional forwarding to the interim Connect DID
5. Verify by dialing the legacy number — the call should connect through Connect

#### 8x8

1. Log in to 8x8 Admin Console
2. Navigate to **Users** or **Ring Groups** for the number
3. Under **Call Forwarding**, enable **Always Forward** to the interim Connect DID
4. Save and verify

#### Cisco Unified Communications Manager (CUCM)

1. Log in to CUCM Administration
2. Navigate to **Call Routing → Directory Number**
3. Find the DN for the number being ported
4. Under **Call Forward and Call Pickup Settings**, set **Call Forward All** to the interim Connect DID
5. Save and verify via CUCM serviceability or a test call

#### Avaya Aura / Communication Manager

1. Log in to Avaya System Manager or Communication Manager
2. Navigate to the station or VDN associated with the number
3. Configure **Call Forwarding All Calls** to the interim Connect DID
4. Submit and verify

#### Generic SIP Carrier (direct PSTN)

If the number is held directly at a SIP carrier (not through a UC platform):

1. Log in to the carrier portal
2. Navigate to number management for the specific DID
3. Enable unconditional forwarding to the interim Connect DID
4. Verify via the carrier's call detail or a test call

**Verification:** After forwarding is configured, dial the legacy number from an external phone. Confirm the call connects through the Connect contact flow. Do not proceed with LOA submission until forwarding is verified working.

### 1.5 — Document the forwarding state

Record the following before submitting the LOA:

- Legacy number: `+1XXXXXXXXXX`
- Forwarding to (interim Connect DID): `+1YYYYYYYYYY`
- Forwarding configured on: [date and time]
- Configured by: [name]
- Verified working: [yes/no + test call timestamp]

---

## Phase 2 — LOA Submission and Carrier Coordination

### 2.1 — Submit the LOA to AWS

Porting requests are submitted through the Amazon Connect console — there is no CLI or Terraform mechanism for this step.

1. Log in to the AWS Console
2. Navigate to **Amazon Connect → your instance → Phone numbers**
3. Select **Port phone numbers**
4. Complete the LOA form:
   - Carrier account number (from Phase 1 audit)
   - Authorized contact name (must match carrier records exactly)
   - Service address (must match carrier records exactly)
   - List of numbers being ported (E.164 format)
5. Upload any supporting documentation the carrier requires (bill copy, etc.)
6. Submit

AWS will acknowledge the request and begin coordination with the losing carrier. You will receive a FOC (Firm Order Commitment) date — the date/time the port will complete.

### 2.2 — Record the FOC date

When AWS provides the FOC date, record it:

- FOC date and time (note the timezone — AWS typically provides UTC)
- Numbers included in this FOC
- AWS porting case/ticket reference number

The FOC date is not negotiable after it is set. If you need to change it, you must contact AWS Support and the losing carrier — expect delays.

### 2.3 — Monitor the porting request

During the 2–4 week porting window:

- Do not remove call forwarding from the legacy system
- Do not decommission or modify the legacy number at the old carrier
- Verify periodically that forwarding is still active (carriers occasionally reset forwarding on their own)
- Monitor the AWS porting status in the Connect console

If the port is rejected (common reasons: name/address mismatch, account number incorrect), AWS will notify you. Correct the LOA and resubmit — the timeline resets.

---

## Phase 3 — FOC Day Cutover

The FOC cutover window is typically a few hours, not an exact minute. Someone must be available on the FOC date to complete the steps below within minutes of the port completing.

### 3.1 — Pre-FOC checklist (day before)

- [ ] Confirm on-call engineer is available for the full FOC window
- [ ] Confirm interim forwarding is still active — test dial the legacy number
- [ ] Confirm the target contact flow in Connect is operational — test dial the interim DID
- [ ] Have the Connect console open and ready
- [ ] Have the AWS CLI authenticated and ready
- [ ] Know the Connect instance ID
- [ ] Have this runbook open

### 3.2 — Monitor for port completion

During the FOC window, monitor for the number appearing in Connect:

```bash
export AWS_PROFILE=<aws_profile_prod>   # use the prod profile for prod cutover

INSTANCE_ID=<your-connect-instance-id>

# Poll until the ported number appears
watch -n 30 "aws connect list-phone-numbers-v2 \
  --instance-id ${INSTANCE_ID} \
  --query \"ListPhoneNumbersSummaryList[?PhoneNumber=='+1XXXXXXXXXX']\""
```

When the port completes, the number will appear in this output. This is your signal to proceed immediately.

### 3.3 — Immediately associate the number with a contact flow (console)

At the moment the ported number appears in Connect, associate it with the target contact flow via the console. Do this immediately — do not wait for Terraform. The Terraform import comes later.

1. In the AWS Console, navigate to **Amazon Connect → your instance → Phone numbers**
2. Find the newly ported number in the list
3. Click the number to edit it
4. Under **Contact flow / IVR**, select the target contact flow
5. Save

**Verify immediately:** Dial the ported number from an external phone. Confirm the call connects through the correct contact flow. Callers are now on Connect.

At this point, interim forwarding is still active on the legacy system — but the ported number now routes directly to Connect without needing the forward. Both paths reach Connect. This is safe.

### 3.4 — Verify call quality and routing

Before removing forwarding, spend 15–30 minutes confirming:

- [ ] Inbound calls to the ported number connect to the correct contact flow
- [ ] DTMF tones work correctly through the flow
- [ ] Calls route to the correct queue and are answered by agents
- [ ] Call recording is functioning (if enabled)
- [ ] No unusual latency or audio quality issues

If any issues are found at this stage, the forwarding on the legacy system is still active as a fallback. Do not remove it until call quality is confirmed.

### 3.5 — Future PRD-91 operator sequence

When PRD-91 is implemented, the intended operator sequence replaces ad-hoc live mutation with guarded handler calls.

Expected sequence:

1. run `check_cutover_readiness` in `DRY_RUN` mode
2. confirm `status = READY`
3. run `execute_switchover` in `EXECUTE` mode
4. run `verify_post_cutover_health`
5. run `execute_rollback` only if health verification or live-call validation fails

Illustrative readiness call:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cutover-readiness-<env> \
  --payload '{
    "migration_unit_id": "mu-main-inbound-001",
    "phone_number": "+1XXXXXXXXXX",
    "operator_identity": "<operator_email>",
    "request_id": "cutover-readiness-001",
    "invocation_mode": "DRY_RUN",
    "target_contact_flow_ref": "main-inbound",
    "operator_prerequisites": {
      "foc_window_open": true,
      "on_call_present": true,
      "legacy_forwarding_still_available": true
    }
  }' \
  --cli-binary-format raw-in-base64-out \
  readiness.json
```

Illustrative switchover call:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cutover-switchover-<env> \
  --payload '{
    "migration_unit_id": "mu-main-inbound-001",
    "phone_number": "+1XXXXXXXXXX",
    "operator_identity": "<operator_email>",
    "request_id": "cutover-switchover-001",
    "invocation_mode": "EXECUTE",
    "target_contact_flow_ref": "main-inbound",
    "expected_previous_target_ref": "legacy-forwarded-interim-did",
    "readiness_request_id": "cutover-readiness-001",
    "operator_notes": "FOC window opened and external readiness confirmed."
  }' \
  --cli-binary-format raw-in-base64-out \
  switchover.json
```

Illustrative health-check call:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cutover-health-<env> \
  --payload '{
    "migration_unit_id": "mu-main-inbound-001",
    "phone_number": "+1XXXXXXXXXX",
    "operator_identity": "<operator_email>",
    "request_id": "cutover-health-001",
    "invocation_mode": "EXECUTE",
    "expected_contact_flow_ref": "main-inbound"
  }' \
  --cli-binary-format raw-in-base64-out \
  health.json
```

Illustrative rollback call:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cutover-rollback-<env> \
  --payload '{
    "migration_unit_id": "mu-main-inbound-001",
    "phone_number": "+1XXXXXXXXXX",
    "operator_identity": "<operator_email>",
    "request_id": "cutover-rollback-001",
    "invocation_mode": "EXECUTE",
    "operator_notes": "Health check failed; restoring prior association."
  }' \
  --cli-binary-format raw-in-base64-out \
  rollback.json
```

Do not invent direct mutation payloads outside those guarded operations once PRD-91 exists.

---

## Phase 4 — Remove Interim Forwarding

Only proceed when Phase 3 verification is complete and call quality is confirmed.

### 4.1 — Remove call forwarding on the legacy system

Reverse the forwarding configuration applied in Phase 1 Step 4. Specific steps vary by legacy system — refer to the same system-specific instructions in Phase 1.4 and disable the **Call Forward All** setting.

**Verify:** Dial the ported number. The call should still connect to the same Connect contact flow — now via the ported number directly, not via forwarding.

Dial the interim Connect DID directly. It should still connect to the same contact flow (the interim number is still claimed and associated — you will clean it up in the next step).

### 4.2 — Remove the interim DID

The interim Connect DID is no longer needed.

Primary procedure:

- follow the number-removal flow in [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)

Porting-specific note:

- do not release the interim DID until the ported number has handled stable production traffic and forwarding has already been removed

---

## Phase 5 — Import Ported Number into Terraform State

The ported number exists in Connect but is not yet managed by Terraform. This step brings it under the `l1-phone-numbers` module.

### 5.1 — Find the phone number ID

```bash
export AWS_PROFILE=<aws_profile_prod>

PHONE_NUMBER_ID=$(aws connect list-phone-numbers-v2 \
  --instance-id ${INSTANCE_ID} \
  --query "ListPhoneNumbersSummaryList[?PhoneNumber=='+1XXXXXXXXXX'].PhoneNumberId" \
  --output text)

echo "Phone Number ID: ${PHONE_NUMBER_ID}"
```

Verify this returns a single ID, not empty or multiple results.

> **Note on ID format:** Ported number IDs use the same format as claimed numbers (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`). Always verify via `list-phone-numbers-v2` — do not assume the format or guess the ID.

### 5.2 — Add the entry to the phone-numbers tfvars

Add the ported number to `environments/prod/phone-numbers.tfvars` (or `environments/dev/phone-numbers.tfvars` for a dev import). Use the same key you intend to use permanently.

```hcl
main-inbound = {
  description  = "Main inbound DID — primary customer number (ported from RingCentral)"
  type         = "DID"
  country_code = "US"
  prefix       = null   # prefix is irrelevant for ported numbers — digits are already fixed
  purpose      = "main-inbound"
  cost_center  = "operations"
}
```

**Do not apply yet.** Adding the tfvars entry before the import would cause Terraform to attempt to claim a new number rather than import the existing one.

### 5.3 — Run the import locally

```bash
cd connect-pbx/modules/l1-phone-numbers

terraform workspace select prod   # or dev

terraform import \
  'aws_connect_phone_number.inventory["main-inbound"]' \
  ${PHONE_NUMBER_ID}
```

### 5.4 — Verify with a plan

```bash
terraform plan \
  -var-file="../../environments/prod/global.tfvars" \
  -var-file="../../environments/prod/phone-numbers.tfvars"
```

The plan must show **no changes** for the imported number. If it shows changes (e.g., tags to add), those are legitimate and will be applied on the next apply to bring the resource into compliance with the Terraform config.

If the plan shows the resource will be **replaced** or **destroyed and recreated**, stop immediately. Do not apply. The import may have used the wrong resource address or ID. Re-examine the import command and the tfvars entry.

### 5.5 — Commit and push

Commit the updated tfvars file and push. Open a PR. The CI pipeline will plan against the imported state and confirm a clean plan. Merge to finalize.

```bash
git checkout -b import-ported-main-inbound
git add connect-pbx/environments/prod/phone-numbers.tfvars
git commit -m "feat(prd-11): import ported number +1XXXXXXXXXX as main-inbound"
git push origin import-ported-main-inbound
```

### 5.6 — Verify tagging after import

After the apply (or plan confirm), verify that the required tags are present on the ported number in Connect:

```bash
export AWS_PROFILE=<aws_profile_prod>

# Get the phone number ARN for the ported number
PHONE_NUMBER_ARN=$(aws connect list-phone-numbers-v2 \
  --instance-id ${INSTANCE_ID} \
  --query "ListPhoneNumbersSummaryList[?PhoneNumber=='+1XXXXXXXXXX'].PhoneNumberArn" \
  --output text)

# Verify tags
aws connect list-tags-for-resource \
  --resource-arn ${PHONE_NUMBER_ARN} \
  --query "tags"
```

Confirm the following tags are present: `Layer = L1`, `PRD = PRD-11`, `Purpose`, `CostCenter`, `NumberKey`. If any are missing, the import ran but the tags were not applied — run a `terraform apply` to bring the resource into full compliance.

After confirming tags, the future PRD-90 integration path is:

```bash
aws lambda invoke \
  --function-name <org_prefix>-migration-state-<env> \
  --payload '{
    "operation": "record_tag_verification",
    "request_id": "cutover-verify-001",
    "operator_identity": "<operator_email>",
    "phone_number": "+1XXXXXXXXXX",
    "tags_verified": true,
    "operator_notes": "Terraform import complete and PRD-11 tags verified."
  }' \
  --cli-binary-format raw-in-base64-out \
  porting-complete.json
```

Then transition the porting record from `IMPORT_VERIFICATION_PENDING` to `COMPLETE` using PRD-90's guarded `transition_porting_state` operation. Do not use a raw status-only payload.

### 5.7 — Post-import spam check and CNAM registration

A ported number inherits the prior holder's spam reputation and CNAM.

Primary procedures:

- run [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md)
- run [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md)

Required outcomes before calling the port complete:

- spam reputation check completed and no unresolved `SPAM` label remains
- CNAM registration submitted for the correct company or employee policy
- follow-up verification scheduled per RB-11-06

---

## Phase 6 — Decommission Legacy System

Only after:
- [ ] Ported number is confirmed routing correctly in Connect
- [ ] Interim forwarding is removed
- [ ] Number is imported into Terraform state
- [ ] At least 48 hours of stable operation observed

Proceed with decommissioning the number from the legacy carrier/platform:

1. Cancel the number at the legacy carrier (it has been ported — it no longer exists at the old carrier, but any associated billing or routing config can be removed)
2. Remove the number from the legacy PBX dial plan
3. Update any internal documentation referencing the old system for this number
4. If this was the last number on the legacy system, proceed with full system decommissioning per the client migration plan

---

## Rollback Procedures

### Rollback during Phase 2 (before FOC date)

Cancel the porting request via the AWS Connect console or AWS Support before the FOC date. The number remains at the old carrier. Remove the interim forwarding configuration.

### Rollback on FOC day (port just completed, issues found)

You cannot reverse a completed port via Terraform or the console. Options:

1. **Leave calls on Connect and fix the flow issue** — this is almost always faster than a rollback. The interim forwarding target (interim DID) is still associated with the flow. Re-enable forwarding on the legacy system to the interim DID as a temporary bypass if needed while fixing the flow.

2. **Contact AWS Support immediately** — AWS can initiate a port-back to the original carrier, but this takes days and is not guaranteed. Use this only for catastrophic failures.

The best rollback is prevention — Phase 3 verification and having the legacy forwarding active as a fallback during the verification window.

### Rollback after Phase 4 (forwarding already removed)

If issues surface after forwarding is removed:

1. Re-enable forwarding on the legacy system to the interim Connect DID (the interim DID is still active until Phase 4.2 is completed)
2. Diagnose and fix the contact flow issue
3. Re-verify, then re-remove forwarding

This is why the interim DID should not be released until 48 hours of stable operation are observed.

---

## Reference: FOC Day Quick Reference Card

Print or bookmark this section for FOC day.

```
FOC DAY CHECKLIST
=================
[ ] On-call engineer available
[ ] Connect console open
[ ] AWS CLI authenticated (correct profile/account)
[ ] This runbook open

WHEN PORT COMPLETES:
  1. Run: aws connect list-phone-numbers-v2 --instance-id <ID>
     Confirm +1XXXXXXXXXX appears in list

  2. Connect console → Phone numbers → Find +1XXXXXXXXXX
     Edit → Assign contact flow → Save

  3. Test dial +1XXXXXXXXXX from external phone
     Confirm correct flow answers

  4. Monitor 15-30 min for call quality

  5. Remove forwarding on legacy system

  6. Test dial again — confirm still works

  7. Begin Terraform import (Phase 5)

EMERGENCY CONTACTS:
  AWS Support: https://console.aws.amazon.com/support
  Legacy carrier support: [fill in before FOC day]
```

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)
- [RB-11-04-pre-loa-portability-verification.md](RB-11-04-pre-loa-portability-verification.md)
- [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md)
- [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md)
- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)
