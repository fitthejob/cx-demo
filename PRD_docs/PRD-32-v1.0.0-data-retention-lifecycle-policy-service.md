# PRD-32 — Data Retention & Lifecycle Policy Service

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-32 |
| **Version** | 1.5.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 3 — Storage & Data |
| **Hard Dependencies** | PRD-02 (KMS keys), PRD-03 (audit bucket), PRD-30 (S3 bucket names), PRD-31 (DynamoDB table ARNs) |
| **Optional Shared Sinks** | Shared alert topic when centralized alerting is enabled |
| **Blocks** | Compliance-focused profiles such as PRD-140 |
| **Optional** | Yes |

---

## 1.1 Module Governance

| Field | Value |
|---|---|
| **Classification** | `conditional-foundation` |
| **Minimum Deployment Profile** | `enterprise` |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Catalog Entry** | `path`: `modules/l3-retention-policy`; `capability_packs`: `[compliance-hardening]`; `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l0-audit-baseline", "modules/l3-recordings-artifacts", "modules/l3-dynamodb"]`; `state_key`: `l3-retention-policy/terraform.tfstate`; `workspace_scoped`: `true`; `domain_tfvars`: `retention-policy.tfvars`; `supports_destroy`: `false` |
| **Optional Shared Sinks** | The audit bucket is a required inbound dependency whenever PRD-32 is enabled because the manifest and verification results are evidence artifacts. The shared alert topic remains optional and only controls notifications. |
| **Destroy / Retention Posture** | `protected`; this module can retain compliance evidence objects and verifier history, so teardown is not a casual operation. |
| **Control Plane Statement** | This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity. |

## 2. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Data retention is not a single setting — it is a policy that must be consistently enforced across every data store in the platform. S3 lifecycle policies are set in PRD-30, DynamoDB TTLs in PRD-31, and CloudWatch log retention in individual PRDs. But a retention policy is only useful if it is auditable, centrally documented, and verified to be operating correctly. This matters most for enterprise, regulated, and audit-sensitive deployments.

This PRD does two things. First, it provisions a retention policy manifest — a structured document stored in the audit bucket that records the declared retention settings for the data stores selected by the environment's module catalog and deployment manifest. Second, it provisions a weekly Lambda that verifies the provider-side retention configuration it can actually inspect for those selected stores and alerts if any discrepancy is detected, when an alert topic is configured.

### What Problem It Solves

- Maintains a single, authoritative retention policy manifest stored in the audit bucket
- Provides automated weekly verification that actual S3 lifecycle, DynamoDB TTL configuration, and CloudWatch log retention settings match the declared policy
- Generates alerts when retention settings drift from the declared policy, if a shared alert topic is enabled
- Provides auditors with a machine-readable retention policy document they can reference without manually querying every service

---

## 3. GOALS

### Goals

- Provision the retention policy manifest as a JSON document written to the audit bucket
- Provision the retention verification Lambda that runs weekly and compares provider configuration to the manifest
- Alert via SNS when any retention setting does not match the declared policy, if a shared alert topic is configured
- Export the manifest S3 location for reference by PRD-140 and adjacent compliance workflows

### Non-Goals

- This PRD does not change any retention settings — those are set in PRD-30, PRD-31, and individual service PRDs
- This PRD does not implement S3 Object Lock. If immutability controls are ever required, PRD-140 documents them as manual change-controlled procedures rather than Terraform-managed programming.
- This PRD does not implement automated remediation of retention drift — alert only

---

## 4. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-32-01 | SOC 2 Auditor | As an auditor, I want a single document listing all retention policies so that I can verify compliance without querying each service | Retention manifest exists in audit bucket; content changes only when the declared policy set changes |
| US-32-02 | Platform Engineer | As the platform engineer, I want automated alerts if any retention setting drifts from the declared policy | Weekly verification Lambda runs; SNS alert on any mismatch |
| US-32-03 | Compliance Officer | As the compliance officer, I want retention policy changes to go through the standard Terraform pipeline so that they are version-controlled | Manifest is a Terraform resource — changes require PR and approval |

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — Retention Policy Manifest
Provision an `aws_s3_object` resource that writes a structured JSON retention policy manifest to `s3://{audit_bucket}/retention-policy/manifest.json`. The audit bucket is a required inbound dependency for this module. The manifest must enumerate the stores selected by the environment's module catalog and deployment manifest through an explicit input contract rather than a hardcoded store list.

### FR-002 — Manifest Schema
The manifest must follow this schema:

```json
{
  "schema_version": "1.2",
  "manifest_version": "retention-policy-v1",
  "environment": "{workspace}",
  "policies": [
    {
      "store_type": "s3",
      "store_name": "{bucket_name}",
      "data_classification": "call-recordings",
      "declared_policy": {
        "retention_days": 2555
      },
      "compliance_basis": ["PCI-DSS-10.7", "SOC2-A1.2"]
    },
    {
      "store_type": "dynamodb",
      "store_name": "{table_name}",
      "data_classification": "contact-state",
      "declared_policy": {
        "writer_retention_days": 90,
        "ttl_attribute": "ExpiresAt"
      },
      "compliance_basis": ["SOC2-A1.2"]
    },
    {
      "store_type": "cloudwatch-logs",
      "store_name": "{log_group_name}",
      "data_classification": "application-logs",
      "declared_policy": {
        "retention_days": 365
      },
      "compliance_basis": ["PCI-DSS-10.7"]
    }
  ]
}
```

The manifest intentionally omits an apply-time timestamp so Terraform does not churn the object content on every run. The S3 object metadata carries the apply time, while the manifest body stays stable unless the policy set itself changes.

### FR-003 — Retention Verification Lambda
Provision a Lambda function `{org_name}-retention-verifier` triggered weekly (every Monday at 07:00 UTC). The Lambda reads the manifest from S3, then queries each declared data store to verify the provider configuration it can actually inspect matches the declared value. Any mismatch triggers an SNS alert when an alert topic is configured and writes a verification result record to `s3://{audit_bucket}/retention-policy/verification/{YYYY}/{MM}/{DD}/result.json`. When the Lambda is invoked manually for a missed run, the caller may supply `verification_date` in `YYYY-MM-DD` form so the verifier writes the result to the missed date path instead of the current day.

### FR-004 — Verification Scope
The verification Lambda must check:
- S3 bucket lifecycle rules (expiry days)
- DynamoDB table TTL attribute and enabled status only. It does not prove per-item expiry timing.
- CloudWatch log group retention in days

### FR-005 — Verification Result Schema

```json
{
  "verified_at": "ISO 8601",
  "environment": "dev | staging | prod",
  "verification_date": "YYYY-MM-DD",
  "overall_status": "PASS | FAIL",
  "checks": [
    {
      "store_name": "string",
      "store_type": "string",
      "declared_policy": "object",
      "actual_configuration": "object",
      "status": "PASS | FAIL",
      "detail": "string"
    }
  ]
}
```

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### Availability
The retention verifier runs weekly — not in the critical path. Lambda cold starts are acceptable.

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 10.7 | Retention manifest documents 7-year log retention | Manifest S3 object, verification result |
| SOC 2 A1.2 | Automated weekly verification of retention settings | Verification result in S3 |

---

## 7. ARCHITECTURE

```
Terraform Apply
      │ Writes manifest when policy inputs change
      ▼
S3 Audit Bucket (required inbound dependency)
└── retention-policy/
    ├── manifest.json          ← Updated when policy inputs change
    └── verification/
        └── {YYYY}/{MM}/{DD}/result.json ← Written by verification Lambda using the scheduled date or an explicit backfill date

Weekly Schedule (Monday 07:00 UTC)
      │
      ▼
Retention Verifier Lambda
      │ Reads manifest.json
      ├── Queries S3 lifecycle configs
      ├── Queries DynamoDB TTL configs
      ├── Queries CloudWatch log retention
      │
      ├── PASS: Write result.json (overall_status: PASS)
      └── FAIL: Write result.json (overall_status: FAIL)
                + SNS alert to shared topic when enabled
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `manifest_s3_key` | string | S3 key of retention manifest | PRD-140 (evidence reference) |
| `verifier_function_arn` | string | Retention verifier Lambda ARN | future observability and compliance monitoring |

---

## 8. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l3-retention-policy/        # PRD-32
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── lambda-src/
            └── retention-verifier/
                └── index.py
```

### Key Resources Declared

```hcl
# main.tf

locals {
  account_id = data.aws_caller_identity.current.account_id
  permission_boundary_arn = var.permission_boundary_arn

  manifest = jsonencode({
    schema_version   = "1.2"
    manifest_version = "retention-policy-v1"
    environment      = terraform.workspace
    policies         = var.retention_policies
  })

  verifier_policy_statements = concat(
    [
      {
        Sid    = "ReadManifestAndWriteResults"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.audit_bucket_name}/retention-policy/*"
      },
      {
        Sid    = "QueryS3Lifecycle"
        Effect = "Allow"
        Action = ["s3:GetLifecycleConfiguration"]
        Resource = [for policy in var.retention_policies : policy.store_arn if policy.store_type == "s3"]
      },
      {
        Sid    = "QueryDynamoDBTTL"
        Effect = "Allow"
        Action = ["dynamodb:DescribeTimeToLive"]
        Resource = [for policy in var.retention_policies : policy.store_arn if policy.store_type == "dynamodb"]
      },
      {
        Sid    = "QueryCloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:DescribeLogGroups"]
        Resource = "*"
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = [var.audit_bucket_kms_key_arn]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${var.org_name}-retention-verifier-${terraform.workspace}:*"
      }
    ],
    var.alert_topic_arn != "" ? [{
      Sid      = "PublishAlerts"
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = [var.alert_topic_arn]
    }] : []
  )
}

data "aws_caller_identity" "current" {}

data "archive_file" "retention_verifier" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-src/retention-verifier"
  output_path = "${path.module}/.terraform-build/retention-verifier.zip"
}

resource "aws_s3_object" "retention_manifest" {
  bucket               = var.audit_bucket_name
  key                  = "retention-policy/manifest.json"
  content              = local.manifest
  content_type         = "application/json"
  server_side_encryption = "aws:kms"
  kms_key_id           = var.audit_bucket_kms_key_arn

  tags = { Layer = "L3", PRD = "PRD-32" }
}

resource "aws_iam_role" "retention_verifier" {
  name = "${var.org_name}-retention-verifier-${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  permissions_boundary = local.permission_boundary_arn != "" ? local.permission_boundary_arn : null
  tags                 = { Layer = "L3", PRD = "PRD-32" }
}

resource "aws_iam_role_policy" "retention_verifier" {
  name = "retention-verifier-policy"
  role = aws_iam_role.retention_verifier.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = local.verifier_policy_statements
  })
}

resource "aws_cloudwatch_log_group" "retention_verifier" {
  name              = "/aws/lambda/${var.org_name}-retention-verifier-${terraform.workspace}"
  retention_in_days = 365
  kms_key_id        = var.audit_bucket_kms_key_arn
  tags              = { Layer = "L3", PRD = "PRD-32" }
}

resource "aws_lambda_function" "retention_verifier" {
  function_name = "${var.org_name}-retention-verifier-${terraform.workspace}"
  role          = aws_iam_role.retention_verifier.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 300

  filename         = data.archive_file.retention_verifier.output_path
  source_code_hash = data.archive_file.retention_verifier.output_base64sha256

  environment {
    variables = {
      AUDIT_BUCKET    = var.audit_bucket_name
      MANIFEST_KEY    = "retention-policy/manifest.json"
      ALERT_TOPIC_ARN = var.alert_topic_arn
      KMS_KEY_ARN     = var.audit_bucket_kms_key_arn
    }
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L3", PRD = "PRD-32" }
}

resource "aws_cloudwatch_event_rule" "weekly_verification" {
  name                = "${var.org_name}-retention-verification-${terraform.workspace}"
  description         = "Weekly retention policy verification — every Monday at 07:00 UTC"
  schedule_expression = "cron(0 7 ? * MON *)"
}

resource "aws_cloudwatch_event_target" "retention_verifier" {
  rule      = aws_cloudwatch_event_rule.weekly_verification.name
  target_id = "retention-verifier-lambda"
  arn       = aws_lambda_function.retention_verifier.arn
}

resource "aws_lambda_permission" "retention_verifier_events" {
  statement_id  = "AllowCloudWatchEvents"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.retention_verifier.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.weekly_verification.arn
}
```

### Lambda Source

```python
# lambda-src/retention-verifier/index.py
import json
import os
import boto3
from datetime import datetime, timezone

s3       = boto3.client('s3')
sns      = boto3.client('sns')
cw_logs  = boto3.client('logs')
dynamodb = boto3.client('dynamodb')

AUDIT_BUCKET    = os.environ['AUDIT_BUCKET']
MANIFEST_KEY    = os.environ['MANIFEST_KEY']
ALERT_TOPIC_ARN = os.environ.get('ALERT_TOPIC_ARN', '')
KMS_KEY_ARN     = os.environ['KMS_KEY_ARN']

def handler(event, context):
    manifest_obj = s3.get_object(Bucket=AUDIT_BUCKET, Key=MANIFEST_KEY)
    manifest     = json.loads(manifest_obj['Body'].read())
    checks       = []
    overall      = 'PASS'
    verification_date = resolve_verification_date(event)

    for policy in manifest['policies']:
        store_type = policy['store_type']
        store_name = policy['store_name']
        declared   = policy.get('declared_policy', {})

        try:
            if store_type == 's3':
                result = check_s3(store_name, policy)
            elif store_type == 'dynamodb':
                result = check_dynamodb(store_name, policy)
            elif store_type == 'cloudwatch-logs':
                result = check_cloudwatch_logs(store_name, policy)
            else:
                result = {'status': 'FAIL', 'detail': f'Unknown store type: {store_type}'}

            if result.get('status') == 'FAIL':
                overall = 'FAIL'
            checks.append({
                'store_name': store_name,
                'store_type': store_type,
                'declared_policy': declared,
                **result
            })
        except Exception as e:
            overall = 'FAIL'
            checks.append({
                'store_name': store_name,
                'store_type': store_type,
                'declared_policy': declared,
                'actual_configuration': {},
                'status': 'FAIL',
                'detail': str(e)
            })

    result_doc = {
        'verified_at': datetime.now(timezone.utc).isoformat(),
        'environment': manifest.get('environment'),
        'verification_date': verification_date.isoformat(),
        'overall_status': overall,
        'checks': checks
    }

    result_key = f"retention-policy/verification/{verification_date.year}/{verification_date.month:02d}/{verification_date.day:02d}/result.json"
    s3.put_object(
        Bucket=AUDIT_BUCKET, Key=result_key,
        Body=json.dumps(result_doc, sort_keys=True),
        ContentType='application/json',
        ServerSideEncryption='aws:kms',
        SSEKMSKeyId=KMS_KEY_ARN
    )

    if overall == 'FAIL' and ALERT_TOPIC_ARN:
        sns.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject="RETENTION POLICY DRIFT DETECTED",
            Message=json.dumps(result_doc, indent=2)
        )

    return result_doc


def resolve_verification_date(event):
    raw = (event or {}).get('verification_date')
    if not raw:
        return datetime.now(timezone.utc).date()

    try:
        return datetime.strptime(raw, '%Y-%m-%d').date()
    except ValueError as exc:
        raise ValueError('verification_date must be YYYY-MM-DD') from exc


def check_s3(bucket_name, policy):
    try:
        lc = s3.get_bucket_lifecycle_configuration(Bucket=bucket_name)
        declared = policy.get('declared_policy', {})
        for rule in lc.get('Rules', []):
            if rule.get('Status') == 'Enabled':
                expiry = rule.get('Expiration', {}).get('Days', 0)
                expected = declared.get('retention_days', 0)
                if expiry == expected:
                    return {
                        'status': 'PASS',
                        'actual_configuration': {'retention_days': expiry}
                    }
        return {
            'status': 'FAIL',
            'detail': 'No matching enabled lifecycle rule found',
            'actual_configuration': {'retention_days': 0}
        }
    except Exception as e:
        return {'status': 'FAIL', 'detail': str(e), 'actual_configuration': {}}


def check_dynamodb(table_name, policy):
    resp = dynamodb.describe_time_to_live(TableName=table_name)
    ttl  = resp.get('TimeToLiveDescription', {})
    declared = policy.get('declared_policy', {})
    actual = {
        'ttl_enabled': ttl.get('TimeToLiveStatus') == 'ENABLED',
        'ttl_attribute': ttl.get('AttributeName')
    }
    if actual['ttl_enabled'] and actual['ttl_attribute'] == declared.get('ttl_attribute'):
        return {
            'status': 'PASS',
            'actual_configuration': actual,
            'detail': f"TTL enabled on {ttl.get('AttributeName')}. Per-item expiry timing remains a writer contract."
        }
    return {
        'status': 'FAIL',
        'actual_configuration': actual,
        'detail': f"TTL not enabled or wrong attribute: {ttl}"
    }


def check_cloudwatch_logs(log_group_name, policy):
    resp   = cw_logs.describe_log_groups(logGroupNamePrefix=log_group_name)
    groups = resp.get('logGroups', [])
    declared = policy.get('declared_policy', {})
    for g in groups:
        if g.get('logGroupName') == log_group_name:
            actual = g.get('retentionInDays', 0)
            expected = declared.get('retention_days', 0)
            if actual == expected:
                return {'status': 'PASS', 'actual_configuration': {'retention_days': actual}}
            return {
                'status': 'FAIL',
                'actual_configuration': {'retention_days': actual},
                'detail': f"Expected {expected} days, found {actual}"
            }
    return {'status': 'FAIL', 'actual_configuration': {}, 'detail': f"Log group not found: {log_group_name}"}
```

### Variables, Outputs, Backend

```hcl
# variables.tf
variable "org_name"                { type = string }
variable "aws_region"              { type = string; default = "us-east-1" }
variable "layer_id"                { type = string; default = "L3" }
variable "prd_id"                  { type = string; default = "PRD-32" }
variable "audit_bucket_name"       { type = string }
variable "audit_bucket_kms_key_arn" { type = string }
variable "alert_topic_arn"         { type = string; default = "" }
variable "permission_boundary_arn" { type = string; default = "" }
variable "retention_policies" {
  type = list(object({
    store_type          = string
    store_name          = string
    store_arn           = string
    data_classification = string
    declared_policy     = map(any)
    compliance_basis    = list(string)
  }))
}
variable "deployment_profile" {
  type = object({
    mode             = string
    instance_count   = number
    multi_az         = bool
    cross_region     = bool
    agent_capacity   = string
    account_topology = string
    hub_account_id   = string
    org_id           = string
  })
  default = {
    mode             = "single"
    instance_count   = 1
    multi_az         = false
    cross_region     = false
    agent_capacity   = "small"
    account_topology = "standalone"
    hub_account_id   = ""
    org_id           = ""
  }
}

# outputs.tf
output "manifest_s3_key" {
  value       = aws_s3_object.retention_manifest.key
  description = "S3 key of retention manifest. Referenced by PRD-140 for compliance evidence."
}
output "verifier_function_arn" {
  value       = aws_lambda_function.retention_verifier.arn
  description = "Retention verifier Lambda ARN. Referenced by future observability and compliance monitoring."
}

# backend.tf
terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # The runner and module catalog supply the real backend configuration and state key.
  backend "s3" {}
}
```

---

## 9. EVENT SCHEMA

PRD-32 produces no EventBridge events. It produces S3 objects (manifest, verification results) and SNS alerts.

---

## 10. API / INTERFACE CONTRACT

Consumers should resolve `manifest_s3_key` through the module catalog's declared `state_key` for this module. Do not hardcode `dev/...` or `${terraform.workspace}/...` remote-state keys in downstream PRDs or implementation notes. The manifest contents come from the explicit `retention_policies` input list, which is assembled from enabled module outputs or curated tfvars rather than inferred from undeclared locals.

---

## 11. DATA MODEL

```
s3://{org}-audit-{account_id}/
└── retention-policy/
    ├── manifest.json              ← Updated only when declared policy inputs change
    └── verification/
        └── {YYYY}/{MM}/{DD}/
            └── result.json        ← Written weekly by verifier Lambda
```

---

## 12. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l3-retention-policy }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l3-retention-policy, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l3-retention-policy
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l3-retention-policy-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Recovery / Evidence Continuity

- Missed weekly runs are remediated by manually invoking the verifier Lambda with `verification_date = YYYY-MM-DD` for the missed run and writing the resulting `result.json` into that date path with an operator note in the incident runbook.
- Bad manifest revisions are corrected by reverting the Terraform change that produced the bad policy set and re-applying; the historical manifest object remains as normal versioned evidence in the audit bucket.
- Re-running against a prior manifest version is an operator procedure, not an automatic behavior. The runbook must record which manifest object version was used for any backfill or post-incident verification.

---

## 13. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-32-01: Retention Policy Drift Detected**
- Source: SNS alert from retention verifier Lambda when `overall_status = FAIL` and an alert topic is configured
- Severity: High — compliance posture compromised

**ALARM-32-02: Retention Verifier Did Not Run**
- Source: Absence of verification result in S3 for the current Monday
- Detection: operator runbook check at 08:00 UTC Monday; this detector is not provisioned by PRD-32
- Severity: Medium

---

## 14. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-32-01 | Retention manifest exists in audit bucket | `aws s3api head-object` on `retention-policy/manifest.json` |
| AC-32-02 | Manifest content is stable unless policy inputs change | Apply module twice without changing policy inputs; confirm the object body does not churn |
| AC-32-03 | Manifest lists the exact declared store inventory from `retention_policies` | Read manifest; confirm it matches the input list supplied for the environment |
| AC-32-04 | Verifier Lambda runs weekly | Check CloudWatch Events rule for Monday schedule |
| AC-32-05 | Verifier passes when settings match | Invoke Lambda manually; confirm PASS result in S3 |
| AC-32-06 | Verifier fails and alerts when S3 lifecycle drifts | Temporarily change a lifecycle rule; invoke Lambda; confirm FAIL result and SNS alert when configured |
| AC-32-07 | Verifier reports DynamoDB TTL configuration drift honestly | Disable TTL or change the TTL attribute; invoke Lambda; confirm FAIL result without claiming a false `actual_retention_days` value |
| AC-32-08 | Verifier reports CloudWatch Logs retention drift | Change a governed log group's retention; invoke Lambda; confirm FAIL result |
| AC-32-09 | Missing alert topic does not break evidence generation | Apply with `alert_topic_arn = ""`; invoke Lambda; confirm result document is written and SNS publish is skipped |
| AC-32-10 | Missed weekly runs are detectable and backfillable | Simulate a missed Monday result; invoke the verifier with `verification_date = YYYY-MM-DD` for that missed Monday; confirm the result document is written under the missed-date path and the runbook check detects the gap |
| AC-32-11 | tfsec and checkov pass | Clean scan output |

---

## 15. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Optional alert sink is not configured | Low | Low | Verifier still writes the result document; SNS publish is skipped cleanly. |
| DynamoDB TTL validation is configuration-level, not item-level | Low | Medium | The verifier checks TTL status and attribute name instead of pretending to measure per-item expiration. The 90-day horizon remains a cross-PRD writer contract. |
| Declared store inventory drifts from enabled module outputs | Medium | Medium | `retention_policies` is assembled from catalog-selected module outputs or curated tfvars and reviewed through normal Terraform change control. |

---

## 16. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-32-01 | Should the manifest content include an apply-time timestamp? | **Resolved** — no. The body stays stable so only real policy changes churn the object; S3 `LastModified` carries the apply-time evidence. |
| OQ-32-02 | Should PRD-32 eventually validate sampled item expiries for DynamoDB in a separate audit workflow? | Deferred — not in this PRD. Current verification is configuration-level only. |

---

## 17. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. Layer 3 Storage & Data complete with PRD-30, PRD-31, PRD-32. Retention manifest pattern established for PRD-140 compliance evidence. |
| 1.1.0 | 2026-03-30 | — | Normalized PRD-32 as an optional governance and compliance feature rather than a baseline platform requirement. Clarified that the manifest covers resources present in the enabled deployment profile. |
| 1.2.0 | 2026-04-05 | — | Added repo-owned modularity/governance section, converted classification to a single value, removed hard PRD-03 alarm coupling from baseline dependencies, and made the manifest/verifier sample deterministic and honest about verification scope. |
| 1.3.0 | 2026-04-06 | — | Implementation-readiness hardening. Made the audit bucket a required inbound dependency, limited optional sink behavior to alerting, replaced the hardcoded store list with an explicit `retention_policies` input contract, corrected DynamoDB verification semantics to configuration-level evidence, added recovery and evidence-continuity guidance, and fixed CI artifact naming. |
| 1.5.0 | 2026-04-06 | — | Clarified that any future Object Lock posture referenced via PRD-140 is manual change-controlled and not programmed by PRD-32. |
| 1.4.0 | 2026-04-06 | — | Implementation-readiness follow-up. Added explicit `verification_date` backfill support to the verifier contract, workspace-qualified the weekly EventBridge rule name, defined the previously implicit Terraform data sources and permission-boundary input, and aligned the recovery runbook and acceptance criteria with the backfill path. |
