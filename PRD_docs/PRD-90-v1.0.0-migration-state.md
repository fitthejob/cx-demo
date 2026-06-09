# PRD-90 — Migration State

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-90 |
| **Version** | 1.2.0 |
| **Status** | Draft |
| **Author** | — |
| **Last Updated** | 2026-04-08 |
| **Layer** | 9 — Migration & Consolidation |
| **Module Classification** | migration-only |
| **Minimum Deployment Profile** | migration-program |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-11 (Phone Number Management), PRD-14 (Contact Flow Framework), PRD-15 (Number Portability Verification) |
| **Blocks** | PRD-91 (Cutover Operations) |
| **Optional Shared Sinks** | Optional `alarm_action_arns` only |
| **Destroy / Retention Posture** | destroyable / migration-state data retained only for the duration of an active migration program |
| **Optional** | Yes — migration-only capability pack |

---

## 2. MODULE GOVERNANCE

This PRD follows the repo's manifest/catalog control plane. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable migration-only modules.

### Module Classification

- `classification`: `migration-only`
- `minimum_deployment_profile`: `migration-program`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l9-migration-state`
- `capability_packs`: `["migration"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-phone-numbers", "modules/l1-contact-flow-framework", "modules/l1-number-portability-check"]`
- `state_key`: `l9-migration-state/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `migration-state.tfvars`
- `supports_destroy`: `true`
- `activation`: manifest-selected `migration` capability pack or direct `enabled_modules` entry for migration programs

### Shared Sink Behavior

- `optional_shared_sinks`: `alarm_action_arns`
- `sink_behavior`: the basic Lambda error alarm may attach shared action ARNs when provided, but empty actions remain valid and do not create a hard dependency on the alerting stack.

### Destroy / Retention Posture

- `destroy_posture`: `destroyable`
- `retention_notes`: migration-state data is intentionally temporary and tied to migration programs, but it remains authoritative while the migration module is enabled.

### Control Plane Statement

PRD-90 must stay outside the core telephony dependency graph. It may consume lower-layer outputs from phone-number, flow-framework, and portability modules, but it must not introduce migration-only dependencies into baseline modules or require cross-module source edits as a steady-state boundary.

## 3. CONTEXT & PURPOSE

PRD-90 defines the migration control plane for the platform. It owns the authoritative state required to prepare, validate, and track number migration work before and immediately after a carrier port or service transition. It is not part of the core telephony baseline and should only be enabled when the migration capability pack is selected.

This PRD replaces the v1 implementation scope that was previously spread across earlier migration planning sections. In v1, migration state and porting workflow state are intentionally consolidated here so operators and future automation have one authoritative control-plane module.

## 4. Goals

- Maintain authoritative migration-unit state for staged migration work.
- Maintain authoritative number-level porting state for each phone number in scope.
- Enforce PRD-15 portability eligibility before LOA progression.
- Provide a CLI-first operator model with guarded mutation logic.
- Provide concurrency-safe and retry-safe state transitions for operator-driven migration work.
- Keep the v1 architecture lean: DynamoDB plus one mutation Lambda, with no required EventBridge or dashboard layer.

## 5. Non-Goals

- This PRD does not perform cutover execution or rollback actions; that is PRD-91.
- This PRD does not publish mandatory EventBridge events in v1.
- This PRD does not host LOA templates or runbook documents in S3.
- This PRD does not provision dashboards or scheduled metrics Lambdas in v1.

## 6. Migration-Only Operating Posture

PRD-90 is classified as `migration-only`.

It must:
- remain disabled in bare-bones telephony deployments
- be enabled only when the migration capability pack is selected
- be deployable and destroyable independently of unrelated optional layers

## 7. Normative Architecture Decisions

The following decisions are part of the PRD and are not left to implementation-time discretion.

1. PRD-90 uses two DynamoDB tables in v1:
   - `migration_state`
   - `porting_state`
2. PRD-90 uses one guarded mutation Lambda in v1 for state transitions and validation.
3. PRD-90 is CLI-first for operator interaction:
   - reads happen through AWS CLI
   - mutations happen by invoking the guarded Lambda
4. PRD-90 hard-depends on PRD-15 for portability eligibility truth.
5. PRD-90 does not hard-depend on PRD-20 through PRD-22, PRD-31, PRD-40, or dashboard layers in v1.
6. PRD-90 uses one-item-per-entity DynamoDB records in v1:
   - `migration_state` partition key: `migration_unit_id`
   - `porting_state` partition key: `phone_number`
7. PRD-90 uses a single mutation Lambda named `{org_name}-migration-state-{environment}`.
8. PRD-90 publishes explicit module-catalog metadata in v1 so manifest-driven deployment remains authoritative.
9. PRD-90 uses conditional DynamoDB writes for mutation safety in v1 so stale reads and competing operator requests are rejected rather than silently overwriting state.

## 8. Dependencies

### Hard dependencies

- PRD-11 provides claimed/imported phone number inventory and Connect phone number references.
- PRD-14 provides routing object references where migration targets or validation depend on live Connect flows and queues.
- PRD-15 provides the authoritative portability eligibility state used to gate LOA progression.

### Explicit non-dependencies in v1

The following are not required for v1:

- EventBridge custom bus or replay services
- shared contact-state and agent-state tables
- shared Lambda baseline/platform SDK layers
- migration dashboards
- scheduled migration metrics collection

## 9. Runtime Model

### AWS resources in v1

- DynamoDB table: `migration_state`
- DynamoDB table: `porting_state`
- Lambda: guarded mutation handler for migration and porting state transitions
- CloudWatch log group for the Lambda
- basic CloudWatch alarm for handler errors

### Operator model

Operators use:

- `aws dynamodb get-item` / `query` for read-only inspection
- `aws lambda invoke` for controlled state transitions

Direct `update-item` writes are not the supported operational path.

## 10. Data Model

### Table 1: `migration_state`

Purpose: track migration-unit level status for a number, department, or batch.

Key schema:

- partition key: `migration_unit_id` (string)
- no sort key in v1

Required GSIs:

- `status-planned-cutover-index`
  - partition key: `status`
  - sort key: `planned_cutover_at`

Minimum fields:

- `migration_unit_id`
- `scope_type`
- `scope_ref`
- `status`
- `legacy_system`
- `target_connect_queue_ref`
- `target_contact_flow_ref`
- `planned_cutover_at`
- `actual_cutover_at`
- `rollback_status`
- `rollback_ready`
- `rollback_snapshot_ref`
- `rollback_snapshot_at`
- `previous_phone_number_contact_flow_arn`
- `previous_contact_flow_ref`
- `operator_notes`
- `updated_at`
- `updated_by`
- `version`
- `last_mutation_request_id`
- `last_mutation_request_hash`
- `last_mutation_result`
- `active_operation_type`
- `active_operation_request_id`
- `active_operation_lock_expires_at`

### Table 2: `porting_state`

Purpose: track number-level porting workflow and portability-gated progression.

Key schema:

- partition key: `phone_number` (E.164 string)
- no sort key in v1

Required GSIs:

- `status-port-date-index`
  - partition key: `status`
  - sort key: `scheduled_port_date`

Minimum fields:

- `phone_number`
- `migration_unit_id`
- `legacy_carrier_name`
- `status`
- `last_portability_check_ref`
- `last_portability_checked_at`
- `foc_date`
- `scheduled_port_date`
- `actual_port_completed_at`
- `connect_phone_number_arn`
- `tags_verified`
- `tags_verified_at`
- `updated_at`
- `updated_by`
- `version`
- `last_mutation_request_id`
- `last_mutation_request_hash`
- `last_mutation_result`

## 10.1 Migration Unit State Machine

PRD-90 also owns the migration-unit state model used by PRD-91 cutover operations.

Required migration-unit status set:

- `PLANNED`
- `READY_FOR_CUTOVER`
- `CUTOVER_IN_PROGRESS`
- `POST_CUTOVER_VALIDATION`
- `CUTOVER_COMPLETE`
- `ROLLBACK_IN_PROGRESS`
- `ROLLED_BACK`
- `BLOCKED`

Allowed transitions:

| Current | Allowed Next |
|---|---|
| `PLANNED` | `READY_FOR_CUTOVER`, `BLOCKED` |
| `READY_FOR_CUTOVER` | `CUTOVER_IN_PROGRESS`, `BLOCKED` |
| `CUTOVER_IN_PROGRESS` | `POST_CUTOVER_VALIDATION`, `ROLLBACK_IN_PROGRESS` |
| `POST_CUTOVER_VALIDATION` | `CUTOVER_COMPLETE`, `ROLLBACK_IN_PROGRESS` |
| `CUTOVER_COMPLETE` | none |
| `ROLLBACK_IN_PROGRESS` | `ROLLED_BACK`, `BLOCKED` |
| `ROLLED_BACK` | `READY_FOR_CUTOVER`, `BLOCKED` |
| `BLOCKED` | `PLANNED`, `READY_FOR_CUTOVER` |

## 11. Porting State Machine

PRD-90 owns the number-level porting state machine.

Minimum status set:

- `DISCOVERED`
- `PORTABILITY_CHECK_PENDING`
- `PORTABILITY_ELIGIBLE`
- `PORTABILITY_BLOCKED`
- `LOA_READY`
- `LOA_SUBMITTED`
- `FOC_RECEIVED`
- `PORT_SCHEDULED`
- `PORTED`
- `IMPORT_VERIFICATION_PENDING`
- `COMPLETE`
- `ROLLBACK_REQUIRED`

The implementation must define an explicit allowed-transition map and reject invalid transitions.

Allowed transitions:

| Current | Allowed Next |
|---|---|
| `DISCOVERED` | `PORTABILITY_CHECK_PENDING` |
| `PORTABILITY_CHECK_PENDING` | `PORTABILITY_ELIGIBLE`, `PORTABILITY_BLOCKED` |
| `PORTABILITY_ELIGIBLE` | `LOA_READY`, `PORTABILITY_BLOCKED` |
| `PORTABILITY_BLOCKED` | `PORTABILITY_CHECK_PENDING` |
| `LOA_READY` | `LOA_SUBMITTED`, `PORTABILITY_BLOCKED` |
| `LOA_SUBMITTED` | `FOC_RECEIVED`, `PORTABILITY_BLOCKED` |
| `FOC_RECEIVED` | `PORT_SCHEDULED`, `ROLLBACK_REQUIRED` |
| `PORT_SCHEDULED` | `PORTED`, `ROLLBACK_REQUIRED` |
| `PORTED` | `IMPORT_VERIFICATION_PENDING`, `ROLLBACK_REQUIRED` |
| `IMPORT_VERIFICATION_PENDING` | `COMPLETE`, `ROLLBACK_REQUIRED` |
| `COMPLETE` | none |
| `ROLLBACK_REQUIRED` | `PORTABILITY_CHECK_PENDING`, `LOA_READY` |

Transition-specific rules:

- `DISCOVERED -> PORTABILITY_CHECK_PENDING`
  - requires `operator_identity`
- `PORTABILITY_CHECK_PENDING -> PORTABILITY_ELIGIBLE`
  - requires a current PRD-15 record with `effective_status = ELIGIBLE`
- `PORTABILITY_CHECK_PENDING -> PORTABILITY_BLOCKED`
  - requires a current PRD-15 record with non-eligible status
- `LOA_READY -> LOA_SUBMITTED`
  - requires current PRD-15 eligibility and freshness check at mutation time
  - requires `legacy_carrier_name`
- `LOA_SUBMITTED -> FOC_RECEIVED`
  - requires `foc_date`
- `FOC_RECEIVED -> PORT_SCHEDULED`
  - requires `scheduled_port_date`
- `PORTED -> IMPORT_VERIFICATION_PENDING`
  - requires `connect_phone_number_arn`
- `IMPORT_VERIFICATION_PENDING -> COMPLETE`
  - requires `tags_verified = true`

## 12. PRD-15 Integration Rules

PRD-15 is the single source of truth for portability eligibility.

PRD-90 must:

- read the PRD-15 `CURRENT` record for the number before allowing progression to `LOA_SUBMITTED`
- require `effective_status = ELIGIBLE`
- compute freshness at read time using the PRD-15 expiry policy
- reject progression when the portability record is stale, blocked, failed, or requires manual verification
- store the PRD-15 record reference used to make the decision

PRD-90 must not duplicate portability truth beyond storing the reference used for the state transition.

## 12.1 Concurrency And Idempotency Rules

PRD-90 is the mutation guard for migration and porting state. In v1 it must enforce both optimistic concurrency and request-level retry safety.

Required mutation safety rules:

- transition operations must use DynamoDB conditional writes so the persisted `current_status` and `version` still match the caller's expectation at mutation time
- stale writes must fail closed rather than overwriting newer operator state
- repeated requests with the same `request_id` and the same normalized payload against the same entity must return the previously stored result instead of applying a second mutation
- repeated requests with the same `request_id` but a different normalized payload must be rejected as an idempotency violation
- migration-unit records must be able to hold a short-lived active-operation lock for PRD-91 cutover and rollback handlers

Canonical rejection reason codes in v1:

- `STALE_STATUS_WRITE_REJECTED`
- `VERSION_MISMATCH`
- `REQUEST_ID_REPLAY_CONFLICT`
- `MUTATION_CONDITION_FAILED`
- `ACTIVE_OPERATION_LOCK_HELD`

## 13. Lambda Responsibilities

The guarded mutation Lambda must:

- validate the requested transition
- enforce required fields for that transition
- read PRD-15 state when the transition requires portability gating
- compute freshness from PRD-15 timestamps and expiry policy
- update the correct DynamoDB table
- use conditional writes on `current_status` and `version`
- persist last-request metadata needed for safe retry handling
- record operator identity and timestamp
- return a machine-readable result with success or rejection reasons

### Request contract

Lambda name:

- `{org_name}-migration-state-{environment}`

Supported operations:

- `upsert_migration_unit`
- `upsert_porting_record`
- `transition_migration_unit`
- `transition_porting_state`
- `record_tag_verification`

Required top-level request fields:

- `operation`
- `operator_identity`
- `request_id`
- `expected_version`

`upsert_migration_unit` request:

- `migration_unit_id`
- `scope_type`
- `scope_ref`
- optional `legacy_system`
- optional `target_connect_queue_ref`
- optional `target_contact_flow_ref`
- optional `planned_cutover_at`
- optional `operator_notes`

`upsert_porting_record` request:

- `phone_number`
- `migration_unit_id`
- `initial_status` (must be `DISCOVERED` in v1)
- optional `legacy_carrier_name`
- optional `connect_phone_number_arn`
- optional `scheduled_port_date`
- optional `operator_notes`

`transition_migration_unit` request:

- `migration_unit_id`
- `current_status`
- `next_status`
- `expected_version`
- optional `operator_notes`

`transition_porting_state` request:

- `phone_number`
- `current_status`
- `next_status`
- `expected_version`
- optional `legacy_carrier_name`
- optional `foc_date`
- optional `scheduled_port_date`
- optional `connect_phone_number_arn`
- optional `operator_notes`

`record_tag_verification` request:

- `phone_number`
- `tags_verified`
- optional `operator_notes`

### Initial operator sequence

The v1 implementation must support the following guarded sequence without requiring ad-hoc table writes:

1. create or update the migration-unit record with `upsert_migration_unit`
2. create the number-level record with `upsert_porting_record` and `initial_status = DISCOVERED`
3. transition the number to `PORTABILITY_CHECK_PENDING`
4. run PRD-15 and read the `CURRENT` record
5. transition to `PORTABILITY_ELIGIBLE` or `PORTABILITY_BLOCKED`
6. transition to `LOA_READY`
7. transition to `LOA_SUBMITTED`

The implementation must not require operators to invent one-off payloads such as raw `status` writes outside these guarded operations.

### Response contract

The Lambda must return:

- `ok` (boolean)
- `operation`
- `target_ref`
- `entity_type`
- `previous_status`
- `new_status`
- `updated_at`
- `request_id`
- `reasons` (array, empty on success)
- `version`
- optional `portability_check_ref`

## 14. Inputs And Outputs

### Inputs

- phone number inventory from PRD-11
- selected migration-unit scope
- PRD-15 portability outputs:
  - portability table name
  - portability table ARN
  - portability expiry policy
- module-scoped tfvars file:
  - `environments/<env>/migration-state.tfvars`

Required tfvars:

- `migration_units`
- `default_legacy_system`
- `allow_cli_mutations` (bool, default `true`)
- `enable_error_alarm` (bool, default `true`)
- `alarm_action_arns` (list(string), default `[]`)

### Outputs

- `migration_state_table_name`
- `migration_state_table_arn`
- `porting_state_table_name`
- `porting_state_table_arn`
- `migration_state_lambda_name`
- `migration_state_lambda_arn`

Recommended module path and resource names:

- module path: `modules/l9-migration-state`
- table names:
  - `{org_name}-migration-state-{environment}`
  - `{org_name}-porting-state-{environment}`
- Lambda:
  - `{org_name}-migration-state-{environment}`

Recommended module-catalog metadata:

- classification: `migration-only`
- capability pack: `migration`
- dependencies:
  - `modules/bootstrap`
  - `modules/l0-account-baseline`
  - `modules/l1-phone-numbers`
  - `modules/l1-contact-flow-framework`
  - `modules/l1-number-portability-check`
- state key: `l9-migration-state/terraform.tfstate`
- domain tfvars: `migration-state.tfvars`
- workspace scoped: `true`
- supports destroy: `true`

Alarm contract in v1:

- `enable_error_alarm = true` creates the basic Lambda error alarm
- `alarm_action_arns = []` is valid and keeps PRD-90 independent of any shared alerting module
- if action ARNs are supplied, they are attached directly and do not create a new hard dependency in the PRD

## 15. Acceptance Criteria

- Operators can query migration and porting state through documented CLI commands.
- Operators can invoke guarded transitions through Lambda.
- Invalid state transitions are rejected with actionable reasons.
- Transition to `LOA_SUBMITTED` is rejected unless PRD-15 reports `ELIGIBLE` and fresh.
- The PRD-15 record reference used for gating is stored in `porting_state`.
- Tag verification can be recorded and queried after port completion.
- Conditional-write protection rejects stale `current_status` or `expected_version` values instead of overwriting newer state.
- Repeated requests with the same `request_id` and same payload return the prior outcome rather than performing a second mutation.
- No EventBridge dependency is required for successful v1 operation.

## 16. Deferred Enhancements

These are explicitly deferred beyond v1:

- migration dashboard
- scheduled migration metrics Lambda
- EventBridge publication of migration events
- automated completion chaining
- S3 document/template storage

## 17. Related Runbooks

- `RB-11-02` Porting and cutover
- `RB-11-04` Pre-LOA portability verification
- future migration-state operations runbook

## 18. Revision History

| Version | Date | Notes |
|---|---|---|
| 1.2.0 | 2026-04-08 | Added the mutation-safety contract for conditional DynamoDB writes, explicit `version` and last-request fields, `expected_version` request requirements, and acceptance criteria for stale-write rejection and safe retry behavior. |
| 1.1.0 | 2026-04-06 | Added the repo-owned governance section, normalized versioning and repo-relative path examples, and made the migration-only catalog, activation, and optional alarm-action boundaries explicit. |
| 1.0.0 | 2026-03-16 | Initial release. Defined the migration-state control plane, state machines, guarded Lambda contract, and migration capability-pack posture. |
