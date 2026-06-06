# RB-11-08 — Routing Drift Investigation & Remediation

**Runbook ID:** RB-11-08
**Module:** l1-routing-drift (PRD-19)
**Audience:** Platform Engineer, On-Call Operations
**Last Updated:** 2026-03-30

---

## Overview

Routing drift occurs when phone number → contact flow routing is changed outside the Terraform-managed path. In the corrected PRD-19 model, the detector does not rely on a point-in-time Connect API read of live flow association. Instead, it combines:

- Terraform state for the expected phone number → flow mapping
- Connect phone inventory for unexpected-number detection
- CloudTrail management events for associate/disassociate/claim/release detection

The PRD-19 detector runs every 15 minutes and fires ALARM-19-01 when drift is detected.

Current implementation note:
- PRD-19 is under correction and should not yet be treated as operator-ready in this repo.
- The command contracts below define the corrected CLI-first operator flow once the CloudTrail-based detector replaces the earlier API-based prototype.
- The drift detector should consume the same manifest-driven state-resolution contract as repo deploy tooling rather than hardcoded state-key conventions.

This runbook covers:
1. Initial triage — is this a real drift or a transient condition during a legitimate apply?
2. Investigation — who made the change and when
3. Remediation — correcting via the standard pipeline
4. Post-incident — escalation if the drift recurs

---

## Trigger

**ALARM-19-01** fires when `RoutingDriftCount >= 1` for two consecutive 15-minute periods.

The two-period requirement filters out transient drift during a legitimate Terraform apply (applies can take up to 15 minutes during which the routing may temporarily differ from state). If you are in the middle of an approved apply, check GitHub Actions before investigating further.

---

## Step 1 — Triage: Is an Apply In Progress?

Before investigating drift as a problem, check if there is a legitimate Terraform apply running:

```bash
# Check GitHub Actions for any in-progress apply workflows
gh run list \
  --workflow tf-apply.yml \
  --status in_progress \
  --json status,createdAt,conclusion,url \
  --jq '.[] | {status, createdAt, url}'
```

If a legitimate apply is running:
- Wait for it to complete (typically 5–15 minutes)
- The drift detection Lambda will run again within 15 minutes of the apply completing
- If drift resolves: alarm clears automatically
- If drift persists after the apply completes: proceed to Step 2

If no apply is running: proceed to Step 2 immediately.

---

## Step 2 — Query the Drift Records

```bash
export AWS_PROFILE=<aws_profile_dev>   # or <aws_profile_prod>

TABLE_NAME="<org_prefix>-routing-drift-<env>"

# Get all unresolved drift records via the OPEN-status GSI
aws dynamodb query \
  --table-name ${TABLE_NAME} \
  --index-name status-by-scope \
  --key-condition-expression "status_scope = :open" \
  --expression-attribute-values '{":open": {"S": "OPEN"}}' \
  --query "Items[*].{
    Number:phone_number.S,
    DriftType:drift_type.S,
    Instance:instance_id.S,
    Expected:expected_flow_arn.S,
    Actual:actual_flow_arn.S,
    FirstDetected:first_detected_at.S,
    Consecutive:consecutive_detections.N
  }" \
  --output table
```

Note the following for each drift record:
- **Phone number** — which number is affected
- **Drift type** — WRONG_FLOW, NO_FLOW, or UNEXPECTED_NUMBER
- **Expected flow ARN** — what Terraform state says the routing should be
- **Actual flow ARN** — what the drift-causing CloudTrail event indicates was associated, when available
- **First detected** — when drift was first observed
- **Consecutive detections** — how many 15-minute periods this has been active

---

## Step 3 — Identify the Contact Flows Involved

For WRONG_FLOW drift, identify both the expected and observed contact flows by name:

```bash
INSTANCE_ID="<connect_instance_id>"

# Get flow name from ARN (extract the ID from the ARN first)
EXPECTED_FLOW_ARN="arn:aws:connect:<region>:<account_id>:instance/<connect_instance_id>/contact-flow/<expected_flow_id>"
ACTUAL_FLOW_ARN="arn:aws:connect:<region>:<account_id>:instance/<connect_instance_id>/contact-flow/<actual_flow_id>"

EXPECTED_FLOW_ID=$(echo ${EXPECTED_FLOW_ARN} | cut -d'/' -f5)
ACTUAL_FLOW_ID=$(echo ${ACTUAL_FLOW_ARN} | cut -d'/' -f5)

aws connect describe-contact-flow \
  --instance-id ${INSTANCE_ID} \
  --contact-flow-id ${EXPECTED_FLOW_ID} \
  --query "ContactFlow.{Name:Name, Type:Type, State:State}" \
  --output table

aws connect describe-contact-flow \
  --instance-id ${INSTANCE_ID} \
  --contact-flow-id ${ACTUAL_FLOW_ID} \
  --query "ContactFlow.{Name:Name, Type:Type, State:State}" \
  --output table
```

This tells you what the unauthorized change attempted to route to versus what it should route to. Assess the impact:
- Is the actual flow answering calls? (Any flow is better than NO_FLOW)
- Is the actual flow routing to the wrong department or business unit?
- Is this a dev/test flow accidentally associated with a production number?

---

## Step 4 — Investigate via CloudTrail

Identify who made the routing mutation and when:

```bash
# Look for Connect phone number association changes in the last 24 hours
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssociatePhoneNumberContactFlow \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --query "Events[*].{
    Time:EventTime,
    User:Username,
    Source:CloudTrailEvent
  }" \
  --output json | jq '.[] | {
    time: .Time,
    user: .User,
    detail: (.Source | fromjson | {
      phoneNumberId: .requestParameters.phoneNumberId,
      contactFlowId: .requestParameters.contactFlowId,
      sourceIPAddress: .sourceIPAddress
    })
  }'
```

Also check related events when the drift type is `NO_FLOW` or `UNEXPECTED_NUMBER`:

- `DisassociatePhoneNumberContactFlow`
- `ClaimPhoneNumber`
- `ReleasePhoneNumber`

Note the IAM principal that made the change. This is critical for the post-incident review.

---

## Step 5 — Assess Live Impact

Determine whether the detected mutation is actively causing caller issues:

```bash
# Check if calls are currently being received on the drifted number
# Look at Connect contact trace records for the last 15 minutes
aws connect search-contacts \
  --instance-id ${INSTANCE_ID} \
  --time-range InitiationTimestamp,StartTime=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%SZ),EndTime=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --filter-criteria '{"Channels": ["VOICE"]}' \
  --query "Contacts[*].{ID:Id, Queue:QueueInfo.Name, Duration:AgentInfo}" \
  --output table
```

If callers are actively being misdirected to the wrong flow, you have two options:

**Option A (faster — manual console fix):** Manually reassociate the number with the correct flow in the Connect console to immediately stop the misdirection. This creates intentional temporary drift — document it and correct via pipeline immediately after.

**Option B (pipeline fix):** Run an emergency Terraform apply via the CI/CD pipeline. This is the correct path but takes 10–20 minutes. Use Option A only if live call impact is ongoing and severe.

---

## Step 6 — Correct Via Pipeline

**Do not run `terraform apply` locally for production.** All corrections go through the CI/CD pipeline.

For PRD-14 style flow repairs, note two implementation details that were validated during dev remediation:

- `TransferToFlow` references should use the target flow ARN, not Terraform's composite resource `id`
- The local phone number → flow association helper is intentionally shell-agnostic; Terraform passes its inputs through environment variables so the same module can be run from Windows, Linux, or macOS without command-quoting differences

1. Verify the manifest-driven plan shows the expected routing correction:

```bash
cd connect-pbx
bash scripts/tf-run.sh plan dev modules/l1-phone-numbers
```

The plan should show the routing change needed to correct back to the expected state.

2. Open a PR documenting the drift correction. The PR description should include:
   - Which numbers were drifted
   - The IAM principal that made the unauthorized change (from CloudTrail)
   - The duration of the drift

3. Get the PR approved and merge. The CI/CD apply pipeline corrects the routing.

4. After the apply completes, verify the drift detector has cleared the record:

```bash
# Within 15 minutes of apply completing, check for recently resolved records
aws dynamodb scan \
  --table-name ${TABLE_NAME} \
  --filter-expression "attribute_exists(resolved_at) AND resolved_at >= :time" \
  --expression-attribute-values "{\":time\": {\"S\": \"$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)\"}}" \
  --query "Items[*].{Number:phone_number.S, DriftType:drift_type.S, ResolvedAt:resolved_at.S}" \
  --output table
```

---

## Step 7 — Post-Incident Actions

### If drift was caused by an unauthorized console change

1. **Document the incident**: create an incident record noting the number affected, duration, IAM principal, and business impact
2. **Review IAM permissions**: determine whether the IAM principal that made the change should have `connect:AssociatePhoneNumberContactFlow` permission. If not, remove it.
3. **Hardening option**: add an IAM deny policy or SCP that restricts `connect:AssociatePhoneNumberContactFlow` to the Terraform execution role only. This prevents future console-based routing changes entirely. Discuss with the team before implementing — this removes the ability to make emergency manual corrections.

```hcl
# Optional: IAM deny policy to prevent console routing changes
# Add to the platform permission boundary (PRD-02) or as an SCP
{
  "Effect": "Deny",
  "Action": "connect:AssociatePhoneNumberContactFlow",
  "Resource": "*",
  "Condition": {
    "StringNotEquals": {
      "aws:PrincipalArn": "${terraform_execution_role_arn}"
    }
  }
}
```

4. **Follow up with the engineer**: understand why the console change was made. Was it an emergency? Was the engineer unaware of the Terraform-managed policy? Update the platform onboarding documentation if needed.

### If drift was caused by a timing issue during a legitimate apply

- If this has happened more than twice: review whether the drift detection Lambda's two-period threshold should be increased to three or four periods for this environment
- Confirm the apply path is using the same manifest-driven state-resolution contract the detector consumes

### If drift was UNEXPECTED_NUMBER (console-claimed number)

A number exists in Connect but not in Terraform state. This means someone claimed a number via the console.

1. Identify the number from the drift record
2. Determine the business justification for the number
3. If legitimate: follow the import procedure (RB-11-01 import section) to bring it under Terraform management, then add it to the phone-numbers tfvars
4. If not legitimate: release the number via the AWS console and document why

---

## Quick Reference

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-13-01-queue-management.md](RB-13-01-queue-management.md)
- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)

```
DRIFT INVESTIGATION QUICK STEPS
================================
1. Check GitHub Actions for in-progress apply
   → gh run list --workflow tf-apply.yml --status in_progress

2. Query drift table
   → aws dynamodb query --table-name {table} --index-name status-by-scope [OPEN]

3. Check CloudTrail for who made the change
   → lookup-events EventName=AssociatePhoneNumberContactFlow

4. Assess live call impact
   → connect search-contacts (last 15 minutes)

5. Correct via pipeline
   → terraform plan → PR → merge → apply

6. Verify resolution
   → drift table should show resolved_at within 15 min of apply

7. Post-incident: document + review IAM permissions
```

## Troubleshooting

| Problem | Likely Cause | Resolution |
|---|---|---|
| No drift records found but callers report wrong routing | Drift may have existed before the detector was deployed, or the scan window missed the mutation event | Check CloudTrail directly for `AssociatePhoneNumberContactFlow` / `DisassociatePhoneNumberContactFlow`; validate routing through the standard PRD-14 correction path |
| All records stuck in OPEN after correction apply | A later CloudTrail restore event was not observed, or the expected state output is stale | Re-run the detector after PRD-14 apply; confirm PRD-14 state exports the corrected expected route map |
| Detector reports actual flow as the Connect instance ARN | The implementation is still using the earlier API-based prototype path instead of the corrected CloudTrail-based model | Treat the result as non-authoritative; complete the PRD-19 correction implementation before relying on alarms |
