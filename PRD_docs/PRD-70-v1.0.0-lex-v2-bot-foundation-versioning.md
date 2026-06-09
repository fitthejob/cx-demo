# PRD-70 — Lex V2 Bot Foundation & Versioning

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-70 |
| **Version** | 1.3.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-08 |
| **Layer** | 7 — AI & Automation |
| **Module Classification** | conditional-foundation |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-02 (KMS keys, permission boundary) |
| **Blocks** | PRD-71 (Intent Design), PRD-72 (Connect-Lex Integration), PRD-73 (Fallback Handler) |
| **Optional Shared Sinks** | Lex alias publication to SSM, if enabled |
| **Destroy / Retention Posture** | conditional / bot artifacts retained until aliases and versions are retired |
| **Optional** | Yes — optional feature and conditional foundation within the AI pack |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable the Lex foundation.

### Module Classification

- `classification`: `conditional-foundation`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l7-lex-bot-foundation`
- `capability_packs`: `["ai-assist"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline"]`
- `state_key`: `l7-lex-bot-foundation/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `lex-bot-foundation.tfvars`
- `supports_destroy`: `true`
- `activation`: `enabled_capability_packs` should include `ai-assist` once the module is cataloged; direct `enabled_modules` staging is acceptable only during pre-catalog rollout

### Shared Sink Behavior

- `optional_shared_sinks`: Lex alias publication to SSM Parameter Store
- `sink_behavior`: PRD-70 bot creation does not require SSM publication, but the current PRD-72 integration contract does. If PRD-72 is enabled, publishing the live alias ARN to the workspace-scoped SSM parameter is a required downstream handoff, not an optional convenience.

### Destroy / Retention Posture

- `destroy_posture`: `conditional`
- `retention_notes`: bot versions and aliases are lifecycle-managed resources. Destroy ordering matters, but the module should not be treated as a universal platform prerequisite.

### Control Plane Statement

The contract for PRD-70 is the Lex bot foundation, locale, and versioning model. The current repo implementation uses `null_resource` plus AWS CLI for alias management because provider support is incomplete; that is the module's present boundary, not a universal control-plane prerequisite and not a signal that the module is always-on. For the current Layer 7 design, the same module also owns publication of the live alias ARN to a single workspace-scoped SSM parameter so PRD-72 has one canonical lookup path.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Amazon Lex V2 is the NLU engine that powers the AI auto-attendant. Before intents, slots, or Connect integrations can be configured, the bot itself must exist with the correct IAM role, locale configuration, and alias strategy. This PRD provisions the Lex V2 bot as the foundation that PRD-71 through PRD-73 build on.

This is an optional AI capability pack foundation. Core telephony and lean migration do not require PRD-70. When the AI pack is enabled, PRD-70 is the authoritative starting point for the remaining Lex modules.

### Terraform Provider Gap — Current Repo Pattern

**`aws_lexv2models_bot_alias` does not exist in the Terraform AWS provider.** This is a documented open issue (`hashicorp/terraform-provider-aws#35780`). The current repo implementation uses `null_resource` + `local-exec` AWS CLI commands for alias management until provider support exists. That boundary is intentionally local to this module and should be revisited if native provider support lands.

Additional known provider behaviors that affect all four Lex PRDs:

| Behavior | Impact | Mitigation |
|---|---|---|
| `aws_lexv2models_bot_version` creates a new version on every apply, even with no changes | Noisy plan output; unnecessary alias update calls | `lifecycle { ignore_changes = all }` — taint explicitly to republish |
| Alias ARN cannot be read back via `data "external"` on first apply — racy | Alias ARN output returns `None` on fresh deploy | Post-apply AWS CLI script resolves ARN; bot ID is the stable Terraform output |
| Amazon Connect rejects `$LATEST` as a bot alias target | Connect association fails if alias points to `$LATEST` | Alias always points to a published version number, never `$LATEST` |
| `DeleteBotVersion` returns 409 ConflictException if alias still references the version | `terraform destroy` fails without correct ordering | Explicit `null_resource` destroy fence: alias deleted → version deleted → bot deleted |
| `fulfillment_code_hook { enabled = false }` required on all intents | Connect handles fulfillment — Lex must not invoke Lambda | All intents in PRD-71 have `fulfillment_code_hook { enabled = false }` |

These constraints are documented here in PRD-70 as the authoritative reference. PRD-71, PRD-72, and PRD-73 inherit and apply these patterns without re-documenting them.

### What Problem It Solves

- Provisions the Lex V2 bot with IAM role, locale, and NLU confidence threshold
- Implements the `null_resource` alias management pattern (create/update/destroy via AWS CLI)
- Establishes the `lifecycle { ignore_changes = all }` bot version pattern with explicit taint for republishing
- Implements the destroy fence to ensure safe teardown ordering
- Exports the bot ID (stable Terraform output) for downstream PRDs; documents the post-apply alias ARN resolution procedure
- Publishes the live alias ARN to the canonical workspace-scoped SSM parameter used by PRD-72

---

## 4. GOALS

### Goals

- Provision the Lex V2 bot with en-US locale
- Provision the Lex IAM role scoped to CloudWatch logs only (no Lambda fulfillment at this layer)
- Implement `live` alias via `null_resource` + AWS CLI (create/update/destroy)
- Implement `bot_version_destroy_fence` for safe destroy ordering
- Export bot ID as a stable Terraform output
- Document the post-apply alias ARN resolution procedure

### Non-Goals

- This PRD does not define intents or slots — that is PRD-71
- This PRD does not configure Connect-Lex association — that is PRD-72
- This PRD does not implement fallback escalation — that is PRD-73
- This PRD does not implement Lambda fulfillment hooks — Connect handles fulfillment per the provider gap finding above
- This PRD does not require the shared Lambda platform from PRD-40 — the bot foundation is self-contained

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-70-01 | Platform Engineer | As the platform engineer, I want the Lex bot provisioned via Terraform so that PRD-71 can add intents | Bot exists; `terraform state list` shows bot, locale, version, and alias null_resource |
| US-70-02 | Platform Engineer | As the platform engineer, I want `terraform destroy` to succeed without 409 errors | Full destroy completes; alias deleted before version, version before bot |
| US-70-03 | Platform Engineer | As the platform engineer, I want `terraform apply` to be idempotent on re-runs when no bot changes are made | Second apply produces no changes to bot version; null_resource does not re-trigger |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Lex V2 Bot
Provision `aws_lexv2models_bot` named `{org_name}-auto-attendant-{environment}` with:
- `idle_session_ttl_in_seconds = 120` (2 minutes — shorter than the reference file's 5 minutes, appropriate for a PBX context where callers rarely resume after 2 minutes of silence)
- `role_arn` = Lex runtime role from this PRD
- `data_privacy { child_directed = false }` (COPPA: No)

### FR-002 — Lex IAM Role
Provision `aws_iam_role` named `{org_name}-lex-runtime-{environment}` with:
- Trust: `lexv2.amazonaws.com`
- Inline policy: CloudWatch Logs write access to `/aws/lex/*` log group ARN only
- No Lambda invoke permissions at this layer — Connect handles fulfillment; Lambda hooks are not used
- Permission boundary from PRD-02 applied

### FR-003 — Bot Locale
Provision `aws_lexv2models_bot_locale` for `en_US` with:
- `n_lu_intent_confidence_threshold = 0.40` — matches the reference implementation; low enough to match short phrases while remaining discriminative
- `bot_version = "DRAFT"` — locale is always registered against DRAFT

### FR-004 — Bot Version with Idempotency
Provision `aws_lexv2models_bot_version` with `lifecycle { ignore_changes = all }`. This prevents Terraform from publishing a new version on every apply when the bot definition has not changed. To republish a new version after intents are updated, the engineer must explicitly taint this resource:

```bash
terraform taint 'module.lex.aws_lexv2models_bot_version.v1'
terraform apply
```

The `depends_on` block must list all intent resources from PRD-71 to ensure intents are fully saved before the version snapshot is taken.

### FR-005 — Live Alias via null_resource (AWS CLI)
Provision `null_resource.bot_alias_live` with:
- `triggers` on `bot_id`, `bot_version`, and `region` — re-triggers when version changes
- `provisioner "local-exec"` (create/update): checks if `live` alias exists; runs `create-bot-alias` if not, `update-bot-alias` if yes
- `provisioner "local-exec" { when = destroy }`: reads alias ID from `self.triggers.bot_id`, runs `delete-bot-alias`; uses `self.triggers` values to preserve bot_id and region after the bot resource is queued for deletion
- `bot-alias-locale-settings` must set `en_US` enabled: `'{"en_US":{"enabled":true}}'`
- After a successful create or update, the same provisioner must resolve the alias ARN and write it to the canonical SSM parameter `/${terraform.workspace}/lex/live-alias-arn` so downstream PRD-72 applies read a single workspace-scoped value.

### FR-006 — Destroy Fence
Provision `null_resource.bot_version_destroy_fence` with `depends_on = [null_resource.bot_alias_live, aws_lexv2models_bot_version.v1]`. This carries no create-time side effects. On destroy, Terraform reverses `depends_on`: the fence is destroyed before `bot_version`, and `bot_alias_live` is destroyed before the fence — producing the required ordering: alias deleted → version deleted → bot deleted.

### FR-007 — Alias ARN Resolution And Canonical Publication
The alias ARN is not exposed as a Terraform output because `data "external"` is racy on first apply. The bot ID is the stable Terraform output, but the current repo contract also requires a canonical SSM publication path for PRD-72. The module creates the SSM parameter placeholder during apply and the alias-management provisioner overwrites it with the real ARN once the alias exists.

```bash
# post-apply-resolve-alias-arn.sh
# Run after terraform apply only for operator verification or repair.
BOT_ID=$(terraform output -raw lex_bot_id)
REGION="${AWS_REGION:-us-east-1}"

ALIAS_ARN=$(aws lexv2-models list-bot-aliases \
  --bot-id "$BOT_ID" \
  --region "$REGION" \
  --query "botAliasSummaries[?botAliasName=='live'].botAliasArn | [0]" \
  --output text)

echo "Bot ID:    $BOT_ID"
echo "Alias ARN: $ALIAS_ARN"
# Store ALIAS_ARN in the same workspace-scoped SSM parameter used by PRD-72
aws ssm put-parameter \
  --name "/$(terraform workspace show)/lex/live-alias-arn" \
  --value "$ALIAS_ARN" \
  --type "String" \
  --overwrite \
  --region "$REGION"
```

PRD-72 consumes that SSM parameter via `data "aws_ssm_parameter"`. If the parameter still contains `PENDING_FIRST_APPLY`, PRD-72 must refuse association rather than proceeding with a placeholder value.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
Amazon Lex V2 SLA: 99.9%. When the `LEX_INTEGRATION_HOOK` is disabled in PRD-14, the bot being unavailable has zero impact on call routing — callers fall through to the DTMF menu.

### Idempotency
`terraform apply` on an unchanged bot must produce zero resource changes. This is achieved by `lifecycle { ignore_changes = all }` on `aws_lexv2models_bot_version` and by the `null_resource` trigger only firing when `bot_version` changes.

### Security
- Lex IAM role restricted to CloudWatch Logs write access — no Lambda invoke, no S3 access at this layer
- Permission boundary from PRD-02 applied
- No PII retained in bot session beyond 120-second TTL

---

## 8. ARCHITECTURE

```
Terraform Module: l7-lex-bot-foundation
│
├── aws_iam_role.lex_runtime
│   └── Trust: lexv2.amazonaws.com
│   └── Policy: CloudWatch Logs /aws/lex/*
│
├── aws_lexv2models_bot.auto_attendant
│   └── idle_session_ttl = 120s
│
├── aws_lexv2models_bot_locale.en_us
│   └── n_lu_intent_confidence_threshold = 0.40
│   └── bot_version = "DRAFT"
│
├── aws_lexv2models_bot_version.v1
│   └── lifecycle { ignore_changes = all }
│   └── depends_on: all intents (PRD-71)
│
├── null_resource.bot_alias_live   ← ALIAS MANAGEMENT (no native TF resource)
│   ├── triggers: bot_id, bot_version, region
│   ├── local-exec (create): create-bot-alias OR update-bot-alias
│   └── local-exec (destroy): delete-bot-alias
│
└── null_resource.bot_version_destroy_fence
    └── depends_on: [bot_alias_live, bot_version]
    └── Ensures destroy order: alias → version → bot

Post-apply:
└── post-apply-resolve-alias-arn.sh
    └── Resolves alias ARN via AWS CLI
    └── Stores in SSM: /{workspace}/lex/live-alias-arn
    └── Consumed by PRD-72 via data.aws_ssm_parameter
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `lex_bot_id` | string | Bot ID — stable Terraform output, entry point for all post-apply scripts | PRD-71, PRD-72, post-apply scripts |
| `lex_bot_locale_id` | string | `en_US` — locale ID for intent registration in PRD-71 | PRD-71 |
| `lex_bot_version` | string | Published version number | PRD-72 |
| SSM: `/{env}/lex/live-alias-arn` | SSM String | Alias ARN — resolved post-apply, stored in SSM | PRD-72 |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l7-lex-bot-foundation/      # PRD-70
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Complete main.tf

```hcl
# main.tf
# IMPORTANT: Read provider gap documentation in Section 2 before modifying.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ─────────────────────────────────────────────────────────────────
# IAM Role for Lex runtime
# ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lex_runtime" {
  name                 = "${var.org_name}-lex-runtime-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lexv2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Layer = "L7", PRD = "PRD-70" }
}

resource "aws_iam_role_policy" "lex_runtime" {
  name = "lex-runtime-inline"
  role = aws_iam_role.lex_runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatch Logs only — no Lambda fulfillment (Connect handles fulfillment)
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lex/*"
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────────
# Lex V2 Bot
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_bot" "auto_attendant" {
  name                        = "${var.org_name}-auto-attendant-${terraform.workspace}"
  role_arn                    = aws_iam_role.lex_runtime.arn
  idle_session_ttl_in_seconds = 120

  data_privacy {
    child_directed = false
  }

  tags = { Layer = "L7", PRD = "PRD-70" }
}

# ─────────────────────────────────────────────────────────────────
# Bot Locale — English (US)
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_bot_locale" "en_us" {
  bot_id      = aws_lexv2models_bot.auto_attendant.id
  bot_version = "DRAFT"
  locale_id   = "en_US"

  # 0.40 matches reference implementation — matches short phrases e.g. "billing"
  n_lu_intent_confidence_threshold = 0.40
}

# ─────────────────────────────────────────────────────────────────
# Bot Version
#
# lifecycle { ignore_changes = all } prevents Terraform from publishing
# a new version on every apply when the bot is unchanged.
# To republish after intent changes (PRD-71):
#   terraform taint 'module.lex_foundation.aws_lexv2models_bot_version.v1'
#   terraform apply
#
# depends_on is populated by PRD-71 — all intent resources are listed there.
# ─────────────────────────────────────────────────────────────────

resource "aws_lexv2models_bot_version" "v1" {
  bot_id = aws_lexv2models_bot.auto_attendant.id

  locale_specification = {
    en_US = {
      source_bot_version = "DRAFT"
    }
  }

  lifecycle {
    ignore_changes = all
  }

  # depends_on list extended by PRD-71 intents — do not remove existing entries
  depends_on = [
    aws_lexv2models_bot_locale.en_us
  ]
}

# ─────────────────────────────────────────────────────────────────
# Live Alias — via null_resource + AWS CLI
#
# aws_lexv2models_bot_alias does not exist in the Terraform AWS provider.
# Issue: hashicorp/terraform-provider-aws#35780 — provider gap remains.
# This null_resource is the current repo boundary, not a universal pattern.
#
# Destroy provisioner uses self.triggers.bot_id to preserve the value
# after the bot resource is queued for deletion.
# ─────────────────────────────────────────────────────────────────

resource "null_resource" "bot_alias_live" {
  triggers = {
    bot_id      = aws_lexv2models_bot.auto_attendant.id
    bot_version = aws_lexv2models_bot_version.v1.bot_version
    region      = data.aws_region.current.name
  }

  provisioner "local-exec" {
    command = <<-EOT
      BOT_ID="${aws_lexv2models_bot.auto_attendant.id}"
      BOT_VERSION="${aws_lexv2models_bot_version.v1.bot_version}"
      REGION="${data.aws_region.current.name}"
      LOCALE_SETTINGS='{"en_US":{"enabled":true}}'

      EXISTING=$(aws lexv2-models list-bot-aliases \
        --bot-id "$BOT_ID" \
        --region "$REGION" \
        --query "botAliasSummaries[?botAliasName=='live'].botAliasId | [0]" \
        --output text 2>/dev/null)

      if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
        echo "Creating 'live' alias for bot $BOT_ID at version $BOT_VERSION"
        aws lexv2-models create-bot-alias \
          --bot-id "$BOT_ID" \
          --bot-alias-name "live" \
          --bot-version "$BOT_VERSION" \
          --bot-alias-locale-settings "$LOCALE_SETTINGS" \
          --region "$REGION"
      else
        echo "Updating 'live' alias $EXISTING for bot $BOT_ID to version $BOT_VERSION"
        aws lexv2-models update-bot-alias \
          --bot-id "$BOT_ID" \
          --bot-alias-id "$EXISTING" \
          --bot-alias-name "live" \
          --bot-version "$BOT_VERSION" \
          --bot-alias-locale-settings "$LOCALE_SETTINGS" \
          --region "$REGION"
      fi

      # Store alias ARN in SSM for PRD-72 to consume without data "external" race
      ALIAS_ARN=$(aws lexv2-models list-bot-aliases \
        --bot-id "$BOT_ID" \
        --region "$REGION" \
        --query "botAliasSummaries[?botAliasName=='live'].botAliasArn | [0]" \
        --output text)
      if [ -n "$ALIAS_ARN" ] && [ "$ALIAS_ARN" != "None" ]; then
        aws ssm put-parameter \
          --name "/${terraform.workspace}/lex/live-alias-arn" \
          --value "$ALIAS_ARN" \
          --type "String" \
          --overwrite \
          --region "$REGION"
        echo "Stored alias ARN in SSM: $ALIAS_ARN"
      fi
    EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      BOT_ID="${self.triggers.bot_id}"
      REGION="${self.triggers.region}"

      ALIAS_ID=$(aws lexv2-models list-bot-aliases \
        --bot-id "$BOT_ID" \
        --region "$REGION" \
        --query "botAliasSummaries[?botAliasName=='live'].botAliasId | [0]" \
        --output text 2>/dev/null)

      if [ -z "$ALIAS_ID" ] || [ "$ALIAS_ID" = "None" ]; then
        echo "No 'live' alias found — skipping delete"
      else
        echo "Deleting 'live' alias $ALIAS_ID from bot $BOT_ID"
        aws lexv2-models delete-bot-alias \
          --bot-id "$BOT_ID" \
          --bot-alias-id "$ALIAS_ID" \
          --region "$REGION"
      fi
    EOT
    interpreter = ["bash", "-c"]
  }
}

# ─────────────────────────────────────────────────────────────────
# Destroy Fence
#
# No create-time side effects. On destroy, Terraform reverses depends_on:
# bot_version_destroy_fence destroyed before bot_version,
# bot_alias_live destroyed before bot_version_destroy_fence.
# Required order: alias deleted → version deleted → bot deleted.
# Without this, DeleteBotVersion returns 409 ConflictException.
# ─────────────────────────────────────────────────────────────────

resource "null_resource" "bot_version_destroy_fence" {
  depends_on = [
    null_resource.bot_alias_live,
    aws_lexv2models_bot_version.v1,
  ]
}

# ─────────────────────────────────────────────────────────────────
# SSM Parameter — optional downstream sink / bootstrap placeholder
# (populated by null_resource.bot_alias_live local-exec on first apply when SSM publication is in use)
# ─────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "lex_alias_arn_placeholder" {
  name  = "/${terraform.workspace}/lex/live-alias-arn"
  type  = "String"
  value = "PENDING_FIRST_APPLY"

  lifecycle {
    # null_resource.bot_alias_live updates this value via AWS CLI after creation.
    # Ignore Terraform-level changes after initial creation.
    ignore_changes = [value]
  }

  tags = { Layer = "L7", PRD = "PRD-70" }
}
```

### Variables

```hcl
# variables.tf

variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "lex_bot_state_key" { type = string }
variable "layer_id"    { type = string; default = "L7" }
variable "prd_id"      { type = string; default = "PRD-70" }
```

### Outputs

```hcl
# outputs.tf

output "lex_bot_id" {
  description = "Lex bot ID. Stable Terraform output. Entry point for all post-apply scripts and PRD-71/72 intent registration."
  value       = aws_lexv2models_bot.auto_attendant.id
}

output "lex_bot_locale_id" {
  description = "Bot locale ID. Passed to all aws_lexv2models_intent resources in PRD-71."
  value       = aws_lexv2models_bot_locale.en_us.locale_id
}

output "lex_bot_version" {
  description = "Published bot version number. Used by PRD-72 to verify alias points to correct version."
  value       = aws_lexv2models_bot_version.v1.bot_version
}

output "lex_alias_arn_ssm_parameter" {
  description = "SSM parameter name containing the live alias ARN. Optional downstream consumers may read it via data.aws_ssm_parameter."
  value       = aws_ssm_parameter.lex_alias_arn_placeholder.name
}

output "lex_runtime_role_arn" {
  description = "Lex runtime IAM role ARN."
  value       = aws_iam_role.lex_runtime.arn
}
```

### Backend

```hcl
terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}
```

The repo's plan and apply workflows inject the catalog-declared `state_key` during `terraform init`. This module does not hardcode environment names or workspace-derived backend paths.

---

## 10. EVENT SCHEMA

PRD-70 produces no EventBridge events. The bot itself processes caller utterances but does not publish to the platform bus — intent outcomes are returned to the Connect contact flow via the Lex-Connect integration (PRD-72), which then sets contact attributes that other services read.

---

## 11. API / INTERFACE CONTRACT

```hcl
# Standard downstream consumption pattern for PRD-71 and PRD-72
data "terraform_remote_state" "lex_bot_foundation" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.lex_bot_state_key, region = var.aws_region }
}

locals {
  lex_bot_id               = data.terraform_remote_state.lex_bot_foundation.outputs.lex_bot_id
  lex_bot_locale_id        = data.terraform_remote_state.lex_bot_foundation.outputs.lex_bot_locale_id
  lex_alias_arn_ssm_param  = data.terraform_remote_state.lex_bot_foundation.outputs.lex_alias_arn_ssm_parameter
}

# PRD-72 reads alias ARN from SSM (not Terraform remote state — see Section 5 FR-007)
data "aws_ssm_parameter" "lex_alias_arn" {
  name = local.lex_alias_arn_ssm_param
}

locals {
  lex_live_alias_arn = data.aws_ssm_parameter.lex_alias_arn.value
}
```

---

## 12. DATA MODEL

### SSM Parameter

| Parameter | Value | Written By |
|---|---|---|
| `/{workspace}/lex/live-alias-arn` | Full alias ARN string | `null_resource.bot_alias_live` local-exec on alias create/update, with the placeholder created by Terraform during the same apply |

The SSM parameter is initialized as `PENDING_FIRST_APPLY` by Terraform and updated to the real ARN by the `null_resource` local-exec script during the same apply. On subsequent applies where the bot version has not changed, the `null_resource` does not re-trigger and the SSM value remains unchanged.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l7-lex-bot-foundation }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l7-lex-bot-foundation, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l7-lex-bot-foundation
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l7-lex-bot-foundation-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Bot Republish Procedure (after PRD-71 intent changes)

When intents are added, updated, or removed in PRD-71, a new bot version must be published:

```bash
# Step 1: Taint the bot version resource
terraform taint 'module.lex_bot_foundation.aws_lexv2models_bot_version.v1'

# Step 2: Apply — publishes new version and updates the live alias
terraform apply

# Step 3: Verify new version is live
BOT_ID=$(terraform output -raw lex_bot_id)
aws lexv2-models list-bot-aliases --bot-id $BOT_ID \
  --query "botAliasSummaries[?botAliasName=='live'].{Version:botVersion,AliasId:botAliasId}"
```

### Bot Rollback Procedure

```bash
# Rollback to previous version — update alias via AWS CLI directly
BOT_ID=$(terraform output -raw lex_bot_id)
REGION="${AWS_REGION:-us-east-1}"

# List available versions
aws lexv2-models list-bot-versions --bot-id $BOT_ID --region $REGION

# Get alias ID
ALIAS_ID=$(aws lexv2-models list-bot-aliases \
  --bot-id $BOT_ID --region $REGION \
  --query "botAliasSummaries[?botAliasName=='live'].botAliasId | [0]" \
  --output text)

# Update alias to previous version
aws lexv2-models update-bot-alias \
  --bot-id $BOT_ID \
  --bot-alias-id $ALIAS_ID \
  --bot-alias-name "live" \
  --bot-version "PREVIOUS_VERSION_NUMBER" \
  --bot-alias-locale-settings '{"en_US":{"enabled":true}}' \
  --region $REGION

# Update SSM parameter
aws ssm put-parameter \
  --name "/${ENVIRONMENT}/lex/live-alias-arn" \
  --value "arn:aws:lex:${REGION}:${ACCOUNT_ID}:bot-alias/${BOT_ID}/${ALIAS_ID}" \
  --type "String" --overwrite --region $REGION
```

### Destroy Procedure

Standard `terraform destroy` with the destroy fence in place handles all ordering automatically. No manual pre-steps required.

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-70-01: Lex Bot Build Failure**
- Source: CloudWatch Events on Lex `BuildBotLocale` status change to `Failed`
- Severity: High — intent changes cannot be deployed

**ALARM-70-02: SSM Parameter Stuck at PENDING_FIRST_APPLY**
- Source: CloudWatch Events rule checking SSM parameter value on schedule
- Threshold: Value equals `PENDING_FIRST_APPLY` after more than 10 minutes
- Severity: Medium — alias ARN not resolved; PRD-72 will read stale value

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-70-01 | Bot exists | `aws lexv2-models list-bots` returns `{org}-auto-attendant-{env}` |
| AC-70-02 | Bot locale en_US exists with NLU threshold 0.40 | `aws lexv2-models describe-bot-locale` returns correct threshold |
| AC-70-03 | Bot version published | `aws lexv2-models list-bot-versions --bot-id {id}` returns at least version 1 |
| AC-70-04 | Live alias exists and points to published version (not $LATEST) | `aws lexv2-models list-bot-aliases` returns alias with numeric version |
| AC-70-05 | SSM parameter contains valid alias ARN (not PENDING) | `aws ssm get-parameter --name /{env}/lex/live-alias-arn` returns ARN string |
| AC-70-06 | Second terraform apply produces no changes | Run apply twice; second run shows 0 changes on all resources |
| AC-70-07 | terraform taint + apply publishes new version and updates alias | Taint bot_version; apply; confirm new version number in alias |
| AC-70-08 | terraform destroy completes without 409 errors | Destroy in dev; confirm clean teardown log |
| AC-70-09 | Module activation is manifest/catalog controlled | Deployment manifest enables the module and the PRD makes no activation claim based on `deployment_profile` |
| AC-70-10 | Current repo conventions are used | Terraform uses partial `s3` backend, `>= 1.14.0`, and AWS provider `~> 6.0` |
| AC-70-11 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `aws_lexv2models_bot_alias` provider gap resolved in future — null_resource conflicts | Low | Medium | When provider support lands, migrate null_resource to native resource in a dedicated amendment PRD. The null_resource destroy provisioner handles cleanup before migration. |
| GitHub Actions runner does not have AWS CLI — null_resource local-exec fails | Low | High | GitHub Actions `ubuntu-latest` includes AWS CLI. Verify in AC-70-01. If custom runners are used, ensure AWS CLI is installed. |
| SSM parameter PENDING_FIRST_APPLY read by PRD-72 before null_resource completes | Low | High | ALARM-70-02 detects this. PRD-72 apply must be sequenced after PRD-70 apply is fully complete including null_resource. Use `dependency-order.json` sequencing. |
| null_resource re-triggers on every apply if bot_version drifts | Medium | Low | `lifecycle { ignore_changes = all }` on bot_version prevents version drift. Taint is the only publish trigger. |
| Destroy fence removed accidentally — terraform destroy fails with 409 | Low | High | The fence null_resource has no create-time cost — never remove it. Document in team runbook. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-70-01 | Should the NLU confidence threshold be environment-specific? Lower threshold in dev for easier testing (e.g., 0.20), higher in prod for accuracy (e.g., 0.40)? | Open — current default 0.40 applied uniformly. Can be parameterized via var.nlu_confidence_threshold if needed before prod apply. |
| OQ-70-02 | Should conversation audio logging be enabled on the live alias? The reference implementation omits it (no S3 audio logs). Enabling adds storage cost but aids quality review. | Open — disabled by default. Can be added to the null_resource local-exec `--conversation-log-settings` parameter when a future Contact Lens or contact analytics layer is applied. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.3.0 | 2026-04-08 | — | Implementation-readiness hardening. Removed the stray PRD-10 dependency, aligned the intended catalog entry to the `ai-assist` pack, made the workspace-scoped SSM alias publication contract explicit for PRD-72, and removed the dual `environment` versus `terraform.workspace` naming drift from the alias publication examples. |
| 1.0.0 | 2026-03-16 | — | Initial release. Provider gap workarounds (hashicorp/terraform-provider-aws#35780) fully incorporated from reference implementation main.tf. null_resource alias management. Destroy fence. SSM alias ARN pattern. lifecycle ignore_changes on bot_version with explicit taint procedure. |
| 1.1.0 | 2026-03-30 | — | Reclassified as an optional AI-pack foundation. Removed unnecessary dependencies on PRD-03 and PRD-40 so the Lex bot foundation can stand up independently of eventing and shared Lambda infrastructure. |
| 1.2.0 | 2026-04-05 | — | Added the repo-owned modularity section, removed `deployment_profile` activation drift, normalized backend/state-key conventions, and clarified that the alias-management workaround is a current repo boundary rather than a universal control-plane prerequisite. |
