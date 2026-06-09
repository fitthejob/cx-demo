# PRD-40 — Shared Lambda Platform & Artifacts Repository

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-40 |
| **Version** | 1.3.0 |
| **Status** | Green |
| **Author** | — |
| **Last Updated** | 2026-04-06 |
| **Layer** | 4 — Compute Foundation |
| **Depends On** | PRD-00 (state backend bootstrap), PRD-02 (KMS keys, permission boundary) |
| **Blocks** | Lambda-heavy profiles that opt into the shared Lambda platform model |
| **Optional** | Yes — conditional foundation for Lambda-heavy profiles |

---

## 2. MODULE GOVERNANCE

### Module Classification

- `classification`: `conditional-foundation`
- `minimum_deployment_profile`: `standard`
- `can_be_omitted_from_bare_bones`: `yes`
- `introduces_new_hard_dependencies_into_lower_layers`: `no`

### Control Plane Statement

This PRD follows the repo's manifest/catalog model. Feature activation is controlled by the module catalog and per-environment deployment manifest. `deployment_profile` is used only for runtime shape such as scale, topology, and capacity.

### Catalog Entry

- `path`: `modules/l4-lambda-baseline`
- `capability_packs`: `[]`
- `dependencies`: `[modules/bootstrap, modules/l0-account-baseline]`
- `state_key`: `l4-lambda-baseline/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `null`
- `supports_destroy`: `false`
- `activation`: direct `enabled_modules` entry in the deployment manifest until a dedicated compute capability pack exists

### Optional Shared Sinks

- `PRD-03` alert topic and audit sink: optional input only when a downstream deployment intentionally enables audit operations
- `PRD-20` event bus: optional input only when a downstream deployment intentionally enables event-driven functions
- `PRD-31` contact and agent state tables: optional input only when a downstream deployment intentionally enables shared state
- DLQ routing: function-owned, not a baseline shared sink or baseline environment variable contract

### Destroy / Retention Posture

- `destroy_posture`: `protected`
- `retention_notes`: PRD-40 owns shared artifacts storage, layer versions, and the baseline role/policy contract; remove only with coordinated downstream updates

## 3. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Some deployments will accumulate enough Lambda surface area that a shared platform kit becomes worthwhile: common packaging rules, a central artifacts bucket, shared layers, and consistent logging/error patterns. Other deployments will stay intentionally lean and ship small self-contained Lambdas directly from their service modules.

This PRD defines the opt-in shared Lambda platform for the former case. It provisions a central artifacts bucket with strict prefix ownership, optional shared Lambda layers, a standard execution-role pattern, and standard conventions for observability and environment wiring. It is not a prerequisite for every Lambda in the system, and its optional integration points stay optional.

### What Problem It Solves

- Provisions the central artifacts bucket used for Lambda packages, shared layers, rendered flow artifacts, and other software-delivery assets
- Provisions the Dependencies Lambda Layer containing all shared third-party packages — eliminates per-function package bundling for common dependencies
- Provisions the Platform SDK Lambda Layer containing the internal `connect_pbx` Python package — structured logging, EventBridge client, DynamoDB helper, error classes, and retry utilities
- Establishes the standard Lambda execution role pattern with permission boundary applied
- Establishes the standard baseline Lambda environment variable set plus optional integration fragments
- Defines the function-owned async failure and DLQ pattern for Lambdas that need one
- Exports layer ARNs and the execution role baseline for all downstream PRDs to reference

### How It Fits the Overall Architecture

PRD-40 is the shared Lambda platform for modules that explicitly opt into it. Lambda-heavy profiles can standardize on the artifacts bucket, shared layers, and common SDK conventions defined here. Small or isolated modules may remain self-contained and bypass PRD-40 entirely without violating platform architecture.

---

## 4. GOALS

### Goals

- Provision the Dependencies Lambda Layer (Python 3.12, all shared third-party packages)
- Provision the Platform SDK Lambda Layer (internal `connect_pbx` package)
- Upload both layer zip packages to the PRD-40-owned artifacts bucket from the PRD-41 build pipeline
- Establish the standard Lambda execution role IAM pattern with permission boundary
- Establish the standard Lambda environment variable set and optional integration fragments
- Establish the Lambda function configuration defaults (timeout, memory, tracing, log group)
- Export layer ARNs and baseline IAM policy documents for all downstream Lambda PRDs

### Non-Goals

- This PRD does not provision any application Lambda functions — those are in their respective service PRDs
- This PRD does not implement the CI/CD pipeline for Lambda deployments — that is PRD-41
- This PRD does not implement Lambda@Edge or Lambda container images — all functions use standard zip deployments with Python 3.12
- This PRD does not require every Lambda in the system to attach shared layers or use the platform SDK

---

## 5. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — Provisions the layers and verifies that downstream Lambda functions can import the Platform SDK correctly.

**Service Developer** — A developer writing a Lambda-heavy service can opt into the shared artifacts bucket, layers, and SDK from PRD-40 instead of rebuilding that foundation in each module.

**Operations Engineer** — Benefits from consistent structured log format across all Lambda functions — every log entry has the same fields in the same positions, making CloudWatch Insights queries uniform across all services.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-40-01 | Service Developer | As a service developer, I want a Lambda Layer with all shared dependencies so that I never bundle boto3 or pydantic in my function package | Layer exists; test Lambda imports boto3 and pydantic from layer successfully |
| US-40-02 | Service Developer | As a service developer, I want a Platform SDK layer with structured logging so that my function produces consistent log entries without writing logging boilerplate | Layer exists; test Lambda imports connect_pbx.logger and produces structured JSON log |
| US-40-03 | Operations Engineer | As an operations engineer, I want all Lambda logs in the same structured JSON format so that I can write a single CloudWatch Insights query that works across all functions | All functions using Platform SDK produce identical log envelope |
| US-40-04 | Platform Engineer | As the platform engineer, I want Lambda execution roles to always have the permission boundary applied so that no function can escalate privileges | All downstream Lambda execution roles reference boundary ARN from PRD-02 |
| US-40-05 | Service Developer | As a service developer, I want a standard EventBridge publish client in the SDK so that I never write raw boto3 PutEvents calls | `connect_pbx.events.publish()` works in test Lambda |

---

## 6. FUNCTIONAL REQUIREMENTS

### FR-000 — Central Artifacts Bucket
Provision a central S3 bucket named `{org_name}-artifacts-{environment}-{account_id}` owned by PRD-40. The bucket must be encrypted with the environment KMS key, versioned, HTTPS-only, and organized by strict prefix ownership:

- `lambda/packages/{module_name}/`
- `lambda/layers/{layer_name}/`
- `generated/contact-flows/{module_name}/`
- `generated/deployment-assets/{module_name}/`

Write access must be limited by prefix to the producing workflow or module. Read access must be granted only to the principals that deploy or execute the relevant artifact.

### FR-001 — Dependencies Lambda Layer
Provision a Lambda Layer named `{org_name}-dependencies-{environment}` containing the following Python 3.12 packages. Versions must be pinned exactly in the build manifest and rebuilt through PRD-41. The layer zip must be built during CI/CD (PRD-41), uploaded to the central artifacts bucket owned by this PRD under a deterministic versioned key, and referenced by Terraform as an existing S3 object rather than uploaded during `terraform apply`:

```
boto3 == 1.34.0
botocore == 1.34.0
pydantic == 2.5.0
requests == 2.31.0
aws-lambda-powertools == 2.30.0
aws-xray-sdk == 2.12.0
```

### FR-002 — Platform SDK Lambda Layer
Provision a Lambda Layer named `{org_name}-platform-sdk-{environment}` containing the internal `connect_pbx` Python package. The package must provide the following modules:

| Module | Purpose |
|---|---|
| `connect_pbx.logger` | Structured JSON logger — wraps aws-lambda-powertools Logger |
| `connect_pbx.events` | EventBridge publish client — wraps PutEvents with envelope enforcement |
| `connect_pbx.dynamodb` | DynamoDB helper — typed read/write for Contact State and Agent State tables |
| `connect_pbx.errors` | Platform error classes — PlatformError, TransientError, PermanentError |
| `connect_pbx.retry` | Retry decorator with exponential backoff and jitter |
| `connect_pbx.tracing` | X-Ray tracing decorator |
| `connect_pbx.config` | Environment variable loader with validation |

### FR-003 — Standard Execution Role Pattern
Every Lambda function that opts into the shared Lambda platform should use an execution role that follows this pattern:

```hcl
resource "aws_iam_role" "{service}_lambda_role" {
  name                 = "{org_name}-{service}-lambda-{environment}"
  permissions_boundary = local.permission_boundary_arn  # Always from PRD-02
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service"; identifiers = ["lambda.amazonaws.com"] }
  }
}
```

The role must include the following baseline inline policy in addition to service-specific permissions:

```hcl
# Baseline policy attached to all Lambda execution roles
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:{region}:{account_id}:log-group:/aws/lambda/{org_name}-*"
    },
    {
      "Sid": "XRayTracing",
      "Effect": "Allow",
      "Action": ["xray:PutTraceSegments", "xray:PutTelemetryRecords", "xray:GetSamplingRules"],
      "Resource": "*"
    },
    {
      "Sid": "KMSDecrypt",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
      "Resource": "{env_kms_key_arn}"
    }
  ]
}
```

### FR-004 — Standard Environment Variable Set
PRD-40 must export a standard environment-variable map that Lambda-heavy modules can merge into their own configuration. Only baseline variables are always present; integration-specific fragments are exported separately and merged only when the corresponding module dependency is enabled:

| Variable | Source | Description |
|---|---|---|
| `ENVIRONMENT` | `terraform.workspace` | dev / staging / prod |
| `LOG_LEVEL` | `var.log_level` (default INFO) | Logger verbosity |
| `ARTIFACTS_BUCKET` | PRD-40 output | Central artifacts S3 bucket |

Optional fragments exported separately:

| Fragment | Variables | Source | Merge When |
|---|---|---|---|
| `eventing_env_vars` | `EVENT_BUS_NAME` | PRD-20 output | The module enables event-driven publishing |
| `shared_state_env_vars` | `CONTACT_STATE_TABLE`, `AGENT_STATE_TABLE` | PRD-31 output | The module enables shared-state reads/writes |
| `alerting_env_vars` | `PLATFORM_ALERT_TOPIC_ARN` | PRD-03 output | The module intentionally routes alerts through the shared topic |

### FR-005 — Standard Lambda Configuration Defaults
Lambda functions that adopt PRD-40 should use these configuration defaults unless explicitly overridden in their service PRD:

| Setting | Default | Override When |
|---|---|---|
| Runtime | `python3.12` | Never — platform standard |
| Architecture | `x86_64` | arm64 for cost-optimized functions in the adopting service PRD |
| Timeout | `30` seconds | Long-running functions (transcription, evidence export) |
| Memory | `256` MB | Memory-intensive functions |
| Tracing | `Active` (X-Ray) | Never — platform standard |
| Layers | `[dependencies_layer_arn, platform_sdk_layer_arn]` | When the service opts into shared layers |
| Dead letter | Function-owned SQS DLQ | Async/event-source functions that declare one in the service PRD |

### FR-006 — Platform SDK: Logger
The `connect_pbx.logger` module must wrap `aws_lambda_powertools.Logger` and produce structured JSON logs with the following standard fields in every log entry:

```json
{
  "timestamp": "ISO 8601",
  "level": "INFO | WARNING | ERROR | DEBUG",
  "service": "function-name",
  "environment": "dev | staging | prod",
  "contact_id": "string | null",
  "correlation_id": "string",
  "message": "string",
  "extra": {}
}
```

### FR-007 — Platform SDK: EventBridge Client
The `connect_pbx.events` module must provide a `publish(event_type, payload, contact_id=None)` function that wraps boto3 PutEvents and enforces the platform event envelope defined in PRD-20 Section 9 when the event-driven profile is enabled. Services that do not enable PRD-20 are not required to use this helper, and the event bus name must arrive through the optional `eventing_env_vars` fragment rather than the baseline env map.

### FR-008 — Platform SDK: DynamoDB Helper
The `connect_pbx.dynamodb` module must provide typed read/write functions for the Contact State and Agent State tables when the shared-state profile is enabled. Those table names must arrive through the optional `shared_state_env_vars` fragment rather than the baseline env map:
- `get_contact(contact_id)` → ContactState dataclass or None
- `put_contact(contact_state)` → None
- `update_contact(contact_id, updates)` → None
- `get_agent(agent_username)` → AgentState dataclass or None
- `put_agent(agent_state)` → None

### FR-009 — Platform SDK: Error Classes
The `connect_pbx.errors` module must define:
- `PlatformError(message, code, retryable=False)` — base class
- `TransientError(message)` — subclass with `retryable=True` (network timeouts, throttles)
- `PermanentError(message)` — subclass with `retryable=False` (validation errors, not-found)

Lambda functions must catch `TransientError` and allow the Lambda runtime to retry. They must treat `PermanentError` as terminal and let the configured Lambda or event-source DLQ policy handle final delivery after the source's retry policy is exhausted.

### FR-010 — Layer Version Management
When a layer is updated (new package version or SDK change), a new layer version is published. Terraform updates the `aws_lambda_layer_version` resource, which triggers a new version number. All Lambda functions referencing the layer must be updated to the new version ARN. PRD-41 handles the automated layer rebuild and version bump process.

---

## 7. NON-FUNCTIONAL REQUIREMENTS

### Cold Start Performance
Lambda cold start time with two attached layers must remain below 2 seconds for all functions. Layer packages must be optimized — no development dependencies, no test files, stripped bytecode.

### Layer Size
- Dependencies Layer: < 50 MB unzipped (Lambda Layer limit is 250 MB unzipped total across all layers)
- Platform SDK Layer: < 5 MB unzipped

### Scale
Lambda scales automatically. Concurrency limits are set per function in each service PRD — not here. The baseline sets `reserved_concurrency = -1` (unreserved, inherits account default) unless overridden.

### Security
- All execution roles have permission boundary from PRD-02
- No execution role has `*` on any AWS action
- Layer packages are built from pinned dependency versions (requirements.txt with exact version pins)
- Layer zip packages are stored in the PRD-40 artifacts bucket, encrypted with the environment KMS key

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 6.3 | Dependency versions pinned — no floating versions | requirements.txt with == pins |
| SOC 2 CC7.2 | Structured logging on all Lambda functions | Log format documentation |
| SOC 2 CC6.1 | Permission boundary on all execution roles | IAM role configuration |

---

## 8. ARCHITECTURE

### Layer Architecture

```
Lambda Function (any service PRD)
      │
      ├── Layer 1: {org_name}-dependencies
      │   └── python/lib/python3.12/site-packages/
      │       ├── boto3/
      │       ├── pydantic/
      │       ├── requests/
      │       ├── aws_lambda_powertools/
      │       └── aws_xray_sdk/
      │
      └── Layer 2: {org_name}-platform-sdk
          └── python/lib/python3.12/site-packages/
              └── connect_pbx/
                  ├── __init__.py
                  ├── logger.py
                  ├── events.py
                  ├── dynamodb.py
                  ├── errors.py
                  ├── retry.py
                  ├── tracing.py
                  └── config.py
```

### Execution Role Hierarchy

```
AWS IAM
└── Permission Boundary: {org_name}-platform-boundary (PRD-02)
    │
    └── Execution Role: {org_name}-{service}-lambda-{env}
        ├── Baseline Policy (CloudWatch Logs, X-Ray, KMS)
        └── Service Policy (specific to each service PRD)
```

### Headless Contract

| Output | Type | Description | Consumed By |
|---|---|---|---|
| `dependencies_layer_arn` | string | Dependencies layer ARN (latest version) | Lambda function `layers` blocks for services that opt into PRD-40 |
| `platform_sdk_layer_arn` | string | Platform SDK layer ARN (latest version) | Lambda function `layers` blocks for services that opt into PRD-40 |
| `lambda_baseline_policy_json` | string | Baseline IAM policy JSON | Execution-role inline policies for services that opt into PRD-40 |
| `standard_env_vars` | map(string) | Baseline environment variable map | Lambda `environment.variables` blocks for services that opt into PRD-40 |
| `eventing_env_vars` | map(string) | Optional eventing fragment | Lambda `environment.variables` blocks for services that enable PRD-20 |
| `shared_state_env_vars` | map(string) | Optional shared-state fragment | Lambda `environment.variables` blocks for services that enable PRD-31 |
| `alerting_env_vars` | map(string) | Optional alert-sink fragment | Lambda `environment.variables` blocks for services that intentionally route alerts through PRD-03 |

---

## 9. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── l4-lambda-baseline/         # PRD-40
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── iam.tf
        └── sdk/
            └── connect_pbx/
                ├── __init__.py
                ├── logger.py
                ├── events.py
                ├── dynamodb.py
                ├── errors.py
                ├── retry.py
                ├── tracing.py
                └── config.py
```

### Key Resources Declared

```hcl
# main.tf

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "terraform_remote_state" "account_baseline" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = var.account_baseline_state_key
    region = var.aws_region
  }
}

locals {
  account_id                = data.aws_caller_identity.current.account_id
  artifacts_bucket_name     = "${var.org_name}-artifacts-${terraform.workspace}-${local.account_id}"
  aws_region                = data.aws_region.current.name
  env_kms_key_arn           = data.terraform_remote_state.account_baseline.outputs.environment_kms_key_arn
  permission_boundary_arn   = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
  dependencies_layer_s3_key = "lambda/layers/dependencies/${var.dependencies_layer_version}.zip"
  platform_sdk_layer_s3_key = "lambda/layers/platform-sdk/${var.platform_sdk_layer_version}.zip"
}

resource "aws_lambda_layer_version" "dependencies" {
  layer_name               = "${var.org_name}-dependencies-${terraform.workspace}"
  description              = "Shared Python dependencies: boto3, botocore, pydantic, requests, powertools, xray"
  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["x86_64"]

  s3_bucket = local.artifacts_bucket_name
  s3_key    = local.dependencies_layer_s3_key
}

resource "aws_lambda_layer_version" "platform_sdk" {
  layer_name               = "${var.org_name}-platform-sdk-${terraform.workspace}"
  description              = "Platform SDK: connect_pbx package with logger, events, dynamodb, errors, retry"
  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["x86_64"]

  s3_bucket = local.artifacts_bucket_name
  s3_key    = local.platform_sdk_layer_s3_key
}

# iam.tf — Baseline policy data source consumed by all downstream Lambda execution roles

data "aws_iam_policy_document" "lambda_baseline" {
  statement {
    sid     = "CloudWatchLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.aws_region}:${local.account_id}:log-group:/aws/lambda/${var.org_name}-*"]
  }

  statement {
    sid     = "XRayTracing"
    effect  = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "KMSDecrypt"
    effect  = "Allow"
    actions = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [local.env_kms_key_arn]
  }
}
```

### Platform SDK Source Code

```python
# sdk/connect_pbx/logger.py
from aws_lambda_powertools import Logger as _Logger
import os

_logger = _Logger(
    service=os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown'),
    level=os.environ.get('LOG_LEVEL', 'INFO')
)

class Logger:
    def __init__(self, contact_id: str = None, correlation_id: str = None):
        self._contact_id = contact_id
        self._correlation_id = correlation_id

    def _extra(self, **kwargs):
        base = {
            'service': os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'unknown'),
            'environment': os.environ.get('ENVIRONMENT', 'unknown'),
            'contact_id': self._contact_id,
            'correlation_id': self._correlation_id,
        }
        base.update(kwargs)
        return base

    def info(self, msg, **kwargs):
        _logger.info(msg, extra=self._extra(**kwargs))

    def warning(self, msg, **kwargs):
        _logger.warning(msg, extra=self._extra(**kwargs))

    def error(self, msg, **kwargs):
        _logger.error(msg, extra=self._extra(**kwargs))

    def debug(self, msg, **kwargs):
        _logger.debug(msg, extra=self._extra(**kwargs))
```

```python
# sdk/connect_pbx/events.py
import boto3
import json
import os
import uuid
from datetime import datetime, timezone
from .config import config
from .errors import PermanentError, TransientError

_client = boto3.client('events')
EVENT_BUS_NAME = config.eventing_env_vars().get('EVENT_BUS_NAME')

def publish(event_type: str, payload: dict, source_suffix: str = 'service', contact_id: str = None) -> dict:
    """
    Publishes an event to the platform EventBridge bus.
    Enforces the canonical event envelope from PRD-20.
    """
    if not EVENT_BUS_NAME:
        raise PermanentError('EVENT_BUS_NAME is not enabled for this function')
    detail = {
        'schema_version': '1.0',
        'event_id': contact_id or str(uuid.uuid4()),
        'timestamp': datetime.now(timezone.utc).isoformat(),
        'environment': os.environ.get('ENVIRONMENT', 'unknown'),
        'payload': payload
    }
    entry = {
        'Source': f'connect-pbx.{source_suffix}',
        'DetailType': f'ConnectPBX.{event_type}',
        'Detail': json.dumps(detail),
        'EventBusName': EVENT_BUS_NAME
    }
    response = _client.put_events(Entries=[entry])
    if response.get('FailedEntryCount', 0) > 0:
        error_msg = response['Entries'][0].get('ErrorMessage', 'Unknown EventBridge PutEvents failure')
        raise TransientError(f"EventBridge PutEvents failed: {error_msg}")
    return response
```

```python
# sdk/connect_pbx/dynamodb.py
import boto3
import os
from dataclasses import dataclass, field
from typing import Optional
from .config import config
from .errors import PermanentError

_db = boto3.resource('dynamodb')
CONTACT_TABLE = config.shared_state_env_vars().get('CONTACT_STATE_TABLE')
AGENT_TABLE   = config.shared_state_env_vars().get('AGENT_STATE_TABLE')

@dataclass
class ContactState:
    ContactId:            str
    Channel:              str = 'VOICE'
    Status:               str = 'INITIATED'
    CustomerEndpoint:     Optional[str] = None
    QueueName:            Optional[str] = None
    AgentUsername:        Optional[str] = None
    VoicemailLocation:    Optional[str] = None
    TranscriptionText:    Optional[str] = None
    CRMContactId:         Optional[str] = None
    ExpiresAt:            Optional[int] = None

@dataclass
class AgentState:
    AgentUsername:        str
    CurrentStatus:        str = 'OFFLINE'
    RoutingProfileName:   Optional[str] = None
    CurrentContactId:     Optional[str] = None

def get_contact(contact_id: str) -> Optional[ContactState]:
    if not CONTACT_TABLE:
        raise PermanentError('CONTACT_STATE_TABLE is not enabled for this function')
    table = _db.Table(CONTACT_TABLE)
    resp  = table.get_item(Key={'ContactId': contact_id})
    item  = resp.get('Item')
    if not item:
        return None
    return ContactState(**{k: v for k, v in item.items() if k in ContactState.__dataclass_fields__})

def put_contact(state: ContactState) -> None:
    if not CONTACT_TABLE:
        raise PermanentError('CONTACT_STATE_TABLE is not enabled for this function')
    table = _db.Table(CONTACT_TABLE)
    table.put_item(Item=state.__dict__)

def update_contact(contact_id: str, updates: dict) -> None:
    if not CONTACT_TABLE:
        raise PermanentError('CONTACT_STATE_TABLE is not enabled for this function')
    table = _db.Table(CONTACT_TABLE)
    expr  = 'SET ' + ', '.join(f'#{k} = :{k}' for k in updates)
    names = {f'#{k}': k for k in updates}
    vals  = {f':{k}': v for k, v in updates.items()}
    table.update_item(
        Key={'ContactId': contact_id},
        UpdateExpression=expr,
        ExpressionAttributeNames=names,
        ExpressionAttributeValues=vals
    )

def get_agent(username: str) -> Optional[AgentState]:
    if not AGENT_TABLE:
        raise PermanentError('AGENT_STATE_TABLE is not enabled for this function')
    table = _db.Table(AGENT_TABLE)
    resp  = table.get_item(Key={'AgentUsername': username})
    item  = resp.get('Item')
    if not item:
        return None
    return AgentState(**{k: v for k, v in item.items() if k in AgentState.__dataclass_fields__})

def put_agent(state: AgentState) -> None:
    if not AGENT_TABLE:
        raise PermanentError('AGENT_STATE_TABLE is not enabled for this function')
    table = _db.Table(AGENT_TABLE)
    table.put_item(Item=state.__dict__)
```

```python
# sdk/connect_pbx/errors.py

class PlatformError(Exception):
    def __init__(self, message: str, code: str = 'PLATFORM_ERROR', retryable: bool = False):
        super().__init__(message)
        self.code      = code
        self.retryable = retryable

class TransientError(PlatformError):
    """Network timeouts, throttles, temporary unavailability. Lambda will retry."""
    def __init__(self, message: str):
        super().__init__(message, code='TRANSIENT_ERROR', retryable=True)

class PermanentError(PlatformError):
    """Validation failures, not-found, permission denied. Treated as terminal by the configured DLQ policy."""
    def __init__(self, message: str):
        super().__init__(message, code='PERMANENT_ERROR', retryable=False)
```

```python
# sdk/connect_pbx/retry.py
import time
import random
import functools
from .errors import TransientError

def with_retry(max_attempts: int = 3, base_delay: float = 0.5, max_delay: float = 30.0):
    """Exponential backoff with jitter for transient errors."""
    def decorator(fn):
        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            for attempt in range(max_attempts):
                try:
                    return fn(*args, **kwargs)
                except TransientError as e:
                    if attempt == max_attempts - 1:
                        raise
                    delay = min(base_delay * (2 ** attempt) + random.uniform(0, 1), max_delay)
                    time.sleep(delay)
        return wrapper
    return decorator
```

```python
# sdk/connect_pbx/config.py
import os
from typing import Optional

class Config:
    """Validated environment variable loader."""

    def get(self, key: str, required: bool = True, default: Optional[str] = None) -> str:
        value = os.environ.get(key, default)
        if required and not value:
            raise EnvironmentError(f"Required environment variable missing: {key}")
        return value

    def get_optional(self, key: str) -> Optional[str]:
        return os.environ.get(key)

    def baseline_env_vars(self) -> dict:
        return {
            "ENVIRONMENT": self.get("ENVIRONMENT"),
            "LOG_LEVEL": self.get("LOG_LEVEL", default="INFO"),
            "ARTIFACTS_BUCKET": self.get("ARTIFACTS_BUCKET"),
        }

    def eventing_env_vars(self) -> dict:
        value = self.get_optional("EVENT_BUS_NAME")
        return {"EVENT_BUS_NAME": value} if value else {}

    def shared_state_env_vars(self) -> dict:
        env_vars = {}
        contact_table = self.get_optional("CONTACT_STATE_TABLE")
        agent_table = self.get_optional("AGENT_STATE_TABLE")
        if contact_table:
            env_vars["CONTACT_STATE_TABLE"] = contact_table
        if agent_table:
            env_vars["AGENT_STATE_TABLE"] = agent_table
        return env_vars

    def alerting_env_vars(self) -> dict:
        value = self.get_optional("PLATFORM_ALERT_TOPIC_ARN")
        return {"PLATFORM_ALERT_TOPIC_ARN": value} if value else {}

    @property
    def environment(self) -> str:
        return self.get('ENVIRONMENT')

    @property
    def log_level(self) -> str:
        return self.get("LOG_LEVEL", default="INFO")

config = Config()
```

### Variables

```hcl
# variables.tf

variable "org_name"    { type = string }
variable "aws_region"  { type = string; default = "us-east-1" }
variable "state_bucket" { type = string }
variable "account_baseline_state_key" { type = string }
variable "layer_id"    { type = string; default = "L4" }
variable "prd_id"      { type = string; default = "PRD-40" }

variable "log_level" {
  type        = string
  description = "Lambda log level for all functions. Override per environment."
  default     = "INFO"
  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be DEBUG, INFO, WARNING, or ERROR."
  }
}

variable "dependencies_layer_version" {
  type        = string
  description = "Version string for the dependencies layer zip. Bump to trigger layer rebuild."
  default     = "1.0.0"
}

variable "platform_sdk_layer_version" {
  type        = string
  description = "Version string for the platform SDK layer zip. Bump to trigger layer rebuild."
  default     = "1.0.0"
}
```

### Outputs

```hcl
# outputs.tf

output "dependencies_layer_arn" {
  description = "Dependencies Lambda Layer ARN (latest version). Attach to functions that opt into PRD-40."
  value       = aws_lambda_layer_version.dependencies.arn
}

output "platform_sdk_layer_arn" {
  description = "Platform SDK Lambda Layer ARN (latest version). Attach to functions that opt into PRD-40."
  value       = aws_lambda_layer_version.platform_sdk.arn
}

output "lambda_baseline_policy_json" {
  description = "Baseline IAM policy JSON. Include as inline policy in execution roles for services that opt into PRD-40."
  value       = data.aws_iam_policy_document.lambda_baseline.json
}

output "standard_env_vars" {
  description = "Baseline environment variable map. Merge into Lambda function environment.variables blocks for services that opt into PRD-40."
  value = {
    ENVIRONMENT     = terraform.workspace
    LOG_LEVEL       = var.log_level
    ARTIFACTS_BUCKET = local.artifacts_bucket_name
  }
}

output "eventing_env_vars" {
  description = "Optional eventing fragment. Merge only for functions that enable PRD-20."
  value       = local.eventing_env_vars
}

output "shared_state_env_vars" {
  description = "Optional shared-state fragment. Merge only for functions that enable PRD-31."
  value       = local.shared_state_env_vars
}

output "alerting_env_vars" {
  description = "Optional alerting fragment. Merge only for functions that intentionally route alerts through PRD-03."
  value       = local.alerting_env_vars
}
```

### Backend

```hcl
terraform {
  required_version = ">= 1.14.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "s3" {}
}
```

Catalog-backed state conventions:

- `path`: `modules/l4-lambda-baseline`
- `state_key`: `l4-lambda-baseline/terraform.tfstate`
- `workspace_scoped`: `true`
- `domain_tfvars`: `null`

```hcl
locals {
  # Placeholder fragment maps; implementation populates these from optional inputs.
  eventing_env_vars     = {}
  shared_state_env_vars = {}
  alerting_env_vars     = {}
}
```

### Standard Downstream Lambda Pattern

Lambda functions that opt into PRD-40 follow this pattern:

```hcl
# Pattern used in PRD-60, PRD-61, PRD-70, PRD-81, etc.
# Only function_name, handler, filename, and service-specific
# environment variables and IAM statements change per service.

data "terraform_remote_state" "lambda_baseline" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.lambda_baseline_state_key, region = var.aws_region }
}

data "terraform_remote_state" "account_baseline" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.account_baseline_state_key, region = var.aws_region }
}

locals {
  dependencies_layer_arn    = data.terraform_remote_state.lambda_baseline.outputs.dependencies_layer_arn
  platform_sdk_layer_arn    = data.terraform_remote_state.lambda_baseline.outputs.platform_sdk_layer_arn
  lambda_baseline_policy_json = data.terraform_remote_state.lambda_baseline.outputs.lambda_baseline_policy_json
  standard_env_vars         = data.terraform_remote_state.lambda_baseline.outputs.standard_env_vars
  eventing_env_vars         = data.terraform_remote_state.lambda_baseline.outputs.eventing_env_vars
  shared_state_env_vars     = data.terraform_remote_state.lambda_baseline.outputs.shared_state_env_vars
  alerting_env_vars         = data.terraform_remote_state.lambda_baseline.outputs.alerting_env_vars
  permission_boundary_arn   = data.terraform_remote_state.account_baseline.outputs.permission_boundary_arn
}

resource "aws_iam_role" "service_lambda" {
  name                 = "${var.org_name}-{service}-lambda-${terraform.workspace}"
  permissions_boundary = local.permission_boundary_arn
  assume_role_policy   = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "service_lambda_baseline" {
  name   = "baseline"
  role   = aws_iam_role.service_lambda.id
  policy = local.lambda_baseline_policy_json
}

resource "aws_iam_role_policy" "service_lambda_specific" {
  name   = "service-specific"
  role   = aws_iam_role.service_lambda.id
  policy = jsonencode({ /* service-specific permissions */ })
}

resource "aws_lambda_function" "service" {
  function_name = "${var.org_name}-{service}-${terraform.workspace}"
  role          = aws_iam_role.service_lambda.arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  layers = [
    local.dependencies_layer_arn,
    local.platform_sdk_layer_arn
  ]

  filename         = data.archive_file.service.output_path
  source_code_hash = data.archive_file.service.output_base64sha256

  environment {
    variables = merge(
      local.standard_env_vars,
      local.eventing_env_vars,
      local.shared_state_env_vars,
      local.alerting_env_vars,
      {
        # Service-specific additions here; do not move optional contracts into the baseline map.
      }
    )
  }

  tracing_config { mode = "Active" }
  tags = { Layer = "L{N}", PRD = "PRD-{XX}" }
}
```

---

## 10. EVENT SCHEMA

PRD-40 produces no EventBridge events. The Platform SDK `connect_pbx.events.publish()` function enforces the envelope from PRD-20 — it does not define new event types.

---

## 11. API / INTERFACE CONTRACT

```hcl
# All downstream Lambda PRDs consume PRD-40 outputs via remote state
data "terraform_remote_state" "lambda_baseline" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = var.lambda_baseline_state_key, region = var.aws_region }
}
```

The `lambda_baseline_state_key` input must match the catalog-declared `state_key` for PRD-40. Downstream PRDs should not reconstruct it from `${terraform.workspace}` or hardcoded `dev/...` paths.

### Platform SDK Usage Convention

All Lambda handler functions must follow this pattern:

```python
# Standard Lambda handler pattern using Platform SDK
from connect_pbx.logger import Logger
from connect_pbx.config import config
from connect_pbx.errors import TransientError, PermanentError
from connect_pbx import events, dynamodb

def handler(event, context):
    log = Logger(
        contact_id=event.get('detail', {}).get('payload', {}).get('contact_id'),
        correlation_id=event.get('headers', {}).get('x-correlation-id')
    )
    _baseline_env = config.baseline_env_vars()

    try:
        log.info("Handler invoked", event_type=event.get('detail-type'))
        # ... service logic using connect_pbx modules ...
        log.info("Handler completed successfully")
        return {'statusCode': 200}

    except TransientError as e:
        log.error("Transient error; Lambda should retry", error=str(e))
        raise

    except PermanentError as e:
        log.error("Terminal error; configured DLQ policy handles final delivery", error=str(e))
        raise

    except Exception as e:
        log.error("Unexpected error", error=str(e))
        raise TransientError(str(e))
```

---

## 12. DATA MODEL

PRD-40 provisions the central artifacts bucket and optional shared layers. The Platform SDK may operate on PRD-03, PRD-20, and PRD-31 contracts when those profiles are enabled.

### Layer Package Inventory

```
s3://{org}-artifacts-{env}-{acct}/
└── lambda/
    ├── packages/
    │   └── {module_name}/
    │       └── {version}.zip       ← Built by PRD-41 CI pipeline or service-local workflow
    └── layers/
        ├── dependencies/
        │   └── {version}.zip       ← Built by PRD-41 CI pipeline
        └── platform-sdk/
            └── {version}.zip       ← Built from sdk/ directory in this module
```

---

## 13. CI/CD SPECIFICATION

```yaml
jobs:
  security-scan:
    uses: ./.github/workflows/tf-security-scan.yml
    with: { module_path: modules/l4-lambda-baseline }
  plan:
    needs: security-scan
    uses: ./.github/workflows/tf-plan.yml
    with: { module_path: modules/l4-lambda-baseline, environment: "${{ inputs.environment }}" }
    secrets: inherit
  apply:
    needs: plan
    uses: ./.github/workflows/tf-apply.yml
    with:
      module_path: modules/l4-lambda-baseline
      environment: ${{ inputs.environment }}
      plan_artifact_name: tfplan-modules-l4-lambda-baseline-${{ inputs.environment }}-${{ github.run_id }}
    secrets: inherit
```

### Layer Build Procedure

PRD-41 owns the layer package build and upload path. Before the Terraform apply for `modules/l4-lambda-baseline`, the CI pipeline must build both layer zip files, upload them to the PRD-40 artifacts bucket under the deterministic keys `lambda/layers/dependencies/{version}.zip` and `lambda/layers/platform-sdk/{version}.zip`, and then bump the matching version input so Terraform references the newly uploaded object:

```bash
# Build dependencies layer
pip install \
  boto3==1.34.0 botocore==1.34.0 pydantic==2.5.0 requests==2.31.0 \
  aws-lambda-powertools==2.30.0 aws-xray-sdk==2.12.0 \
  --target dist/dependencies-layer/python/lib/python3.12/site-packages \
  --platform manylinux2014_x86_64 --only-binary=:all:
cd dist/dependencies-layer && zip -r ../dependencies-layer.zip . && cd ../..
aws s3 cp dist/dependencies-layer.zip \
  "s3://${ARTIFACTS_BUCKET}/lambda/layers/dependencies/${DEPENDENCIES_LAYER_VERSION}.zip" \
  --sse aws:kms --sse-kms-key-id "${ENV_KMS_KEY_ARN}"

# Build platform SDK layer
mkdir -p dist/platform-sdk-layer/python/lib/python3.12/site-packages
cp -r sdk/connect_pbx dist/platform-sdk-layer/python/lib/python3.12/site-packages/
cd dist/platform-sdk-layer && zip -r ../platform-sdk-layer.zip . && cd ../..
aws s3 cp dist/platform-sdk-layer.zip \
  "s3://${ARTIFACTS_BUCKET}/lambda/layers/platform-sdk/${PLATFORM_SDK_LAYER_VERSION}.zip" \
  --sse aws:kms --sse-kms-key-id "${ENV_KMS_KEY_ARN}"
```

### Rollback Procedure
Layer version rollback: update `dependencies_layer_version` or `platform_sdk_layer_version` variable to the previous version string and apply. All Lambda functions referencing the layer ARN output will automatically point to the previous version after re-apply.

---

## 14. OBSERVABILITY SPECIFICATION

### Alarms

**ALARM-40-01: Lambda Layer Size Approaching Limit**
- Source: Custom check in PRD-41 build pipeline
- Threshold: Unzipped layer size > 200 MB (limit is 250 MB)
- Severity: High — if layer exceeds 250 MB, all Lambda deployments fail

**ALARM-40-02: Platform SDK Import Error**
- Source: CloudWatch Logs Insights query for `"ImportError" AND "connect_pbx"` across all Lambda log groups
- Threshold: > 0 occurrences in 5 minutes
- Severity: Critical — SDK layer not loading in one or more functions

---

## 15. ACCEPTANCE CRITERIA

| ID | Criterion | Verification Method |
|---|---|---|
| AC-40-01 | Dependencies layer exists in Lambda | `aws lambda list-layer-versions --layer-name {org}-dependencies-{env}` |
| AC-40-02 | Platform SDK layer exists | `aws lambda list-layer-versions --layer-name {org}-platform-sdk-{env}` |
| AC-40-03 | Test Lambda imports boto3 from dependencies layer | Deploy test function with layer; confirm `import boto3` succeeds |
| AC-40-04 | Test Lambda imports connect_pbx from SDK layer | Deploy test function; confirm `from connect_pbx.logger import Logger` succeeds |
| AC-40-05 | Logger produces structured JSON output | Invoke test Lambda; confirm CloudWatch log is valid JSON with all required fields |
| AC-40-06 | events.publish() produces correct envelope | Invoke test Lambda calling publish(); confirm EventBridge event has correct source and detail-type |
| AC-40-07 | dynamodb.get_contact() returns None for unknown ID | Invoke test Lambda; confirm None returned for non-existent ContactId |
| AC-40-08 | TransientError triggers Lambda retry | Invoke test Lambda that raises TransientError; confirm Lambda retried |
| AC-40-09 | PermanentError is terminal and respects the configured DLQ policy | Invoke test Lambda that raises PermanentError; confirm the configured DLQ receives the event after the source retry policy is exhausted |
| AC-40-10 | All execution roles have permission boundary | Inspect test execution role — confirm boundary ARN matches PRD-02 output |
| AC-40-11 | Baseline env vars present in test Lambda | Invoke test Lambda; confirm baseline variables accessible via config.baseline_env_vars() |
| AC-40-12 | Layer packages remain under documented size limits | Confirm dependencies layer < 50 MB unzipped and SDK layer < 5 MB unzipped before publish |
| AC-40-13 | tfsec and checkov pass | Clean scan output |

---

## 16. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Layer size exceeds 250 MB unzipped as dependencies grow | Low | Critical | ALARM-40-01 triggers at 200 MB. Split into multiple layers if needed. Remove unused packages from requirements.txt. |
| Platform SDK breaking change affects all Lambda functions | Medium | High | SDK is versioned via `platform_sdk_layer_version`. Test in dev before bumping in staging/prod. Breaking changes require a new version and coordinated Lambda function updates. |
| boto3 version in layer conflicts with Lambda runtime boto3 | Low | Medium | Lambda runtime includes boto3 but layer takes precedence when same path. Pin layer boto3 to a version tested against all functions. |
| connect_pbx.dynamodb dataclass fields drift from actual DynamoDB schema | Medium | Medium | Dataclass fields are typed. PRD-31 schema changes require coordinated SDK version bump. Schema is the authoritative source — SDK follows PRD-31. |

---

## 17. OPEN QUESTIONS

| ID | Question | Status |
|---|---|---|
| OQ-40-01 | Should the platform SDK be published to a private CodeArtifact repository rather than distributed as a Lambda Layer? This would allow versioned pip installs rather than layer attachment. Layer approach is simpler and sufficient for this platform's scale. | Open — Layer approach adopted. CodeArtifact can be added if the SDK is needed outside Lambda (e.g., in containers). |
| OQ-40-02 | Should arm64 architecture be used for all Lambda functions to reduce cost (~20% cheaper)? arm64 is compatible with Python 3.12 and all platform dependencies. | Open — x86_64 adopted as default for compatibility. arm64 can be enabled per function in the adopting service PRD. |

---

## 18. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.3.0 | 2026-04-06 | — | Implementation-readiness hardening: made the artifacts bucket environment-safe for workspace-scoped deployments, removed duplicate Terraform ownership of layer zip uploads, pinned dependency versions exactly, added the missing account-baseline sample contracts, and aligned CI examples with the PRD-41 versioned artifact flow. |
| 1.0.0 | 2026-03-16 | — | Initial release. Two-layer architecture. Platform SDK with six modules. Standard execution role pattern. Standard environment variable set. Canonical Lambda handler pattern documented. |
| 1.1.0 | 2026-03-30 | — | Normalized PRD-40 into an opt-in shared Lambda platform rather than a universal prerequisite. Moved central artifacts-bucket responsibility from PRD-30 into PRD-40 and clarified prefix ownership and optional integration points for PRD-20 and PRD-31. |
| 1.2.0 | 2026-04-05 | — | Added repo-owned modularity/governance metadata, split baseline env vars from optional integration fragments, aligned backend/state-key/provider examples to current manifest/catalog conventions, and corrected logger/config/DLQ sample behavior. |
