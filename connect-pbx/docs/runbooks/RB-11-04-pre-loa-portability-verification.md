# RB-11-04 — Pre-LOA Portability Verification

**Runbook ID:** RB-11-04
**Module:** l1-number-portability-check (PRD-15)
**Audience:** Migration Lead, Platform Engineer, Terraform Operator
**Last Updated:** 2026-03-30

---

## Overview

This runbook covers the PRD-15 portability verification service that must be used before any number advances to LOA submission.

PRD-15 is the authoritative portability eligibility source of truth. It does not submit LOAs and it does not manage the PRD-90 workflow state machine. Instead, it:

- runs a DID or toll-free portability check in AWS Lambda
- writes immutable history records
- updates one `CURRENT` record per number
- gives PRD-90 the eligibility state it needs to allow or block `LOA_SUBMITTED`

The current v1 implementation supports:

- `mock` provider for dev/test
- `bandwidth` provider contract for real provider-backed lookups
- explicit operator overrides with audit history

---

## Source Of Truth

Use these references together:

- module: [modules/l1-number-portability-check](../../modules/l1-number-portability-check)
- PRD: [PRD-15-v1.0.0-number-portability-verification.md](../../../PRD_docs/PRD-15-v1.0.0-number-portability-verification.md)
- PRD-90 integration: [PRD-90-v1.0.0-migration-state.md](../../../PRD_docs/PRD-90-v1.0.0-migration-state.md)
- cutover context: [PRD-91-v1.0.0-cutover-operations.md](../../../PRD_docs/PRD-91-v1.0.0-cutover-operations.md)

Environment config path:

- `connect-pbx/environments/<env>/portability.tfvars`

---

## Preconditions

Before using PRD-15, confirm:

- the module is enabled in the environment deployment manifest if you intend to deploy it
- the module has been applied in the target environment
- you are using the correct AWS account/profile
- numbers are in E.164 format

Helpful checks:

```bash
aws sts get-caller-identity
```

```bash
python connect-pbx/scripts/module_manifest.py validate \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json
```

---

## Service Model

PRD-15 accepts two actions:

- `check`
- `override`

It persists records in one DynamoDB table:

- `PK = phone_number`
- `SK = CURRENT`
- `SK = CHECK#<timestamp>`
- `SK = OVERRIDE#<timestamp>`

Important fields on the `CURRENT` record:

- `provider_status`
- `effective_status`
- `effective_source`
- `checked_at`
- `effective_at`
- `expires_at`
- `lookup_provider`

PRD-90 must read `CURRENT` and evaluate freshness from that record.

---

## Step 1 — Confirm Module Deployment

From the module directory:

```bash
terraform output portability_check_lambda_name
terraform output portability_audit_table_name
```

Or via AWS:

```bash
aws lambda get-function --function-name <org_prefix>-number-portability-check-<env>
```

```bash
aws dynamodb describe-table --table-name <org_prefix>-number-portability-audit-<env>
```

If these do not exist, deploy the module before running checks.

---

## Step 2 — Prepare The Payload

### Check Action

The `check` action accepts either:

- a single `phone_number`
- or a list in `numbers`

Numbers may be strings or per-number objects.

### Recommended dev/mock payload

```json
{
  "action": "check",
  "numbers": [
    { "phone_number": "+12125550100", "scenario": "eligible_did" },
    { "phone_number": "+12125550101", "scenario": "ineligible_voip" },
    { "phone_number": "+18005550199", "scenario": "manual_tollfree" }
  ]
}
```

Supported mock scenarios:

- `eligible_did`
- `ineligible_voip`
- `porting_freeze`
- `eligible_tollfree`
- `manual_tollfree`
- `check_failed`

Save it as:

```bash
cat > portability-check.json <<'EOF'
{
  "action": "check",
  "numbers": [
    { "phone_number": "+12125550100", "scenario": "eligible_did" },
    { "phone_number": "+12125550101", "scenario": "ineligible_voip" },
    { "phone_number": "+18005550199", "scenario": "manual_tollfree" }
  ]
}
EOF
```

---

## Step 3 — Invoke The Lambda

```bash
aws lambda invoke \
  --function-name <org_prefix>-number-portability-check-<env> \
  --payload file://portability-check.json \
  --cli-binary-format raw-in-base64-out \
  portability-results.json
```

Then inspect:

```bash
cat portability-results.json
```

Expected shape:

```json
{
  "action": "check",
  "lookup_provider": "mock",
  "results": [
    {
      "phone_number": "+12125550100",
      "provider_status": "ELIGIBLE",
      "effective_status": "ELIGIBLE",
      "line_type": "POTS",
      "ocn": "9101",
      "losing_carrier_name": "Bandwidth.com Inc",
      "record_ref": "CHECK#2026-03-30T12:00:00Z"
    }
  ]
}
```

---

## Step 4 — Verify DynamoDB Records

Check the current record:

```bash
aws dynamodb get-item \
  --table-name <org_prefix>-number-portability-audit-<env> \
  --key '{
    "phone_number": {"S": "+12125550100"},
    "record_type": {"S": "CURRENT"}
  }'
```

Check history for the same number:

```bash
aws dynamodb query \
  --table-name <org_prefix>-number-portability-audit-<env> \
  --key-condition-expression "phone_number = :n" \
  --expression-attribute-values '{":n":{"S":"+12125550100"}}'
```

What to look for:

- one `CURRENT` record
- one or more `CHECK#...` history records
- `effective_status` matching the Lambda response
- `expires_at` present on the current record

---

## Step 5 — Interpret Results

### `ELIGIBLE`

The number passed the current provider evaluation and can move forward in PRD-90 if the record is still fresh.

### `INELIGIBLE`

The provider reported a condition that blocks porting. Typical reasons:

- non-portable line type
- porting freeze
- missing OCN for DID
- missing RespOrg for toll-free

### `MANUAL_VERIFICATION_REQUIRED`

The service could not confidently automate the decision, especially on toll-free paths in v1. Human review is required before progressing.

### `CHECK_FAILED`

The portability check itself failed technically. Typical causes:

- missing or malformed provider secret
- provider outage
- invalid provider configuration

Do not treat `CHECK_FAILED` as eligibility.

---

## Step 6 — Run An Operator Override

Use an override only when the provider result is incomplete, disputed, or manually confirmed through carrier/RespOrg channels.

Example payload:

```json
{
  "action": "override",
  "phone_number": "+18005550199",
  "effective_status": "ELIGIBLE",
  "reason_code": "TF_RESPORG_VERIFIED_MANUALLY",
  "justification": "RespOrg confirmed manually with carrier documentation on file.",
  "operator_identity": "<operator_email>",
  "override_review_by": "2026-04-30T00:00:00Z"
}
```

Invoke:

```bash
aws lambda invoke \
  --function-name <org_prefix>-number-portability-check-<env> \
  --payload file://portability-override.json \
  --cli-binary-format raw-in-base64-out \
  portability-override-result.json
```

Verify:

- `CURRENT.effective_source = OPERATOR_OVERRIDE`
- `CURRENT.override_reason_code` populated
- an immutable `OVERRIDE#...` history record exists

---

## Provider Secret Contract

### Mock

`mock` does not require a real secret.

### Bandwidth

The current v1 implementation expects one Secrets Manager JSON secret for the provider. It should contain:

```json
{
  "base_url": "https://provider.example.com",
  "api_token": "secret-token",
  "did_lookup_path": "/lookup/did",
  "tollfree_lookup_path": "/lookup/tollfree",
  "auth_header_name": "Authorization",
  "auth_header_value_prefix": "Bearer ",
  "timeout_seconds": 10
}
```

Notes:

- the Lambda expects the remote endpoint to return JSON fields that can be normalized into PRD-15 state
- if the provider secret is missing or malformed, the Lambda returns `CHECK_FAILED`
- if a real vendor contract changes, update this runbook and the Lambda adapter together

---

## Freshness & PRD-90 Gating

PRD-15 itself does not run on a schedule in v1.

Instead:

- PRD-15 writes `expires_at`
- PRD-90 reads `CURRENT`
- PRD-90 blocks `LOA_SUBMITTED` if the record is no longer fresh

Operational rule:

- rerun checks before LOA if the current record is close to or beyond expiry

---

## Troubleshooting

### Lambda returns `CHECK_FAILED`

Check:

- CloudWatch logs for `<org_prefix>-number-portability-check-<env>`
- provider secret ARN in `portability.tfvars`
- provider secret JSON schema
- provider endpoint availability

### No DynamoDB history record written

Check:

- Lambda IAM access to DynamoDB
- table name in Lambda environment variables
- Lambda error logs

### Override succeeds but PRD-90 still blocks

Check:

- `CURRENT.effective_status`
- `CURRENT.expires_at`
- that PRD-90 is reading the same environment’s table

### Manifest validation fails before deploy

Check:

- [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md)

PRD-15 is migration-only and is not enabled in the default bare-bones deployment manifests.

---

## Guardrails

1. Do not treat PRD-15 as a replacement for PRD-90 workflow state.
2. Do not silently overwrite provider results without an override record.
3. Do not enable PRD-15 in an environment manifest unless the migration capability pack is intentionally needed.
4. Do not submit an LOA from stale or manually ambiguous data without a documented override path.

---

## Related Documents

- [PRD-15-v1.0.0-number-portability-verification.md](../../../PRD_docs/PRD-15-v1.0.0-number-portability-verification.md)
- [PRD-90-v1.0.0-migration-state.md](../../../PRD_docs/PRD-90-v1.0.0-migration-state.md)
- [PRD-91-v1.0.0-cutover-operations.md](../../../PRD_docs/PRD-91-v1.0.0-cutover-operations.md)
- [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md)
- [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md)
