# RB-11-01 — Adding New Phone Numbers

**Runbook ID:** RB-11-01
**Module:** l1-phone-numbers (PRD-11)
**Audience:** Platform Engineer
**Last Updated:** 2026-03-22

---

## Overview

This runbook covers the end-to-end procedure for adding a new phone number to an existing Connect instance. The number inventory is managed exclusively via Terraform — no numbers are claimed manually in the Connect console.

When you add an entry to the number inventory tfvars file and apply, AWS claims the next available number from its telephony pool for the specified country, type, and optional area code prefix. **You do not specify the exact digits.** The actual E.164 number assigned is available in Terraform outputs after the apply completes.

---

## Prerequisites

Before starting, confirm:

| Requirement | Verification |
|---|---|
| l1-phone-numbers module is deployed | `terraform state list` shows `aws_connect_phone_number.inventory` resources |
| PRD-14 (contact flows) is deployed | New number will be reachable but unrouted until a flow is associated |
| AWS service quota allows additional numbers | Default quota is 10 per instance — verify current count before adding |
| AWS profile is set to the correct account | `aws sts get-caller-identity` returns expected account ID |
| You are working against the correct environment | Confirm `dev` vs `prod` before proceeding |

### Check current number count

```bash
export AWS_PROFILE=<aws_profile_dev>   # or <aws_profile_prod>

INSTANCE_ID=$(terraform -chdir=connect-pbx/modules/l1-connect-instance \
  output -raw connect_instance_id)

aws connect list-phone-numbers-v2 \
  --instance-id ${INSTANCE_ID} \
  --query "length(ListPhoneNumbersSummaryList)"
```

If the count is at or near your quota limit, request a service quota increase before proceeding. See PRD-10 Section 8.

---

## Step 1 — Determine number requirements

Collect the following from the requestor before editing any files:

| Field | Description | Example |
|---|---|---|
| **Key** | Human-readable identifier for this number in Terraform | `sales`, `support-tier2`, `billing` |
| **Description** | Plain-text description visible in the Connect console | `Sales team direct DID` |
| **Type** | `DID` (local inbound) or `TOLL_FREE` (800/888/877) | `DID` |
| **Country code** | ISO 3166-1 alpha-2 | `US` |
| **Prefix** | Area code preference in E.164 format, or `null` for any available | `+1212` or `null` |
| **Purpose** | Routing/reporting label | `sales` |
| **Cost center** | Business unit for cost allocation tagging | `sales` |

**On prefix availability:** AWS does not guarantee that a requested prefix has available inventory. If the apply fails due to unavailable prefix, work with the requestor to identify an acceptable alternative area code, or set `prefix = null` to accept any available US number.

---

## Step 2 — Edit the number inventory tfvars

Open `connect-pbx/environments/dev/phone-numbers.tfvars` (or `connect-pbx/environments/prod/phone-numbers.tfvars` for production).

Add the new entry to the `phone_numbers` map:

```hcl
phone_numbers = {

  main-inbound = {
    description  = "Main inbound DID — primary customer-facing number"
    type         = "DID"
    country_code = "US"
    prefix       = null
    purpose      = "main-inbound"
    cost_center  = "operations"
  }

  # New entry:
  sales = {
    description  = "Sales team direct DID"
    type         = "DID"
    country_code = "US"
    prefix       = "+1212"   # Request NYC area code — not guaranteed
    purpose      = "sales"
    cost_center  = "sales"
  }

}
```

**Do not modify** unrelated module `.tf` files for day-to-day number management. The environment-folder tfvars files are the only files that should change routinely.

---

## Step 3 — Run a plan locally and review

```bash
export AWS_PROFILE=<aws_profile_dev>
cd connect-pbx/modules/l1-phone-numbers

BOOTSTRAP_DIR="${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/<github_repo>/bootstrap}"
terraform init -backend-config="${BOOTSTRAP_DIR}/backend-<aws_profile_dev>.hcl"
terraform workspace select dev

terraform plan \
  -var-file="../../environments/dev/global.tfvars" \
  -var-file="../../environments/dev/phone-numbers.tfvars"
```

Review the plan output. You should see exactly one new resource:

```
# aws_connect_phone_number.inventory["sales"] will be created
+ resource "aws_connect_phone_number" "inventory" {
    + country_code = "US"
    + description  = "Sales team direct DID"
    + prefix       = "+1212"
    + type         = "DID"
    + target_arn   = "arn:aws:connect:us-east-1:..."
    + tags         = {
        + "CostCenter" = "sales"
        + "Layer"      = "L1"
        + "NumberKey"  = "sales"
        + "PRD"        = "PRD-11"
        + "Purpose"    = "sales"
      }
  }
```

If the plan shows any unexpected changes to existing numbers, stop and investigate before proceeding.

---

## Step 4 — Open a pull request

Commit the tfvars change and open a PR:

```bash
git checkout -b add-sales-did
git add connect-pbx/environments/dev/phone-numbers.tfvars
git commit -m "feat(prd-11): add sales DID to dev number inventory"
git push origin add-sales-did
```

The CI pipeline will:
1. Run a security scan (checkov, tfsec)
2. Run `terraform plan` and post the output as a PR comment
3. Gate the merge on a clean plan

Review the plan comment in the PR. Confirm it matches what you saw locally.

---

## Step 5 — Merge and verify

After the PR is approved and merged, the CI pipeline applies the change automatically for `dev`. For `prod`, a manual dispatch is required per PRD-01.

After the apply completes, verify the number was claimed:

```bash
# Check the Terraform output for the actual E.164 digits assigned
terraform output phone_number_inventory

# Verify in Connect directly
aws connect list-phone-numbers-v2 \
  --instance-id ${INSTANCE_ID} \
  --query "ListPhoneNumbersSummaryList[?PhoneNumberCountryCode=='US']"
```

The `phone_number_inventory` output will show the actual digits:

```json
{
  "sales": {
    "arn": "arn:aws:connect:us-east-1:...",
    "cost_center": "sales",
    "country_code": "US",
    "description": "Sales team direct DID",
    "phone_number": "+12125550142",
    "prefix": "+1212",
    "purpose": "sales",
    "type": "DID"
  }
}
```

---

## Step 6 — Associate with a contact flow (PRD-14)

A newly claimed number is in `CLAIMED` state when held by the Connect instance. It is not ready for external use until the PRD-14 association step succeeds.

To associate the number with a flow, update the PRD-14 tfvars to map the new number key to the appropriate contact flow. See the PRD-14 runbook for the association procedure.

Primary procedure:

- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)

Until a flow is associated and verified, **do not publish the number externally.**

### Step 6.1 — Verify the association actually succeeded

After the PRD-14 apply completes, confirm the association helper returned success.

Example from `connect-pbx/modules/l1-contact-flow-framework`:

```bash
cat .build/phone-association-<number-key>.json
```

Expected success shape:

```json
{
  "status": "associated",
  "phone_number_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "contact_flow_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

If the file contains an error payload such as `AccessDeniedException`, the number is still unassociated even if the flow resources themselves deployed successfully.

### Step 6.2 — Place a live test call before publishing

Dial the actual E.164 number from the `phone_number_inventory` output before publishing the number externally.

Important interpretation:

- If you hear Connect audio or the default Connect disconnect treatment, the call reached Connect and the issue is likely routing/flow-related
- If you hear a carrier intercept such as "Your call cannot be completed as dialed," the call likely did not complete end-to-end, or the number may still not be effectively associated/routable

During PRD-14 dev repair, a number produced a carrier-style failure until the phone number → flow association was fixed. Do not assume every intercept message is a pure carrier outage without verifying association success first.

---

## Removing a Number (two-step process)

`prevent_destroy = true` is active on all numbers. A single-step removal will fail with a Terraform error. The release requires two separate PRs.

### Step 1 — Remove prevent_destroy

In `connect-pbx/modules/l1-phone-numbers/main.tf`, add a `prevent_destroy = false` override for the specific number key, or temporarily set it to false for all numbers. Open a PR, merge, apply.

```hcl
# Temporary — revert after Step 2
resource "aws_connect_phone_number" "inventory" {
  for_each = var.phone_numbers
  ...
  lifecycle {
    prevent_destroy = false
  }
}
```

### Step 2 — Remove the tfvars entry

Remove the entry from the phone-numbers tfvars file. Open a second PR, merge, apply. The number is released back to the AWS pool.

**After Step 2:** Revert the `prevent_destroy = false` change back to `true` in a third PR. This restores the protection for remaining numbers.

> **WARNING:** Released numbers are permanently gone. AWS assigns them back into the general pool immediately. The same digits cannot be reclaimed. If a number is released accidentally, contact AWS Support immediately — recovery is not guaranteed.

---

## Post-Provisioning Checklist

After a new number is claimed and a contact flow is associated (Step 6), complete the following operational steps before publishing the number externally or assigning it to an employee.

```
POST-PROVISIONING CHECKLIST
=============================
Number key:             [e.g. sales]
Actual E.164 digits:    [from terraform output — e.g. +12125550142]
Environment:            [ ] dev   [ ] prod

[ ] Contact flow associated — callers no longer hear default disconnect
[ ] Spam reputation check completed — no SPAM label (RB-11-05)
      Check date: ______________________
      Spam label: ______________________
[ ] CNAM registration submitted (RB-11-06)
      Policy applied: [ ] company   [ ] employee
      CNAM string: ___________________________ (max 15 chars)
      Submission status: ______________________
[ ] E911 record created (RB-11-07) — REQUIRED for PBX employee DIDs
      Location type: [ ] OFFICE   [ ] REMOTE   [ ] N/A (contact center only)
      Provider sync status: ______________________
[ ] Number published to external directory / communicated to assignee
Completed by:  [name]
Date:          [YYYY-MM-DD]
```

**For PBX deployments (employee direct-dial):** All three checks (spam, CNAM, E911) are required before giving the number to an employee. Do not distribute the number until all checks show green.

**For contact center DIDs (main-inbound, support queue, etc.):** E911 record may not be required — verify with your E911 provider whether queue numbers require location registration. Spam and CNAM checks are still required.

---

## Troubleshooting

| Problem | Likely Cause | Resolution |
|---|---|---|
| Apply fails: `No phone numbers available for the requested prefix` | Requested area code has no inventory | Change `prefix` to a nearby area code or set `null` |
| Apply fails: `Phone number limit exceeded` | Instance quota reached | Request service quota increase via AWS Support |
| Plan shows unexpected changes to existing numbers | `target_arn` or tags changed | Review recent changes to l1-connect-instance or platform tags |
| `terraform output phone_number_inventory` shows empty map | Module not applied yet, or wrong workspace | Confirm workspace: `terraform workspace show` |
| Number appears in Connect console but not in Terraform state | Number was claimed manually or via a previous import | Run `terraform plan` — if it shows a create, the number needs to be imported. See RB-11-02. |
| Dialing the new DID returns a carrier intercept instead of Connect audio | Number may still be unassociated, association helper may have failed, or PSTN propagation is incomplete | Check `phone_number_inventory`, inspect `.build/phone-association-<number-key>.json`, confirm the number is mapped to a flow, then retest from more than one originating carrier |

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md)
- [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md)
- [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md)
- [RB-11-07-e911-location-registration-compliance.md](RB-11-07-e911-location-registration-compliance.md)
- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)
