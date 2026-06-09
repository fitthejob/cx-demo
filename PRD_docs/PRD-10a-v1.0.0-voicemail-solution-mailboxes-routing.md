# PRD-10a - Voicemail Solution

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-10a |
| **Version** | 1.3.0 |
| **Status** | Draft |
| **Author** | - |
| **Last Updated** | 2026-04-29 |
| **Layer** | 6 - Voicemail Service |
| **Module Classification** | optional-feature |
| **Minimum Deployment Profile** | standard |
| **Can Be Omitted From Bare-Bones** | Yes |
| **Introduces New Hard Dependencies Into Lower Layers** | No |
| **Depends On** | PRD-00 (state backend), PRD-02 (KMS keys, permission boundary), PRD-10 (Connect instance ID and placeholder recording storage), PRD-13 (queue registry), PRD-14 (contact flow hooks and attributes) |
| **Supersedes** | PRD-30, PRD-60, PRD-61, PRD-62 |
| **Blocks** | None - canonical Layer 6 voicemail contract |
| **Optional Shared Sinks** | EventBridge publication, Contact State writes, SES bounce and complaint sinks, if enabled |
| **Destroy / Retention Posture** | conditional / voicemail compute and flow resources destroyable only before or after call-recordings ownership handoff; customer-audio buckets retained per lifecycle and retention policy |
| **Optional** | Yes - additive voicemail capability pack |

---

## 2. MODULE GOVERNANCE

This PRD is the single active design contract for voicemail in the repo. Feature activation is controlled by the module catalog and the per-environment deployment manifest. `deployment_profile` is runtime shape only and is not used to enable or disable voicemail.

### Module Classification

- `classification`: `optional-feature`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Intended Catalog Entry

- `path`: `modules/l1-voicemail`
- `capability_packs`: `["voicemail"]`
- `dependencies`: `["modules/bootstrap", "modules/l0-account-baseline", "modules/l1-connect-instance", "modules/l1-queue-architecture", "modules/l1-contact-flow-framework"]`
- `state_key`: `l1-voicemail/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `voicemail.tfvars`
- `supports_destroy`: `false`
- `activation`: direct `enabled_modules` entry in the deployment manifest until the voicemail capability pack is promoted into the active pack chain

### Shared Sink Behavior

- `optional_shared_sinks`: EventBridge publication, Contact State writes, SES bounce/complaint sinks
- `sink_behavior`: optional inputs only. They do not determine whether the voicemail module exists in an environment.

### Destroy / Retention Posture

- `destroy_posture`: `conditional`
- `retention_notes`: destroying the module removes voicemail flows, Lambdas, resolver logic, and optional notification/transcription wiring only when the Connect `CALL_RECORDINGS` storage association has not yet been adopted by this module or has already been handed off elsewhere. Existing recordings, voicemail artifacts, and transcription artifacts remain governed by this PRD and PRD-32 lifecycle policy and are not erased retroactively by module destroy.

### Control Plane Statement

The core boundary of PRD-10a is a single voicemail module that owns mailbox resolution, voicemail storage, recording orchestration, optional transcription, and optional email notification. In voicemail-enabled environments, the same module may also become the authoritative owner of the Connect `CALL_RECORDINGS` storage association and the production recordings bucket through an explicit cutover step. Optional enrichments remain internal toggles of the module rather than separate manifest-selected modules.

---

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Amazon Connect does not provide native PBX-style voicemail. The platform must therefore implement voicemail as a managed capability composed of:

- mailbox ownership and routing
- customer-audio storage
- caller greeting and recording
- artifact storage
- optional transcription
- optional notification delivery

The prior planning set split the problem across:

- PRD-30 - customer-audio storage
- PRD-60 - recording and storage
- PRD-61 - transcription
- PRD-62 - email notification

That split was useful for design hardening, but it does not match the operator mental model. The platform should expose voicemail as one deployable feature, not four separate planning contracts with loosely coupled ownership and storage semantics.

### What Problem It Solves

PRD-10a defines voicemail as one cohesive product capability:

- a first-class mailbox model with `USER` and `GROUP` mailboxes
- production-grade recordings and voicemail buckets with lifecycle, encryption, and access controls
- the Connect call-recordings storage association cutover from the PRD-10 placeholder to the production recordings bucket when the environment promotes this module to customer-audio owner
- routing into voicemail from queue overflow, after-hours handling, and direct contact flow branches
- a canonical mailbox-aware recording flow
- optional transcription built into the voicemail module
- optional email notification built into the voicemail module
- a single catalog and manifest contract for enabling voicemail in an environment

### How It Fits the Overall Architecture

PRD-14 provides the entry hooks and call-path attributes.

PRD-10a owns the rest of Layer 6:

- mailbox registry
- mailbox resolver
- production recordings bucket after cutover
- voicemail bucket
- Connect call-recordings storage association after cutover
- voicemail recording flow
- voicemail processor
- optional transcription path
- optional notification path

This makes voicemail one additive capability pack with one Terraform module boundary and one environment tfvars surface.

---

## 4. GOALS

### Goals

- Make voicemail a single module and a single active PRD
- Support both `USER` and `GROUP` mailboxes
- Support queue overflow, after-hours, and direct-flow voicemail entry points
- Provision and govern the voicemail storage used by voicemail and, when promoted by cutover, the production customer-audio storage used by Connect call recordings
- Update the Connect call-recordings storage association from the PRD-10 placeholder to the production recordings bucket through an explicit ownership-adoption step
- Record voicemail artifacts to the dedicated voicemail storage estate
- Support optional transcription within the same module
- Support optional email notification within the same module
- Keep queue, mailbox, prompt, and recipient policy data-driven through tfvars
- Preserve deployability without PRD-20, PRD-31, PRD-50, or SES-specific operational sinks
- Standardize mailbox-aware metadata for downstream reporting and future workflow extensions

### Non-Goals

- This PRD does not implement an end-user voicemail inbox UI
- This PRD does not implement subscriber login, PIN retrieval, or voicemail self-service menus
- This PRD does not implement call recording playback APIs or investigation tooling
- This PRD does not require a CRM or tasking integration to be considered complete
- This PRD does not turn shared-state, event bus, or agent provisioning into universal prerequisites

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** - Enables and maintains voicemail as a single capability through one module and one tfvars surface.

**Compliance Officer** - Requires customer audio to be encrypted, retained, and governed according to the correct data class.

**Operations Manager** - Defines which queues and flows map to which mailboxes and who gets notified.

**Supervisor / Team Lead** - Owns group voicemail destinations and callback accountability for a team.

**Named User** - Owns a mailbox that receives voicemail intended for a specific person or role.

**Caller** - Leaves a voicemail after hours, during overflow, or from a direct dial flow.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-10a-01 | Operations Manager | As an operations manager, I want voicemail to be enabled as one feature rather than several disconnected services | One module and one tfvars file define the voicemail capability |
| US-10a-02 | Operations Manager | As an operations manager, I want voicemail mailboxes for both users and teams so routing reflects real ownership | Mailboxes support `USER` and `GROUP` types |
| US-10a-03 | Platform Engineer | As the platform engineer, I want queue overflow and after-hours routing to resolve mailbox keys cleanly so downstream behavior is deterministic | Resolver returns a canonical mailbox contract before recording |
| US-10a-04 | Supervisor | As a supervisor, I want group voicemail to notify the correct team recipients so callers are not dependent on one individual | Group mailbox notifications route to the configured recipient list |
| US-10a-05 | Named User | As a named user, I want voicemail meant for me to use my mailbox policy and greeting instead of a generic team mailbox | User mailbox routes resolve to the configured owner mailbox |
| US-10a-06 | Agent | As an agent, I want to receive voicemail notifications with transcript text when enabled so I can triage quickly | Notification includes transcript when transcription is enabled and completed |
| US-10a-07 | Platform Engineer | As the platform engineer, I want to disable transcription or email notification without removing voicemail itself | Module feature flags control those optional behaviors |
| US-10a-08 | Compliance Officer | As the compliance officer, I want recordings and voicemail stored in separate governed buckets so retention and access policies stay easy to reason about | Distinct S3 buckets exist with the expected lifecycle and encryption posture |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-001 - Single Voicemail Module Boundary

The system must implement voicemail as one Terraform module, `modules/l1-voicemail`, with one environment configuration file, `voicemail.tfvars`. The module owns mailbox resolution, customer-audio storage, recording orchestration, optional transcription, and optional email notification.

### FR-001a - Customer Audio Storage Boundary

In environments where voicemail is enabled, the same module may also become the authoritative owner of the customer-audio storage that supports voicemail processing:

- the production call recordings bucket
- the voicemail bucket
- the Connect `CALL_RECORDINGS` storage association cutover

This storage boundary is no longer a separate PRD/module contract. Once cutover is performed, no other active PRD/module may manage that storage association unless ownership is explicitly migrated again.

### FR-002 - Mailbox Registry

The module must support a `voicemail_mailboxes` input variable of type `map(object)`. Each mailbox entry must include:

- `enabled`
- `mailbox_type` - `USER` or `GROUP`
- `display_name`
- `owner_username` - optional for `USER`
- `group_name` - optional for `GROUP`
- `notification_targets` - list of one or more recipients
- `fallback_notification_targets` - optional list
- `greeting_key`
- `max_recording_seconds`
- `transcription_policy` - `ENABLED`, `DISABLED`, or `INHERIT`
- `email_notification_policy` - `ENABLED`, `DISABLED`, or `INHERIT`
- `callback_queue_key` - optional
- `retention_policy_key` - optional
- `tags` - optional metadata

No mailbox may be hard-coded in module source.

### FR-003 - Mailbox Routing Registry

The module must support a `voicemail_routes` input variable of type `map(object)` that maps routing sources to mailbox keys. Each route entry must include:

- `enabled`
- `source_type` - `QUEUE_OVERFLOW`, `AFTER_HOURS`, `DIRECT_FLOW`, or `EXPLICIT_MAILBOX`
- `source_queue_key` - required for queue-driven routes
- `source_flow_key` - required for direct-flow routes
- `source_reason` - `OVERFLOW`, `AFTER_HOURS`, `MENU_BRANCH`, `TRANSFER`, or another explicit value
- `target_mailbox_key`
- `fallback_mailbox_key`

The module must validate that every enabled route targets an enabled mailbox.

### FR-004 - Mailbox Resolver Contract

The module must provision a resolver contract named `{org_name}-voicemail-resolver`. The operating form may be a Lambda invoked from contact flows or another equivalent stable callable contract, but its interface must remain consistent.

Resolver input must support:

- `source_route_type`
- `source_reason`
- `source_queue_key`
- `source_flow_key`
- `explicit_mailbox_key`
- `caller_number`
- `contact_id`

Resolver output must include:

- `resolved`
- `mailbox_key`
- `mailbox_type`
- `mailbox_display_name`
- `greeting_key`
- `notification_targets`
- `callback_queue_key`
- `transcription_policy`
- `email_notification_policy`
- `max_recording_seconds`
- `retention_policy_key`
- `fallback_used`

### FR-005 - Contact Attribute Standardization

The resolver output must be written into stable contact attributes that the rest of the module consumes. At minimum:

- `voicemail_mailbox_key`
- `voicemail_mailbox_type`
- `voicemail_mailbox_display_name`
- `voicemail_greeting_key`
- `voicemail_callback_queue_key`
- `voicemail_transcription_policy`
- `voicemail_email_policy`
- `voicemail_source_route_type`
- `voicemail_source_queue_key`
- `voicemail_source_flow_key`

Mailbox key is the canonical ownership field. Queue name remains context only.

### FR-006 - Queue Overflow Routing

When a call reaches voicemail from queue overflow, the module must resolve mailbox ownership from the queue key exported by PRD-13 and the overflow branch defined by PRD-14.

Queue name alone must not be the canonical recipient routing key.

### FR-007 - After-Hours Routing

When a call reaches voicemail from PRD-14 after-hours handling, the module must resolve mailbox ownership based on:

- original queue context, when known
- direct inbound flow key, when queue context is absent
- explicit fallback mailbox, when neither route key is present

### FR-008 - Direct Contact Flow Routing

Any contact flow may enter voicemail directly without queue overflow. The flow must be able to pass:

- `explicit_mailbox_key`, or
- `source_flow_key`

to the resolver contract.

### FR-009 - Voicemail Recording Flow

The module must provision a contact flow named `{org_name}-Voicemail-Recording` of type `CONTACT_FLOW`. The flow must:

1. invoke or consume the mailbox resolution contract before recording
2. select the greeting based on mailbox policy
3. enable contact recording for the voicemail leg
4. record the caller message using mailbox-specific or default max duration
5. play a confirmation message
6. disconnect the caller
7. invoke the voicemail processor asynchronously with contact and mailbox metadata

### FR-010 - Voicemail Processor

The module must provision a Lambda function `{org_name}-voicemail-processor` triggered asynchronously by the voicemail flow after disconnect. The Lambda must:

1. resolve the Connect-managed recording location for the voicemail contact using `DescribeContact`
2. retry briefly until the recording location is visible
3. copy the recording from the module-owned recordings estate to the voicemail bucket under `voicemail/{mailbox_key}/{yyyy}/{mm}/{dd}/{contact_id}/recording.wav`
4. persist mailbox-aware metadata to `voicemail/{mailbox_key}/{yyyy}/{mm}/{dd}/{contact_id}/metadata.json`
5. delete the source recording from the recordings bucket after durable copy and metadata write succeed so voicemail artifacts do not inherit long-term call-recordings retention
6. surface a retryable failure and operator alarm if the source recording cannot be deleted after successful copy
7. optionally update Contact State when shared-state integration is enabled
8. optionally publish `ConnectPBX.VoicemailReceived` when event publication is enabled

### FR-011 - Mailbox-Aware Recording Metadata

The voicemail artifact metadata must include:

- `ContactId`
- `MailboxKey`
- `MailboxType`
- `MailboxDisplayName`
- `QueueKey` when present
- `SourceRouteType`
- `CallerNumber`
- `RecordingTimestamp`
- `RecordingS3Uri`
- `TranscriptS3Uri` when applicable
- `SourceRecordingDeleted`

### FR-012 - Prompt Selection Policy

Prompt selection must follow this order:

1. mailbox-specific greeting key
2. route-specific override, if defined
3. queue-specific default, if present
4. platform default greeting

### FR-013 - Optional Transcription

The single voicemail module must support transcription as an internal optional behavior controlled by feature flags and mailbox policy. When enabled:

- a trigger Lambda starts an asynchronous Amazon Transcribe job using the voicemail artifact
- output is written under `voicemail/{mailbox_key}/{yyyy}/{mm}/{dd}/{contact_id}/transcript.json`
- a completion Lambda reads the result and persists transcript text or metadata
- the module may optionally publish `ConnectPBX.VoicemailTranscribed`

When disabled, voicemail remains fully deployable and functional without transcript generation.

### FR-014 - Optional Email Notification

The single voicemail module must support email notification as an internal optional behavior controlled by feature flags and mailbox policy. When enabled:

- a notifier Lambda generates a pre-signed URL for the recording
- recipients are resolved from the mailbox definition rather than queue-only mapping
- transcript text is included when available and enabled
- the notifier sends mail using Amazon SES

When disabled, voicemail remains fully deployable and functional without email delivery.

### FR-015 - SES Sender Identity

If email notification is enabled, the module must verify or reference a verified SES sender identity:

- sandbox environments require verified sender and verified recipients
- production should use domain verification

### FR-016 - Optional Shared State

If shared-state integration is enabled, the module may update Contact State with:

- voicemail location
- transcript status
- notification sent status
- mailbox key

Shared state must remain optional and must not be required for basic voicemail deployability.

### FR-017 - Optional Event Publication

If event publication is enabled, the module may publish:

- `ConnectPBX.VoicemailReceived`
- `ConnectPBX.VoicemailTranscribed`

These publishers are optional and must not make PRD-20 a hard dependency for basic voicemail.

### FR-018 - Feature Flags

The module must expose explicit feature toggles such as:

- `enable_transcription`
- `enable_email_notifications`
- `enable_shared_state`
- `enable_event_publication`
- `enable_ses_bounce_notifications`
- `manage_call_recordings_storage`

The toggles govern runtime behavior inside the same module. They do not create separate module boundaries.

`manage_call_recordings_storage` is the rollout guard for the import-based production cutover. When `false`, the module may still provision voicemail resources against the existing Connect recording association. When `true`, the module must adopt and manage the authoritative `CALL_RECORDINGS` storage association in-place.

### FR-019 - Configuration Validation

The module must fail validation when:

- a route targets a nonexistent mailbox
- a `USER` mailbox lacks both owner identity and notification target
- a `GROUP` mailbox lacks both group name and notification target
- `callback_queue_key` references a queue key not exported by PRD-13
- `mailbox_type` is invalid

### FR-020 - Compatibility Rule

During transition from the older split Layer 6 contracts:

- mailbox-aware fields are canonical
- queue-derived fields remain available for compatibility and reporting
- downstream consumers must prefer `voicemail_mailbox_key` when present

### FR-021 - Call Recordings Bucket

Provision `{org_name}-recordings-{environment}-{account_id}` with:

- versioning enabled
- SSE-KMS using the environment key from PRD-02
- public access fully blocked
- HTTPS-only bucket policy
- lifecycle policy that expires objects at 2,555 days

Objects remain in standard S3 storage throughout the retained life unless a later PRD explicitly changes that policy. This bucket is the retention system of record for non-voicemail call recordings only. Successful voicemail processing must remove voicemail-origin source recordings from this bucket.

### FR-022 - Voicemail Bucket

Provision `{org_name}-voicemail-{environment}-{account_id}` with:

- versioning enabled
- SSE-KMS using the environment key from PRD-02
- public access fully blocked
- HTTPS-only bucket policy
- lifecycle policy that expires objects at 365 days

The voicemail bucket is the retention system of record for voicemail artifacts. Voicemail audio is treated as an operational artifact with a mailbox-aware lifecycle distinct from general call recordings.

### FR-023 - Customer Audio Prefix Convention

The module must standardize these prefixes:

- recordings: `recordings/{contact_id}/{timestamp}.wav`
- voicemail audio: `voicemail/{mailbox_key}/{yyyy}/{mm}/{dd}/{contact_id}/recording.wav`
- voicemail metadata: `voicemail/{mailbox_key}/{yyyy}/{mm}/{dd}/{contact_id}/metadata.json`
- transcription outputs when enabled: `voicemail/{mailbox_key}/{yyyy}/{mm}/{dd}/{contact_id}/transcript.json`

Any event payloads, Contact State pointers, and notification links must use this canonical voicemail path family. The recordings bucket copy is transitional source material only and must not be treated as the durable voicemail URI.

### FR-024 - Connect Storage Association Cutover

When `manage_call_recordings_storage = true`, the module must adopt and update the existing `aws_connect_instance_storage_config` for `CALL_RECORDINGS` so the Connect instance writes new call recordings to the production recordings bucket instead of the PRD-10 placeholder.

The cutover contract is import-block based:

- adopt the live storage association into the voicemail module state
- update it in place to the production recordings bucket
- avoid manual `terraform state rm`
- avoid editing PRD-10 source files as the steady-state boundary
- preserve the same Connect instance and resource type during adoption
- leave the PRD-10 placeholder bucket in place until post-cutover verification proves new recordings are landing in the production recordings bucket

### FR-025 - Customer Audio Access Policies

The recordings bucket policy must:

- allow the Connect service principal to write recordings scoped to the Connect instance ARN
- allow only explicitly provided workload roles to read objects
- optionally enable shared audit logging only when configured

The voicemail bucket policy must:

- allow only explicitly provided workload roles to read and write voicemail objects
- deny public access
- avoid hidden dependency on PRD-03 or other shared sinks

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Availability

The caller experience is Connect-hosted. Failures in asynchronous post-disconnect processing must not degrade the caller's ability to leave a voicemail.

### Latency

- mailbox resolution target: under 500 ms p95
- voicemail artifact stored in S3: under 30 seconds after disconnect
- notification delivery target when enabled: under 5 minutes after disconnect
- transcription completion target when enabled: under 5 minutes after disconnect
- Connect call-recordings storage association update must complete without manual state surgery
- successful voicemail processing must leave the voicemail bucket as the only retained store of voicemail artifacts

### Security

- voicemail recordings encrypted in S3 with the environment KMS key
- call recordings encrypted in S3 with the environment KMS key
- IAM roles scoped only to the services and prefixes actually used
- recipient lists and mailbox definitions remain configuration, not hard-coded source data
- transcript text and recording links must not be logged in application logs

### Scale

The design must support:

- tens to low hundreds of mailboxes per environment
- mailbox-specific policies without flow rewrites
- voicemail volumes typical of SMB through mid-market Amazon Connect deployments

### Compliance

Artifact retention and encryption are governed by this PRD together with PRD-32 lifecycle policy. This PRD must not weaken the prior customer-audio controls that were formerly described in PRD-30.

---

## 8. ARCHITECTURE

```text
Caller reaches voicemail-capable branch
      |
      +-- PRD-14 queue overflow
      +-- PRD-14 after-hours
      +-- direct contact flow branch
      v
voicemail-resolver contract
      |
      +-- mailbox registry
      +-- route registry
      +-- policy resolution
      v
voicemail recording flow
      |
      +-- record audio
      +-- async voicemail processor
      v
voicemail artifact in S3
      |
      +-- optional transcription path
      +-- optional email notification path
      +-- optional shared-state update
      +-- optional event publication

Amazon Connect call recordings
      |
      +-- CALL_RECORDINGS storage association
      v
recordings bucket in same module
```

### Boundary Notes

- PRD-14 owns entry hooks
- PRD-10a owns all Layer 6 voicemail logic
- PRD-10a owns the voicemail retention boundary and, after explicit cutover, becomes the authoritative owner of the production call-recordings storage association
- voicemail bucket is the durable system of record for voicemail artifacts
- recordings bucket remains the durable system of record for non-voicemail call recordings

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `voicemail_flow_id` | string | Voicemail recording contact flow ID | PRD-14 hook input |
| `voicemail_flow_arn` | string | Voicemail recording flow ARN | internal monitoring and optional event correlation |
| `voicemail_resolver_arn` | string | Mailbox resolver callable contract | PRD-14 and direct voicemail-capable flows |
| `voicemail_processor_arn` | string | Post-disconnect processor Lambda ARN | observability and operations |
| `enabled_mailbox_keys` | list(string) | Enabled mailbox inventory | operator validation and future dashboards |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```text
connect-pbx/
  modules/
    l1-voicemail/
      main.tf
      variables.tf
      outputs.tf
      iam.tf
      s3.tf
      storage-association.tf
      flows/
        voicemail-recording.json.tftpl
      lambda-src/
        voicemail-resolver/
          index.py
        voicemail-processor/
          index.py
        voicemail-transcription-trigger/
          index.py
        voicemail-transcription-complete/
          index.py
        voicemail-email-notifier/
          index.py
```

### Key Resources Declared

```hcl
resource "aws_connect_contact_flow" "voicemail_recording" {
  name        = "${var.org_name}-Voicemail-Recording"
  instance_id = var.connect_instance_id
  type        = "CONTACT_FLOW"
}

resource "aws_s3_bucket" "customer_audio" {
  for_each = {
    recordings = "${var.org_name}-recordings-${var.environment}-${local.account_id}"
    voicemail  = "${var.org_name}-voicemail-${var.environment}-${local.account_id}"
  }
  bucket = each.value
}

resource "aws_connect_instance_storage_config" "call_recordings" {
  instance_id   = var.connect_instance_id
  resource_type = "CALL_RECORDINGS"

  storage_config {
    storage_type = "S3"

    s3_config {
      bucket_name   = aws_s3_bucket.customer_audio["recordings"].bucket
      bucket_prefix = "recordings"

      encryption_config {
        encryption_type = "KMS"
        key_id          = var.kms_key_arn
      }
    }
  }
}

resource "aws_lambda_function" "voicemail_resolver" {
  function_name = "${var.org_name}-voicemail-resolver-${terraform.workspace}"
}

resource "aws_lambda_function" "voicemail_processor" {
  function_name = "${var.org_name}-voicemail-processor-${terraform.workspace}"
}

resource "aws_lambda_function" "voicemail_transcription_trigger" {
  count         = var.enable_transcription ? 1 : 0
  function_name = "${var.org_name}-voicemail-transcription-trigger-${terraform.workspace}"
}

resource "aws_lambda_function" "voicemail_transcription_complete" {
  count         = var.enable_transcription ? 1 : 0
  function_name = "${var.org_name}-voicemail-transcription-complete-${terraform.workspace}"
}

resource "aws_lambda_function" "voicemail_email_notifier" {
  count         = var.enable_email_notifications ? 1 : 0
  function_name = "${var.org_name}-voicemail-email-notifier-${terraform.workspace}"
}
```

```hcl
import {
  to = aws_connect_instance_storage_config.call_recordings
  id = "${var.connect_instance_id}:CALL_RECORDINGS"
}
```

The import block is enabled only for cutover runs where `manage_call_recordings_storage = true`. The production implementation must guard the storage-association resource so normal voicemail-only changes do not force ownership adoption unexpectedly.

### Core Variables

```hcl
variable "enable_transcription"       { type = bool   default = true }
variable "enable_email_notifications" { type = bool   default = true }
variable "enable_shared_state"        { type = bool   default = false }
variable "enable_event_publication"   { type = bool   default = false }
variable "manage_call_recordings_storage" { type = bool default = false }

variable "voicemail_mailboxes" {
  type = map(object({
    enabled                       = bool
    mailbox_type                  = string
    display_name                  = string
    owner_username                = optional(string)
    group_name                    = optional(string)
    notification_targets          = list(string)
    fallback_notification_targets = optional(list(string), [])
    greeting_key                  = string
    max_recording_seconds         = optional(number, 120)
    transcription_policy          = optional(string, "INHERIT")
    email_notification_policy     = optional(string, "INHERIT")
    callback_queue_key            = optional(string)
    retention_policy_key          = optional(string)
    tags                          = optional(map(string), {})
  }))
}

variable "voicemail_routes" {
  type = map(object({
    enabled              = bool
    source_type          = string
    source_queue_key     = optional(string)
    source_flow_key      = optional(string)
    source_reason        = string
    target_mailbox_key   = string
    fallback_mailbox_key = optional(string)
  }))
}
```

### Environment Configuration Surface

Environment-specific configuration lives in:

- `environments/dev/voicemail.tfvars`
- `environments/staging/voicemail.tfvars`
- `environments/prod/voicemail.tfvars`

This replaces the split `voicemail-recording.tfvars`, `voicemail-transcription.tfvars`, and `voicemail-email.tfvars` planning model.

---

## 10. EVENT SCHEMA

Event publication remains optional.

### VoicemailReceived

If enabled:

```json
{
  "source": "connect-pbx.voicemail",
  "detail-type": "ConnectPBX.VoicemailReceived",
  "detail": {
    "contact_id": "abcd-1234",
    "mailbox_key": "support-team",
    "queue_key": "customer-support",
    "caller_number": "+15551234567",
    "voicemail_location": "s3://bucket/voicemail/support-team/2026/04/29/abcd-1234/recording.wav"
  }
}
```

### VoicemailTranscribed

If enabled:

```json
{
  "source": "connect-pbx.voicemail",
  "detail-type": "ConnectPBX.VoicemailTranscribed",
  "detail": {
    "contact_id": "abcd-1234",
    "mailbox_key": "support-team",
    "transcription_location": "s3://bucket/voicemail/support-team/2026/04/29/abcd-1234/transcript.json"
  }
}
```

Reserved schemas must not be treated as implemented unless the corresponding publishers exist.

---

## 11. API / INTERFACE CONTRACT

### Resolver Input

```json
{
  "source_route_type": "QUEUE_OVERFLOW",
  "source_reason": "OVERFLOW",
  "source_queue_key": "customer-support",
  "source_flow_key": "main-inbound",
  "explicit_mailbox_key": null,
  "caller_number": "+15551234567",
  "contact_id": "abcd-1234"
}
```

### Resolver Output

```json
{
  "resolved": true,
  "mailbox_key": "support-team",
  "mailbox_type": "GROUP",
  "mailbox_display_name": "Customer Support Voicemail",
  "greeting_key": "support_after_hours",
  "notification_targets": ["support@company.example"],
  "callback_queue_key": "customer-support",
  "transcription_policy": "ENABLED",
  "email_notification_policy": "ENABLED",
  "max_recording_seconds": 120,
  "retention_policy_key": "voicemail-standard",
  "fallback_used": false
}
```

### Failure Contract

If mailbox resolution fails, the contract must return structured failure data that allows the invoking flow to:

- route to a configured fallback mailbox
- play `voicemail_unavailable` and disconnect
- record structured logs for operator review

---

## 12. DATA MODEL

### Example Mailboxes

```hcl
voicemail_mailboxes = {
  support-team = {
    enabled                   = true
    mailbox_type              = "GROUP"
    display_name              = "Customer Support Voicemail"
    group_name                = "Customer Support"
    notification_targets      = ["support@company.example"]
    greeting_key              = "support_default"
    max_recording_seconds     = 120
    transcription_policy      = "ENABLED"
    email_notification_policy = "ENABLED"
    callback_queue_key        = "customer-support"
    retention_policy_key      = "voicemail-standard"
  }

  jane-smith = {
    enabled                       = true
    mailbox_type                  = "USER"
    display_name                  = "Jane Smith"
    owner_username                = "jsmith"
    notification_targets          = ["jane.smith@company.example"]
    fallback_notification_targets = ["support-leads@company.example"]
    greeting_key                  = "jane_smith_personal"
    max_recording_seconds         = 90
    transcription_policy          = "ENABLED"
    email_notification_policy     = "ENABLED"
    callback_queue_key            = "customer-support"
  }
}
```

### Example Routes

```hcl
voicemail_routes = {
  support-overflow = {
    enabled              = true
    source_type          = "QUEUE_OVERFLOW"
    source_queue_key     = "customer-support"
    source_reason        = "OVERFLOW"
    target_mailbox_key   = "support-team"
    fallback_mailbox_key = "general-ops"
  }

  executive-line = {
    enabled            = true
    source_type        = "DIRECT_FLOW"
    source_flow_key    = "executive-inbound"
    source_reason      = "MENU_BRANCH"
    target_mailbox_key = "jane-smith"
  }
}
```

### Customer Audio Naming

```text
{org}-recordings-{environment}-{account_id}
{org}-voicemail-{environment}-{account_id}
```

---

## 13. CI/CD SPECIFICATION

- Use the shared reusable workflows defined by PRD-01
- Module path is `modules/l1-voicemail`
- Environment-specific configuration is loaded from `voicemail.tfvars`
- Schema validation for mailbox and route definitions must run before apply
- Local backend configuration must use the repo-standard bootstrap artifact pattern and current state-key conventions

---

## 14. OBSERVABILITY SPECIFICATION

### Required Metrics

- resolver Lambda `Invocations`, `Errors`, `Duration`
- processor Lambda `Invocations`, `Errors`, `Duration`
- recordings bucket object count/size where operationally useful
- voicemail bucket object count/size where operationally useful
- transcription Lambdas `Errors` and completion latency when enabled
- notifier Lambda `Errors` and delivery attempts when enabled
- mailbox resolution failures by route type

### Alarms

Alarm actions must be explicit optional inputs. The module remains deployable without a shared alert sink.

Recommended alarms:

- voicemail resolver errors > 0
- voicemail processor errors > 0
- repeated mailbox resolution failure for same route key
- transcription completion latency above target when enabled
- notification Lambda errors > 0 when enabled

### Logging

Structured logs must include:

- `contact_id`
- `source_route_type`
- `source_queue_key`
- `source_flow_key`
- `resolved_mailbox_key`
- `fallback_used`

Logs must not include transcript text, recording contents, or pre-signed URLs.

---

## 15. ACCEPTANCE CRITERIA

| ID | Scenario | Verification |
|---|---|---|
| AC-10a-01 | Queue overflow resolves to the correct group mailbox | Simulate queue overflow and confirm resolver returns the expected mailbox key |
| AC-10a-02 | After-hours route resolves correctly using queue or flow context | Simulate after-hours path and confirm mailbox policy output |
| AC-10a-03 | Direct flow can route to a user mailbox | Invoke resolver with direct flow or explicit mailbox key and confirm output |
| AC-10a-04 | Recording artifact stored within target window | Leave a voicemail and confirm S3 object exists within 30 seconds |
| AC-10a-05 | Recording metadata includes mailbox-aware fields | Inspect artifact metadata and confirm mailbox key and route type are present |
| AC-10a-06 | Transcription completes when enabled | Leave test voicemail and confirm transcription artifact exists within 5 minutes |
| AC-10a-07 | Notification routes to mailbox recipients when enabled | Leave voicemail and confirm email reaches configured mailbox targets |
| AC-10a-08 | Voicemail deploys without transcription, email, shared state, or event publication | Plan and apply with those feature flags disabled and confirm module still functions |
| AC-10a-09 | Invalid mailbox or route configuration fails validation | Supply invalid config and confirm plan or validation failure |
| AC-10a-10 | Queue context remains available for compatibility while mailbox key is canonical | Confirm queue-derived fields still exist in metadata for reporting and transition support |
| AC-10a-11 | Production recordings bucket is provisioned with the expected retention and encryption policy | Inspect S3 config and confirm 2,555-day retention, SSE-KMS, HTTPS-only policy, and public access block |
| AC-10a-12 | Voicemail bucket is provisioned with the expected retention and encryption policy | Inspect S3 config and confirm 365-day retention, SSE-KMS, HTTPS-only policy, and public access block |
| AC-10a-13 | Connect call-recordings storage association is cut over to the production bucket when the rollout guard is enabled | Apply with `manage_call_recordings_storage = true` and confirm the instance storage config points to the production recordings bucket after apply |
| AC-10a-14 | Voicemail source recordings do not remain retained in the long-term recordings bucket | Leave a voicemail, confirm the voicemail artifact exists in the canonical voicemail path, and confirm the source recording in the recordings bucket is deleted after processing |

---

## 16. RISKS & MITIGATIONS

| Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|
| Consolidation causes ambiguity between canonical mailbox ownership and older queue-only assumptions | High | Medium | Make mailbox key canonical and preserve queue context only for compatibility |
| Single module grows too broad and accidentally gains hidden dependencies | High | Medium | Keep event publication, shared state, and SES sinks behind explicit feature flags and optional inputs |
| User mailbox semantics accidentally create a hard dependency on PRD-50 | High | Medium | Treat mailbox registry as authoritative; any PRD-50 validation remains optional |
| Notification behavior becomes tightly coupled to queue names again | Medium | Medium | Route notifications from mailbox definitions, not queue recipient maps |
| Module destroy is misinterpreted as artifact deletion | Medium | Low | State retention posture explicitly and keep S3 lifecycle ownership in this PRD and PRD-32 |
| Consolidating the production recordings cutover into voicemail creates a sensitive shared-foundation ownership handoff | High | Medium | Gate cutover behind `manage_call_recordings_storage`, require import-based adoption, and block destroy until ownership is reassigned or intentionally torn down |

---

## 17. OPEN QUESTIONS

| ID | Question | Notes |
|---|---|---|
| OQ-10a-01 | Should mailbox config be stored in Lambda env vars, SSM, or versioned S3 JSON for the first implementation? | SSM or versioned S3 likely scale better than env vars |
| OQ-10a-02 | Should future work create voicemail tasks in Connect instead of or in addition to email notifications? | Out of scope for this combined baseline but likely future enhancement |
| OQ-10a-03 | Should transcription be enabled by default in dev and staging? | Depends on cost and testing posture |
| OQ-10a-04 | Should mailbox-aware reporting become part of Layer 8 observability after implementation? | Likely yes |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-04-29 | - | Initial mailbox-and-routing draft above the prior split voicemail PRDs |
| 1.1.0 | 2026-04-29 | - | Consolidated PRD-60, PRD-61, PRD-62, and the original PRD-10a draft into one canonical voicemail PRD and one intended `modules/l1-voicemail` contract |
| 1.2.0 | 2026-04-29 | - | Rolled PRD-30 customer-audio storage into PRD-10a so the consolidated module now owns recordings storage, voicemail storage, and Connect storage-association cutover in addition to mailbox routing, recording, transcription, and notification |
| 1.3.0 | 2026-04-29 | - | Hardened the consolidated design by making the call-recordings cutover an explicit gated ownership adoption, standardizing canonical voicemail object paths and event URIs, and defining deletion of voicemail-origin source recordings from the long-term recordings bucket |
