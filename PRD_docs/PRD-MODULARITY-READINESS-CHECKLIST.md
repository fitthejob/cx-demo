# PRD Modularity Readiness Checklist

---

**Document Type:** Governance Checklist  
**Version:** 1.0.0  
**Status:** Active  
**Applies To:** Any PRD not yet implemented in the repo  

---

## 1. Purpose

Use this checklist before a PRD is considered implementation-ready.

The goal is to keep the repo feature-rich without allowing optional layers, shared sinks, or stale conventions to harden into accidental complexity.

This checklist is the practical gate that sits between:

- [PREFACE.md](./PREFACE.md)
- [PLATFORM-MODULARITY-PROFILES.md](./PLATFORM-MODULARITY-PROFILES.md)
- [RB-00-02-modular-deployment-manifests.md](../connect-pbx/docs/runbooks/RB-00-02-modular-deployment-manifests.md)

---

## 2. Pass Criteria

A PRD is ready for implementation only when:

- its modularity classification is explicit
- its real hard dependencies are declared
- its catalog entry is known
- its shared sinks are modeled honestly
- its state and teardown posture are defined
- its sample Terraform and Lambda code match the repo's current conventions

If any of those are still unknown, the PRD should stay in planning.

---

## 3. Required Declarations

Every implementation-ready PRD must explicitly state:

- `Module Classification`
- `Minimum Deployment Profile`
- `Can Be Omitted From Bare-Bones`
- `Introduces New Hard Dependencies Into Lower Layers`
- `Optional Shared Sinks`
- `Destroy / Retention Posture`

Required `Catalog Entry` fields:

- `path`
- `capability_packs`
- `dependencies`
- `state_key`
- `workspace_scoped`
- `domain_tfvars`
- `supports_destroy`

---

## 4. Review Questions

### 4.1 Control Plane

- Is feature activation described through the module catalog and deployment manifest?
- Does the PRD avoid using `deployment_profile` as the authority for whether a module exists?
- If `deployment_profile` is present, is it limited to runtime shape such as scale, topology, or capacity?

### 4.2 Dependency Discipline

- Are all remote-state reads declared as hard dependencies?
- Does the module avoid reading remote state from optional-feature modules in lower layers?
- Are lower layers protected from backflow dependencies introduced by this PRD?

### 4.3 Shared Sinks

- Are alarm topics, audit buckets, and evidence exports modeled as optional inputs unless they are the module's primary activation condition?
- Does the PRD avoid hidden PRD-03 dependencies for basic deployability?

### 4.4 State And Backend Conventions

- Does the PRD use the repo's current partial backend pattern?
- Does it avoid hardcoded `dev/...` keys and stale `${terraform.workspace}/...` examples when the catalog-driven `state_key` model should be used?
- Are provider and Terraform version examples aligned with current repo conventions?

### 4.5 Module Boundary Quality

- Can the module be deployed and removed without editing another module's files?
- Does the runbook avoid manual `terraform state rm` as a steady-state ownership transfer mechanism?
- Is the module boundary operator-friendly and dashboard/catalog-friendly?

### 4.6 Event Contracts

- Are future or reserved event schemas clearly separated from implemented publishers?
- Do sample Lambdas satisfy the functional requirements they claim to implement?
- Are event consumers and event producers declared honestly, without implied contracts that do not yet exist?

### 4.7 Destroy And Retention

- Is `supports_destroy` appropriate and explicitly justified?
- If the module owns stateful data, is its retention strategy defined?
- If the module should not be destroyed casually, is that reflected in the PRD and planned catalog entry?

---

## 5. Red Flags

Stop and redesign before implementation if the PRD includes any of these:

- manual `terraform state rm` as a normal ownership handoff
- instructions to edit another module's source files to complete the module boundary
- hardcoded backend configuration or environment-specific state keys
- hidden dependency on PRD-03 just for alarm routing or optional audit export
- lower-layer dependence on optional-feature remote state
- universal outputs that the module does not truly own
- reserved schemas described as if they are already published
- sample code that does not actually implement the functional requirements

---

## 6. Outcome

Use one of these outcomes:

- `Green`: ready for implementation
- `Yellow`: implementation should wait for targeted doc or contract fixes
- `Red`: architectural redesign needed before implementation

Recommended minimum review output per PRD:

```text
PRD:
Outcome:
Classification:
Minimum Profile:
Hard Dependencies:
Optional Shared Sinks:
Catalog Entry Ready: yes/no
Destroy Posture:
Findings:
```

---

## 7. Initial Priority Targets

Apply this checklist first to:

1. PRD-20 through PRD-22
2. PRD-30 through PRD-32
3. PRD-40 through PRD-41
4. higher optional layers before implementation begins

These layers create the most technical debt if they drift away from the manifest/catalog model.
