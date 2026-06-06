# Operator Bible Outline

**Purpose:** future compiled operator handbook structure  
**Source spine:** [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)  
**Last Updated:** 2026-03-30

---

## Goal

This outline is the future table of contents for a compiled operator handbook.

It is intentionally built from the primary-runbook ownership model in `RB-00-01` so the final handbook stays:

- navigable
- non-duplicative
- operationally sane
- suitable for both day-to-day operations and incident use

---

## Part I — Operating Model

1. Platform overview and deployment profiles
2. Module eligibility and environment manifests
3. Operator roles and change boundaries
4. Standard deployment workflow

Primary source:

- [RB-00-02-modular-deployment-manifests.md](RB-00-02-modular-deployment-manifests.md)

---

## Part II — Number Lifecycle Operations

1. Claiming new Connect numbers
2. Publishing readiness checks
3. Removing temporary or obsolete numbers
4. Post-provisioning hygiene

Primary source:

- [RB-11-01-adding-new-phone-numbers.md](RB-11-01-adding-new-phone-numbers.md)

Supporting appendices:

- [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md)
- [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md)
- [RB-11-07-e911-location-registration-compliance.md](RB-11-07-e911-location-registration-compliance.md)

---

## Part III — Migration & Porting

1. Pre-LOA portability verification
2. Porting preparation
3. FOC-day cutover
4. Post-cutover import and stabilization
5. Migration rollback model

Primary sources:

- [RB-11-04-pre-loa-portability-verification.md](RB-11-04-pre-loa-portability-verification.md)
- [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md)

---

## Part IV — Capacity, Reputation, and Compliance

1. Concurrent call capacity planning
2. Spam reputation remediation
3. CNAM registration and verification
4. E911 compliance lifecycle

Primary sources:

- [RB-11-03-concurrent-call-capacity-assessment.md](RB-11-03-concurrent-call-capacity-assessment.md)
- [RB-11-05-spam-reputation-check-remediation.md](RB-11-05-spam-reputation-check-remediation.md)
- [RB-11-06-cnam-registration-verification.md](RB-11-06-cnam-registration-verification.md)
- [RB-11-07-e911-location-registration-compliance.md](RB-11-07-e911-location-registration-compliance.md)

---

## Part V — Telephony Control Plane

1. Emergency closure operations
2. Queue and routing profile management
3. Contact flow authoring and debugging
4. Routing drift investigation

Primary sources:

- [RB-12-01-emergency-closure-procedure.md](RB-12-01-emergency-closure-procedure.md)
- [RB-13-01-queue-management.md](RB-13-01-queue-management.md)
- [RB-14-01-programming-contact-flows.md](RB-14-01-programming-contact-flows.md)
- [RB-11-08-routing-drift-investigation-remediation.md](RB-11-08-routing-drift-investigation-remediation.md)

---

## Editorial Rules For The Future Compiled Handbook

1. Each chapter should map to one primary runbook owner.
2. Supporting runbooks should be referenced, not inlined wholesale.
3. Repeated commands should live in the specialist runbook, not every workflow chapter.
4. Workflow chapters should explain sequence, gates, and decision points.
5. Specialist chapters should explain execution details, payloads, and troubleshooting.
6. Any new runbook added to the set should first be classified in [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md).
