# SANDBOX-MEGA-TELCOGO

This repository currently centers on `connect-pbx/`, an infrastructure project for building and operating an Amazon Connect based PBX/contact-center platform with Terraform, manifest-driven module selection, operator runbooks, and a lightweight local deployment dashboard.

The goal is not just to provision AWS resources, but to give operators a repeatable way to bootstrap accounts, deploy environment-specific capabilities, validate module eligibility, and run day-to-day telephony operations with documentation close to the code.

## What this project includes

- Terraform modules for bootstrap, account baseline, audit pipeline, Amazon Connect, phone numbers, hours of operation, queues, contact flows, routing drift, CNAM, E911, spam reputation, and portability checks
- Environment-specific deployment manifests for `dev`, `staging`, and `prod`
- A manifest helper that validates module metadata and resolves which modules are eligible for plan, apply, audit, and destroy actions
- Shell scripts for Terraform execution, audit reporting, teardown, redeploy, and GitHub Actions secret synchronization
- Operator runbooks for provisioning, migration, routing, phone number operations, emergency closure, and queue/contact-flow management
- A local Python dashboard that wraps the repo's existing deployment contracts instead of introducing a second deployment engine

## Repository layout

```text
.
|-- README.md
`-- connect-pbx/
    |-- dashboard/                  Local deployment dashboard
    |-- docs/                       Deployment guides and runbooks
    |-- environments/               Per-environment manifests and tfvars
    |-- modules/                    Terraform modules by layer/domain
    `-- scripts/                    Terraform runners and helper utilities
```

## Architecture at a glance

The deployment model is catalog and manifest driven:

- `connect-pbx/modules/dependency-order.json` defines module ordering and deployment layers
- `connect-pbx/environments/<env>/deployment-manifest.json` selects capability packs and enabled modules per environment
- `connect-pbx/scripts/module_manifest.py` validates those inputs and resolves eligible modules
- `connect-pbx/scripts/tf-run.sh` is the main operator entry point for `plan`, `apply`, and `destroy`

Current environments in the repo:

- `dev`
- `staging`
- `prod`

Current layer groups in the catalog:

- Layer 0: bootstrap, account baseline, audit pipeline
- Layer 1: connect instance, phone numbers, hours of operation, queue architecture, contact flow framework

## Prerequisites

You will typically want the following installed before working in this repo:

- Terraform `1.14.7` or compatible
- Python 3
- AWS CLI configured for the target account
- Git Bash on Windows for running the repo's `.sh` helper scripts
- GitHub CLI (`gh`) if you plan to sync GitHub Actions environment secrets

You should also know which AWS account and environment you are targeting before you run anything. The bootstrap and deployment scripts assume your active AWS credentials are already correct.

## Getting started

### 1. Start with the bootstrap guide

The first critical document is [connect-pbx/docs/DEPLOY-00-bootstrapping-guide.md](connect-pbx/docs/DEPLOY-00-bootstrapping-guide.md). It covers the one-time creation of the Terraform remote state backend, DynamoDB locking, KMS encryption, and GitHub OIDC roles.

### 2. Review the runbook index

Use [connect-pbx/docs/runbooks/RB-00-01-runbook-index.md](connect-pbx/docs/runbooks/RB-00-01-runbook-index.md) as the front door for operator procedures. It points to the owning runbook for each operational task.

### 3. Validate the module catalog and an environment manifest

From the repo root:

```bash
cd connect-pbx
python scripts/module_manifest.py validate-catalog --catalog modules/dependency-order.json
python scripts/module_manifest.py validate --catalog modules/dependency-order.json --manifest environments/dev/deployment-manifest.json
```

### 4. Run Terraform through the repo wrapper

The main interactive runner is:

```bash
cd connect-pbx
./scripts/tf-run.sh
```

You can also provide arguments directly:

```bash
./scripts/tf-run.sh plan dev modules/l1-connect-instance
./scripts/tf-run.sh apply dev modules/l1-phone-numbers
```

### 5. Use the local dashboard if you want a guided deployment view

From `connect-pbx/`:

```bash
python dashboard/app.py
```

Then open `http://127.0.0.1:8765`.

The dashboard shows manifest-enabled modules, adds required dependencies automatically, previews execution order, and runs the existing shell-based workflow under the hood.

## Common workflows

### Plan or apply infrastructure

Use `connect-pbx/scripts/tf-run.sh` for routine Terraform execution. It validates the manifest, confirms the selected environment and module, and uses environment tfvars plus backend configuration derived from bootstrap artifacts.

### Produce a read-only Terraform audit report

```bash
cd connect-pbx
./scripts/tf-plan-audit.sh dev
```

This generates a markdown report under `connect-pbx/reports/plan-audits/` and runs `terraform plan` in read-only audit mode.

### Sync GitHub Actions environment secrets

After bootstrap or baseline deployment, the repo includes helpers to populate GitHub environment secrets:

- `connect-pbx/scripts/sync-github-bootstrap-secrets.sh`
- `connect-pbx/scripts/sync-github-env-secrets.sh`
- `connect-pbx/scripts/sync-github-audit-secrets.sh`

See the CI/CD runbook for exact expectations: [connect-pbx/docs/runbooks/RB-01-01-github-actions-cicd-setup-and-operations.md](connect-pbx/docs/runbooks/RB-01-01-github-actions-cicd-setup-and-operations.md).

## Documentation map

- Bootstrap: [connect-pbx/docs/DEPLOY-00-bootstrapping-guide.md](connect-pbx/docs/DEPLOY-00-bootstrapping-guide.md)
- Runbook index: [connect-pbx/docs/runbooks/RB-00-01-runbook-index.md](connect-pbx/docs/runbooks/RB-00-01-runbook-index.md)
- Modular deployment manifests: [connect-pbx/docs/runbooks/RB-00-02-modular-deployment-manifests.md](connect-pbx/docs/runbooks/RB-00-02-modular-deployment-manifests.md)
- GitHub Actions setup and operations: [connect-pbx/docs/runbooks/RB-01-01-github-actions-cicd-setup-and-operations.md](connect-pbx/docs/runbooks/RB-01-01-github-actions-cicd-setup-and-operations.md)
- Dashboard notes: [connect-pbx/dashboard/README.md](connect-pbx/dashboard/README.md)

## Notes

- This repo is designed around controlled, auditable infrastructure changes rather than ad hoc local Terraform usage.
- The bootstrap layer is a one-time prerequisite for downstream environments.
- The primary project content lives in `connect-pbx/`, so contributors should generally start there.
