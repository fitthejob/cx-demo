# RB-11-05 — Spam Reputation Check & Remediation

**Runbook ID:** RB-11-05
**Module:** l1-spam-reputation (PRD-16)
**Audience:** Platform Engineer, Operations Manager
**Last Updated:** 2026-03-30

---

## Overview

This runbook covers three scenarios:
1. **Post-claim check** — run immediately after new DIDs are claimed via Terraform apply
2. **Weekly scheduled scan** — the Lambda runs automatically but this runbook covers how to interpret and act on the results
3. **Alarm response** — how to investigate and remediate when ALARM-16-01 fires

For PBX deployments where employees use Connect DIDs as direct-dial business lines, no number may be assigned to an employee until its reputation check shows `spam_label = CLEAN` with a check date within 30 days.

Current implementation note:
- PRD-16 is implemented in this repo and validated in `dev`.
- The commands below reflect the live CLI-first operator flow for the deployed module.
- Optional weekly schedules may exist in some environments, but operator-triggered CLI invocation remains the authoritative path.

---

## Trigger Scenarios

| Trigger | Action Required |
|---|---|
| New DIDs claimed via `terraform apply` | Run Step 1 immediately after apply |
| Numbers ported into Connect | Run Step 1 within 24 hours of cutover (see RB-11-02) |
| ALARM-16-01 fires | Run Step 3 (investigation) |
| Weekly scheduled scan completes | Review results per Step 2 |

---

## Step 1 — Post-Claim / Post-Port Reputation Check

Run this immediately after any new numbers enter the Connect inventory.

```bash
export AWS_PROFILE=<aws_profile_dev>

# Get the list of newly claimed numbers from Terraform output
cd connect-pbx/modules/l1-phone-numbers
terraform workspace select dev

NEW_NUMBERS=$(terraform output -json phone_number_inventory | \
  jq -r '[.[] | .phone_number] | @json')

echo "Numbers to check: ${NEW_NUMBERS}"

# Invoke the reputation operations Lambda
LAMBDA_NAME="<org_prefix>-spam-reputation-check-<env>"

aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload "{\"operation\":\"CHECK_NUMBERS\",\"numbers\": ${NEW_NUMBERS},\"request_id\":\"post-claim-2026-03-30-01\",\"operator_identity\":\"<operator_email>\"}" \
  --cli-binary-format raw-in-base64-out \
  reputation-results.json

cat reputation-results.json | jq '.'
```

Review the results. Look for:
- Any `spam_label` of `RISK` or `SPAM`
- Any number with `eligibility_status = NOT_ELIGIBLE`
- Any number with missing provider scores (indicates API failure — re-run)

---

## Step 2 — Reviewing Weekly Scan Results

If the optional weekly schedule is enabled, review results after the Monday scan. The authoritative state view is the `CURRENT` record set, not historical scan rows.

### Check CURRENT records via DynamoDB GSI

```bash
export AWS_PROFILE=<aws_profile_dev>

TABLE_NAME=$(aws dynamodb list-tables \
  --query "TableNames[?contains(@, 'number-reputation')]" \
  --output text)

# Future implementation output from the PRD-16 module
CURRENT_GSI_NAME="current-by-scope"

# Show all CURRENT records with RISK or SPAM labels
aws dynamodb query \
  --table-name ${TABLE_NAME} \
  --index-name ${CURRENT_GSI_NAME} \
  --key-condition-expression "record_scope = :current" \
  --filter-expression "spam_label IN (:risk, :spam)" \
  --expression-attribute-values '{
    ":current": {"S": "CURRENT"},
    ":risk": {"S": "RISK"},
    ":spam": {"S": "SPAM"}
  }' \
  --query "Items[*].{Number:phone_number.S, Score:spam_score.N, Label:spam_label.S, Remediation:remediation_status.S, AssignedTo:assigned_to.S}" \
  --output table
```

### Check via CloudWatch

```bash
# Get the current count of high-risk numbers
aws cloudwatch get-metric-statistics \
  --namespace "ConnectPBX/dev" \
  --metric-name "NumbersWithHighSpamRisk" \
  --dimensions Name=Environment,Value=dev \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Maximum \
  --output table
```

---

## Step 3 — ALARM-16-01 Investigation

When ALARM-16-01 fires, one or more current records have exceeded the spam threshold.

```bash
# Find all CURRENT records with SPAM label and no completed replacement
aws dynamodb query \
  --table-name ${TABLE_NAME} \
  --index-name ${CURRENT_GSI_NAME} \
  --key-condition-expression "record_scope = :current" \
  --filter-expression "spam_label = :spam AND (remediation_status = :none OR remediation_status = :dispute)" \
  --expression-attribute-values '{
    ":current": {"S": "CURRENT"},
    ":spam": {"S": "SPAM"},
    ":none": {"S": "NONE"},
    ":dispute": {"S": "DISPUTE_SUBMITTED"}
  }' \
  --output json | jq '.Items[] | {
    number: .phone_number.S,
    score: .spam_score.N,
    hiya: .hiya_score.N,
    first_orion: .first_orion_score.N,
    assigned_to: .assigned_to.S
  }'
```

For each SPAM-labeled number, determine:
- Is it currently assigned to an employee DID?
- Is it currently receiving inbound calls? (Check Connect contact flow logs)
- Which provider(s) flagged it?

---

## Step 4 — Remediation Path A: Dispute (RISK label, score 30–69)

For numbers labeled RISK, attempt a business verification dispute before replacing the number.

### Hiya Business Portal

1. Navigate to `hiya.com/business`
2. Click **Register Your Business**
3. Select the number(s) to register
4. Provide business name, website, and description of outbound call purpose
5. Hiya verifies the registration (typically 3–7 business days)
6. After verification, the number receives a "Verified" badge that suppresses spam indicators

Record the remediation action through the guarded PRD-16 mutation operation:

```bash
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload '{
    "operation": "RECORD_REMEDIATION_ACTION",
    "phone_number": "+12125550100",
    "target_status": "DISPUTE_SUBMITTED",
    "provider": "hiya",
    "effective_date": "2026-03-30",
    "request_id": "remediation-2026-03-30-01",
    "operator_identity": "<operator_email>",
    "ticket_ref": "OPS-1234",
    "notes": "Submitted business verification after RISK label"
  }' \
  --cli-binary-format raw-in-base64-out \
  remediation-update.json

cat remediation-update.json | jq '.'
```

### First Orion Business Registration

1. Navigate to `firstorion.com/branded-communication`
2. Register the business and the specific phone numbers
3. First Orion provides branded caller ID display (shows business name instead of spam label) to T-Mobile subscribers

### TNS Call Guardian (AT&T network)

1. Navigate to `tnsi.com/solutions/call-guardian`
2. Submit the number for business reputation verification
3. AT&T subscribers will see the verified business name display

### Re-check after 14 days

```bash
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload '{"operation":"CHECK_NUMBERS","numbers":["+12125550100"],"request_id":"recheck-2026-04-13-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  recheck-results.json

cat recheck-results.json | jq '.results[] | {number: .phone_number, score: .spam_score, label: .spam_label}'
```

If the score has dropped below 30: invoke `RECORD_REMEDIATION_ACTION` again with `target_status = NONE` to mark the issue resolved. If not improved after 30 days: escalate to Path B.

---

## Step 5 — Remediation Path B: Number Replacement (SPAM label, score ≥ 70)

A number with SPAM label must be replaced. Do not assign it to any employee DID.

**If the number is currently assigned to an employee:**
1. Notify the employee that their DID will change
2. Update any published directories, email signatures, or business cards with the replacement number (after claiming)
3. Set up interim call forwarding from the SPAM-labeled number to a clean number during the transition

**Replacement procedure:**

```bash
# Step 1 — Remove prevent_destroy (see RB-11-01 for full procedure)
# Edit main.tf: lifecycle { prevent_destroy = false }
# Open PR, merge, apply

# Step 2 — Remove the number from phone-numbers tfvars
# Open PR, merge, apply — number is released

# Step 3 — Claim replacement
# Add new entry to phone-numbers tfvars with same purpose and cost_center
# Open PR, merge, apply

# Step 4 — Immediately check reputation of the new number
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload '{"operation":"CHECK_NUMBERS","numbers":["+1REPLACEMENT_NUMBER"],"request_id":"replacement-check-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  new-number-reputation.json

cat new-number-reputation.json | jq '.'
```

Only assign the replacement number to an employee DID if the reputation check shows `spam_label = CLEAN`.

---

## Step 6 — STIR/SHAKEN Attestation Check

If the optional attestation scan is enabled, review STIR/SHAKEN attestation status:

```bash
aws dynamodb query \
  --table-name ${TABLE_NAME} \
  --index-name ${CURRENT_GSI_NAME} \
  --key-condition-expression "record_scope = :current" \
  --filter-expression "stir_shaken_attestation IN (:b, :c)" \
  --expression-attribute-values '{
    ":current": {"S": "CURRENT"},
    ":b": {"S": "B"},
    ":c": {"S": "C"}
  }' \
  --query "Items[*].{Number:phone_number.S, Attestation:stir_shaken_attestation.S, CheckDate:attestation_check_date.S}" \
  --output table
```

For numbers with B or C attestation:
- If the number was recently ported: wait 24–72 hours for the SHAKEN database to propagate the new AWS ownership record, then re-check
- If the number was recently claimed (not ported): contact AWS Support — newly claimed numbers should receive A-level attestation immediately
- If the issue persists more than 72 hours after claiming/porting: open an AWS Support case referencing the specific DID and requesting attestation investigation

---

## Pre-Assignment Checklist for PBX Employee DIDs

Before adding a number as an employee direct-dial entry in `environments/dev/phone-numbers.tfvars`, verify:

```
PRE-ASSIGNMENT CHECKLIST
========================
Phone number:            [E.164]
Spam label:              [ ] CLEAN  (required)
Check date:              [date — must be within 30 days]
STIR/SHAKEN attestation: [ ] A  (preferred)
CNAM submitted:          [ ] Yes (RB-11-06)
E911 record exists:      [ ] Yes (RB-11-07, for PBX deployments)
Verified by:             [name]
Date:                    [YYYY-MM-DD]
```

Future automation note:
- The CI/CD pre-apply gate should invoke `VALIDATE_ASSIGNMENT_ELIGIBILITY` and fail the change when `status = NOT_ELIGIBLE`.
- That gate should read only the PRD-16 `CURRENT` record for each affected number.

---

## Troubleshooting

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)
- [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md)
- [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md)

| Problem | Likely Cause | Resolution |
|---|---|---|
| Lambda returns no scores (all null) | API credentials expired or invalid | Rotate credentials in Secrets Manager; redeploy Lambda with `terraform apply` |
| Reputation check times out for large inventory | Batch size too large for API rate limits | Check Lambda logs for rate limit errors; reduce batch size via `var.reputation_batch_size` |
| SPAM-labeled number is a brand new claim | Prior holder had spam history; number inherited it | Proceed directly to Path B replacement |
| Dispute submitted but score unchanged after 30 days | Provider did not accept the business verification | Call the provider's business support line directly; escalate within their system |
| ALARM-16-01 fires during weekly scan but no SPAM numbers visible | RISK numbers crossing alarm threshold if `alarm_on_risk_label = true` | Review alarm configuration in PRD-81; adjust threshold or `alarm_on_risk_label` variable |
