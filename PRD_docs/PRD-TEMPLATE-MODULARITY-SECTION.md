# PRD Template Modularity Section

---

**Document Type:** PRD Template Section  
**Version:** 1.0.0  
**Status:** Active  
**Applies To:** New or substantially revised downstream PRDs  

---

## Usage

Copy this section into any PRD before it moves into implementation.

Do not treat this as optional guidance. In this repo, this section is mandatory for downstream PRDs because the module catalog and deployment manifests are the feature-activation control plane.

---

## Module Governance

### Module Classification

- `classification`: `core-required | optional-feature | migration-only | conditional-foundation`
- `minimum_deployment_profile`: `<bare-bones | standard | enterprise | migration-program | other explicit profile>`
- `can_be_omitted_from_bare_bones`: `yes | no`
- `introduces_new_hard_dependencies_into_lower_layers`: `yes | no`

If the last field is `yes`, the PRD requires architecture review before implementation.

### Catalog Entry

- `path`: `modules/<module-name>`
- `capability_packs`: `[ ... ]`
- `dependencies`: `[ ... ]`
- `state_key`: `<module-state-key>/terraform.tfstate`
- `workspace_scoped`: `true | false`
- `domain_tfvars`: `<file-name.tfvars | null>`
- `supports_destroy`: `true | false`

### Shared Sink Behavior

- `optional_shared_sinks`: list any shared sinks such as alarm topics, audit buckets, or evidence exports
- `sink_behavior`: state whether each sink is:
  - optional input
  - activation condition
  - true hard dependency

PRD-03 outputs must not become hidden universal dependencies just for convenience.

### Destroy / Retention Posture

- `destroy_posture`: `<destroyable | retained | protected | conditional>`
- `retention_notes`: describe any stateful data, manual retention boundaries, or operator expectations

### Control Plane Statement

Include this statement or an equivalent:

> This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

---

## Red Flags To Resolve Before Implementation

- backend examples hardcode environment names or stale state-key patterns
- remote-state reads are not mirrored as declared hard dependencies
- optional-feature modules become prerequisites for lower layers
- alarm routing or audit export silently requires PRD-03
- module ownership transfer requires manual `terraform state rm`
- another module's source files must be edited to complete the boundary
- sample code does not actually satisfy the functional requirements
