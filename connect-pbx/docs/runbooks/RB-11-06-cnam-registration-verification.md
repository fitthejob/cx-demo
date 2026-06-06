# RB-11-06 — CNAM Registration & Verification

**Runbook ID:** RB-11-06
**Module:** l1-cnam-registry (PRD-17)
**Audience:** Platform Engineer, Operations Manager
**Last Updated:** 2026-03-30

---

## Overview

CNAM (Caller ID Name) is what recipients see alongside your phone number when you call them. Amazon Connect does not manage CNAM — it is a carrier-side database record. This runbook covers how to register, verify, and maintain CNAM records for all Connect DIDs on this platform.

Current implementation note:
- PRD-17 is implemented in this repo and validated in `dev`.
- The commands below reflect the live CLI-first operator flow for the deployed module.
- Desired CNAM inventory may be Terraform-managed for small deployments, but provider submission remains an explicit CLI/pipeline action.

CNAM must be registered after:
- New DIDs are claimed via Terraform apply (RB-11-01)
- Numbers are ported into Connect (RB-11-02)
- Company name changes
- Employee name changes (employee-name CNAM policy deployments)

**Prerequisites:** Run RB-11-05 (spam reputation check) before registering CNAM. The CNAM provisioner reads the PRD-16 `CURRENT` record and will skip numbers whose current reputation state is not CNAM-eligible.

---

## Step 1 — Determine CNAM Policy

Before registering CNAM, confirm which policy applies to this deployment. This is set in `var.cnam_policy` in the `l1-cnam-registry` module tfvars.

| Policy | When to Use |
|---|---|
| `company` | All numbers display the same company name. Appropriate for contact centers and for PBX deployments where a unified brand identity is preferred. |
| `employee` | Each number displays an individual employee name. Appropriate for PBX deployments where employees want their personal caller ID visible. |

**The 15-character limit is a hard NANPA standard constraint.** There are no exceptions.

Common company name truncations:
- "ACME CORPORATION" → "ACME CORP" (9 chars ✓)
- "SMITH & JONES LLC" → "SMITH & JONES" (13 chars ✓)
- "METROPOLITAN HOSP" → "METRO HOSPITAL" (14 chars ✓)

Test your CNAM string:
```bash
echo -n "YOUR COMPANY NAME" | wc -c
# Must be ≤ 15
```

---

## Step 2 — Register CNAM for New Numbers

### Company-name policy

```bash
export AWS_PROFILE=<aws_profile_dev>

# Get newly claimed numbers from Terraform output
cd connect-pbx/modules/l1-phone-numbers
terraform workspace select dev

NEW_NUMBERS=$(terraform output -json phone_number_inventory | \
  jq -r '[.[] | .phone_number]')

# Invoke CNAM provisioner
LAMBDA_NAME="<org_prefix>-cnam-provisioner-<env>"

aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload "{\"operation\":\"SUBMIT_NUMBERS\",\"numbers\": ${NEW_NUMBERS},\"request_id\":\"cnam-submit-2026-03-30-01\",\"operator_identity\":\"<operator_email>\"}" \
  --cli-binary-format raw-in-base64-out \
  cnam-submission-results.json

cat cnam-submission-results.json | jq '.'
```

### Employee-name policy (single number)

```bash
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload '{
    "operation": "UPSERT_DESIRED_RECORDS",
    "request_id": "cnam-upsert-2026-03-30-01",
    "operator_identity": "<operator_email>",
    "records": [
      {"phone_number": "+12125550100", "cnam": "J SMITH"},
      {"phone_number": "+12125550101", "cnam": "SALES DEPT"}
    ]
  }' \
  --cli-binary-format raw-in-base64-out \
  cnam-submission-results.json

cat cnam-submission-results.json | jq '.'

# Submit the newly upserted PENDING records to the provider
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload '{"operation":"SUBMIT_PENDING","request_id":"cnam-submit-pending-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  cnam-submit-pending-results.json

cat cnam-submit-pending-results.json | jq '.'
```

### Employee-name policy (bulk — PBX scale)

For deployments with many employee DIDs, use the CSV bulk import.

The optional S3-trigger path is a future enhancement, not part of the current implementation in this repo. The authoritative contract today is that CSV ingestion lands in `UPSERT_DESIRED_RECORDS`, followed by an explicit `SUBMIT_PENDING` invocation.

```bash
# Prepare the bulk CSV file
cat > cnam-bulk.csv << 'EOF'
+12125550100,J SMITH
+12125550101,M JONES
+12125550102,SALES DEPT
+12125550103,SUPPORT
+12125550104,BILLING
EOF

# Validate all CNAM strings are ≤ 15 characters
awk -F',' '{
  len = length($2);
  if (len > 15) print "ERROR: " $1 " CNAM \"" $2 "\" is " len " chars (max 15)";
  else print "OK: " $1 " (" len " chars)"
}' cnam-bulk.csv

# Future enhancement only: upload to an S3 trigger bucket
aws s3 cp cnam-bulk.csv s3://<state_bucket_name>/cnam-bulk-imports/$(date +%Y%m%d)-bulk.csv
```

If a future S3 upload path is implemented, the upload can trigger the Lambda via an S3 event notification. In the current implementation, invoke `UPSERT_DESIRED_RECORDS` directly and then monitor progress:

```bash
# Watch records in PENDING state via the status GSI
watch -n 10 "aws dynamodb query \
  --table-name <org_prefix>-cnam-inventory-<env> \
  --index-name status-by-scope \
  --key-condition-expression 'status_scope = :status' \
  --expression-attribute-values '{\":status\":{\"S\":\"PENDING\"}}' \
  --query 'Items[*].{Number:phone_number.S, Status:submission_status.S, Error:error_message.S}' \
  --output table"
```

After desired inventory is present, invoke submission explicitly:

```bash
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload '{"operation":"SUBMIT_PENDING","request_id":"cnam-submit-pending-2026-03-30-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  cnam-submit-pending-results.json

cat cnam-submit-pending-results.json | jq '.'
```

---

## Step 3 — Verify CNAM Propagation

CNAM records take **24–72 hours** to propagate through carrier databases. Do not verify immediately after submission.

Run the CNAM verifier Lambda after 48 hours:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cnam-verifier-<env> \
  --payload '{"operation":"VERIFY_ACTIVE","request_id":"cnam-verify-2026-04-01-01","operator_identity":"<operator_email>"}' \
  --cli-binary-format raw-in-base64-out \
  cnam-verification-results.json

cat cnam-verification-results.json | jq '.'
```

Check the results in the DynamoDB table:

```bash
aws dynamodb scan \
  --table-name <org_prefix>-cnam-inventory-<env> \
  --query "Items[*].{Number:phone_number.S, Desired:desired_cnam.S, Actual:actual_cnam.S, Status:submission_status.S}" \
  --output table
```

| Status | Meaning | Action |
|---|---|---|
| `VERIFIED` | Actual CNAM matches desired CNAM | None — complete |
| `SUBMITTED` | Submitted but not yet verified | Wait another 24 hours and re-run verifier |
| `DRIFT_DETECTED` | Actual CNAM differs from desired | See Step 5 |
| `FAILED` | Submission failed at provider API | See Step 4 |
| `PENDING` | Lambda has not processed this record yet | Check Lambda logs for errors |

---

## Step 4 — Resolving Submission Failures

Query failed records using the status GSI:

```bash
aws dynamodb query \
  --table-name <org_prefix>-cnam-inventory-<env> \
  --index-name status-by-scope \
  --key-condition-expression "status_scope = :failed" \
  --expression-attribute-values '{":failed": {"S": "FAILED"}}' \
  --query "Items[*].{Number:phone_number.S, Error:error_message.S}" \
  --output table
```

Common failure causes and resolutions:

| Error Message | Cause | Resolution |
|---|---|---|
| `Number not found in CNAM database` | Number too recently claimed — not yet in NANPA database | Wait 24 hours after claiming; retry |
| `CNAM string exceeds maximum length` | String is > 15 chars | Shorten the CNAM string and resubmit |
| `Authentication failed` | API credentials expired | Rotate credentials in Secrets Manager; redeploy Lambda |
| `Number is not owned by this account` | CNAM provider doesn't recognize AWS as the authoritative carrier for this number | For ported numbers, wait 72 hours post-port for NANPA database to update carrier records |
| `Rate limit exceeded` | Too many submissions in batch | Lambda will retry with backoff; check logs for retry status |

Retry failed records through the guarded provisioner action:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cnam-provisioner-<env> \
  --payload '{"operation":"REQUEUE_NUMBERS","request_id":"cnam-requeue-2026-03-30-01","operator_identity":"<operator_email>","status":"FAILED"}' \
  --cli-binary-format raw-in-base64-out \
  retry-results.json
```

---

## Step 5 — Resolving CNAM Drift (ALARM-17-02)

CNAM drift occurs when the CNAM registered at the provider differs from the desired CNAM. This can happen if:
- A carrier re-sets the CNAM on a ported number
- The prior RespOrg (for toll-free) updated their records after porting
- The CNAM provisioner submitted incorrect data

Query drift records using the status GSI:

```bash
aws dynamodb query \
  --table-name <org_prefix>-cnam-inventory-<env> \
  --index-name status-by-scope \
  --key-condition-expression "status_scope = :drift" \
  --expression-attribute-values '{":drift": {"S": "DRIFT_DETECTED"}}' \
  --query "Items[*].{Number:phone_number.S, Desired:desired_cnam.S, Actual:actual_cnam.S}" \
  --output table
```

Remediation: requeue the drifted records through `REQUEUE_NUMBERS` and then re-run submission (same as Step 4 retry procedure). The provisioner will resubmit the desired CNAM and overwrite the drifted record.

---

## Step 6 — Updating CNAM After Company Name Change

When a company rebrands or changes name:

1. Update `var.cnam_company_name` in the `l1-cnam-registry` module tfvars
2. Open a PR and apply via the standard pipeline
3. Requeue or upsert the desired records if needed, then invoke `SUBMIT_PENDING`
4. Verify propagation per Step 3 (allow 48–72 hours)

---

## Step 7 — Updating CNAM After Employee Name Change (Employee Policy)

For employee-name CNAM, when an employee's name changes (legal name change, role change):

1. Update the `cnam_name` field in `environments/{env}/phone-numbers.tfvars` for that employee's number entry
2. Open a PR and apply
3. Upsert or requeue the affected record if needed, then invoke `SUBMIT_PENDING`
4. Verify propagation per Step 3

For a direct urgent update without a full Terraform apply:

```bash
aws lambda invoke \
  --function-name <org_prefix>-cnam-provisioner-<env> \
  --payload '{
    "operation": "UPSERT_DESIRED_RECORDS",
    "request_id": "cnam-urgent-update-2026-03-30-01",
    "operator_identity": "<operator_email>",
    "records": [
      {"phone_number": "+12125550100", "cnam": "NEW NAME"}
    ]
  }' \
  --cli-binary-format raw-in-base64-out \
  urgent-cnam-update.json
```

---

## Post-Port CNAM Registration Checklist

When a number is ported into Connect (RB-11-02), run CNAM registration within 24 hours of cutover. The ported number inherits the prior holder's CNAM:

```
POST-PORT CNAM CHECKLIST
========================
[ ] Spam reputation check completed (RB-11-05) — current record is CNAM-eligible
[ ] CNAM provisioner invoked for ported number
[ ] Submission status = SUBMITTED in DynamoDB
[ ] Verifier run after 48 hours — status = VERIFIED
[ ] CNAM confirmed via test call from external phone
Verified by:   [name]
Date:          [YYYY-MM-DD]
```

Make a test call from a mobile phone (not from the same carrier as your Connect instance) and verify that the displayed caller name matches the registered CNAM.

---

## Troubleshooting

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)
- [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md)
- [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md)

| Problem | Likely Cause | Resolution |
|---|---|---|
| No records in CNAM inventory table | PRD-17 module not deployed, `UPSERT_DESIRED_RECORDS` not invoked, or Lambda failed silently | Check Lambda CloudWatch logs; verify module is applied and desired inventory was seeded |
| All records stuck in PENDING | `SUBMIT_PENDING` has not been invoked, or a future trigger path is misconfigured | Manually invoke `SUBMIT_PENDING`; check scheduled verification only if using it |
| CNAM shows as blank after 72 hours | Provider rejected submission without error | Check provider API logs; contact provider support with the number and submission timestamp |
| Caller on AT&T sees different CNAM than Verizon caller | Different CNAM registries used by different carriers | Normal behavior during propagation; submit to both Neustar and iconectiv if discrepancy persists >72 hours |
| CNAM shows prior company name after company rebrand | CNAM drift — prior record not overwritten | Requeue the record and resubmit; some carriers cache CNAM for 24–48 hours |
