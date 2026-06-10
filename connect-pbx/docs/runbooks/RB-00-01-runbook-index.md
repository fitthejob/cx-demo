# RB-00-01 — Runbook Index & Operator Entry Points

**Runbook ID:** RB-00-01
**Scope:** Operator navigation
**Audience:** Platform Engineer, Release Engineer, Migration Lead, Operations Manager
**Last Updated:** 2026-03-30

---

## Overview

This runbook is the front door for the runbook set.

Use it to answer two questions quickly:

- which runbook is the primary procedure for the task in front of me
- which other runbooks are supporting references only

Design rule for this runbook set:

- one runbook should own the primary procedure for an operator task
- adjacent runbooks may summarize prerequisites or outcomes, but should point back to the primary runbook instead of repeating it

---

## Primary Runbooks By Task

| Task | Primary Runbook | Supporting References |
|---|---|---|
| Set up and operate GitHub Actions CI/CD | [RB-01-01-github-actions-cicd-setup-and-operations.md](RB-01-01-github-actions-cicd-setup-and-operations.md) | [DEPLOY-00-bootstrapping-guide.md](../DEPLOY-00-bootstrapping-guide.md), [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md) |
| Understand which modules are deployable in an environment | [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md) | PRD modularity docs in `PRD_docs/` |
| Claim a new Connect phone number | [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md) | [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md), [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md), [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md), [RB-11-07-e911-location-registration-compliance.md](RB-11-07-e911-location-registration-compliance.md) |
| Port a legacy number into Connect | [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md) | [RB-11-04-pre-loa-portability-verification.md](RB-11-04-pre-loa-portability-verification.md), [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md), [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md), [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md), [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md) |
| Verify portability before LOA | [RB-11-04-pre-loa-portability-verification.md](RB-11-04-pre-loa-portability-verification.md) | [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md) |
| Assess concurrent call requirements for quota increase | [RB-11-03-concurrent-call-capacity-assessment.md](RB-11-03-concurrent-call-capacity-assessment.md) | PRD-10 planning docs |
| Investigate spam reputation issues | [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md) | [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md), [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md) |
| Register or verify CNAM | [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md) | [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md), [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md) |
| Manage E911 location compliance | [RB-11-07-e911-location-registration-compliance.md](RB-11-07-e911-location-registration-compliance.md) | [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md) |
| Investigate routing drift | [RB-11-08-routing-drift-investigation-remediation.md](RB-11-08-routing-drift-investigation-remediation.md) | [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md), [RB-13-01-queue-management.md](RB-13-01-queue-management.md) |
| Activate or clear emergency closure | [RB-12-01-emergency-closure-procedure.md](RB-12-01-emergency-closure-procedure.md) | [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md) |
| Add or change queues and routing profiles | [RB-13-01-queue-management.md](RB-13-01-queue-management.md) | [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md) |
| Author or debug contact flows | [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md) | [RB-11-08-routing-drift-investigation-remediation.md](RB-11-08-routing-drift-investigation-remediation.md) |

---

## Usage Pattern

When operating the platform:

1. Start with the primary runbook for the task.
2. Use supporting runbooks only when the primary runbook tells you to branch out.
3. If two runbooks appear to own the same detailed procedure, treat that as documentation drift and fix the overlap.

---

## Editorial Guardrails

When adding or updating runbooks, preserve these rules:

1. A workflow runbook may summarize another procedure in one short gate or prerequisite section, but should not restate the specialist runbook step-by-step.
2. Specialist runbooks should own detailed commands, payloads, troubleshooting, and result interpretation for their domain.
3. Cross-links should point to the owning runbook for repeated procedures like portability verification, CNAM, E911, spam remediation, modular deployment, and contact flow debugging.
4. Keep orchestration runbooks focused on sequencing and decision points.
5. Keep module runbooks focused on execution detail for that module alone.

---

## Related Documents

- [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md)
