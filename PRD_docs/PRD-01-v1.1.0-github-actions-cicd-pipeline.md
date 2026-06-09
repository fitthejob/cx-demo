# PRD-01 — GitHub Actions CI/CD Pipeline

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-01 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-03-21 |
| **Layer** | 0 — Platform Foundation |
| **Depends On** | PRD-00 (execution role ARN, OIDC provider ARN, state bucket name, lock table name) |
| **Blocks** | All PRDs — no downstream PRD is applied without this pipeline |
| **Optional** | No |

---

## 2. MODULE GOVERNANCE

### Module Classification

| Field | Value |
|---|---|
| `classification` | `core-required` |
| `minimum_deployment_profile` | `bare-bones` |
| `can_be_omitted_from_bare_bones` | `no` |
| `introduces_new_hard_dependencies_into_lower_layers` | `no` |

### Catalog Entry

PRD-01 is a workflow-only PRD. It defines GitHub Actions CI/CD workflows, not a Terraform root module. It does not produce a deployable module directory, does not own Terraform state, and does not appear in the module catalog.

| Field | Value |
|---|---|
| `path` | N/A — workflow definitions in `.github/workflows/` |
| `state_key` | N/A |
| `workspace_scoped` | N/A |
| `supports_destroy` | N/A |

### Shared Sink Behavior

| Sink | Relationship |
|---|---|
| PRD-03 platform alert topic | **optional input** — CI/CD alarm notifications (ALARM-01-01, 01-02, 01-03) should publish to the platform alert topic only when `SNS_ALERT_TOPIC_ARN` is supplied as a GitHub Actions secret. When the secret is absent, alarms must degrade gracefully (log-only) rather than fail silently. PRD-03 is not a hard prerequisite for CI/CD pipeline operation. |

### Destroy / Retention Posture

| Field | Value |
|---|---|
| `destroy_posture` | N/A — workflow YAML files are source-controlled, not Terraform-managed |
| `retention_notes` | Workflow run logs retained per GitHub organization settings |

### Control Plane Statement

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity. PRD-01 is a workflow-only PRD and does not participate in the module catalog.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Infrastructure applied manually is infrastructure that is untracked, unreviewable, and non-auditable. For SOC 2 Type II, every change to production infrastructure must be traceable to a specific actor, a specific intent, and a specific outcome. Manual `terraform apply` satisfies none of these requirements. For PCI-DSS, change management controls require that production changes are authorized, tested, and recorded before application.

The CI/CD pipeline is the enforcement mechanism for all of these controls. It is not a convenience — it is a compliance boundary. Once this pipeline is live, no engineer applies infrastructure changes to staging or production directly. Every change flows through a pull request, a security scan, a plan review, and an environment-gated apply.

For a solo developer, the pipeline also functions as a personal discipline framework. It prevents the most common solo failure mode: applying an untested change to production under time pressure, without a reviewable record of what changed or why.

### What Problem It Solves

- Enforces the three-stage promotion model: `dev → staging → prod`
- Ensures every infrastructure change is planned, scanned, reviewed, and recorded before application
- Posts Terraform plan output directly to pull requests so the exact diff is reviewed before approval
- Eliminates long-lived AWS credentials from GitHub entirely via OIDC federation from PRD-00
- Creates an auditable record of every infrastructure change: who triggered it, what it changed, which environment, and whether it succeeded
- Detects configuration drift in production nightly and alerts before drift accumulates
- Supports selective module targeting so a single PR can apply one PRD module without affecting others

### How It Fits the Overall Architecture

The CI/CD pipeline is the delivery mechanism for every PRD from PRD-02 onward. It provisions no application resources itself. It is the wrapper that safely executes all other modules' Terraform code. The reusable workflow templates defined here are referenced by every subsequent PRD's CI/CD specification section. The workflow filenames, environment variable conventions, and promotion gates established here are platform-wide standards that do not vary between PRDs.

PRD-01 consumes the backend and CI identity primitives established by PRD-00. In the current architecture, PRD-00 serves as the account-level delivery backplane for downstream automation, while PRD-01 defines the workflow layer that uses those primitives.

### File Type Clarification — YAML vs HCL

This PRD defines two categories of files that must not be confused:

**GitHub Actions workflow files** (`.github/workflows/*.yml`) are written in **YAML**. This is a GitHub platform requirement — the GitHub Actions runner only parses YAML. These are not Terraform files. There is no HCL equivalent for GitHub Actions workflow definitions. This is intentional and correct.

**Terraform configuration files** (`*.tf`) are written in **HCL** throughout this platform without exception. Every module, resource, variable, output, and backend block in every PRD is HCL.

The YAML workflow files call the HCL Terraform modules. They are complementary technologies serving different roles. Any future engineer reading this PRD should understand that the presence of YAML in this PRD is scoped exclusively to GitHub Actions orchestration and does not represent a deviation from the HCL-first infrastructure standard.

---

## 4. GOALS

### Goals

- Define and implement four reusable GitHub Actions workflow files covering plan, apply, security scan, and drift detection
- Implement the three-stage promotion model with appropriate gates at each stage
- Post formatted, human-readable Terraform plan output as a PR comment on every pull request
- Implement per-environment secret and variable injection via GitHub Actions environments — no values hardcoded in workflow files
- Implement security scanning (tfsec + checkov) as a required PR gate that blocks merge on HIGH or CRITICAL findings
- Support selective module targeting via workflow dispatch input specifying which PRD module to target
- Implement nightly drift detection against the production environment with SNS alerting on detected drift
- Produce a structured JSON deployment audit log entry for every apply operation written to S3
- Enforce that no apply runs against staging or prod without explicit manual approval via GitHub environment protection rules

### Non-Goals

- This PRD does not manage GitHub repository settings, branch protection rules, or team access via Terraform — these are configured manually in GitHub and documented here as required configuration
- This PRD does not provision any AWS application resources
- This PRD does not implement application-layer testing such as Lambda unit tests or contact flow integration tests — those are defined in their respective PRDs
- This PRD does not configure Slack or PagerDuty notifications — those are defined in a future alerting and on-call layer
- This PRD does not implement multi-region pipeline promotion — that is addressed in PRD-122

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — The sole developer who authors Terraform changes, opens pull requests, reviews plan output, and approves environment-gated applies. Also the operator who responds to drift detection alerts.

**GitHub Actions Runner** — The automated agent that executes workflow steps: assumes the Terraform execution role directly via OIDC, runs Terraform commands, posts PR comments, and records deployment audit entries.

**Auditor** — A SOC 2 or PCI auditor who requires evidence of change management controls. Every production change must have a linked pull request, a plan review, an approval, and a recorded outcome.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-01-01 | Platform Engineer | As the platform engineer, I want Terraform plan output posted to my PR so I can review the exact diff before approving | Plan comment appears on PR within 5 minutes of push, contains full resource diff |
| US-01-02 | Platform Engineer | As the platform engineer, I want security scan failures to block my PR merge so that misconfigured resources never reach production | PR merge is blocked when tfsec or checkov returns HIGH or CRITICAL findings |
| US-01-03 | Platform Engineer | As the platform engineer, I want dev to apply automatically on merge so that the development environment always reflects the current main branch state | Dev apply runs within 10 minutes of PR merge to main |
| US-01-04 | Platform Engineer | As the platform engineer, I want to manually approve staging and prod applies so that I control when each environment is updated | Staging and prod apply jobs require explicit approval in GitHub environment gate before running |
| US-01-05 | Platform Engineer | As the platform engineer, I want to target a specific PRD module for apply so I can deploy one service without triggering changes to unrelated modules | Workflow dispatch input accepts a module path and applies only that module |
| US-01-06 | Platform Engineer | As the platform engineer, I want nightly drift detection to alert me if production has drifted from state | Nightly workflow runs terraform plan against prod; any non-empty plan triggers SNS alert |
| US-01-07 | Auditor | As an auditor, I want a recorded deployment log for every apply so I can demonstrate change management controls during the SOC 2 audit | Every apply writes a structured JSON audit entry to the S3 audit prefix |
| US-01-08 | Auditor | As an auditor, I want evidence that no long-lived AWS credentials exist in the CI system | GitHub Actions secrets contain no AWS access keys; OIDC is the sole authentication mechanism |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 — Reusable Workflow: tf-plan.yml
The system must implement a reusable GitHub Actions workflow (YAML) that accepts `module_path` and `environment` as inputs. It must assume the Terraform execution role via OIDC, select the correct Terraform workspace, run `terraform init` and `terraform plan -out=tfplan.binary`, save human-readable plan output to a text file, upload the binary plan file as a GitHub Actions artifact, and post a formatted plan summary as a PR comment. If a previous plan comment exists on the same PR from the same workflow, it must be updated in place rather than appending a new comment.

### FR-002 — Reusable Workflow: tf-apply.yml
The system must implement a reusable GitHub Actions workflow (YAML) that accepts `module_path`, `environment`, and `plan_run_id` as inputs. It must download the binary plan artifact produced by tf-plan.yml, assume the Terraform execution role via OIDC, select the correct workspace, and run `terraform apply` using the downloaded plan file. It must never re-run `terraform plan`. On completion it must write a structured JSON audit entry to S3 regardless of whether the apply succeeded or failed.

### FR-003 — Reusable Workflow: tf-security-scan.yml
The system must implement a reusable GitHub Actions workflow (YAML) that runs both `tfsec` and `checkov` against a specified `module_path`. The workflow must exit with a failure code if either tool returns any finding at HIGH or CRITICAL severity. All findings must be posted as a structured PR comment. MEDIUM and LOW findings must be reported in the comment but must not cause the workflow to fail.

### FR-004 — Reusable Workflow: tf-drift-detect.yml
The system must implement a scheduled GitHub Actions workflow (YAML) that runs nightly at 00:00 UTC against the production workspace for all deployed modules. Any module whose plan output is non-empty must trigger an SNS notification. The workflow must write a structured JSON drift detection result per module to the S3 audit prefix. The SNS topic ARN is injected as a GitHub environment secret — no ARN values are hardcoded in the workflow file.

### FR-005 — Promotion Model Enforcement
The pipeline must enforce the following promotion model:

| Trigger | Action | Gate |
|---|---|---|
| Push to feature branch | Security scan + plan | None — informational only |
| PR opened or updated against main | Security scan + plan posted as comment | Security scan must pass for merge |
| Merge to main | Auto-apply to dev | None — automatic |
| Manual workflow dispatch | Apply to staging | GitHub environment approval |
| Manual workflow dispatch | Apply to prod | GitHub environment approval + 5 minute wait timer |

### FR-006 — Environment Isolation via GitHub Environments
Each of the three environments (dev, staging, prod) must be configured as a distinct GitHub Actions environment. Each holds its own secrets and variables. No value may be hardcoded in any workflow YAML file. Values injected per environment at runtime:

| Variable or Secret | Description |
|---|---|
| `AWS_ACCOUNT_ID` | Target AWS account ID |
| `AWS_REGION` | Deployment region |
| `TF_EXEC_ROLE_ARN` | Terraform execution role ARN from PRD-00 |
| `ENV_KMS_KEY_ARN` | Environment KMS key ARN from PRD-02 |
| `STATE_BUCKET` | S3 state bucket name from PRD-00 |
| `LOCK_TABLE` | DynamoDB lock table name from PRD-00 |
| `SNS_ALERT_TOPIC_ARN` | SNS topic for drift and failure alerts from the future alerting layer — stubbed until available |

### FR-007 — OIDC Authentication
All AWS authentication within workflow runs must use the OIDC identity provider and execution role established in PRD-00. No AWS access keys may be stored in GitHub Actions secrets. The `aws-actions/configure-aws-credentials` action must be used in a single step with `role-to-assume` set to `${{ secrets.TF_EXEC_ROLE_ARN }}`. The action automatically detects the GitHub OIDC token and performs `AssumeRoleWithWebIdentity` directly against the execution role — no intermediate role or role chaining is involved.

### FR-008 — Plan File Integrity
The binary Terraform plan file must be uploaded as a GitHub Actions artifact immediately after the plan step completes. The apply workflow must download this exact artifact and apply it without re-planning. The artifact must be named using the pattern `tfplan-{module_slug}-{environment}-{run_id}` to prevent collision between concurrent workflow runs.

### FR-009 — Selective Module Targeting
Both tf-plan.yml and tf-apply.yml must accept a `module_path` workflow input specifying which PRD module to operate on. When `module_path` is set to `all`, the caller workflow must iterate modules in dependency order as defined in the module dependency manifest at `modules/dependency-order.json`.

### FR-010 — Deployment Audit Log
Every apply run (successful or failed) must write a JSON document to the S3 state bucket under the prefix `audit/deployments/{environment}/{YYYY}/{MM}/{DD}/`. The document must be encrypted with the environment KMS key from PRD-02. Schema is defined in Section 10.

### FR-011 — PR Plan Comment Format
The plan comment must include: module name, target environment, timestamp; a destruction warning banner if the plan includes any resource deletions; a summary line showing resources to add, change, and destroy; the full plan output in a collapsible details block; and a link to the full GitHub Actions workflow run.

### FR-012 — Terraform Version Pinning
All workflow runs must read the Terraform version from the repository root `.terraform-version` file and pass it to the `hashicorp/setup-terraform` action. This file is the single source of truth for the Terraform version across local development and CI.

### FR-013 — Required Branch Protection (Manual Configuration)
The following GitHub branch protection settings must be applied to the `main` branch manually by the platform engineer. They are not managed by Terraform. They must be verified as part of AC-01-13:

- Require pull request before merging — no direct push to main
- Require status checks to pass before merging: `security-scan` and `terraform-plan`
- Require branches to be up to date before merging
- Do not allow bypassing the above settings
- Require linear history

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability
GitHub Actions availability is governed by GitHub's SLA. The pipeline is not in the critical path of telephony operations — Amazon Connect operates independently of the CI/CD system at runtime. A pipeline outage does not affect calls in flight.

### Latency Targets

| Operation | Target |
|---|---|
| Security scan completion | < 3 minutes |
| Plan completion and PR comment posted | < 5 minutes |
| Dev apply completion after merge | < 10 minutes |
| Staging or prod apply completion | < 15 minutes |
| Drift detection full run across all prod modules | < 30 minutes |

### Scale
The four reusable workflow files serve all PRD modules without modification. Adding a new module requires no changes to pipeline infrastructure — only the `dependency-order.json` manifest is updated.

### Security
- Zero long-lived credentials — OIDC only, enforced by FR-007
- Plan artifacts scoped to the workflow run and auto-expired after 30 days
- Audit log entries encrypted with environment KMS key from PRD-02
- GitHub environment protection rules enforce approval gates on staging and prod
- All secret values injected at runtime from GitHub environment secrets — never logged, never hardcoded

### Compliance Touch Points

| Requirement | Control | Evidence Artifact |
|---|---|---|
| PCI-DSS Req 6.4 | Security scan gate blocks HIGH or CRITICAL findings | PR comment with scan results, workflow run log |
| PCI-DSS Req 12.3 | All prod changes require documented approval | GitHub environment approval audit trail |
| SOC 2 CC7.1 | Changes tested in dev and staging before prod | Promotion model enforcement via FR-005 |
| SOC 2 CC7.2 | Change monitoring via nightly drift detection | Drift log in S3 audit prefix |
| SOC 2 CC8.1 | Change authorization — prod requires explicit approval | GitHub environment protection rules and approval log |

---

## 8. ARCHITECTURE

### Workflow Execution Flow

```
PULL REQUEST EVENT
        │
        ├──► tf-security-scan.yml ──► PASS: continue | FAIL: block merge
        │         (YAML)
        │
        └──► tf-plan.yml ──────────► PR comment posted
                  (YAML)              Plan artifact uploaded

MERGE TO MAIN
        │
        └──► tf-apply.yml (dev) ───► Auto-apply, no gate
                  (YAML)              Audit entry → S3
                                            │
                               Manual dispatch + approval
                                            │
                              tf-apply.yml (staging)
                                      Audit entry → S3
                                            │
                               Manual dispatch + approval
                                      + 5 minute wait
                                            │
                               tf-apply.yml (prod)
                                      Audit entry → S3

NIGHTLY SCHEDULE 00:00 UTC
        │
        └──► tf-drift-detect.yml ──► Per module: clean → log
                  (YAML)                           drift → SNS alert + log
```

### Repository Structure

```
connect-pbx/
│
├── .github/
│   └── workflows/
│       ├── tf-plan.yml              # YAML — GitHub Actions reusable
│       ├── tf-apply.yml             # YAML — GitHub Actions reusable
│       ├── tf-security-scan.yml     # YAML — GitHub Actions reusable
│       ├── tf-drift-detect.yml      # YAML — GitHub Actions scheduled
│       └── ci.yml                   # YAML — Caller, orchestrates above
│
├── modules/                         # All HCL Terraform modules
│   ├── bootstrap/                   # PRD-00 (HCL)
│   ├── l0-account-baseline/         # PRD-02 (HCL)
│   ├── l0-audit-pipeline/           # PRD-03 (HCL)
│   ├── l1-connect-instance/         # PRD-10 (HCL)
│   └── ...                          # One directory per PRD, all HCL
│
├── environments/
│   ├── dev.tfvars                   # HCL variable values for dev
│   ├── staging.tfvars               # HCL variable values for staging
│   └── prod.tfvars                  # HCL variable values for prod
│
├── modules/dependency-order.json    # Module apply order for full-stack runs
├── .terraform-version               # Pinned Terraform version string
└── .tfsec.yml                       # tfsec configuration and approved ignores
```

### GitHub Actions Environments

```
GitHub Repository Settings → Environments

├── dev
│   ├── Protection rules: none (auto-apply on merge)
│   └── Secrets: AWS_ACCOUNT_ID, AWS_REGION, TF_EXEC_ROLE_ARN,
│               ENV_KMS_KEY_ARN, STATE_BUCKET, LOCK_TABLE,
│               SNS_ALERT_TOPIC_ARN (stubbed until alerting layer exists)
│
├── staging
│   ├── Required reviewer: platform engineer
│   ├── Wait timer: 0 minutes
│   └── Secrets: same keys, staging-specific values
│
└── prod
    ├── Required reviewer: platform engineer
    ├── Wait timer: 5 minutes
    └── Secrets: same keys, prod-specific values
```

### Integration Points

| Service | Direction | Purpose |
|---|---|---|
| AWS IAM via OIDC | Outbound | Role assumption using PRD-00 provider |
| AWS S3 state bucket | Outbound | Backend initialization and audit log writes |
| AWS DynamoDB lock table | Outbound | Lock acquisition and release during apply |
| AWS KMS environment key | Outbound | Audit log encryption using PRD-02 key |
| AWS SNS alert topic | Outbound | Drift and failure alerts — future alerting topic, stubbed until available |
| GitHub API | Outbound | PR comment creation and update |

### Headless Contract

| Contract Item | Type | Description |
|---|---|---|
| `tf-plan.yml` | Reusable YAML workflow | Called in CI/CD section of every downstream PRD |
| `tf-apply.yml` | Reusable YAML workflow | Called in CI/CD section of every downstream PRD |
| `tf-security-scan.yml` | Reusable YAML workflow | Called in CI/CD section of every downstream PRD |
| `audit/deployments/` S3 prefix | S3 path | Consumed by PRD-03 audit pipeline |
| Deployment audit JSON schema | Schema definition | Consumed by PRD-03 for evidence aggregation |

---

## 9. TERRAFORM SPECIFICATION

### No Terraform Module in This PRD

PRD-01 provisions no Terraform-managed AWS resources. GitHub Actions workflow files are YAML and are committed directly to the repository — they are not Terraform resources and are not managed by HCL. This is the only PRD where the primary deliverables are YAML files rather than HCL modules.

All other PRDs deliver HCL Terraform modules exclusively.

### HCL Standards Established by This PRD

While PRD-01 has no Terraform module of its own, it establishes the HCL conventions used by all downstream modules.

#### Standard `main.tf` Block (HCL)

All downstream modules (`PRD-02` through `PRD-142`) consolidate the `terraform {}` block, provider, and data sources in `main.tf`. `backend.tf` contains only a comment stub. No account-specific values are hardcoded — the empty `backend "s3" {}` block receives all values at runtime via `-backend-config` flags:

```hcl
# main.tf — standard template for PRD-02 through PRD-142
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

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "bootstrap/terraform.tfstate"
    region = var.aws_region
  }
}
```

```
# backend.tf — all downstream modules
# Backend configuration is defined in main.tf
```

Backend values are injected at init time:

| Context | How values are supplied |
|---|---|
| Local runs | `terraform init -backend-config=../bootstrap/backend-<profile>.hcl -backend-config="key=..."` |
| CI/CD | `-backend-config` flags from GitHub Actions secrets (`STATE_BUCKET`, `AWS_REGION`, `ENV_KMS_KEY_ARN`, `LOCK_TABLE`) |

#### Module Dependency Manifest (JSON)

```json
{
  "version": "1.0",
  "layers": [
    {
      "layer": 0,
      "parallel": false,
      "modules": [
        "modules/bootstrap",
        "modules/l0-account-baseline",
        "modules/l0-audit-pipeline"
      ]
    },
    {
      "layer": 1,
      "parallel": true,
      "modules": [
        "modules/l1-connect-instance",
        "modules/l1-phone-numbers",
        "modules/l1-hours-of-operation",
        "modules/l1-queue-architecture",
        "modules/l1-contact-flow-framework"
      ]
    }
  ]
}
```

### GitHub Actions Workflow Files (YAML)

These are platform files, not Terraform. They are included here as the primary deliverable of this PRD.

#### tf-security-scan.yml

```yaml
# .github/workflows/tf-security-scan.yml
# Reusable workflow. Caller: ci.yml
# Runs tfsec and checkov. Fails on HIGH or CRITICAL findings.
# YAML is required by the GitHub Actions platform.

name: Terraform Security Scan

on:
  workflow_call:
    inputs:
      module_path:
        required: true
        type: string

jobs:
  tfsec:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run tfsec
        uses: aquasecurity/tfsec-action@v1.0.0
        with:
          working_directory: ${{ inputs.module_path }}
          soft_fail: false
          format: lovely

  checkov:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: ${{ inputs.module_path }}
          soft_fail: false
          output_format: cli
          download_external_modules: true
```

#### tf-plan.yml

```yaml
# .github/workflows/tf-plan.yml
# Reusable workflow. Caller: ci.yml
# Runs terraform plan and posts output as PR comment.
# YAML is required by the GitHub Actions platform.

name: Terraform Plan

on:
  workflow_call:
    inputs:
      module_path:
        required: true
        type: string
      environment:
        required: true
        type: string

jobs:
  plan:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    permissions:
      id-token: write
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.TF_EXEC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version_file: .terraform-version

      - name: Terraform Init
        working-directory: ${{ inputs.module_path }}
        run: |
          terraform init \
            -backend-config="bucket=${{ secrets.STATE_BUCKET }}" \
            -backend-config="key=${{ inputs.environment }}/${{ inputs.module_path }}/terraform.tfstate" \
            -backend-config="region=${{ secrets.AWS_REGION }}" \
            -backend-config="encrypt=true" \
            -backend-config="kms_key_id=${{ secrets.ENV_KMS_KEY_ARN }}" \
            -backend-config="dynamodb_table=${{ secrets.LOCK_TABLE }}"

      - name: Select Workspace
        working-directory: ${{ inputs.module_path }}
        run: |
          terraform workspace select ${{ inputs.environment }} \
            || terraform workspace new ${{ inputs.environment }}

      - name: Terraform Plan
        id: plan
        working-directory: ${{ inputs.module_path }}
        run: |
          terraform plan \
            -var-file="${{ github.workspace }}/environments/${{ inputs.environment }}.tfvars" \
            -out=tfplan.binary \
            -no-color 2>&1 | tee plan.txt
        continue-on-error: true

      - name: Slugify module path
        id: slug
        run: echo "module_slug=$(echo '${{ inputs.module_path }}' | tr '/' '-')" >> $GITHUB_OUTPUT

      - name: Upload Plan Artifact
        uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ steps.slug.outputs.module_slug }}-${{ inputs.environment }}-${{ github.run_id }}
          path: ${{ inputs.module_path }}/tfplan.binary
          retention-days: 30

      - name: Post Plan to PR
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const plan = fs.readFileSync('${{ inputs.module_path }}/plan.txt', 'utf8');
            const hasDestructions = plan.includes(' destroy');
            const warning = hasDestructions
              ? '> ⚠️ **WARNING: This plan includes resource destructions. Review carefully.**\n\n'
              : '';
            const body = [
              '## Terraform Plan — `${{ inputs.module_path }}` → `${{ inputs.environment }}`',
              warning,
              '<details><summary>Full Plan Output</summary>',
              '',
              '```',
              plan.substring(0, 60000),
              '```',
              '</details>',
              '',
              `[Full workflow run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }})`
            ].join('\n');

            const { data: comments } = await github.rest.issues.listComments({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number
            });
            const existing = comments.find(c =>
              c.body.includes('Terraform Plan') &&
              c.body.includes('${{ inputs.module_path }}') &&
              c.body.includes('${{ inputs.environment }}')
            );
            if (existing) {
              await github.rest.issues.updateComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                comment_id: existing.id,
                body
              });
            } else {
              await github.rest.issues.createComment({
                owner: context.repo.owner,
                repo: context.repo.repo,
                issue_number: context.issue.number,
                body
              });
            }
```

#### tf-apply.yml

```yaml
# .github/workflows/tf-apply.yml
# Reusable workflow. Caller: ci.yml
# Downloads plan artifact and applies it. Never re-plans.
# YAML is required by the GitHub Actions platform.

name: Terraform Apply

on:
  workflow_call:
    inputs:
      module_path:
        required: true
        type: string
      environment:
        required: true
        type: string
      plan_run_id:
        required: true
        type: string

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.TF_EXEC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version_file: .terraform-version

      - name: Slugify module path
        id: slug
        run: echo "module_slug=$(echo '${{ inputs.module_path }}' | tr '/' '-')" >> $GITHUB_OUTPUT

      - name: Download Plan Artifact
        uses: actions/download-artifact@v4
        with:
          name: tfplan-${{ steps.slug.outputs.module_slug }}-${{ inputs.environment }}-${{ inputs.plan_run_id }}
          path: ${{ inputs.module_path }}

      - name: Terraform Init
        working-directory: ${{ inputs.module_path }}
        run: |
          terraform init \
            -backend-config="bucket=${{ secrets.STATE_BUCKET }}" \
            -backend-config="key=${{ inputs.environment }}/${{ inputs.module_path }}/terraform.tfstate" \
            -backend-config="region=${{ secrets.AWS_REGION }}" \
            -backend-config="encrypt=true" \
            -backend-config="kms_key_id=${{ secrets.ENV_KMS_KEY_ARN }}" \
            -backend-config="dynamodb_table=${{ secrets.LOCK_TABLE }}"

      - name: Select Workspace
        working-directory: ${{ inputs.module_path }}
        run: terraform workspace select ${{ inputs.environment }}

      - name: Terraform Apply
        id: apply
        working-directory: ${{ inputs.module_path }}
        run: terraform apply -auto-approve tfplan.binary
        continue-on-error: true

      - name: Write Deployment Audit Log
        if: always()
        run: |
          DATE=$(date -u +%Y/%m/%d)
          TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          cat > audit-entry.json <<EOF
          {
            "timestamp": "${TIMESTAMP}",
            "github_run_id": "${{ github.run_id }}",
            "github_actor": "${{ github.actor }}",
            "environment": "${{ inputs.environment }}",
            "module_path": "${{ inputs.module_path }}",
            "workspace": "${{ inputs.environment }}",
            "outcome": "${{ steps.apply.outcome }}",
            "plan_artifact": "tfplan-${{ steps.slug.outputs.module_slug }}-${{ inputs.environment }}-${{ inputs.plan_run_id }}",
            "workflow_run_url": "${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
          }
          EOF
          aws s3 cp audit-entry.json \
            "s3://${{ secrets.STATE_BUCKET }}/audit/deployments/${{ inputs.environment }}/${DATE}/${{ github.run_id }}.json" \
            --sse aws:kms \
            --sse-kms-key-id "${{ secrets.ENV_KMS_KEY_ARN }}"

      - name: Fail if Apply Failed
        if: steps.apply.outcome == 'failure'
        run: exit 1
```

#### tf-drift-detect.yml

```yaml
# .github/workflows/tf-drift-detect.yml
# Scheduled workflow. Runs nightly at 00:00 UTC.
# Detects drift between actual prod infrastructure and Terraform state.
# YAML is required by the GitHub Actions platform.

name: Terraform Drift Detection

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

jobs:
  load-modules:
    runs-on: ubuntu-latest
    outputs:
      modules: ${{ steps.read.outputs.modules }}
    steps:
      - uses: actions/checkout@v4
      - id: read
        run: |
          MODULES=$(jq -c '[.layers[].modules[]]' modules/dependency-order.json)
          echo "modules=${MODULES}" >> $GITHUB_OUTPUT

  drift-detect:
    needs: load-modules
    runs-on: ubuntu-latest
    environment: prod
    permissions:
      id-token: write
      contents: read
    strategy:
      matrix:
        module: ${{ fromJson(needs.load-modules.outputs.modules) }}
      fail-fast: false

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials via OIDC
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.TF_EXEC_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version_file: .terraform-version

      - name: Terraform Init
        working-directory: ${{ matrix.module }}
        run: |
          terraform init \
            -backend-config="bucket=${{ secrets.STATE_BUCKET }}" \
            -backend-config="key=prod/${{ matrix.module }}/terraform.tfstate" \
            -backend-config="region=${{ secrets.AWS_REGION }}" \
            -backend-config="encrypt=true" \
            -backend-config="kms_key_id=${{ secrets.ENV_KMS_KEY_ARN }}" \
            -backend-config="dynamodb_table=${{ secrets.LOCK_TABLE }}"

      - name: Detect Drift
        id: drift
        working-directory: ${{ matrix.module }}
        run: |
          terraform workspace select prod
          EXIT_CODE=0
          terraform plan -detailed-exitcode -no-color 2>&1 || EXIT_CODE=$?
          echo "exit_code=${EXIT_CODE}" >> $GITHUB_OUTPUT

      - name: Write Drift Result to S3
        if: always()
        run: |
          DATE=$(date -u +%Y/%m/%d)
          TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          DRIFTED=$([[ "${{ steps.drift.outputs.exit_code }}" == "2" ]] && echo "true" || echo "false")
          MODULE_SLUG=$(echo "${{ matrix.module }}" | tr '/' '-')
          cat > drift-result.json <<EOF
          {
            "timestamp": "${TIMESTAMP}",
            "module": "${{ matrix.module }}",
            "environment": "prod",
            "drifted": ${DRIFTED},
            "exit_code": "${{ steps.drift.outputs.exit_code }}"
          }
          EOF
          aws s3 cp drift-result.json \
            "s3://${{ secrets.STATE_BUCKET }}/audit/drift/${DATE}/${MODULE_SLUG}-${{ github.run_id }}.json" \
            --sse aws:kms \
            --sse-kms-key-id "${{ secrets.ENV_KMS_KEY_ARN }}"

      - name: Alert on Drift
        if: steps.drift.outputs.exit_code == '2'
        run: |
          aws sns publish \
            --topic-arn "${{ secrets.SNS_ALERT_TOPIC_ARN }}" \
            --subject "DRIFT DETECTED: ${{ matrix.module }} in prod" \
            --message "Drift detected in ${{ matrix.module }} (prod). Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
```

---

## 10. EVENT SCHEMA

PRD-01 produces no EventBridge events. It produces two S3-persisted JSON schemas consumed by the PRD-03 audit pipeline.

### Deployment Audit Entry Schema

Written to: `s3://{state_bucket}/audit/deployments/{environment}/{YYYY}/{MM}/{DD}/{run_id}.json`

```json
{
  "timestamp":        "ISO 8601 UTC — apply completion time",
  "github_run_id":    "GitHub Actions workflow run ID",
  "github_actor":     "GitHub username that triggered the workflow",
  "environment":      "dev | staging | prod",
  "module_path":      "Relative path to Terraform module e.g. modules/l1-connect-instance",
  "workspace":        "Terraform workspace name matching environment",
  "outcome":          "success | failure",
  "plan_artifact":    "GitHub Actions artifact name of the applied plan file",
  "workflow_run_url": "Full URL to the GitHub Actions workflow run"
}
```

### Drift Detection Result Schema

Written to: `s3://{state_bucket}/audit/drift/{YYYY}/{MM}/{DD}/{module_slug}-{run_id}.json`

```json
{
  "timestamp":   "ISO 8601 UTC — drift check completion time",
  "module":      "Relative path to the Terraform module",
  "environment": "prod",
  "drifted":     "true | false",
  "exit_code":   "0 (no changes) | 1 (plan error) | 2 (drift detected)"
}
```

---

## 11. API / INTERFACE CONTRACT

PRD-01 exposes no HTTP APIs. Its interface contract to downstream PRDs consists of the four reusable workflow files and the two S3 audit log schemas.

### Standard Downstream CI/CD Caller Pattern

Every downstream PRD's CI/CD section references the reusable workflows using this pattern. Only `module_path` changes per PRD:

```yaml
# .github/workflows/ci.yml — caller pattern for downstream PRDs
# module_path is the only value that changes between PRDs

jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with:
      module_path: modules/l1-connect-instance

  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with:
      module_path: modules/l1-connect-instance
      environment: ${{ inputs.environment }}
    secrets: inherit

  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l1-connect-instance
      environment: ${{ inputs.environment }}
      plan_run_id: ${{ github.run_id }}
    secrets: inherit
```

---

## 12. DATA MODEL

### S3 Audit Log Structure

```
s3://{org}-tfstate-{account_id}/
│
└── audit/
    ├── deployments/
    │   ├── dev/
    │   │   └── {YYYY}/{MM}/{DD}/{run_id}.json
    │   ├── staging/
    │   │   └── {YYYY}/{MM}/{DD}/{run_id}.json
    │   └── prod/
    │       └── {YYYY}/{MM}/{DD}/{run_id}.json
    │
    └── drift/
        └── {YYYY}/{MM}/{DD}/{module_slug}-{run_id}.json
```

### Retention Policy

| Data | Retention | Mechanism |
|---|---|---|
| Deployment audit entries | 7 years | S3 lifecycle policy — satisfies SOC 2 Type II evidence retention |
| Drift detection results | 1 year | S3 lifecycle policy |
| Plan artifacts in GitHub | 30 days | GitHub Actions artifact retention setting |
| GitHub Actions workflow logs | 90 days | GitHub default — not configurable without GitHub Enterprise |

### Encryption

All S3 audit entries are written with `--sse aws:kms` using the environment-specific KMS key from PRD-02. No audit entry is ever written without encryption. The S3 bucket policy from PRD-00 enforces this at the bucket level as a second control.

---

## 13. CI/CD SPECIFICATION

### PRD-01 Is the CI/CD System

PRD-01 defines the pipeline. Its own deployment is a one-time manual operation performed by the platform engineer after PRD-00 bootstrap is complete.

### Deployment Sequence

```
1. PRD-00 bootstrap applied and outputs confirmed
2. Copy all four YAML workflow files to .github/workflows/
3. Create dependency-order.json at modules/dependency-order.json
4. Create .terraform-version with the pinned version string
5. Configure GitHub Actions environments: dev, staging, prod
6. Populate all secrets for each environment per FR-006
7. Configure branch protection rules per FR-013
8. Commit and push .github/workflows/ to main
9. Open a test PR and verify plan comment appears
10. Verify security scan runs and posts findings
11. Merge test PR and verify dev auto-apply runs
12. Dispatch staging apply and verify approval gate blocks auto-run
13. Trigger manual drift detection workflow and verify S3 output
```

### Break-Glass Procedure

If the pipeline is broken by a bad workflow change and infrastructure changes cannot wait:

1. Platform engineer runs `terraform apply` locally using personal AWS credentials
2. Engineer assumes the Terraform execution role via `aws sts assume-role`
3. Change is applied with the correct workspace and backend configuration
4. The break-glass usage is recorded manually in the S3 audit log using the same JSON schema
5. Branch protection is temporarily bypassed only to revert the bad workflow file
6. Branch protection is re-enabled immediately after the revert commit is merged
7. All bypass events are logged in the incident record maintained by the platform team

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-01-01: Apply Failure in Production**
- Source: S3 audit entry with `"outcome": "failure"` and `"environment": "prod"`
- Detection: Lambda on S3 ObjectCreated event at `audit/deployments/prod/` — implemented in PRD-03
- Severity: Critical
- Graceful degradation: When `SNS_ALERT_TOPIC_ARN` is not supplied as a GitHub Actions secret (i.e., PRD-03 is not yet deployed), the alarm Lambda logs to CloudWatch only and skips SNS publication. The alarm must not fail silently or error due to a missing topic ARN.

**ALARM-01-02: Drift Detected in Production**
- Source: S3 drift entry with `"drifted": true`
- Detection: Lambda on S3 ObjectCreated event at `audit/drift/` — implemented in PRD-03
- Severity: High
- Graceful degradation: When `SNS_ALERT_TOPIC_ARN` is not supplied as a GitHub Actions secret (i.e., PRD-03 is not yet deployed), the alarm Lambda logs to CloudWatch only and skips SNS publication. The alarm must not fail silently or error due to a missing topic ARN.

**ALARM-01-03: Drift Detection Workflow Did Not Run**
- Source: Absence of today's drift log entry in S3 at 01:00 UTC
- Detection: Scheduled CloudWatch rule — implemented in PRD-03
- Severity: Medium — indicates the nightly workflow itself failed
- Graceful degradation: When `SNS_ALERT_TOPIC_ARN` is not supplied as a GitHub Actions secret (i.e., PRD-03 is not yet deployed), the alarm Lambda logs to CloudWatch only and skips SNS publication. The alarm must not fail silently or error due to a missing topic ARN.

### Log Retention

| Log | Location | Retention |
|---|---|---|
| Deployment audit entries | S3 `audit/deployments/` | 7 years |
| Drift detection results | S3 `audit/drift/` | 1 year |
| GitHub Actions workflow logs | GitHub | 90 days |

### SOC 2 and PCI Evidence Artifacts

| Artifact | Location | Demonstrates |
|---|---|---|
| Deployment audit JSON entries | S3 `audit/deployments/` | SOC 2 CC8.1 — change authorization and recording |
| Drift detection JSON results | S3 `audit/drift/` | SOC 2 CC7.2 — change monitoring |
| GitHub PR approval records | GitHub API | SOC 2 CC8.1 — change authorization |
| tfsec and checkov PR comments | GitHub PR history | PCI-DSS Req 6.4 — security testing before deployment |

---

## 15. ACCEPTANCE CRITERIA

### Definition of Done

| ID | Criterion | Verification Method |
|---|---|---|
| AC-01-01 | Security scan runs on PR and posts findings as comment | Open test PR with known tfsec violation; confirm comment appears |
| AC-01-02 | PR merge blocked when HIGH or CRITICAL finding exists | Confirm GitHub status check fails; merge button disabled |
| AC-01-03 | Plan comment appears within 5 minutes of PR push | Open PR against a module; time comment appearance |
| AC-01-04 | Plan comment updated in place on subsequent pushes | Push second commit to same PR; confirm no duplicate comment |
| AC-01-05 | Plan comment shows destruction warning when plan destroys resources | Create plan that destroys a resource; confirm warning banner present |
| AC-01-06 | Plan artifact uploaded and accessible after plan job | Confirm artifact appears in GitHub Actions run |
| AC-01-07 | Apply job uses plan artifact without re-planning | Confirm apply job downloads artifact and runs `terraform apply tfplan.binary` |
| AC-01-08 | Dev apply runs automatically within 10 minutes of merge | Merge test PR; confirm dev apply starts without manual action |
| AC-01-09 | Staging apply requires manual approval | Trigger staging dispatch; confirm job waits at approval gate |
| AC-01-10 | Prod apply requires approval and 5 minute wait | Trigger prod dispatch; confirm approval gate and timer |
| AC-01-11 | No AWS access keys in GitHub Actions secrets | Audit all environment secrets; confirm no AWS_ACCESS_KEY_ID present |
| AC-01-12 | Every apply writes JSON audit entry to S3 | Trigger dev apply; confirm JSON appears in S3 audit prefix within 2 minutes |
| AC-01-13 | Branch protection rules active on main | Verify in GitHub repository settings |
| AC-01-14 | Nightly drift detection runs at 00:00 UTC | Check GitHub Actions scheduled run history |
| AC-01-15 | Drift detection writes result to S3 per module | After drift run confirm one JSON file per module in `audit/drift/` |
| AC-01-16 | Drift detection publishes SNS alert when drift found | Introduce manual drift in dev; trigger manual drift workflow; confirm SNS message |
| AC-01-17 | Selective module targeting works via dispatch input | Dispatch apply with specific module_path; confirm only that module applied |
| AC-01-18 | Terraform version in CI matches .terraform-version file | Confirm `terraform version` output in workflow log matches file content |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| GitHub Actions outage blocks all infrastructure changes | Low | High | Break-glass procedure: platform engineer applies locally using Terraform execution role. Documented in Section 13. |
| Plan artifact tampered with between plan and apply | Very Low | Critical | Artifacts scoped to workflow run, accessible only within the repository. Execution role has no external artifact write access. |
| OIDC trust policy too broad — any repo in org can assume role | Medium | Critical | PRD-00 execution role trust policy restricts to specific org, repo, branches, and environments via StringLike condition on sub claim. Verify before first use. |
| Audit log S3 writes fail silently | Low | High | Audit write step uses `if: always()` — runs even on apply failure. ALARM-01-01 detects missing entries via PRD-03. |
| Nightly drift workflow fails silently | Medium | Medium | ALARM-01-03 detects absence of today's drift log at 01:00 UTC via PRD-03. |
| Branch protection bypassed during incident recovery | Medium | Medium | All bypasses logged in incident record. Re-enable immediately after recovery. Documented in the platform incident procedure. |
| SNS_ALERT_TOPIC_ARN unavailable before alerting layer is deployed | High early phases | Low | When the secret is absent, alarm Lambdas log to CloudWatch only and skip SNS publication. Replace when the alerting layer is applied. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-01-01 | GitHub organization and repository name for OIDC trust and workflow uses references | Open | Carried from PRD-00 OQ-00-03. Required before first workflow run. Platform engineer to supply. |
| OQ-01-02 | Should dependency-order.json be auto-generated from Terraform output dependencies or manually maintained? | Open | Manual is simpler but error-prone at scale. Auto-generation requires a custom script. Decision needed before first full-stack apply. |
| OQ-01-03 | Should failed prod applies trigger automatic rollback or alert-only? | Open | Recommend alert-only initially for a solo developer. Revisit at PRD-120 (HA and Multi-AZ Promotion). |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial release. File type clarification added to Sections 3 and 9 explicitly distinguishing YAML (GitHub Actions platform files) from HCL (Terraform infrastructure files). |
| 1.1.0 | 2026-03-21 | — | Aligned with PRD-00 v1.2.0 OIDC simplification. FR-007 updated to reflect single-step OIDC authentication (no role chaining). tf-apply.yml input changed from `plan_artifact_name` to `plan_run_id` — artifact name is computed from module path slug. Artifact names now use `-` instead of `/` to comply with GitHub Actions naming rules. Caller pattern updated. |
| 1.2.0 | 2026-04-05 | — | Governance normalization. Added mandatory Module Governance section. Reclassified PRD-03 alarm dependency as optional shared sink with graceful degradation. |
