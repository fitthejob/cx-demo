# RB-14-01 — Programming Amazon Connect Contact Flows

**Runbook ID:** RB-14-01
**Module:** l1-contact-flow-framework (PRD-14)
**Audience:** Platform Engineer, Terraform Operator
**Last Updated:** 2026-03-28

---

## Overview

This runbook describes the supported workflow for authoring, validating, debugging, and deploying Amazon Connect contact flows in this repo.

Use this runbook when you are:
- changing flow JSON templates in `connect-pbx/modules/l1-contact-flow-framework/flows/`
- updating Terraform wiring for flow references in `flows.tf`
- debugging `InvalidContactFlowException`
- validating phone number → flow associations after deployment

This repo treats Amazon Connect flow authoring as:
- Terraform-managed
- provider-supported
- validated against the Connect API, not the console export format

---

## Source Of Truth

Use these references together:

- Terraform module: [modules/l1-contact-flow-framework](../../modules/l1-contact-flow-framework)
- PRD design: [PRD-14-v1.0.0-base-contact-flow-framework.md](../../../PRD_docs/PRD-14-v1.0.0-base-contact-flow-framework.md)

Practical rule:
- treat `describe-contact-flow` output and Connect validator feedback as authoritative
- do not trust console-export JSON by itself

---

## Repo Layout

Relevant paths:

- `connect-pbx/modules/l1-contact-flow-framework/flows.tf`
- `connect-pbx/modules/l1-contact-flow-framework/locals.tf`
- `connect-pbx/modules/l1-contact-flow-framework/outputs.tf`
- `connect-pbx/modules/l1-contact-flow-framework/phone-associations.tf`
- `connect-pbx/modules/l1-contact-flow-framework/scripts/invoke_phone_association.py`
- `connect-pbx/modules/l1-contact-flow-framework/flows/*.json.tftpl`
- `connect-pbx/environments/<env>/contact-flows.tfvars`

Environment-scoped inputs live under:

- `connect-pbx/environments/dev/`
- `connect-pbx/environments/staging/`
- `connect-pbx/environments/prod/`

---

## Authoring Rules

### 1. Use API-accepted CFL, not console export syntax

Always build against Amazon Connect API-compatible Contact Flow Language.

Examples of known-good patterns in this repo:
- `InvokeLambdaFunction` followed by `Compare`
- `UpdateContactTargetQueue` followed by `TransferContactToQueue`
- explicit action UUIDs

### 2. Use the correct identifier shape

Within flow JSON:

- `UpdateContactTargetQueue.Parameters.QueueId` -> queue ARN
- `TransferToFlow.Parameters.ContactFlowId` -> contact flow ARN

Do not use:
- Terraform resource `id` (`instance_id:contact_flow_id`)
- guessed identifier formats

In Terraform, prefer resource-derived attributes:

- `aws_connect_contact_flow.<name>.arn`
- `aws_connect_queue.<name>.arn` or remote-state queue ARNs

### 3. Keep flows simple when provider support is incomplete

If a Connect abstraction depends on unsupported provider features, prefer:
- plain `aws_connect_contact_flow`
- explicit JSON templates
- direct Terraform rendering of queue and flow references

Do not reintroduce unsupported contact flow module features as a workaround.

### 4. Respect action-specific validator rules

Generic CFL structure is not sufficient. Connect enforces action-level rules.

Examples validated during PRD-14 repair:

- `CheckHoursOfOperation` required `Transitions.NextAction`
- `Compare` rejected `NoMatchingError` in the tested pattern
- `TransferContactToQueue` required `QueueAtCapacity` plus `NextAction`
- `TransferToFlow` required `NextAction`

If the validator says a field is required, trust it over inferred cleanup.

---

## Standard Change Workflow

### Step 1 — Edit the Terraform and flow template files

Typical files:

- `flows/main-inbound.json.tftpl`
- `flows.tf`
- `locals.tf`
- `outputs.tf`
- `environments/<env>/contact-flows.tfvars`

### Step 2 — Validate locally

From `connect-pbx/modules/l1-contact-flow-framework`:

```bash
terraform validate
```

If validation fails, fix Terraform syntax first before attempting API-level tests.

### Step 3 — Create a plan

```bash
terraform plan -out=prd14-dev.tfplan \
  -var-file=../../environments/dev/global.tfvars \
  -var-file=../../environments/dev/contact-flows.tfvars
```

Adjust the environment path as needed for `staging` or `prod`.

### Step 4 — Render the exact planned flow JSON

```bash
terraform show -json prd14-dev.tfplan > .build/prd14-dev-plan.json
python - <<'PY'
import json
from pathlib import Path

plan = json.loads(Path(".build/prd14-dev-plan.json").read_text())
resources = plan["planned_values"]["root_module"]["resources"]
target = next(r for r in resources if r["address"] == "aws_connect_contact_flow.main_inbound")
Path(".build/main-inbound-rendered.json").write_text(target["values"]["content"], encoding="utf-8")
print("wrote .build/main-inbound-rendered.json")
PY
```

Use this same pattern for any other flow address you need to inspect.

### Step 5 — Sanity-check rendered values

Examples:

```bash
python -m json.tool .build/main-inbound-rendered.json > /dev/null
grep -o 'arn:aws:connect:[^"]*contact-flow[^"]*' .build/main-inbound-rendered.json
grep -n 'QueueAtCapacity\|NextAction\|NoMatchingCondition\|NoMatchingError' .build/main-inbound-rendered.json
```

Confirm:
- target flow references are ARNs
- queue references are ARNs
- the rendered JSON matches the expected action patterns

---

## Debugging `InvalidContactFlowException`

### Step 1 — Use the Connect API directly

Terraform hides most validator detail. Use a direct debug create to surface the hidden `problems` array.

Example:

```bash
aws connect create-contact-flow \
  --region us-east-1 \
  --instance-id <instance-id> \
  --name debug-main-inbound \
  --type CONTACT_FLOW \
  --description "debug main inbound" \
  --content file://.build/main-inbound-rendered.json \
  --debug 2> .build/connect-create-debug.log
```

Then inspect:

```bash
grep -n -i -C 2 "problems\|InvalidContactFlowException" .build/connect-create-debug.log
grep -n -i -C 3 "\"message\"" .build/connect-create-debug.log
```

### Step 2 — Fix the exact reported path

Do not redesign the whole flow first. Fix what the validator names.

Typical failure categories:
- missing `Transitions.NextAction`
- invalid error type on an action
- missing required error branch like `QueueAtCapacity`
- invalid `ContactFlowId` value format

### Step 3 — Re-render before retesting

If you change a template and immediately rerun the debug create without regenerating `.build/main-inbound-rendered.json`, you are still testing the old payload.

Always:
1. rerun `terraform plan`
2. rerender the JSON
3. rerun the debug create

### Step 4 — Delete temporary debug flows after success

If the debug create succeeds, remove the temporary flow:

```bash
aws connect delete-contact-flow \
  --region us-east-1 \
  --instance-id <instance-id> \
  --contact-flow-id <debug-flow-id>
```

---

## Deploying Through Terraform

Once the debug create succeeds:

```bash
terraform apply prd14-dev.tfplan
```

Expected order for PRD-14 style changes:
1. helper flows created or updated
2. main inbound flow created or updated
3. phone number association step runs

If Terraform fails after a successful debug create, the issue is usually no longer flow JSON. Focus next on:
- phone association helper execution
- Lambda invoke permissions
- Connect association API behavior

---

## Phone Association Rules

Phone number association in this module is handled by:

- `terraform_data.phone_number_flow_associations`
- `scripts/invoke_phone_association.py`
- the PRD-14 phone association Lambda

This path is intentionally shell-agnostic:
- Terraform `local-exec` passes inputs via environment variables
- the Python helper accepts either env vars or CLI args

This is deliberate so operators can run from:
- Windows
- Linux
- macOS

Do not revert this to complex shell-quoted inline arguments unless absolutely necessary.

---

## Validation Checklist

Before merging a contact flow change, confirm:

- `terraform validate` passes
- the rendered JSON uses correct ARN/ID shapes
- a direct debug `create-contact-flow` succeeds for the changed flow
- the real Terraform apply succeeds
- the phone number association completes if routing changed
- at least one live test call confirms expected behavior

For PRD-14 main inbound, test at minimum:
- open-hours greeting/menu path
- after-hours transfer path
- one queue routing branch
- error fallback behavior if applicable

---

## Troubleshooting Shortcuts

### Flow create fails immediately

Use:

```bash
grep -n -i -C 2 "problems\|InvalidContactFlowException" .build/connect-create-debug.log
```

### Direct debug create returns `ResourceNotFoundException`

Check:
- correct AWS account/profile
- correct region
- correct Connect instance ID

### Terraform apply succeeds for flows but fails on phone association

Check:
- `terraform_data.phone_number_flow_associations`
- `.build/phone-association-*.json`
- Lambda logs for `{org_name}-phone-flow-association-{environment}`

### Test call returns a carrier intercept after a "successful" deploy

Check in this order:

- the actual E.164 digits from `l1-phone-numbers` output `phone_number_inventory`
- `.build/phone-association-*.json` to confirm the association helper returned `"status": "associated"`
- whether the number is associated to the expected flow in Connect

If the association file contains an IAM or runtime error, treat the issue as an incomplete PRD-14 deployment first, not purely as a telephony/carrier issue.

### Routing is wrong after apply

Use:
- [RB-11-08-routing-drift-investigation-remediation.md](RB-11-08-routing-drift-investigation-remediation.md)

---

## Lessons To Preserve

1. Connect validator output is more useful than Terraform errors for flow debugging.
2. Cross-flow references should remain Terraform-derived, but must use the value shape Connect accepts.
3. Simpler flows deploy more reliably than clever abstractions when provider/API support is uneven.
4. Re-rendering the exact planned JSON is the safest way to debug what Terraform will really send.
5. Shell-agnostic helper execution avoids operator-specific deploy failures.

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)
- [RB-11-08-routing-drift-investigation-remediation.md](RB-11-08-routing-drift-investigation-remediation.md)
