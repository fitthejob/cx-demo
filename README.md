# CONNECT PBX - RAPID CONTACT CENTER DEPLOYMENT

This repository currently centers on `connect-pbx/`, an infrastructure project for building and operating an Amazon Connect based PBX/contact-center platform with Terraform, manifest-driven module selection, operator runbooks, and a lightweight local deployment dashboard.

The goal is not just to provision AWS resources, but to give operators a fast, repeatable way to bootstrap accounts, deploy environment-specific capabilities, validate module eligibility, and run day-to-day telephony operations with documentation close to the code.

## Why this repo exists

The focus of this project is to show how it is possible to achieve standard, rapidly deployable Connect implementations that are operable, governable, and extensible across environments.

The repo models a modular Connect platform with:

- Account bootstrap and backend design
- Environment-aware deployment control
- Capability-pack driven module selection
- Dependency-aware rollout sequencing
- GitHub OIDC based CI/CD
- Drift detection and operator-facing runbooks

## What this project includes

- Terraform modules for bootstrap, account baseline, audit pipeline, Amazon Connect, phone numbers, hours of operation, queues, contact flows, routing drift, CNAM, E911, spam reputation, and portability checks
- A local web-based dashboard that wraps the repo's existing deployment contracts
- Environment-specific deployment manifests for `dev`, `staging`, and `prod`
- Shell scripts for Terraform execution, audit reporting, teardown, redeploy, and GitHub Actions secret synchronization
- Operator runbooks for provisioning, migration, routing, phone number operations, emergency closure, and queue/contact-flow management

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

Current layer groups avaiable in the dashboard:

- Layer 0: bootstrap, account baseline, audit pipeline
- Layer 1: connect instance, phone numbers, hours of operation, queue architecture, contact flow framework

High-level platform flow:

1. Bootstrap creates the Terraform backend, KMS, and GitHub OIDC trust.
2. Account baseline establishes the shared account foundation and environment KMS posture.
3. Core telephony modules build the Connect instance, numbers, hours, queues, and contact flows in dependency order.
4. Optional governance and migration modules layer on top without becoming accidental hard prerequisites.
5. The local dashboard and GitHub Actions workflows both drive the same underlying Terraform contracts rather than introducing parallel deployment engines.

## What this demonstrates

This repo is strongest as evidence of:

- Amazon Connect solution design across instance, routing, queue, hours, number, and contact-flow domains
- CI/CD and identity design using GitHub OIDC instead of long-lived AWS credentials
- Observability design using CloudWatch log groups, metric filters, metric alarms, EventBridge schedules, SNS alerting, and audit evidence capture through the shared audit pipeline
- Terraform modularization with explicit dependency management and environment manifests
- Lambda-backed operational automation for contact-flow association, closure checks, holiday evaluation, routing drift, and audit/alarm handling
- Operational design for safe rollout sequencing, re-apply behavior, destroy gating, and drift review
- Balancing platform standardization with optional layers such as audit operations, migration support, and number-governance modules
- Working through real platform constraints such as Connect quota blockers, backend locking changes, IAM hardening, and operator UX clarity

## Design decisions

Some of the most important design choices in this repo are:

- Manifest-driven module selection instead of ad hoc Terraform targeting, so environment intent is explicit and reviewable
- Capability packs and dependency metadata instead of a flat module list, so optional layers do not become accidental prerequisites
- GitHub OIDC instead of long-lived AWS credentials, so CI/CD access is short-lived and tied to repo and environment trust
- A local dashboard that wraps the existing Terraform runner instead of introducing a second deployment engine, so operator UX improves without splitting the source of truth
- Shared audit and drift patterns that feed CloudWatch, SNS, S3 evidence, and scheduled checks, so observability is treated as part of the platform design rather than an afterthought

## Challenges addressed

This repo also reflects several real implementation and operations challenges:

- Amazon Connect phone-number quota constraints that forced safer optionality and sequencing decisions
- The need to keep downstream telephony modules modular when core number provisioning is temporarily constrained
- Migration from deprecated DynamoDB state locking to native S3 lockfiles without breaking active operator workflows
- Hardening the GitHub execution role so drift detection can read managed resources across Connect, Lambda, CloudWatch, DynamoDB, EventBridge, SSM, and S3
- Making the deployment dashboard intuitive for both first-time deploys and re-apply/update workflows without overloading the UI

## Current state

This is currently a `dev`-first implementation and active working platform blueprint.

A few important realities:

- The repo is being exercised primarily against `dev` right now rather than a polished multi-environment production rollout
- Some modules are intentionally optional or migration-specific
- Drift detection and GitHub execution-role IAM coverage are being actively hardened
- Phone-number provisioning has been shaped by real Amazon Connect quota limitations, which influenced how optionality and deployment sequencing are handled

## Planned future buildout

The tracked repo focuses on the modular platform foundation and current implementation layers, but the broader design roadmap is more extensive than what is checked in here today.

Future buildout is documented in a larger PRD set covering areas such as:

- Scale and resilience patterns
- Multi-account topology
- Optional SSO and CRM integration layers
- Richer storage and data architecture
- Lambda deployment baseline and versioning strategy
- Agent management and CCP configuration
- Voicemail, transcription, and notification services
- Lex V2 and conversational routing layers
- Deeper observability, alerting, and FinOps coverage
- Migration and consolidation workflows

To keep the main repo surface readable and focused on the active implementation, those broader planning PRDs are intentionally maintained outside the tracked project contents and are gitignored from this public repo snapshot.

Additional architecture and roadmap materials can be shared separately during solution review conversations when deeper planning context would be helpful.

## Representative scenarios

Examples of the kinds of workflows this repo is built to support:

- Bootstrap a new AWS account with a remote Terraform backend, KMS, and GitHub OIDC trust
- Deploy core telephony capabilities into `dev` with dependency-aware rollout sequencing
- Re-apply updated Connect routing, queue, or contact-flow logic from the local dashboard without changing the deployment engine
- Run drift detection and route findings into the shared audit pipeline for review and alerting
- Add optional governance layers such as routing drift, spam reputation, CNAM, or E911 without collapsing them into mandatory base infrastructure

## How to review this repo

To review this repo, start here:

1. `connect-pbx/modules/dependency-order.json` for the capability-pack and dependency model
2. `connect-pbx/dashboard/` for the operator-facing deployment workflow and wave-based preview
3. `connect-pbx/modules/bootstrap/` for backend, OIDC, and execution-role design
4. Representative domain modules such as:
   - `connect-pbx/modules/l1-connect-instance/`
   - `connect-pbx/modules/l1-phone-numbers/`
   - `connect-pbx/modules/l1-contact-flow-framework/`
5. `connect-pbx/docs/runbooks/` for the operational model and implementation guidance

## What is intentionally not here

This repo is intentionally not presented as:

- A finished SaaS product or polished commercial offering
- A complete implementation of every PRD in the broader planning set
- A devops-only exercise with no architecture intent behind it

Instead, it is meant to be a reviewable implementation blueprint that shows how I think about Amazon Connect platform architecture, AWS integration, operational safety, and phased capability buildout.

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

The first critical document is [connect-pbx/docs/DEPLOY-00-bootstrapping-guide.md](connect-pbx/docs/DEPLOY-00-bootstrapping-guide.md). It covers the one-time creation of the Terraform remote state backend, S3 lockfile-based state locking, KMS encryption, and GitHub OIDC roles.

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
