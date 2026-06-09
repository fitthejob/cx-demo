# PRD-51 — Contact Control Panel (CCP) Configuration

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-51 |
| **Version** | 1.3.0 |
| **Status** | Green |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 5 — Agent Experience |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-10 (Connect instance URL), PRD-11 (phone number IDs), PRD-13 (routing profiles) |
| **Blocks** | PRD-52 (Whisper Flows), PRD-53 (Agent Transfer) |
| **Optional** | Yes — optional agent-experience feature |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is not used as the activation gate for this module; it only describes runtime shape when the module is enabled.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l5-ccp-configuration`
- `capability_packs`: `[]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-phone-numbers", "modules/l1-queue-architecture"]`
- `state_key`: `l5-ccp-configuration/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `ccp.tfvars`
- `supports_destroy`: `true`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated capability pack exists

### Shared Sink Behavior

- `optional_shared_sinks`: CloudWatch alarms and audit/export hooks, if enabled
- `sink_behavior`: optional inputs only. They are not activation conditions and they do not gate the CCP module's existence in an environment.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: this module does not own persistent data. Its outputs and Connect instance configuration may be removed when the environment is torn down, subject to the surrounding Connect instance lifecycle.

### Control Plane Statement

This PRD uses the repo's module catalog and deployment manifest as the feature-activation control plane. Browser embedding settings, origin allowlists, and caller ID mappings are runtime inputs only; they do not decide whether the module is enabled.

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

The Contact Control Panel (CCP) is the browser-based softphone used by agents in environments that enable the CCP experience. Without CCP configuration, those agents cannot connect to the system. This PRD configures the CCP at the Connect instance level — specifically the approved origins (domains from which the CCP can be embedded), the softphone settings, and the outbound caller ID configuration.

The CCP is embedded in the agent workspace — either as a standalone browser page hosted at the Connect-provided URL, or embedded in a third-party application (CRM, custom dashboard) via the Amazon Connect Streams API. This PRD supports both modes by configuring the approved origins list and exporting the CCP URL and configuration parameters needed by any embedding application.

### What Problem It Solves

- Configures the Connect instance approved origins whitelist for CCP embedding
- Sets outbound caller ID numbers for each department's routing profile
- Exports the CCP URL and configuration for embedding in third-party applications
- Documents the Connect Streams API integration pattern for custom agent workspaces

---

## 4. GOALS

### Goals

- Configure approved origins on the Connect instance for CCP access
- Set outbound caller ID per routing profile using phone numbers from PRD-11
- Export the CCP URL, instance alias, and Streams API configuration parameters
- Document the CCP embedding pattern for CRM integrations (PRD-81, PRD-83)

### Non-Goals

- This PRD does not build a custom agent workspace UI — that is an application-layer concern
- This PRD does not configure the CRM screen pop integration — that is PRD-83
- This PRD does not configure whisper flows — that is PRD-52
- This PRD does not manage CNAM (Caller ID Name) registry submissions — the outbound caller ID number is configured here, but what recipients see as the caller name is managed by PRD-17 (CNAM Registry Management)

---

## 5. PERSONAS & USER STORIES

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-51-01 | Agent | As an agent, I want to open the CCP in my browser and receive calls without any additional configuration | CCP URL opens, agent can log in and set status to Available |
| US-51-02 | Platform Engineer | As the platform engineer, I want approved origins configured so that the CCP can be embedded in authorized applications only | CCP loads from approved origins; rejected from unapproved origins |
| US-51-03 | Operations Manager | As the operations manager, I want outbound calls to show the correct department phone number as caller ID | Outbound call from Sales agent shows sales DID; support agent shows support DID |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Approved Origins
The Connect instance must have approved origins configured to allow CCP access from the following sources. Origins are configured through provider-backed instance updates or the Connect API, not through `deployment_profile` gating:
- The Connect-hosted CCP URL (always approved by default)
- Any custom domain hosting an embedded CCP workspace (specified in `var.approved_ccp_origins`)
- `localhost` for development environments only (excluded from staging and prod)

### FR-002 — Outbound Caller ID Configuration
Each routing profile must have an outbound caller ID phone number assigned. The assignment maps routing profile keys to phone number keys from PRD-11:

| Routing Profile | Outbound Caller ID Phone Number Key |
|---|---|
| sales-primary | sales |
| support-primary | support |
| billing-primary | billing |
| tech-support-primary | support |
| escalations-primary | support |
| general-primary | main-inbound |
| omni | main-inbound |

### FR-003 — CCP URL Export
The CCP standalone URL must be exported as a Terraform output. The URL follows the pattern `https://{instance_alias}.my.connect.aws/ccp-v2/`. This URL is used by agents who access the CCP as a standalone browser tab rather than through an embedded workspace.

### FR-004 — Streams API Configuration Export
The Connect Streams API configuration parameters must be exported for consumption by CRM embedding applications (PRD-83). The configuration includes the instance alias, the CCP URL, and the SAML/native login URL. These parameters are passed to `connect.core.initCCP()` in the embedding application.

### FR-005 — Controlled Apply Contract
This PRD's implementation contract is split into desired state and apply state:

1. Terraform owns the desired configuration contract: approved origins, effective origin policy, routing-profile caller-ID mappings, and exported CCP embedding parameters.
2. The actual Connect writes are applied through a controlled operator workflow that calls the Connect API with the Terraform-rendered contract and captures evidence of the resulting instance settings.
3. The module must not rely on a recurring `null_resource`, shell-out provisioner, or cross-module source edit as its normal boundary.
4. The apply workflow must be repeatable and idempotent for the same desired configuration payload.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Security
Approved origins restrict CCP access to authorized domains. In production, `localhost` must not be in the approved origins list. The approved origins list is managed as a Terraform variable so changes go through PR review.

---

## 8. ARCHITECTURE

```
Agent Browser
      │
      ├── Standalone: https://{alias}.my.connect.aws/ccp-v2/
      │
      └── Embedded: Custom app loads CCP via Streams API
                    connect.core.initCCP({
                      ccpUrl: "https://{alias}.my.connect.aws/ccp-v2/",
                      loginUrl: "https://{alias}.my.connect.aws/connect/login",
                      softphone: { allowFramedSoftphone: true }
                    });
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `ccp_url` | string | Standalone CCP URL for agents | Operations documentation, PRD-83 |
| `instance_alias` | string | Connect instance alias | PRD-83 (Streams API config) |
| `streams_api_config` | map | Full Streams API init config | PRD-83 |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l5-ccp-configuration/       # PRD-51
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Key Resources Declared

```hcl
# main.tf

# Terraform owns the desired CCP configuration contract and exports the
# rendered apply payload used by the controlled operator workflow.
# This module does not rely on recurring shell-out provisioners or cross-module
# source edits as its normal boundary.

data "terraform_remote_state" "connect_instance" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.connect_instance_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "routing_profiles" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.routing_profiles_state_key
    region = var.aws_region
  }
}

data "terraform_remote_state" "phone_numbers" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.phone_numbers_state_key
    region = var.aws_region
  }
}

locals {
  connect_instance_id    = data.terraform_remote_state.connect_instance.outputs.instance_id
  connect_instance_alias = data.terraform_remote_state.connect_instance.outputs.instance_alias
  routing_profile_ids    = data.terraform_remote_state.routing_profiles.outputs.routing_profile_ids
  phone_number_ids       = data.terraform_remote_state.phone_numbers.outputs.phone_number_ids
  approved_ccp_origins_effective = distinct(concat(
    var.approved_ccp_origins,
    terraform.workspace == "dev" && var.allow_localhost_ccp_origin ? ["http://localhost:3000"] : []
  ))
  outbound_caller_id_map = {
    sales-primary        = local.phone_number_ids["sales"]
    support-primary      = local.phone_number_ids["support"]
    billing-primary      = local.phone_number_ids["billing"]
    tech-support-primary = local.phone_number_ids["support"]
    escalations-primary  = local.phone_number_ids["support"]
    general-primary      = local.phone_number_ids["main-inbound"]
    omni                 = local.phone_number_ids["main-inbound"]
  }
  ccp_apply_contract = {
    instance_id                 = local.connect_instance_id
    instance_alias              = local.connect_instance_alias
    approved_origins            = local.approved_ccp_origins_effective
    outbound_caller_id_map      = local.outbound_caller_id_map
    standalone_ccp_url          = "https://${local.connect_instance_alias}.my.connect.aws/ccp-v2/"
    streams_login_url           = "https://${local.connect_instance_alias}.my.connect.aws/connect/login"
  }
}
```

### Variables

```hcl
variable "org_name"   { type = string }
variable "aws_region" { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "ccp_state_key" { type = string }
variable "connect_instance_state_key" { type = string }
variable "routing_profiles_state_key" { type = string }
variable "phone_numbers_state_key" { type = string }
variable "allow_localhost_ccp_origin" { type = bool, default = false }

variable "approved_ccp_origins" {
  type        = list(string)
  description = "List of approved domains for CCP embedding. Do NOT include localhost in staging/prod."
  default     = []
  validation {
    condition     = alltrue([for origin in var.approved_ccp_origins : !can(regex("localhost", origin))])
    error_message = "approved_ccp_origins must not include localhost. Use allow_localhost_ccp_origin only in dev."
  }
}
```

### Outputs

```hcl
output "ccp_url" {
  description = "Standalone CCP URL for agents. Share with agents as their softphone access point."
  value       = "https://${local.connect_instance_alias}.my.connect.aws/ccp-v2/"
}

output "instance_alias" {
  description = "Connect instance alias. Used in Streams API configuration."
  value       = local.connect_instance_alias
}

output "streams_api_config" {
  description = "Connect Streams API initialization configuration. Consumed by PRD-83 for CRM embedding."
  value = {
    ccpUrl    = "https://${local.connect_instance_alias}.my.connect.aws/ccp-v2/"
    loginUrl  = "https://${local.connect_instance_alias}.my.connect.aws/connect/login"
    softphone = { allowFramedSoftphone = true }
  }
}

output "approved_ccp_origins_effective" {
  description = "Effective approved origin list after environment validation rules are applied."
  value       = local.approved_ccp_origins_effective
}

output "outbound_caller_id_map" {
  description = "Resolved routing-profile key to phone-number ID mapping for the controlled CCP apply path."
  value       = local.outbound_caller_id_map
}

output "ccp_apply_contract" {
  description = "Rendered Connect API apply payload for approved origins and outbound caller ID settings."
  value       = local.ccp_apply_contract
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

The repo's plan and apply workflows inject the catalog-declared `state_key` during `terraform init`. This module does not hardcode environment names, workspace paths, or backend key fragments.

---

## 10. EVENT SCHEMA

PRD-51 produces no EventBridge events.

---

## 11. API / INTERFACE CONTRACT

```hcl
data "terraform_remote_state" "ccp" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.ccp_state_key
    region = var.aws_region
  }
}
locals {
  ccp_url            = data.terraform_remote_state.ccp.outputs.ccp_url
  streams_api_config = data.terraform_remote_state.ccp.outputs.streams_api_config
}
```

The `ccp_state_key` input must match the catalog-declared `state_key` for this module. It is not a workspace-derived path.

---

## 12. DATA MODEL

PRD-51 provisions no data stores.

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l5-ccp-configuration }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l5-ccp-configuration, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l5-ccp-configuration
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l5-ccp-configuration-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-51-01: CCP Login Failures**
- Source: CloudTrail — Connect `LoginUser` API calls with error responses
- Threshold: > 10 failed logins in 5 minutes
- Severity: Medium — agents unable to access CCP

This alarm is an optional operational sink only. It does not gate CCP activation and it does not create a hidden dependency on PRD-03.

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-51-01 | CCP URL opens in browser | Navigate to CCP URL; confirm login page loads |
| AC-51-02 | Agent can log in and set status to Available | Log in as test agent; set status; confirm Available in Connect console |
| AC-51-03 | CCP loads from approved origin | Load CCP from approved domain; confirm loads without CORS error |
| AC-51-04 | CCP rejected from unapproved origin | Attempt to load CCP from non-approved domain; confirm blocked |
| AC-51-05 | streams_api_config output contains correct URLs | `terraform output streams_api_config` returns correct ccpUrl and loginUrl |
| AC-51-06 | Controlled apply contract renders the expected approved origins and caller-ID mappings | `terraform output ccp_apply_contract` matches the intended environment inputs |
| AC-51-07 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Approved origins list too restrictive — blocks legitimate embedding | Medium | High | Test from all intended origins before prod apply. Keep `approved_ccp_origins` in version-controlled tfvars. |
| localhost in approved origins leaks to prod | Low | Medium | Terraform validation block rejects localhost in staging and prod environments. |
| Provider coverage is insufficient for a steady-state CCP write path | Medium | High | Keep Terraform as the source of desired state, then apply the rendered Connect API contract through the controlled operator workflow with captured evidence. Do not rely on a recurring `null_resource`, shell-out provisioner, or cross-module source edit as the normal boundary. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-51-01 | What custom domains (if any) need to be added to approved_ccp_origins? This depends on whether the CCP will be embedded in a custom agent workspace or CRM. | Open — add domains to prod.tfvars before prod apply. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.3.0 | 2026-04-06 | — | Implementation-readiness hardening: resolved the write-path ambiguity by separating Terraform-owned desired state from a controlled Connect API apply workflow, added the missing phone-number dependency and rendered apply contract outputs, and aligned plan artifact naming with current repo conventions. |
| 1.0.0 | 2026-03-16 | — | Initial release. CCP URL and Streams API config exported. Approved origins pattern established. |
| 1.1.0 | 2026-03-22 | — | Added Non-Goal clarifying that CNAM (Caller ID Name) registry management is PRD-17, not PRD-51. PRD-51 configures which phone number is used as outbound caller ID; PRD-17 controls what recipients see as the caller name display. |
| 1.2.0 | 2026-04-05 | — | Added repo-owned modularity/governance section, removed `deployment_profile` gating, aligned backend/provider examples to current repo conventions, and replaced shell-out-oriented resource sketches with provider-backed remote-state wiring. |
