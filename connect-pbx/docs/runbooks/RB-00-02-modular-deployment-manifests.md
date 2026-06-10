# RB-00-02 — Modular Deployment Manifests & Module Catalog

**Runbook ID:** RB-00-02
**Scope:** Repo-wide deployment model
**Audience:** Platform Engineer, Terraform Operator, Release Engineer
**Last Updated:** 2026-04-05

---

## Overview

This runbook describes how the repo selects which Terraform modules are active in a given environment.

Use this runbook when you need to:

- understand which modules are considered deployable in an environment
- add a new module to the repo-operational catalog
- enable or disable optional modules for an environment
- run plan/apply/audit using the current modular deployment model
- prepare for future operator-driven deployment selection

This runbook is the operational companion to:

- [PRD-MODULARITY-READINESS-CHECKLIST.md](../../../PRD_docs/PRD-MODULARITY-READINESS-CHECKLIST.md)
- [PRD-TEMPLATE-MODULARITY-SECTION.md](../../../PRD_docs/PRD-TEMPLATE-MODULARITY-SECTION.md)

---

## Source Of Truth

The repo now uses two machine-readable files as deployment truth:

- module catalog:
  [connect-pbx/modules/dependency-order.json](../../modules/dependency-order.json)
- per-environment deployment manifest:
  [connect-pbx/environments/dev/deployment-manifest.json](../../environments/dev/deployment-manifest.json)
  [connect-pbx/environments/staging/deployment-manifest.json](../../environments/staging/deployment-manifest.json)
  [connect-pbx/environments/prod/deployment-manifest.json](../../environments/prod/deployment-manifest.json)

Helper script:

- [connect-pbx/scripts/module_manifest.py](../../scripts/module_manifest.py)

Operational runners that consume these files:

- [connect-pbx/scripts/tf-run.sh](../../scripts/tf-run.sh)
- [connect-pbx/scripts/tf-plan-audit.sh](../../scripts/tf-plan-audit.sh)
- [connect-pbx/scripts/tf-teardown.sh](../../scripts/tf-teardown.sh)
- [connect-pbx/scripts/tf-redeploy.sh](../../scripts/tf-redeploy.sh)

CI workflows that consume these files:

- [ci.yml](../../.github/workflows/ci.yml)
- [tf-plan.yml](../../.github/workflows/tf-plan.yml)
- [tf-apply.yml](../../.github/workflows/tf-apply.yml)
- [tf-drift-detect.yml](../../.github/workflows/tf-drift-detect.yml)

Important authority rule:

- the module catalog and environment deployment manifest are the only feature-activation authority in the repo
- `deployment_profile` and tfvars provide runtime shape and configuration, but do not decide whether a module is enabled

---

## Core Concepts

### 1. Module Catalog

The module catalog defines repo-level facts about each Terraform module:

- module path
- PRD
- layer
- classification
- capability packs
- hard dependencies
- state key
- domain tfvars file
- whether it is workspace scoped
- whether it is marked destroyable

The current catalog is intentionally conservative. Standard destroy remains limited to modules marked `supports_destroy = true`. PRD-10 and PRD-11 now use an operator-gated destroy path: they stay retained by default, but the dashboard can promote them into a destroy run after explicit approval.

### 2. Deployment Manifest

Each environment has a deployment manifest that decides which modules are enabled in that environment.

Current fields:

- `deployment_profile_name`
- `enabled_capability_packs`
- `enabled_modules`
- `disabled_modules`

The manifest does not replace normal tfvars. It controls module eligibility, while tfvars still provide module configuration.

Profile naming rule:

- `deployment_profile_name` should describe the environment's actual operating posture
- if only `core-telephony` is enabled, names like `bare-bones-telephony` are appropriate
- if `audit-operations` is enabled, include that explicitly in the profile name
- if migration capabilities are enabled, use a name that reflects that, such as `migration-program`
- do not leave a baseline profile name in place after enabling additional capability packs

### 3. Capability Packs

A capability pack is a logical bundle of modules.

Current examples:

- `core-telephony`
- `audit-operations`
- `migration`

In future, examples may include:

- `eventing`
- `voicemail`
- `crm`
- `compliance`

Capability packs are the preferred operator-facing way to enable additive features. Direct `enabled_modules` entries should be used only when a module is intentionally outside a broader pack or while a new pack is being introduced.

Important:

- `core-telephony` should represent the minimum telephony baseline only
- `audit-operations` is the opt-in pack for PRD-03 and similar shared audit or alarm foundations
- environments that already run audit services should enable `audit-operations` explicitly rather than relying on `core-telephony` to include them

### 4. Eligibility

A module is eligible for plan/apply/audit only if:

- it is enabled by the manifest
- all catalog-declared dependencies are also enabled
- the action allows it

For direct `tf-run.sh` destroy operations, the module must also be marked:

- `supports_destroy = true`

Dashboard exception:

- `modules/bootstrap` can now appear as a manual final destroy step inside the Platform Foundation rollup
- it is still not sent to `tf-run.sh destroy`
- the dashboard destroys other selected modules first, then hands bootstrap off to the documented local-state teardown procedure

---

## Standard Operator Workflow

### Step 1 — Validate the manifest

From repo root:

```bash
python connect-pbx/scripts/module_manifest.py validate \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json
```

Expected result:

```text
Validated manifest: connect-pbx/environments/dev/deployment-manifest.json
Enabled modules: <count>
```

### Step 2 — List enabled modules for an action

Example for plan:

```bash
python connect-pbx/scripts/module_manifest.py eligible-modules \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json \
  --action plan
```

Example for destroy:

```bash
python connect-pbx/scripts/module_manifest.py eligible-modules \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json \
  --action destroy
```

Important:

- `destroy` returns only modules explicitly marked destroyable in the catalog
- core modules should not be marked destroyable casually

### Step 3 — Run Terraform through the local runner

Examples:

```bash
connect-pbx/scripts/tf-run.sh plan dev modules/l1-contact-flow-framework
```

```bash
connect-pbx/scripts/tf-run.sh apply dev modules/l1-contact-flow-framework
```

The runner now:

- validates the environment manifest
- checks module eligibility
- derives state key from the catalog
- derives domain tfvars from the catalog
- derives workspace behavior from the catalog

### Step 4 — Run read-only plan audit

```bash
connect-pbx/scripts/tf-plan-audit.sh dev
```

The audit runner now resolves modules from the deployment manifest rather than assuming every catalog module is always active in every environment.

---

## How To Enable A New Optional Module

When a future optional module is added, use this sequence.

### 1. Add the module to the catalog

Update:

- [connect-pbx/modules/dependency-order.json](../../modules/dependency-order.json)

At minimum include:

- `path`
- `prd`
- `layer`
- `classification`
- `capability_packs`
- `dependencies`
- `state_key`
- `domain_tfvars`
- `workspace_scoped`
- `supports_destroy`

Do not implement a new module before these fields are known. If a PRD cannot declare its catalog entry yet, it is not implementation-ready for this repo model.

### 2. Add environment configuration if needed

If the module has environment-specific settings, add a domain tfvars file under:

- `connect-pbx/environments/dev/`
- `connect-pbx/environments/staging/`
- `connect-pbx/environments/prod/`

Examples:

- `portability.tfvars`
- `eventing.tfvars`
- `voicemail.tfvars`

### 3. Enable the module in the deployment manifest

Either:

- add its capability pack to `enabled_capability_packs`
- or add the module path directly to `enabled_modules`

### 4. Validate and deploy

Run:

```bash
python connect-pbx/scripts/module_manifest.py validate \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json
```

Then use:

```bash
connect-pbx/scripts/tf-run.sh plan dev <module-path>
connect-pbx/scripts/tf-run.sh apply dev <module-path>
```

---

## How To Disable A Module

Only disable modules that are truly optional and operationally safe to omit.

Use one of these methods:

- remove the relevant capability pack from `enabled_capability_packs`
- add the module path to `disabled_modules`

After editing the manifest:

```bash
python connect-pbx/scripts/module_manifest.py validate \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json
```

Validation will fail if:

- the module is unknown
- a dependency is missing
- a core-required module is disabled

Disabling a module in the manifest does not itself destroy live infrastructure. It only removes that module from normal plan/apply/audit selection.

---

## How To Prepare A Module For Safe Teardown

Do not mark a module destroyable until all of the following are true:

- it is classified as optional or otherwise safe to remove
- it owns its own state
- it does not mutate core resources in irreversible ways
- its dependencies are clear
- its teardown does not orphan shared contracts unexpectedly

When ready:

1. set `supports_destroy` to `true` in the catalog
2. validate that the deployment manifest still resolves correctly
3. test destroy only in a non-production environment first

Destroy command pattern:

```bash
connect-pbx/scripts/tf-run.sh destroy dev <module-path>
```

Current note:

- `modules/l0-audit-pipeline` and `modules/l0-account-baseline` are marked `supports_destroy = true`
- `modules/bootstrap` remains intentionally outside `tf-run.sh destroy` because it owns the active backend
- `modules/l1-connect-instance` and `modules/l1-phone-numbers` remain retained by default, but they can be destroyed only through an explicitly approved operator destroy path that lifts the Terraform lifecycle guard for that run
- the teardown runner computes destroyable targets from the catalog plus a retention mode

## Teardown Modes

The repo now includes:

- [connect-pbx/scripts/tf-teardown.sh](../../scripts/tf-teardown.sh)
- [connect-pbx/scripts/tf-redeploy.sh](../../scripts/tf-redeploy.sh)

This runner supports teardown planning and execution using explicit retention modes.

Current modes:

- `retain-stateful`
- `retain-core`
- `destroy-all`

### Mode Semantics

#### `retain-stateful`

Retains:

- `modules/bootstrap`
- `modules/l0-account-baseline`
- `modules/l0-audit-pipeline`
- `modules/l1-connect-instance`
- `modules/l1-phone-numbers`

Use this mode when you want to park most higher-level infrastructure but intentionally keep:

- backend/state foundations
- account KMS and IAM foundations
- audit bucket/foundation
- Connect instance
- retained phone numbers

Compliance note:

- `retain-stateful` keeps AWS Config and Security Hub because it retains `modules/l0-audit-pipeline`

This is the safest teardown profile for environments that may be resumed later.

#### `retain-core`

Retains:

- `modules/bootstrap`
- `modules/l0-account-baseline`
- `modules/l1-connect-instance`
- `modules/l1-phone-numbers`

Use this mode when you want to destroy optional modules and audit infrastructure but keep the minimal telephony core and retained numbers.

Compliance note:

- `retain-core` destroys AWS Config and Security Hub because `modules/l0-audit-pipeline` becomes a destroy target

#### `destroy-all`

Targets every enabled module in the environment manifest.

Important:

- this is a planning/guardrail mode, not a promise that every module can be auto-destroyed today
- modules not marked `supports_destroy = true` are reported as blockers
- `modules/bootstrap` is always reported as a special blocker in automation today because it owns the remote backend
- `modules/l0-account-baseline` can now be included as a destroy target when no deployed higher-layer modules still depend on it
- `modules/l1-connect-instance` and `modules/l1-phone-numbers` remain retained by default inside pack destroy and teardown planning unless an operator explicitly chooses the gated destroy path

Compliance note:

- `destroy-all` destroys AWS Config and Security Hub because `modules/l0-audit-pipeline` becomes a destroy target

### Standard Teardown Planning Flow

Dry-run report:

```bash
connect-pbx/scripts/tf-teardown.sh --mode retain-stateful --env dev
```

Execute a retained-profile teardown:

```bash
connect-pbx/scripts/tf-teardown.sh --mode retain-stateful --env dev --execute
```

Plan a full teardown and inspect blockers:

```bash
connect-pbx/scripts/tf-teardown.sh --mode destroy-all --env dev
```

### Standard Redeploy Planning Flow

Dry-run report:

```bash
connect-pbx/scripts/tf-redeploy.sh --mode retain-core --env dev
```

Execute a redeploy for the modules previously destroyed by a retained teardown:

```bash
connect-pbx/scripts/tf-redeploy.sh --mode retain-core --env dev --execute
```

Important:

- `tf-redeploy.sh` mirrors the retention modes from `tf-teardown.sh`
- redeploy runs in forward dependency order
- `retain-core` redeploy re-applies `modules/l0-audit-pipeline`, so AWS Config and Security Hub are restored as part of that redeploy path
- bootstrap recovery is not automated in `tf-redeploy.sh`; backend/bootstrap recreation remains a separate procedure

### Current Guardrails

1. Phone numbers and the Connect instance are retained by default.
   PRD-10 and PRD-11 still use lifecycle guards during normal operation. The dashboard may include them only after explicit operator approval, and only for that approved destroy run.

2. Bootstrap is not auto-destroyed by the teardown runner.
   Bootstrap owns the remote backend, so destroying it safely requires a separate local-state procedure rather than the standard `tf-run.sh` path.

3. Retention should be module-based, not resource-based.
   If you want to keep keys, buckets, numbers, or the Connect instance, retain the modules that own them.

4. `destroy-all` is intentionally conservative.
   It reports blockers rather than trying to bypass safeguards.

### Dashboard Destroy Behavior For Platform Foundation

When the dashboard is in destroy mode, the `Platform Foundation` rollup now exposes these components independently:

- `PRD-03 audit add-on`
- `PRD-02 account baseline`
- `PRD-00 bootstrap backend`

Rules:

- the dashboard may destroy `PRD-03` and `PRD-02` through the normal runner when they are selected and safe
- reverse-dependent checks still apply across the full environment, not just inside the rollup
- if `PRD-00 bootstrap backend` is selected, the dashboard computes it as the final step but does not run `tf-run.sh destroy` against bootstrap
- after all dashboard-executable modules finish, the operator must complete bootstrap teardown manually using [DEPLOY-00-bootstrapping-guide.md Scenario E](../DEPLOY-00-bootstrapping-guide.md)

Example:

- selecting only `PRD-03` destroys the audit pipeline
- selecting `PRD-02` auto-includes deployed destroyable reverse dependents such as `PRD-03`
- selecting `PRD-00` causes the dashboard to preview higher dependent teardown first and then warn that bootstrap is a manual final handoff

## Current Service Impact By Mode

The following notes summarize the current Terraform-managed ownership model for key shared services.

### DynamoDB

#### `retain-stateful`

Keeps:

- no bootstrap-owned DynamoDB backend lock resource; bootstrap retains the S3 backend and its lockfile objects

Destroys:

- module-local DynamoDB tables owned by destroyed modules, such as PRD-15 through PRD-19 optional or migration tables

#### `retain-core`

Keeps:

- no bootstrap-owned DynamoDB backend lock resource; bootstrap retains the S3 backend and its lockfile objects

Destroys:

- module-local DynamoDB tables owned by destroyed modules
- any audit-pipeline-managed DynamoDB resources if added later

#### `destroy-all`

Targets:

- all Terraform-managed DynamoDB tables owned by enabled modules; bootstrap backend locking is no longer DynamoDB-based

Important:

- bootstrap remains a manual blocker in automation today, so full removal of backend bucket contents and stale lockfile objects still requires the separate bootstrap-destroy path

### CloudWatch Logs And Alarms

#### `retain-stateful`

Keeps:

- CloudWatch log groups and alarms owned by retained modules
- this includes the audit pipeline and Connect-instance-owned logging/alarm resources

Destroys:

- CloudWatch log groups and alarms owned by destroyed optional and higher-layer modules

#### `retain-core`

Keeps:

- CloudWatch log groups and alarms owned by retained core modules such as `modules/l1-connect-instance`

Destroys:

- audit-pipeline-owned CloudWatch logs and alarms
- optional-module CloudWatch logs and alarms

#### `destroy-all`

Targets:

- all Terraform-managed CloudWatch log groups and CloudWatch alarms

Important:

- as with other services, `destroy-all` still reports blockers rather than bypassing protected modules such as bootstrap and phone-number ownership boundaries

---

## CI Behavior

Reusable plan/apply workflows now validate the module against the environment deployment manifest before running.

That means CI will reject:

- a module not enabled in the target environment
- a manifest with broken dependencies
- a module whose catalog metadata does not match the requested action

Drift detection also uses the deployment manifest and records whether a module is enabled in that environment.

---

## Troubleshooting

### Manifest validation fails

Common causes:

- unknown capability pack
- unknown module path
- enabled module depends on a disabled dependency
- attempt to disable a core-required module
- capability-pack membership no longer reflects the intended deployability boundary

Use:

```bash
python connect-pbx/scripts/module_manifest.py validate \
  --catalog connect-pbx/modules/dependency-order.json \
  --manifest connect-pbx/environments/dev/deployment-manifest.json
```

### Runner says module is not enabled

Check:

- the environment manifest
- capability pack membership in the catalog
- whether the module was explicitly disabled

### Domain tfvars are missing

If the catalog declares `domain_tfvars`, that file must exist under the environment directory.

Examples:

- `phone-numbers.tfvars`
- `hours.tfvars`
- `queues.tfvars`
- `contact-flows.tfvars`

### Destroy returns no eligible modules

This usually means no enabled modules are marked:

- `supports_destroy = true`

That is expected today for the currently implemented core modules.

---

## Guardrails To Preserve

1. Core modules must not depend on optional or migration-only modules.
2. `core-telephony` must remain deployable without `audit-operations`.
3. Optional modules must remain additive.
4. State remains per module, not shared across unrelated capability packs.
5. Environment manifests decide eligibility; tfvars decide configuration.
6. A module should not be marked destroyable until teardown semantics are understood and tested.
7. Lower layers must not depend on optional-feature remote state.
8. Shared alarm and audit sinks should be optional inputs unless they are the module's primary activation condition.
9. Manual state surgery is not an acceptable steady-state inter-module contract.

---

## Authoring Gate For New PRDs

Before a new PRD moves into implementation, complete the checklist in:

- [PRD-MODULARITY-READINESS-CHECKLIST.md](../../../PRD_docs/PRD-MODULARITY-READINESS-CHECKLIST.md)
- [PRD-TEMPLATE-MODULARITY-SECTION.md](../../../PRD_docs/PRD-TEMPLATE-MODULARITY-SECTION.md)

At minimum, the PRD should already declare:

- module classification
- minimum deployment profile
- whether bare-bones can omit it
- whether it introduces lower-layer hard dependencies
- full catalog entry fields
- optional sink behavior
- destroy / retention posture

This gate is mandatory for downstream PRDs before implementation starts.

---

## Related Documents

- [PRD-15-v1.0.0-number-portability-verification.md](../../../PRD_docs/PRD-15-v1.0.0-number-portability-verification.md)
- [PRD-90-v1.0.0-migration-state.md](../../../PRD_docs/PRD-90-v1.0.0-migration-state.md)
- [PRD-91-v1.0.0-cutover-operations.md](../../../PRD_docs/PRD-91-v1.0.0-cutover-operations.md)
