# RB-01-01 — GitHub Actions CI/CD Setup and Operations

**Runbook ID:** RB-01-01
**Scope:** PRD-01 workflow setup and day-to-day operation
**Audience:** Platform Engineer, Release Engineer
**Last Updated:** 2026-06-06

---

## Overview

This runbook covers the one-time setup and routine operation of the PRD-01 GitHub Actions pipeline.

PRD-01 is a workflow-only layer. It does not deploy a Terraform module, does not own Terraform state, and does not appear in the module catalog. Its job is to run security scan, plan, apply, and drift detection workflows against modules that are already defined elsewhere in the repo.

Use this runbook in three phases:
- after PRD-00 bootstrap to scaffold GitHub environments and bootstrap-owned secrets
- after PRD-02 account baseline is deployed to complete the environment-specific secret set
- during ongoing CI/CD operation and governance maintenance

---

### What this configures

| Workflow | Purpose |
|---|---|
| `ci.yml` | Manual operator entry point for plan + apply of one module or all eligible modules in an environment |
| `tf-security-scan.yml` | Runs catalog integrity checks, `tfsec`, and `checkov` before Terraform plan/apply |
| `tf-plan.yml` | Initializes Terraform with GitHub environment secrets, selects workspace when needed, and creates the binary plan artifact |
| `tf-apply.yml` | Downloads the exact plan artifact from the same run, applies it, and writes an audit JSON record to S3 |
| `tf-auto-deploy-dev.yml` | Full-stack dev deploy workflow. Currently manual dispatch only; push trigger is disabled |
| `tf-drift-detect.yml` | Nightly and manual drift detection across `dev`, `staging`, and `prod` |

The architectural reason for this layer is simple: infrastructure changes should be executed through one auditable path instead of ad hoc local applies.

---

## Prerequisites

Before starting, confirm the following:

| Requirement | Verification |
|---|---|
| PRD-00 bootstrap is complete | `modules/bootstrap` outputs exist and the Terraform execution role ARN is known |
| PRD-02 account baseline is deployed in each target environment when completing full CI/CD secrets | `terraform output -raw kms_key_arn` succeeds in `modules/l0-account-baseline` for that workspace |
| GitHub repository exists | Repository is accessible and `Settings -> Environments` is available |
| GitHub CLI is installed and authenticated if using the sync helper | `gh auth status` |
| Workflow files are present on the default branch | `.github/workflows/ci.yml` and related workflow files exist in `main` |
| The repo uses OIDC, not static AWS keys | No AWS access keys are stored in GitHub secrets |

---

## Inputs you need before touching GitHub

Collect these values first:

| GitHub secret | Source |
|---|---|
| `AWS_REGION` | Bootstrap/account region, usually `us-east-1` |
| `TF_EXEC_ROLE_ARN` | `terraform_execution_role_arn` output from PRD-00 |
| `STATE_BUCKET` | `state_bucket_name` output from PRD-00 |
| `LOCK_TABLE` | `lock_table_name` output from PRD-00 |
| `ENV_KMS_KEY_ARN` | `kms_key_arn` output from PRD-02 for the target workspace |
| `SNS_ALERT_TOPIC_ARN` | Optional. Set only when PRD-03 alerting is deployed |

Optional but useful operator sanity-check value:

| GitHub secret or note | Source |
|---|---|
| `AWS_ACCOUNT_ID` | `aws sts get-caller-identity --query Account --output text` |

`AWS_ACCOUNT_ID` is part of the PRD setup contract, but the current workflow YAML does not consume it directly. It is still useful for confirming each GitHub environment is pointed at the intended account.

---

## Step 1 — Scaffold GitHub environments after bootstrap

Immediately after PRD-00 bootstrap, you can scaffold the GitHub environments in one of two ways:

```bash
cd connect-pbx
./scripts/github-env-bootstrap.sh
```

Or let `modules/bootstrap/scripts/bootstrap.sh` do it for you by answering `yes` to the post-bootstrap prompt or by running:

```bash
./modules/bootstrap/scripts/bootstrap.sh --configure-github
```

What the scaffold helper does:
- resolves the target repository from `modules/bootstrap/bootstrap.tfvars` unless `--repo` is provided
- ensures `dev`, `staging`, and `prod` environments exist
- syncs only bootstrap-owned secrets into each environment
- does not configure protection rules, reviewers, wait timers, or PRD-02 secrets

If you prefer to create the environments manually, go to:

`Settings -> Environments`

Create these environments:
- `dev`
- `staging`
- `prod`

These environments are the isolation boundary for PRD-01. Each environment carries its own AWS and Terraform backend values.

---

## Step 2 — Bootstrap-owned environment secrets

After bootstrap, the following environment secrets can be populated safely before PRD-02 exists:

| Secret | Required | Notes |
|---|---|---|
| `AWS_REGION` | Yes | Usually `us-east-1` |
| `TF_EXEC_ROLE_ARN` | Yes | From PRD-00 |
| `STATE_BUCKET` | Yes | From PRD-00 |
| `LOCK_TABLE` | Yes | From PRD-00; used for Terraform state locking |
| `AWS_ACCOUNT_ID` | No | Operator sanity-check value only |

These values are written automatically by `github-env-bootstrap.sh` or `sync-github-bootstrap-secrets.sh`.

The following values are intentionally not part of bootstrap-owned secret sync:

| Secret | When it becomes available |
|---|---|
| `ENV_KMS_KEY_ARN` | After PRD-02 account baseline is deployed for that environment |
| `SNS_ALERT_TOPIC_ARN` | After PRD-03 alerting is deployed |

---

## Step 3 — Configure environment protection rules manually

Set protection rules as follows:

| Environment | Protection posture |
|---|---|
| `dev` | No approval gate required |
| `staging` | Manual approval required |
| `prod` | Manual approval required |

If you want to match the PRD target posture exactly, also add a 5-minute wait timer to `prod`.

The workflows already target the correct GitHub environment at runtime. The protection rules are what turn those workflow references into approval gates. These controls are intentionally not managed by bootstrap or by the GitHub scaffold helper.

---

## Step 4 — Verify bootstrap values match GitHub after scaffold

Before running any workflow, verify the bootstrap-owned values in GitHub still match the current AWS environment:

```bash
# PRD-00 outputs
cd connect-pbx/modules/bootstrap
terraform output terraform_execution_role_arn
terraform output state_bucket_name

```

What the bootstrap helper does:
- reads `AWS_ACCOUNT_ID` from `aws sts get-caller-identity`
- reads `STATE_BUCKET`, `LOCK_TABLE`, and `TF_EXEC_ROLE_ARN` from `modules/bootstrap`
- writes those values into the matching GitHub Actions environment with `gh secret set`

Secrets written by the bootstrap helper:
- `AWS_ACCOUNT_ID`
- `AWS_REGION`
- `STATE_BUCKET`
- `LOCK_TABLE`
- `TF_EXEC_ROLE_ARN`

Optional flags:
- `--repo <owner/name>` if you want to target a repository other than the current `gh` context
- `--backend-config <path>` if your backend file lives outside the default bootstrap artifact directory

By default, the bootstrap artifact directory is repo-scoped:

- Windows Git Bash: `${LOCALAPPDATA}/connect-pbx/<github_repo>/bootstrap`
- fallback: `${HOME}/.connect-pbx/<github_repo>/bootstrap`

This helper intentionally does not read `modules/l0-account-baseline` and does not write `ENV_KMS_KEY_ARN`.

---

## Step 5 — Complete the full environment secret set after PRD-02

If bootstrap and account-baseline are already deployed, you can populate the full GitHub Actions environment secret set automatically:

```bash
cd connect-pbx
./scripts/sync-github-env-secrets.sh --env dev
```

What the script does:
- reads `AWS_ACCOUNT_ID` from `aws sts get-caller-identity`
- reads `STATE_BUCKET`, `LOCK_TABLE`, and `TF_EXEC_ROLE_ARN` from `modules/bootstrap`
- initializes `modules/l0-account-baseline` against the remote backend
- runs `terraform workspace select <env>` explicitly
- reads `ENV_KMS_KEY_ARN` from that selected workspace
- writes the values into the matching GitHub Actions environment with `gh secret set`

Optional flags:
- `--repo <owner/name>` if you want to target a repository other than the current `gh` context
- `--backend-config <path>` if your backend file lives outside the default bootstrap artifact directory

Example for staging:

```bash
./scripts/sync-github-env-secrets.sh --env staging
```

---

## Step 6 — Run the first manual pipeline test

Use `ci.yml` for the first validation run.

In GitHub:

`Actions -> CI -> Run workflow`

Provide:
- `environment`: `dev`
- `module_path`: the exact catalog path for a safe test module, or `"all"` to run every eligible module in manifest order

Current behavior:
- `ci.yml` is manual dispatch only
- it resolves eligible modules from `environments/<env>/deployment-manifest.json`
- it runs security scan, then plan, then apply in the same workflow run

If `module_path = "all"`, the workflow expands the module list in dependency order using the module catalog.

---

## Step 7 — Operate the day-to-day workflows

### Single module or targeted environment run

Use `ci.yml` when you want to:
- deploy one module
- deploy a specific environment manually
- re-run a module after fixing plan or apply issues

Inputs:
- `environment`
- `module_path`

This is the primary operator workflow today.

### Full dev deploy

Use `tf-auto-deploy-dev.yml` when you want to run the full set of currently eligible dev modules.

Current repo behavior:
- the `push` trigger is disabled
- the workflow is manual dispatch only right now

So despite the PRD goal of automatic dev deploy on merge, the live workflow must be started manually today.

### Drift detection

Use `tf-drift-detect.yml` when you want to:
- run the nightly drift job on schedule
- trigger drift detection manually

Current repo behavior:
- scheduled nightly at `00:00 UTC`
- also supports manual dispatch
- writes drift result JSON files to the state bucket audit prefix
- publishes SNS only when `SNS_ALERT_TOPIC_ARN` exists

---

## What success looks like

After a healthy setup:
- `ci.yml` can assume the Terraform execution role through OIDC without static credentials
- Terraform init succeeds using GitHub environment secrets
- plan artifacts are created and consumed by apply from the same run
- apply writes an audit JSON record under the state bucket audit prefix
- staging and prod runs pause at GitHub environment approval gates
- drift detection runs without hard dependency on PRD-03

---

## Common operator checks

Use these checks when a workflow fails early:

| Symptom | First check |
|---|---|
| OIDC or AWS auth failure | Confirm `TF_EXEC_ROLE_ARN` and `AWS_REGION` in the target GitHub environment |
| Backend init failure | Confirm `STATE_BUCKET`, `LOCK_TABLE`, `ENV_KMS_KEY_ARN`, and the GitHub environment's AWS region are correct for that environment |
| Module rejected before plan | Confirm the module is enabled in `environments/<env>/deployment-manifest.json` |
| Missing tfvars failure | Confirm the module's required environment tfvars file exists under `environments/<env>/` |
| No SNS drift alert | Confirm `SNS_ALERT_TOPIC_ARN` is set; otherwise drift falls back to log-only behavior |

---

## Break-glass note

PRD-01 is the normal path for downstream infrastructure changes. Do not bypass it for staging or prod unless you are handling a documented emergency and are prepared to capture the same change evidence manually.

Bootstrap remains a separate operator-managed flow under PRD-00 and is not deployed through PRD-01.

---

## Related Documents

- [DEPLOY-00-bootstrapping-guide.md](../DEPLOY-00-bootstrapping-guide.md)
- [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md)
- [plan-apply.md](../plan-apply-docs/plan-apply.md)
- [PRD-01-v1.1.0-github-actions-cicd-pipeline.md](../../PLANNING/PRD-01-v1.1.0-github-actions-cicd-pipeline.md)
