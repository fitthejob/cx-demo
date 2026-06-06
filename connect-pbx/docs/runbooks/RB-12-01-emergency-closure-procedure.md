# RB-12-01 — Emergency Closure Procedure

## Purpose

This runbook covers how to activate and deactivate emergency closures for the Amazon Connect PBX platform. Emergency closures take effect immediately — no PR, no Terraform apply, no Lambda required.

When an emergency closure is active, **all inbound calls** are routed to the closure message before any other routing logic (holiday checks, hours of operation, queue routing).

## Prerequisites

- AWS CLI configured with the correct profile (`<aws_profile_dev>` for dev, `<aws_profile_prod>` for prod)
- Permissions: `ssm:PutParameter` and `kms:Encrypt` on the environment KMS key
- Know the org name (for example `<org_prefix>`) and workspace (for example `dev`, `prod`)

## SSM Parameter Path

```
/{org_name}/{workspace}/emergency-closure
```

Example: `/<org_prefix>/dev/emergency-closure`

---

## Activate Emergency Closure

Run the following command, replacing the values in angle brackets:

```bash
export AWS_PROFILE=<aws_profile_dev>  # or <aws_profile_prod>

aws ssm put-parameter \
  --name "/<org_name>/<workspace>/emergency-closure" \
  --type SecureString \
  --overwrite \
  --value '{
    "active": true,
    "message": "<reason — e.g. Office closed due to severe weather>",
    "updated_by": "<your-name>",
    "updated_at": "<ISO 8601 timestamp — e.g. 2026-03-22T14:30:00Z>"
  }'
```

**Concrete example (dev):**

```bash
export AWS_PROFILE=<aws_profile_dev>

aws ssm put-parameter \
  --name "/<org_prefix>/dev/emergency-closure" \
  --type SecureString \
  --overwrite \
  --value '{
    "active": true,
    "message": "Office closed due to severe weather",
    "updated_by": "<operator_alias>",
    "updated_at": "2026-03-22T14:30:00Z"
  }'
```

### Verify Activation

```bash
aws ssm get-parameter \
  --name "/<org_prefix>/dev/emergency-closure" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text
```

Expected output:

```json
{"active": true, "message": "Office closed due to severe weather", "updated_by": "<operator_alias>", "updated_at": "2026-03-22T14:30:00Z"}
```

### Test (optional)

Place a test call to the main inbound number. The call should be routed to the closure/after-hours message without reaching any queue.

---

## Deactivate Emergency Closure

```bash
export AWS_PROFILE=<aws_profile_dev>  # or <aws_profile_prod>

aws ssm put-parameter \
  --name "/<org_prefix>/dev/emergency-closure" \
  --type SecureString \
  --overwrite \
  --value '{
    "active": false,
    "message": "",
    "updated_by": "<your-name>",
    "updated_at": "<ISO 8601 timestamp>"
  }'
```

**Concrete example (dev):**

```bash
export AWS_PROFILE=<aws_profile_dev>

aws ssm put-parameter \
  --name "/<org_prefix>/dev/emergency-closure" \
  --type SecureString \
  --overwrite \
  --value '{
    "active": false,
    "message": "",
    "updated_by": "<operator_alias>",
    "updated_at": "2026-03-22T18:00:00Z"
  }'
```

### Verify Deactivation

```bash
aws ssm get-parameter \
  --name "/<org_prefix>/dev/emergency-closure" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text
```

Expected output:

```json
{"active": false, "message": "", "updated_by": "<operator_alias>", "updated_at": "2026-03-22T18:00:00Z"}
```

### Test (optional)

Place a test call. The call should now route normally through hours of operation and queue logic.

---

## Important Notes

### Terraform Will Not Reset This Parameter

The SSM parameter has `lifecycle { ignore_changes = [value] }` in Terraform. Running `terraform apply` will **not** overwrite the current value — the operations manager's CLI changes are preserved across all future applies.

### Audit Trail

All SSM parameter changes are logged in CloudTrail. The `updated_by` and `updated_at` fields in the JSON value provide additional human-readable context, but CloudTrail is the authoritative audit source.

### Alarm: Stale Emergency Closure

If the emergency closure remains active for more than 24 hours, ALARM-12-03 fires an SNS notification asking if the closure is still intentional. If the closure is planned to last longer than 24 hours, acknowledge the alarm and document the reason.

### When NOT to Use Emergency Closure

- **Known future closures** (company shutdown days, office moves): Add these to the `holiday_closures` variable in tfvars and apply via the normal PR pipeline. These are handled by the company closures DynamoDB table.
- **US federal holidays**: These are computed automatically by the daily Lambda. No action required.
- **Schedule changes** (e.g., changing business hours from 8-6 to 9-5): Update the `hours_of_operation` variable in tfvars and apply.

Emergency closure is for **unplanned, immediate** situations only: severe weather, infrastructure emergencies, power outages, etc.

---

## Checklist

### Activation Checklist
- [ ] Confirm the closure is necessary and cannot wait for normal PR pipeline
- [ ] Run the `put-parameter` command with `active: true`
- [ ] Verify the parameter was updated correctly
- [ ] Place a test call to confirm closure routing
- [ ] Notify the team (Slack, email, etc.) that emergency closure is active

### Deactivation Checklist

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)
- [ ] Confirm the emergency has passed and normal operations can resume
- [ ] Run the `put-parameter` command with `active: false`
- [ ] Verify the parameter was updated correctly
- [ ] Place a test call to confirm normal routing is restored
- [ ] Notify the team that normal operations have resumed
