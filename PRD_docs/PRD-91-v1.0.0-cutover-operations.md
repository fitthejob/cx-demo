# PRD-91 — Cutover Operations

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-91 |
| **Version** | 1.3.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-08 |
| **Layer** | 9 — Migration & Consolidation |
| **Module Classification** | migration-only |
| **Minimum Deployment Profile** | migration-program |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-11 (Phone Number Management), PRD-14 (Contact Flow Framework), PRD-90 (Migration State) |
| **Blocks** | None |
| **Optional Shared Sinks** | Optional `alarm_action_arns` only |
| **Destroy / Retention Posture** | destroyable / PRD-91 owns stateless operator handlers; rollback and migration records remain retained under PRD-90 ownership |
| **Optional** | Yes — migration-only capability pack |

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable migration-only modules.

### Module Classification

- `classification`: `migration-only`
- `minimum_deployment_profile`: `migration-program`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l9-cutover-operations`
- `capability_packs`: `["migration"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-phone-numbers", "modules/l1-contact-flow-framework", "modules/l9-migration-state"]`
- `state_key`: `l9-cutover-operations/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `cutover-operations.tfvars`
- `supports_destroy`: `true`
- `activation`: manifest-selected `migration` capability pack or a direct `enabled_modules` entry for an intentional migration program

### Shared Sink Behavior

- `optional_shared_sinks`: `alarm_action_arns`
- `sink_behavior`: basic Lambda error alarms may attach shared action ARNs when provided, but empty actions remain valid and do not create a hard dependency on PRD-03, Layer 8 alert transport, or any other shared sink module.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: PRD-91 owns stateless operator handlers, log groups, and alarms. Migration-unit rollback snapshots and cutover outcome records remain authoritative in PRD-90 and are not retained inside PRD-91-owned infrastructure.

### Control Plane Statement

PRD-91 must stay outside the core telephony dependency graph. It may consume lower-layer phone-number and flow-framework contracts plus PRD-90 migration-state truth, but it must not introduce migration-only dependencies into baseline modules or rely on cross-module source edits or state surgery as a steady-state boundary.

## 3. OVERVIEW

PRD-91 defines the migration execution plane for the platform. It owns readiness checks, switchover actions, rollback actions, and post-cutover validation for migration events.

This PRD replaces the v1 implementation scope that was previously spread across the former parallel-run and phased-cutover planning sections. In v1, those execution-time concerns are intentionally consolidated here so operators and future automation have one coherent cutover operations module.

## 4. Goals

- Provide controlled cutover execution for migration events.
- Provide a documented rollback path.
- Validate readiness before cutover.
- Validate basic post-cutover health after execution.
- Keep the live Connect mutation path explicit and AWS-realistic.
- Keep v1 lean and operator-friendly: CLI-triggered actions with focused handlers and no required event bus.

## 5. Non-Goals

- This PRD does not own migration or porting state truth; that is PRD-90.
- This PRD does not make portability eligibility decisions; that is PRD-15 via PRD-90 gating.
- This PRD does not require dashboards, scheduled traffic comparison, or EventBridge orchestration in v1.
- This PRD does not require configuration snapshot storage in v1.

## 6. Migration-Only Operating Posture

PRD-91 is classified as `migration-only`.

It must:

- remain disabled in bare-bones telephony deployments
- be enabled only when the migration capability pack is selected
- remain deployable and destroyable independently of optional eventing, analytics, and audit layers

## 7. Normative Architecture Decisions

The following decisions are part of the PRD and are not left to implementation-time discretion.

1. PRD-91 depends on PRD-90 as the authoritative migration state source.
2. PRD-91 uses focused operational handlers in v1:
   - `check_cutover_readiness`
   - `execute_switchover`
   - `execute_rollback`
   - `verify_post_cutover_health`
3. PRD-91 is CLI-first for operator interaction.
4. PRD-91 hard-depends on PRD-14 because cutover operations modify or validate live Connect routing behavior.
5. PRD-91 does not hard-depend on EventBridge, replay, dashboard, configuration snapshot, or shared alert-routing services in v1.
6. PRD-91 must write rollback-safe pre-cutover state into PRD-90 before any switchover is attempted.
7. PRD-91 uses one Lambda per handler in v1 for operational clarity and simpler IAM boundaries.
8. PRD-91 publishes explicit module-catalog metadata in v1 so manifest-driven deployment remains authoritative before implementation begins.
9. The canonical v1 live mutation path is the Amazon Connect phone-number-to-contact-flow association inside the target instance. Queue references are validation context only and are not treated as a direct Connect mutation primitive.

## 8. Dependencies

### Hard dependencies

- PRD-11 for phone number inventory and imported Connect number references
- PRD-14 for live flow and phone association behavior
- PRD-90 for migration-state truth, cutover eligibility, and rollback snapshot persistence

### Explicit non-dependencies in v1

The following are not required for v1:

- PRD-15 as a direct runtime dependency beyond the PRD-90 gating contract
- PRD-20 through PRD-22
- scheduled parallel-run monitoring
- comparison dashboards
- S3 configuration snapshots
- richer analytics and replay layers
- PRD-03 or Layer 8 alert transport as a prerequisite for basic handler alarms
- cross-instance or traffic-distribution-group number moves as part of the default switchover path

## 9. Runtime Model

### AWS resources in v1

- focused Lambda handlers for cutover operations
- CloudWatch log groups for those handlers
- basic CloudWatch alarms for handler errors

Canonical Connect API surface in v1:

- read current phone-number state with `DescribePhoneNumber`
- validate target flow details with `DescribeContactFlow`
- associate the inbound phone number to the published target flow with `AssociatePhoneNumberContactFlow`

If a migration program must move a claimed number between Connect instances or a traffic distribution group, that step is a runbook-controlled prerequisite outside the default PRD-91 switchover path. It must not be silently bundled into `execute_switchover`, because `UpdatePhoneNumber` changes the instance or traffic distribution group assignment but does not migrate the phone number's flow association.

Important v1 constraint:

- Amazon Connect exposes an explicit API to associate or disassociate a phone number and contact flow, but `DescribePhoneNumber` does not return the current contact-flow attachment. PRD-91 therefore must not claim a direct live readback of the current flow association from the phone-number API surface.

Required handler names:

- `{org_name}-cutover-readiness-{environment}`
- `{org_name}-cutover-switchover-{environment}`
- `{org_name}-cutover-rollback-{environment}`
- `{org_name}-cutover-health-{environment}`

### Operator model

Operators use:

- CLI reads for validation and inspection
- `aws lambda invoke` for readiness checks, switchover, rollback, and health checks

## 10. Handler Definitions

### `check_cutover_readiness`

Must validate:

- target number exists in Connect
- target number belongs to the intended Connect instance for the cutover
- PRD-90 migration-unit state is `READY_FOR_CUTOVER`
- PRD-90 porting-state status is one of:
  - `PORTED`
  - `IMPORT_VERIFICATION_PENDING`
  - `COMPLETE`
- required flow and queue references exist
- target contact flow status is `PUBLISHED`
- target association information is known
- rollback baseline information is present in PRD-90 or confirmed by the operator for first-time cutover
- required operator prerequisites are satisfied
- obvious blocking failures are absent

Canonical readiness reason codes in v1:

- `MIGRATION_UNIT_NOT_READY_FOR_CUTOVER`
- `PORTING_STATUS_NOT_CUTOVER_ELIGIBLE`
- `CONNECT_PHONE_NUMBER_NOT_FOUND`
- `PHONE_NUMBER_INSTANCE_MISMATCH`
- `TARGET_CONTACT_FLOW_MISSING`
- `TARGET_CONTACT_FLOW_NOT_PUBLISHED`
- `TARGET_QUEUE_MISSING`
- `PREVIOUS_TARGET_NOT_BASELINED`
- `ROLLBACK_BASELINE_NOT_AVAILABLE`
- `OPERATOR_PREREQUISITE_NOT_CONFIRMED`
- `CONNECT_VALIDATION_ERROR`
- `INTERNAL_VALIDATION_ERROR`

Returns:

- `READY`
- `NOT_READY`
- reasons list
- normalized `readiness_status`
- normalized `readiness_check_results`

### `execute_switchover`

Must:

- require or invoke readiness validation first
- capture and persist rollback-safe pre-cutover state into PRD-90 before changing Connect state
- acquire an operation lock through PRD-90 before changing live Connect state
- perform the controlled Connect-side change using the phone-number-to-contact-flow association path
- update PRD-90 migration state coherently
- return success or failure with actionable details

The handler must refuse mutation if:

- readiness fails
- the operator-supplied or PRD-90-baselined `expected_previous_target_ref` does not match the persisted rollback baseline when provided
- a PRD-90 operation lock cannot be acquired
- rollback snapshot persistence fails
- the requested target is already active and the request is not explicitly treated as an idempotent replay

The handler must treat a repeated request with the same `request_id` and same intended target as idempotent and return the previously observed outcome rather than applying a second mutation.

### `execute_rollback`

Must:

- restore the prior known-good configuration target recorded in PRD-90
- acquire an operation lock through PRD-90 before restoring live Connect state
- update PRD-90 rollback status
- return success or failure with actionable details

The rollback handler must refuse execution when:

- `allow_operator_rollback = false`
- PRD-90 does not indicate `rollback_ready = true`
- a PRD-90 operation lock cannot be acquired
- the referenced rollback snapshot is missing required fields

The rollback handler must also be idempotent for the same `request_id`.

### `verify_post_cutover_health`

Must:

- confirm the expected routing target is active
- confirm no obvious Connect-side failure condition is present
- confirm the cutover succeeded through a controlled post-cutover validation path rather than a nonexistent direct phone-number association readback API
- return pass/fail with reasons

Canonical post-cutover health reason codes in v1:

- `EXPECTED_ASSOCIATION_ACTIVE`
- `EXPECTED_ASSOCIATION_NOT_ACTIVE`
- `CONNECT_PHONE_NUMBER_LOOKUP_FAILED`
- `POST_CUTOVER_SMOKE_TEST_FAILED`
- `CONTACT_FLOW_REFERENCE_MISMATCH`
- `HEALTHCHECK_INTERNAL_ERROR`

### Common request contract

All handler requests must include:

- `migration_unit_id`
- `phone_number`
- `operator_identity`
- `request_id`
- `invocation_mode`

`invocation_mode` must be one of:

- `DRY_RUN`
- `EXECUTE`

`request_id` is the v1 idempotency key and must be unique per intentional operator action.

`check_cutover_readiness` may also include:

- optional `target_contact_flow_ref`
- optional `target_queue_ref`
- optional `operator_prerequisites`

`execute_switchover` must also include:

- `target_contact_flow_ref`
- optional `target_queue_ref`
- `expected_previous_target_ref`
- `expected_previous_version`
- optional `readiness_request_id`
- optional `operator_notes`

`execute_rollback` must also include:

- `expected_previous_version`
- optional `rollback_snapshot_ref`
- optional `operator_notes`

`verify_post_cutover_health` may also include:

- optional `expected_contact_flow_ref`
- optional `expected_queue_ref`

### Common response contract

All handlers must return:

- `ok` (boolean)
- `status`
- `handler`
- `migration_unit_id`
- `phone_number`
- `request_id`
- `checked_at`
- `reasons` (array)
- `invocation_mode`

`execute_switchover` and `execute_rollback` must additionally return:

- `connect_change_applied` (boolean)
- `previous_target_ref`
- `current_target_ref`
- `migration_state_status`
- `rollback_status`
- `rollback_snapshot_written` (boolean)
- `rollback_snapshot_ref`
- `operation_lock_acquired` (boolean)

Required response semantics:

- `status` must be a handler-specific normalized string such as `READY`, `NOT_READY`, `SWITCHOVER_APPLIED`, `SWITCHOVER_SKIPPED`, `ROLLBACK_APPLIED`, `ROLLBACK_SKIPPED`, `HEALTHCHECK_PASS`, or `HEALTHCHECK_FAIL`
- `reasons` must contain stable machine-readable reason codes, not only prose

### Rollback Snapshot Contract

Before live mutation, `execute_switchover` must persist the following PRD-90 rollback snapshot fields:

- `rollback_ready = true`
- `rollback_snapshot_at`
- `rollback_snapshot_ref`
- `previous_target_ref`
- `previous_phone_number_contact_flow_arn`
- `previous_phone_number_contact_flow_id`
- `previous_contact_flow_ref`
- `previous_queue_ref` when applicable
- `previous_association_source`
- `switchover_request_id`

`rollback_snapshot_ref` in v1 must be a stable PRD-90-owned reference, not an S3 object pointer.

### Mutation Safety Contract

PRD-91 must rely on PRD-90 for both rollback persistence and mutation safety.

Required v1 behavior:

- before `execute_switchover` or `execute_rollback`, the handler must acquire a PRD-90-backed operation lock using conditional writes against the current migration-unit record
- lock acquisition must fail closed when another cutover operation is already active for the same `migration_unit_id`
- `expected_previous_version` from the caller must match the current PRD-90 version at mutation time
- successful or failed outcomes must be written back to PRD-90 so repeated `request_id` retries can return the prior result

Canonical reason codes in v1:

- `OPERATION_LOCK_NOT_ACQUIRED`
- `REQUEST_ID_ALREADY_COMPLETED`
- `EXPECTED_VERSION_MISMATCH`

## 11. Operational Model

PRD-91 assumes:

- operator-triggered migration execution
- runbook-driven sequencing
- guarded runtime logic in handlers
- no required event choreography in v1

The expected operator sequence is:

1. run readiness check in `DRY_RUN` mode
2. confirm the returned `status = READY`
3. execute switchover in `EXECUTE` mode, passing:
   - `expected_previous_target_ref`
   - `expected_previous_version`
   - `readiness_request_id`
4. run post-cutover health validation in `EXECUTE` mode
5. execute rollback only if post-cutover validation or live call verification fails

Readiness-to-switchover rule in v1:

- `execute_switchover` must either perform a fresh readiness check internally or verify that the supplied `readiness_request_id` corresponds to a still-valid `READY` result for the same `migration_unit_id` and target reference.

Queue-reference rule in v1:

- `target_queue_ref` and `expected_queue_ref` are validation-only context used to confirm that the selected published contact flow aligns with the intended queueing behavior
- the live Connect mutation itself is the phone number's contact-flow association, not a direct queue mutation

Association-verification rule in v1:

- because Amazon Connect does not expose the current attached flow through `DescribePhoneNumber`, post-cutover validation must use a controlled smoke-call or equivalent operator validation path plus Connect resource checks, not a fictional direct readback of the current phone-number-to-flow association

Rollback-safe definition in v1:

- a switchover is rollback-safe only after PRD-91 records the pre-cutover association into PRD-90 fields:
  - `rollback_ready = true`
  - `rollback_snapshot_at`
  - `previous_phone_number_contact_flow_arn`
  - `previous_contact_flow_ref`
  - `rollback_snapshot_ref`

The switchover handler is responsible for writing these fields before mutating live Connect state.

Rollback baseline source in v1:

- the pre-cutover target recorded in PRD-90 must come from a previously established migration baseline or explicit operator confirmation captured in PRD-90
- `previous_association_source` must reflect that provenance honestly, such as `PRD90_BASELINE` or `OPERATOR_CONFIRMED`

## 12. Inputs And Outputs

### Inputs

- phone number inventory from PRD-11
- live flow and queue references from PRD-14
- migration and porting state from PRD-90
- module-scoped tfvars file:
  - `environments/<env>/cutover-operations.tfvars`

Required tfvars:

- `cutover_timeout_seconds`
- `post_cutover_health_timeout_seconds`
- `allow_operator_rollback`
- `default_readiness_checks_enabled`
- `enable_error_alarm`
- `alarm_action_arns`

### Outputs

- `cutover_readiness_lambda_arn`
- `cutover_switchover_lambda_arn`
- `cutover_rollback_lambda_arn`
- `cutover_healthcheck_lambda_arn`

Recommended module path and resource names:

- module path: `modules/l9-cutover-operations`
- Lambda handlers:
  - `{org_name}-cutover-readiness-{environment}`
  - `{org_name}-cutover-switchover-{environment}`
  - `{org_name}-cutover-rollback-{environment}`
  - `{org_name}-cutover-health-{environment}`

Recommended module-catalog metadata:

- classification: `migration-only`
- capability pack: `migration`
- dependencies:
  - `modules/bootstrap`
  - `modules/l0-account-baseline`
  - `modules/l1-phone-numbers`
  - `modules/l1-contact-flow-framework`
  - `modules/l9-migration-state`
- state key: `l9-cutover-operations/terraform.tfstate`
- domain tfvars: `cutover-operations.tfvars`
- workspace scoped: `true`
- supports destroy: `true`

Alarm contract in v1:

- `enable_error_alarm = true` creates the basic Lambda error alarms
- `alarm_action_arns = []` is valid and keeps PRD-91 independent of any shared alerting module
- if action ARNs are supplied, they are attached directly and do not create a new hard dependency in the PRD

## 13. Acceptance Criteria

- Readiness check returns `READY` or `NOT_READY` with actionable reasons.
- Switchover updates the live phone-number-to-contact-flow association and PRD-90 state coherently.
- Rollback restores prior state and records rollback outcome in PRD-90.
- Post-cutover validation detects obvious failure conditions.
- All v1 operations are invocable from CLI without EventBridge.
- Readiness and health handlers return stable machine-readable reason codes.
- Switchover refuses mutation when rollback snapshot persistence fails.
- Switchover and rollback refuse mutation when the PRD-90 operation lock cannot be acquired or the caller's `expected_previous_version` is stale.
- Readiness rejects target flows that are not `PUBLISHED`.
- Post-cutover validation uses a controlled smoke-call or operator validation path rather than claiming a direct current-association read API that Amazon Connect does not provide.
- Repeated requests with the same `request_id` are idempotent.

## 14. Deferred Enhancements

These are explicitly deferred beyond v1:

- scheduled parallel-run monitoring
- comparison dashboards
- EventBridge publication and replay
- configuration snapshot/export
- analytics-heavy health scoring

## 15. Related Runbooks

- `RB-11-02` Porting and cutover
- `RB-11-04` Pre-LOA portability verification
- future cutover operations runbook

## 16. Revision History

| Version | Date | Notes |
|---|---|---|
| 1.3.0 | 2026-04-08 | Added the explicit Connect phone-number-to-contact-flow mutation contract, clarified that queue references are validation context rather than direct mutation targets, removed the unsupported assumption of direct current-association readback from `DescribePhoneNumber`, and hardened the switchover and rollback flow around PRD-90-backed locking, version checks, and retry-safe outcome persistence. |
| 1.2.0 | 2026-04-06 | Governance normalization. Added the repo-owned governance section, made manifest/catalog activation authoritative, declared optional alarm sink behavior, completed the intended catalog entry, and clarified destroyable migration-only module boundaries. |
| 1.1.0 | 2026-03-30 | Readiness pass. Added canonical reason codes, stricter request and response contracts, explicit rollback snapshot fields, idempotency rule, tfvars alarm contract, and recommended module-catalog metadata. |
| 1.0.0 | 2026-03-27 | Initial normalized cutover operations draft. |
