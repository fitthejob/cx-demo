# PRD-00 — Terraform State & Backend Bootstrap

---

## 1. METADATA

| Field | Value |
|---|---|
| **PRD ID** | PRD-00 |
| **Version** | 1.3.0 |
| **Status** | Approved |
| **Author** | — |
| **Last Updated** | 2026-03-21 |
| **Layer** | 0 — Platform Foundation |
| **Depends On** | None — this is the root PRD |
| **Blocks** | All other PRDs |
| **Optional** | No |

### Amendment Log (v1.0.0 → v1.2.0)

| Ref | Section | Change | Reason |
|---|---|---|---|
| AMD-00-07 | §2, §5, §8, §11, §12 | Clarified that the current backend layout is the live dev checkpoint baseline, not the only future enterprise topology. Added forward-compatible wording for expanded state-key conventions without requiring migration of existing state. | Live system through PRD-13 must remain stable; future scale options must stay additive and non-breaking. |
| AMD-00-01 | FR-003, §7, §8, §11 | KMS architecture revised. PRD-00 provisions bootstrap key only. Per-environment keys moved to PRD-02. | Decision: separate KMS key per environment for blast radius isolation. Per-object key specification at S3 backend block level. |
| AMD-00-02 | §10 | Downstream consumption note added clarifying that environment KMS keys come from PRD-02 remote state, not PRD-00. | Follows from AMD-00-01. |
| AMD-00-03 | §16 OQ-00-01 | Closed. Object Lock deferred to PRD-140 (Compliance Hardening, optional Layer 14). | Decision: versioning is sufficient baseline. Object Lock is a compliance hardening concern. |
| AMD-00-04 | §16 OQ-00-02 | Closed. Separate key per environment confirmed. | Decision recorded. |
| AMD-00-05 | FR-010, FR-011, §3, §7, §8 | OIDC architecture simplified. Removed intermediate OIDC role and role chaining. Execution role now trusts the GitHub OIDC provider directly via `AssumeRoleWithWebIdentity`. Trust policy accepts both branch-scoped and environment-scoped sub claims. | AWS best practice for machine workloads: single direct trust eliminates an unnecessary STS hop, avoids halved session duration from role chaining, and removes an intermediate role that held no permissions. The `configure-aws-credentials` action natively handles OIDC token exchange in a single step. |
| AMD-00-06 | §8, §14 | Execution role IAM policies expanded with full read permissions required by the Terraform AWS provider during state refresh (S3 bucket attribute reads, KMS key policy reads, DynamoDB backup status reads). | Terraform AWS provider v6 reads additional S3/KMS/DynamoDB attributes during `terraform plan` refresh that were not covered by the original least-privilege policy. |

---

## 2. CONTEXT & PROBLEM STATEMENT

### Why This Service Exists

Every Terraform-managed resource in this platform requires a backend to store state files and a locking mechanism to prevent concurrent modifications. Without this foundation, no other PRD can be safely executed. State corruption or concurrent apply collisions on any downstream PRD would have cascading effects across the entire platform.

This PRD is intentionally minimal in scope. It provisions exactly the infrastructure required to support all subsequent Terraform operations — nothing more. It is the only PRD where a portion of the bootstrap sequence is executed manually or via a one-time script rather than through the standard CI/CD pipeline, because the CI/CD pipeline itself depends on this state backend existing.

**Live Dev Checkpoint Note:**
As of this revision, the platform is already deployed in a live development state through PRD-13. The backend model defined here is the active baseline and must be preserved unless a future change is strictly additive or required to prevent breakage. This PRD therefore documents the currently deployed backend shape as the dev checkpoint foundation, while leaving room for future enterprise expansion without requiring immediate migration of state, buckets, or IAM roles.

### What Problem It Solves

- Provides a durable, encrypted, versioned, centralized location for all Terraform state files
- Prevents concurrent `terraform apply` operations from corrupting shared state
- Establishes the S3 bucket and DynamoDB table naming conventions that all subsequent PRDs reference
- Creates the workspace isolation pattern that separates per-environment state without duplicating backend configuration
- Defines the IAM role that GitHub Actions assumes to interact with AWS — the trust boundary between the CI/CD system and the AWS account
- Provisions the bootstrap-scoped KMS key for encrypting the bootstrap state object itself

### How It Fits the Overall Architecture

PRD-00 has no EventBridge integration, no Lambda functions, and no application logic. It is pure infrastructure plumbing. Its outputs are consumed by every other module via `-backend-config` flags at init time and `data "terraform_remote_state"` blocks. It is the only PRD whose initial apply is performed outside of the GitHub Actions pipeline — because the pipeline cannot exist before the state backend does.

**KMS Key Responsibility Boundary:**
PRD-00 provisions one KMS key: the bootstrap key, used exclusively to encrypt the bootstrap module's own state object. Per-environment KMS keys (dev, staging, prod) are provisioned by PRD-02 and referenced at the S3 backend object level via the `kms_key_id` parameter in each workspace's backend configuration. This provides full per-environment encryption isolation without requiring separate S3 buckets.

---

## 3. GOALS

### Goals

- Provision the S3 bucket for Terraform state storage with versioning, encryption, and access controls
- Provision the DynamoDB table for state locking
- Provision the bootstrap-scoped KMS key for bootstrap state encryption only
- Define the workspace naming convention for environment isolation
- Provision the GitHub Actions OIDC identity provider for keyless CI/CD authentication
- Provision a single Terraform execution IAM role that trusts the GitHub OIDC provider directly, with least-privilege boundaries
- Document the one-time bootstrap sequence precisely so it is reproducible

### Non-Goals

- This PRD does not provision per-environment KMS keys (PRD-02)
- This PRD does not configure GitHub Actions workflows (PRD-01)
- This PRD does not establish VPCs, security groups, or networking
- This PRD does not configure KMS keys for application data (PRD-02)
- This PRD does not provision monitoring or alerting
- This PRD does not implement S3 Object Lock or WORM controls. If those controls are ever required, they are handled as manual change-controlled procedures documented in PRD-140 rather than programmed here.

---

## 4. PERSONAS & USER STORIES

### Personas

**Platform Engineer** — The sole developer responsible for deploying and maintaining the platform. Executes the bootstrap sequence and owns the state backend infrastructure.

**GitHub Actions Runner** — The automated CI/CD agent that assumes the Terraform execution role directly via OIDC to execute `terraform plan` and `terraform apply` on behalf of the platform engineer.

**Auditor** — A SOC 2 or PCI auditor who requires evidence that state files are encrypted, access-controlled, and versioned.

### User Stories

| ID | Persona | Story | Acceptance Criterion |
|---|---|---|---|
| US-00-01 | Platform Engineer | As the platform engineer, I want a single command to bootstrap the state backend so that I can begin using Terraform for all subsequent PRDs | Bootstrap script completes without error and state bucket is accessible |
| US-00-02 | Platform Engineer | As the platform engineer, I want state isolated per environment so that a failed dev apply cannot corrupt prod state | Separate S3 keys per workspace, separate DynamoDB lock entries per workspace |
| US-00-03 | Platform Engineer | As the platform engineer, I want per-environment KMS key isolation so that a key compromise in dev cannot expose prod state | Each environment's backend block specifies its own KMS key ARN from PRD-02 |
| US-00-04 | GitHub Actions Runner | As the CI/CD pipeline, I want to authenticate to AWS without long-lived credentials so that secrets are never stored in GitHub | OIDC federation works, no AWS access keys stored in GitHub secrets |
| US-00-05 | Auditor | As an auditor, I want evidence that state files are encrypted at rest and access is logged so that I can verify PCI and SOC 2 controls | S3 bucket has SSE-KMS, S3 server access logging enabled, bucket policy denies non-HTTPS |

---

## 5. FUNCTIONAL REQUIREMENTS

### FR-001 — State Bucket Provisioning
The system must provision a single S3 bucket to store all Terraform state files across all environments and modules in the current deployed baseline. The bucket name must follow the convention `{org}-tfstate-{account_id}` to guarantee global uniqueness across AWS.

This single-bucket model is the approved live dev checkpoint architecture. Future enterprise topologies may introduce additional backend segmentation if scaling, governance, or account-boundary requirements justify it, but such expansion must be additive and must not require redesign of the current live backend as a prerequisite.

### FR-002 — State Bucket Versioning
The state bucket must have S3 versioning enabled. This allows recovery from accidental state deletion or corruption by restoring a previous state version. Versioning is the baseline immutability control. S3 Object Lock is explicitly out of scope for this PRD; if ever required, it is handled as a manual change-controlled control documented in PRD-140 rather than as Terraform-managed baseline behavior.

### FR-003 — State Bucket Encryption
The state bucket must have a default encryption configuration using SSE-KMS with the bootstrap KMS key provisioned in this PRD. This default applies to the bootstrap state object. Per-environment state objects are encrypted using environment-specific KMS keys provisioned in PRD-02, specified at write time via the `kms_key_id` parameter in each workspace's Terraform backend block. The bucket policy must deny any `PutObject` request that does not specify SSE-KMS encryption, ensuring no state object can ever be written unencrypted regardless of which KMS key is specified.

### FR-004 — State Bucket Access Logging
The state bucket must have S3 server access logging enabled, writing logs to a dedicated access-logs bucket within the same account. The access-logs bucket must use SSE-S3 (AES-256) default encryption, as AWS S3 server access log delivery does not support KMS-encrypted destination buckets. The access-logs bucket must also have public access blocked and an HTTPS-only bucket policy. This satisfies SOC 2 access audit requirements from day one of deployment.

### FR-005 — State Bucket Public Access Block
The state bucket must have all four public access block settings enabled. The bucket must have a bucket policy that explicitly denies any request not using HTTPS (aws:SecureTransport condition).

### FR-006 — DynamoDB Lock Table
The system must provision a DynamoDB table named `{org}-tfstate-lock` with `LockID` as the string hash key, using PAY_PER_REQUEST billing mode. This table is the sole mechanism for preventing concurrent Terraform operations across all modules and environments. Lock entries are namespaced by the full S3 state key, ensuring dev and prod locks never collide.

### FR-007 — DynamoDB Encryption
The DynamoDB lock table must be encrypted using the bootstrap KMS key. Lock table data is non-sensitive (it contains workspace paths and lock metadata only) but encryption is applied for consistency and compliance posture.

### FR-008 — Bootstrap KMS Key
The system must provision one KMS customer-managed key scoped exclusively to encrypting the bootstrap module's own state object. This key must have automatic annual rotation enabled and a deletion window of 14 days minimum. This key is not used by any other module — it is the root key that makes the bootstrap state itself auditable and recoverable.

### FR-009 — OIDC Identity Provider
The system must configure the GitHub Actions OIDC identity provider (`token.actions.githubusercontent.com`) in the AWS account, enabling keyless, credential-free authentication from GitHub Actions workflow runs.

### FR-010 — Terraform Execution IAM Role (Direct OIDC Trust)
The system must provision a single IAM role for Terraform execution that GitHub Actions assumes directly via OIDC (`sts:AssumeRoleWithWebIdentity`). The trust policy must accept the GitHub OIDC provider as a federated principal, restricted to a specific GitHub organization and repository. The trust policy must accept both branch-scoped sub claims (`ref:refs/heads/{branch}`) and environment-scoped sub claims (`environment:{env}`) to support workflows that use GitHub Actions environments. The role's maximum session duration must be set to 4 hours to accommodate the longest expected Terraform apply operations. The `aws-actions/configure-aws-credentials` action handles the OIDC token exchange in a single step — no intermediate role or role chaining is required.

### FR-011 — Removed (consolidated into FR-010)
Previously specified a separate OIDC intermediary role with role chaining to the execution role. This has been consolidated into FR-010. The execution role now trusts the OIDC provider directly, eliminating the intermediate role. This follows AWS best practice for machine workloads: a single direct trust avoids an unnecessary STS hop and the halved session duration that role chaining imposes.

### FR-012 — Workspace Isolation
The state backend must support Terraform workspaces. In the current deployed baseline, each environment uses a named workspace. State objects are written to a key path following the pattern `{workspace}/{module_name}/terraform.tfstate`, ensuring complete isolation between environments and between modules within an environment.

For the live dev checkpoint and current promotion flow, the expected workspaces are `dev`, `staging`, and `prod`. These names are the active baseline examples, not a permanent architectural limit. If future enterprise expansion requires additional topology dimensions such as region, instance group, market, or account role, new state-key conventions may be introduced prospectively for those deployments without requiring migration of existing state objects.

### FR-013 — Bootstrap Script
A one-time bootstrap script must be provided that provisions the state backend resources using local state, then migrates the bootstrap module's state to the newly created remote backend. The script must be idempotent — running it twice must not create duplicate resources or errors. The script must validate that remote state is readable before exiting successfully.

---

## 6. NON-FUNCTIONAL REQUIREMENTS

### Availability
S3 and DynamoDB are AWS-managed services with 99.99% availability SLAs. No additional HA configuration is required at this layer.

### Durability
S3 provides 99.999999999% (11 nines) object durability. Versioning provides an additional recovery layer. Per-environment KMS key isolation (PRD-02) ensures that a key compromise in one environment does not affect others.

### Latency
Not applicable. State backend operations are not in the critical path of telephony operations.

### Scale
The state backend scales automatically with AWS-managed services. No capacity planning is required regardless of platform size or number of modules.

### Security
- State files may contain sensitive resource attributes including ARNs, connection strings, and resource IDs. KMS encryption at rest is mandatory for all state objects.
- HTTPS-only access is enforced via bucket policy.
- Access is restricted to the Terraform execution role and the platform engineer's IAM identity only.
- Per-environment KMS keys (PRD-02) provide cryptographic isolation between environments.

### Compliance Touch Points

| Requirement | Control | Evidence |
|---|---|---|
| PCI-DSS Req 3.5 | KMS encryption of state files | S3 encryption configuration, KMS key policy |
| PCI-DSS Req 4.1 | HTTPS-only bucket policy | Bucket policy document |
| PCI-DSS Req 10.2 | S3 server access logging | Access log bucket contents |
| SOC 2 CC6.1 | IAM role restriction on state access | IAM role and bucket policy |
| SOC 2 CC6.7 | Encryption at rest and in transit | KMS config, HTTPS enforcement |
| SOC 2 CC7.2 | Access audit logging | S3 server access logs |

---

## 7. ARCHITECTURE

### Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                       AWS ACCOUNT                           │
│                                                             │
│  ┌───────────────────────┐   ┌────────────────────────────┐ │
│  │     S3 Bucket         │   │    DynamoDB Table          │ │
│  │  {org}-tfstate-{acct} │   │  {org}-tfstate-lock        │ │
│  │                       │   │                            │ │
│  │  Versioning:   ON     │   │  HashKey: LockID (S)       │ │
│  │  Default SSE:  KMS    │   │  Billing: PAY_PER_REQUEST  │ │
│  │  Access Log:   ON     │   │  Encryption: KMS           │ │
│  │  Public Access: OFF   │   │  (bootstrap key)           │ │
│  │  HTTPS Only:   ON     │   └────────────────────────────┘ │
│  │                       │                                  │
│  │  State Key Structure: │   ┌────────────────────────────┐ │
│  │  bootstrap/…tfstate   │   │   KMS Key (bootstrap only) │ │
│  │  dev/{module}/…       │◄──│   {org}-tfstate-bootstrap  │ │
│  │  staging/{module}/…   │   │   Rotation: Annual         │ │
│  │  prod/{module}/…      │   │   Deletion Window: 14 days │ │
│  └───────────────────────┘   │                            │ │
│                              │   NOTE: dev/staging/prod   │ │
│  ┌───────────────────────┐   │   KMS keys provisioned     │ │
│  │  S3 Access Logs       │   │   in PRD-02, referenced    │ │
│  │  Bucket               │   │   via kms_key_id in each   │ │
│  │  90-day retention     │   │   workspace backend block  │ │
│  └───────────────────────┘   └────────────────────────────┘ │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                      IAM                             │   │
│  │                                                      │   │
│  │  OIDC Provider                                       │   │
│  │  token.actions.githubusercontent.com                 │   │
│  │                                                      │   │
│  │  Role: {org}-terraform-execution-role                │   │
│  │  Trust: GitHub OIDC provider (direct, no chaining)   │   │
│  │  Sub claims: branch-scoped + environment-scoped      │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

GitHub Actions Runner
        │
        │ AssumeRoleWithWebIdentity (OIDC — single step, no stored credentials)
        ▼
{org}-terraform-execution-role
        │
        ├──► S3 GetObject / PutObject (state read/write, per-environment key)
        ├──► S3 ListBucket + bucket attribute reads (workspace enumeration)
        ├──► DynamoDB GetItem / PutItem / DeleteItem (lock acquire/release)
        └──► KMS Decrypt / GenerateDataKey (state encryption/decryption)

Per-Environment KMS Key Flow (post PRD-02):
        │
        ├──► dev state objects     ◄── dev KMS key (PRD-02)
        ├──► staging state objects ◄── staging KMS key (PRD-02)
        └──► prod state objects    ◄── prod KMS key (PRD-02)
```

### Integration Points

PRD-00 has **no EventBridge integration**. It produces no events and consumes no events. All outputs are Terraform module outputs consumed by backend configuration blocks and remote state data sources in downstream PRDs.

### Headless Contract

This service exposes the following contract to all downstream PRDs:

| Output | Type | Description | Consumer |
|---|---|---|---|
| `state_bucket_name` | string | S3 bucket name for backend blocks | All PRDs |
| `state_bucket_arn` | string | S3 bucket ARN for IAM policies | PRD-02, PRD-03 |
| `lock_table_name` | string | DynamoDB table name for backend blocks | All PRDs |
| `lock_table_arn` | string | DynamoDB table ARN for IAM policies | PRD-02 |
| `bootstrap_kms_key_arn` | string | Bootstrap KMS key ARN (bootstrap state only) | PRD-02 (for reference) |
| `terraform_execution_role_arn` | string | Execution role ARN — GitHub Actions assumes this directly via OIDC | PRD-01 |
| `github_oidc_provider_arn` | string | OIDC provider ARN | PRD-01 (reference only) |

---

## 8. TERRAFORM SPECIFICATION

### Module Path

```
connect-pbx/
└── modules/
    └── bootstrap/              # PRD-00
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        ├── kms.tf              # Bootstrap KMS key only
        ├── s3.tf               # State bucket + access logs bucket
        ├── dynamodb.tf         # Lock table
        ├── iam.tf              # OIDC provider, execution role (direct OIDC trust)
        └── scripts/
            └── bootstrap.sh    # One-time execution script
```

### Key Resources Declared

```hcl
# kms.tf — bootstrap key only
resource "aws_kms_key" "tfstate_bootstrap" {
  description             = "Terraform state encryption — bootstrap module only"
  deletion_window_in_days = 14
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "TerraformExecutionAccess"
        Effect = "Allow"
        Principal = { AWS = aws_iam_role.terraform_execution.arn }
        Action = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey", "kms:GetKeyPolicy", "kms:GetKeyRotationStatus", "kms:ListResourceTags"]
        Resource = "*"
      }
    ]
  })

  tags = { PRD = "PRD-00", Scope = "bootstrap-only" }
}

resource "aws_kms_alias" "tfstate_bootstrap" {
  name          = "alias/${var.org_name}-tfstate-bootstrap"
  target_key_id = aws_kms_key.tfstate_bootstrap.key_id
}

# s3.tf
resource "aws_s3_bucket" "tfstate" { }
resource "aws_s3_bucket_versioning" "tfstate" { }
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" { }
resource "aws_s3_bucket_public_access_block" "tfstate" { }
resource "aws_s3_bucket_policy" "tfstate" { }
resource "aws_s3_bucket_logging" "tfstate" { }
resource "aws_s3_bucket" "tfstate_logs" { }
resource "aws_s3_bucket_public_access_block" "tfstate_logs" { }
resource "aws_s3_bucket_lifecycle_configuration" "tfstate_logs" { }

# dynamodb.tf
resource "aws_dynamodb_table" "tfstate_lock" { }

# iam.tf
resource "aws_iam_openid_connect_provider" "github" { }
resource "aws_iam_role" "terraform_execution" { }           # Direct OIDC trust — no intermediate role
resource "aws_iam_role_policy" "terraform_execution_s3" { }
resource "aws_iam_role_policy" "terraform_execution_dynamo_db" { }
resource "aws_iam_role_policy" "terraform_execution_kms" { }
resource "aws_iam_role_policy" "terraform_execution_iam" { }
```

### Variables

```hcl
variable "org_name" {
  type        = string
  description = "Organization identifier used in all resource names."
}

variable "aws_region" {
  type        = string
  description = "AWS region for all state backend resources."
  default     = "us-east-1"
}

variable "github_org" {
  type        = string
  description = "GitHub organization name for OIDC trust policy scoping."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name for OIDC trust policy scoping."
}

variable "allowed_branches" {
  type        = list(string)
  description = "GitHub branches permitted to assume the execution role via OIDC (branch-scoped sub claims)."
  default     = ["main", "develop"]
}

variable "terraform_execution_role_boundary_arn" {
  type        = string
  description = "Optional permissions boundary ARN for the Terraform execution role."
  default     = ""
}

variable "deployment_profile" {
  description = "Platform-wide deployment profile. Authoritative definition — all modules inherit this structure."
  type = object({
    mode             = string
    instance_count   = number
    multi_az         = bool
    cross_region     = bool
    agent_capacity   = string
    account_topology = string
    hub_account_id   = string
    org_id           = string
    shared_bus_arn   = string
    optional_layers = object({
      sso_enabled        = bool
      crm_enabled        = bool
      compliance_enabled = bool
    })
  })
  default = {
    mode             = "single"
    instance_count   = 1
    multi_az         = false
    cross_region     = false
    agent_capacity   = "small"
    account_topology = "standalone"
    hub_account_id   = ""
    org_id           = ""
    shared_bus_arn   = ""
    optional_layers = {
      sso_enabled        = false
      crm_enabled        = false
      compliance_enabled = false
    }
  }
}
```

### Outputs

```hcl
output "state_bucket_name" {
  description = "S3 bucket name. Used in backend blocks of all downstream PRDs."
  value       = aws_s3_bucket.tfstate.bucket
}

output "state_bucket_arn" {
  description = "S3 bucket ARN. Used in IAM policies in PRD-02."
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "DynamoDB lock table name. Used in backend blocks of all downstream PRDs."
  value       = aws_dynamodb_table.tfstate_lock.name
}

output "lock_table_arn" {
  description = "DynamoDB lock table ARN. Used in IAM policies in PRD-02."
  value       = aws_dynamodb_table.tfstate_lock.arn
}

output "bootstrap_kms_key_arn" {
  description = "Bootstrap-scoped KMS key ARN. Used for bootstrap state only. Per-environment keys in PRD-02."
  value       = aws_kms_key.tfstate_bootstrap.arn
}

output "terraform_execution_role_arn" {
  description = "Terraform execution IAM role ARN. Consumed by PRD-01 GitHub Actions workflows."
  value       = aws_iam_role.terraform_execution.arn
}

output "github_oidc_provider_arn" {
  description = "GitHub OIDC provider ARN. Consumed by PRD-01 for workflow trust configuration."
  value       = aws_iam_openid_connect_provider.github.arn
}
```

### Backend Configuration

This project uses **partial backend configuration**. All modules permanently contain an empty `backend "s3" {}` block in `main.tf` — no account-specific values are ever hardcoded in the repository. Backend values are supplied at runtime via `-backend-config` flags.

#### Bootstrap and All Downstream Modules — Permanent backend block

```hcl
# main.tf — identical pattern in bootstrap and all downstream modules
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

`backend.tf` in each module contains only:

```
# Backend configuration is defined in main.tf
```

#### How backend values are supplied

| Context | How values are supplied |
|---|---|
| Bootstrap (first time) | `bootstrap.sh` generates `backend-<profile>.hcl`, init uses `-backend-config=backend-<profile>.hcl` |
| Local runs after bootstrap | `terraform init -backend-config=../bootstrap/backend-<profile>.hcl -backend-config="key=..."` |
| CI/CD (all modules) | `-backend-config` flags injected by GitHub Actions workflows via secrets |

`backend-*.hcl` files are gitignored and never committed. They are generated by `bootstrap.sh` and live only on the engineer's local machine.

### Workspace Naming Convention

The table below reflects the active dev checkpoint baseline:

| Environment | Workspace Name | Example State Key |
|---|---|---|
| Bootstrap | `default` | `bootstrap/terraform.tfstate` |
| Development | `dev` | `dev/l1-connect-instance/terraform.tfstate` |
| Staging | `staging` | `staging/l1-connect-instance/terraform.tfstate` |
| Production | `prod` | `prod/l1-connect-instance/terraform.tfstate` |

These workspace names are sufficient for the current live system. Future enterprise rollouts may extend the key naming model for new deployments where additional topology dimensions are required. Such expansion must be additive and must not force migration of the existing dev, staging, or prod state paths unless there is a demonstrated operational need.

### Environment Toggle Behavior

PRD-00 has no conditional resource creation. The state backend is identical regardless of deployment profile. The `deployment_profile` variable is declared here as the authoritative definition and propagated to all child modules. No child module redefines this variable's type or default — they only reference it.

For avoidance of doubt: in the currently deployed dev checkpoint, `deployment_profile` does not alter backend topology. Any future enterprise-specific backend segmentation would require an explicit follow-on decision and must be implemented in a backward-compatible manner.

---

## 9. EVENT SCHEMA

**PRD-00 produces no EventBridge events and consumes no EventBridge events.**

This is the only PRD with no event schema. The state backend is infrastructure plumbing with no application-level semantics.

---

## 10. API / INTERFACE CONTRACT

PRD-00 exposes no APIs. Its interface contract is exclusively Terraform outputs consumed by downstream `-backend-config` flags at init time and `data "terraform_remote_state"` blocks.

### Downstream Consumption Pattern

All subsequent PRDs reference PRD-00 outputs using the remote state data source pattern below. Note that the environment KMS key ARN for backend encryption comes from PRD-02, not PRD-00:

```hcl
# Pattern used in PRD-01 through PRD-142
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config = {
    bucket = "{org}-tfstate-{account_id}"
    key    = "bootstrap/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "account_baseline" {
  backend   = "s3"
  workspace = terraform.workspace   # resolves to dev | staging | prod
  config = {
    bucket = "{org}-tfstate-{account_id}"
    key    = "${terraform.workspace}/l0-account-baseline/terraform.tfstate"
    region = "us-east-1"
  }
}

locals {
  # Bootstrap outputs (infrastructure plumbing)
  state_bucket_name           = data.terraform_remote_state.bootstrap.outputs.state_bucket_name
  terraform_execution_role    = data.terraform_remote_state.bootstrap.outputs.terraform_execution_role_arn

  # Environment-specific outputs from PRD-02
  env_kms_key_arn             = data.terraform_remote_state.account_baseline.outputs.kms_key_arn
}
```

---

## 11. DATA MODEL

### State File Organization

The layout below reflects the currently deployed dev checkpoint:

```
s3://{org}-tfstate-{account_id}/
│
├── bootstrap/
│   └── terraform.tfstate           # Encrypted: bootstrap KMS key (PRD-00)
│
├── dev/
│   ├── l0-account-baseline/        # Encrypted: dev KMS key (PRD-02)
│   │   └── terraform.tfstate
│   ├── l0-audit-pipeline/
│   │   └── terraform.tfstate
│   ├── l0-cicd-pipeline/
│   │   └── terraform.tfstate
│   ├── l1-connect-instance/
│   │   └── terraform.tfstate
│   └── ... (one prefix per PRD)
│
├── staging/
│   └── ... (mirrors dev structure)  # Encrypted: staging KMS key (PRD-02)
│
└── prod/
    └── ... (mirrors dev structure)  # Encrypted: prod KMS key (PRD-02)
```

This structure is the active baseline for the live system. It should be treated as stable. Future enterprise expansions may add new prefixes or alternative key hierarchies for newly introduced topologies, but existing state paths should remain unchanged unless migration becomes operationally necessary.

### KMS Key Responsibility Map

| State Objects | KMS Key | Provisioned By |
|---|---|---|
| `bootstrap/terraform.tfstate` | `{org}-tfstate-bootstrap` | PRD-00 |
| `dev/**` | `{org}-tfstate-dev` | PRD-02 |
| `staging/**` | `{org}-tfstate-staging` | PRD-02 |
| `prod/**` | `{org}-tfstate-prod` | PRD-02 |

### Encryption Requirements

- Bootstrap state: SSE-KMS with bootstrap key (PRD-00)
- All environment state: SSE-KMS with environment-specific key (PRD-02)
- Bucket policy enforces KMS encryption on all PutObject requests
- KMS key rotation: Annual (automatic) on all keys
- KMS key deletion window: 14 days minimum on all keys

### Retention Policy

| Data | Retention | Mechanism |
|---|---|---|
| Current state files | Indefinite | No expiration on current versions |
| Previous state versions | 365 days | S3 lifecycle noncurrent version expiration |
| Access logs | 90 days | S3 lifecycle expiration on logs bucket |
| DynamoDB lock entries | TTL not set | Entries are deleted on lock release by Terraform |

---

## 12. CI/CD SPECIFICATION

### Bootstrap Sequence (One-Time Creation, Manual)

This sequence is executed to create the backend in a new AWS account by the platform engineer. After initial creation, PRD-00 resources are managed through normal Terraform workflows. The bootstrap script should not be used as a routine reconciliation path for an already-established backend, but it should remain safe to re-run for recovery, validation, or rebuild scenarios.

```bash
#!/bin/bash
# scripts/bootstrap.sh
# Prerequisites: AWS CLI configured, Terraform >= 1.14.0 installed
# Run from: connect-pbx/modules/bootstrap/

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_REGION:-us-east-1}"
echo "Bootstrapping account: ${ACCOUNT_ID}"

echo "[1/5] Initializing with local backend..."
terraform init -backend=false

echo "[2/5] Applying with local state..."
terraform apply -auto-approve -var-file="bootstrap.tfvars" -state="bootstrap.tfstate"

echo "[3/5] Capturing outputs..."
BUCKET_NAME=$(terraform output -state="bootstrap.tfstate" -raw state_bucket_name)
KMS_KEY_ARN=$(terraform output -state="bootstrap.tfstate" -raw bootstrap_kms_key_arn)
LOCK_TABLE=$(terraform output -state="bootstrap.tfstate" -raw lock_table_name)

echo "  State bucket:  ${BUCKET_NAME}"
echo "  Bootstrap key: ${KMS_KEY_ARN}"
echo "  Lock table:    ${LOCK_TABLE}"

echo "[4/5] Writing backend config file..."
cat > "backend-${AWS_PROFILE:-default}.hcl" <<EOF
bucket         = "${BUCKET_NAME}"
key            = "bootstrap/terraform.tfstate"
region         = "${REGION}"
encrypt        = true
kms_key_id     = "${KMS_KEY_ARN}"
dynamodb_table = "${LOCK_TABLE}"
EOF

echo "[5/5] Migrating state to remote backend..."
terraform init \
  -migrate-state \
  -force-copy \
  -backend-config="backend-${AWS_PROFILE:-default}.hcl"

echo ""
echo "Verifying remote state..."
terraform state list

echo ""
echo "Bootstrap complete."
echo "backend-${AWS_PROFILE:-default}.hcl is gitignored — do not commit it."
echo "Do NOT commit bootstrap.tfstate."
```

### Post-Bootstrap Pipeline

After bootstrap, PRD-00 resources are maintained via the GitHub Actions pipeline defined in PRD-01. All subsequent changes to IAM roles, KMS policies, or bucket configurations go through the standard PR → plan → apply workflow.

### Rollback Procedure

PRD-00 resources must never be destroyed in a running system. In the event of accidental destruction:

1. **DynamoDB table:** Recreate manually — no state dependency. Use identical table name and schema.
2. **S3 bucket:** Recreate with identical name and configuration. Restore state files from S3 versioning (current versions are retained unless the bucket itself was deleted).
3. **KMS key:** Cannot be recreated with the same key material. If destroyed, state files encrypted with that key are unrecoverable. This is why the 14-day deletion window alarm is critical — it provides a recovery window.
4. **After restoration:** Re-run `terraform init` in each dependent module to reconnect to the restored backend.

---

## 13. OBSERVABILITY SPECIFICATION

### CloudWatch Metrics

| Metric | Source | Purpose |
|---|---|---|
| `NumberOfItemsWithExpiredUserKeys` | KMS | Detect key rotation failures |
| S3 bucket size (Storage Lens) | S3 | Detect unexpected state growth |
| DynamoDB consumed capacity | DynamoDB | Detect lock table abuse or runaway locking |

### Alarms

**ALARM-00-01: KMS Bootstrap Key Pending Deletion**
- Source: CloudTrail event filter on `ScheduleKeyDeletion` for the bootstrap KMS key ARN
- Action: SNS notification to platform engineer
- Severity: Critical
- Rationale: If the bootstrap KMS key is deleted, the bootstrap state file becomes permanently unreadable, breaking all module backend authentication

**ALARM-00-02: State Bucket HTTPS Denial Spike**
- Source: S3 server access logs (HTTP 403, non-HTTPS requests)
- Threshold: > 5 denied requests in 5 minutes
- Severity: High
- Rationale: Indicates misconfiguration, probing, or an application attempting unencrypted state access

**ALARM-00-03: DynamoDB Lock Table Sustained Lock**
- Source: DynamoDB — item count > 0 sustained for > 30 minutes
- Severity: Medium
- Rationale: Indicates a Terraform process may have crashed without releasing a lock, blocking all subsequent applies

### Log Retention

| Log Type | Destination | Retention |
|---|---|---|
| S3 server access logs | `{org}-tfstate-logs` bucket | 90 days |
| CloudTrail (KMS, S3 API calls) | PRD-03 (Audit Pipeline) | Per PRD-03 policy |

### SOC 2 / PCI Evidence Artifacts

| Artifact | Location | Collection Frequency |
|---|---|---|
| S3 server access logs | `s3://{org}-tfstate-logs/` | Continuous |
| KMS key usage events | CloudTrail (PRD-03) | Continuous |
| Bucket policy document | S3 bucket policy API | On change (via Config, PRD-03) |
| IAM role definitions | CloudTrail (PRD-03) | On change |

---

## 14. ACCEPTANCE CRITERIA

### Definition of Done

| ID | Criterion | Verification Method |
|---|---|---|
| AC-00-01 | S3 state bucket exists with versioning enabled | `aws s3api get-bucket-versioning` → `Enabled` |
| AC-00-02 | State bucket default encryption is SSE-KMS with bootstrap key | `aws s3api get-bucket-encryption` → bootstrap KMS key ARN |
| AC-00-03 | Bucket policy denies non-HTTPS requests | `curl http://` against bucket URL → 403 |
| AC-00-04 | Bucket policy denies non-KMS PutObject | Attempt `aws s3 cp` without `--sse aws:kms` → access denied |
| AC-00-05 | State bucket blocks all public access | `aws s3api get-public-access-block` → all four fields `true` |
| AC-00-06 | DynamoDB lock table exists with correct schema | `aws dynamodb describe-table` → `LockID` string hash key |
| AC-00-07 | DynamoDB table encrypted with bootstrap KMS key | `aws dynamodb describe-table` → SSEDescription KMS key ARN |
| AC-00-08 | GitHub OIDC provider registered | `aws iam list-open-id-connect-providers` → GitHub URL present |
| AC-00-09 | GitHub Actions assumes execution role via OIDC from target repo only | Test workflow run succeeds; run from fork fails |
| AC-00-10 | Bootstrap remote state readable after migration | `terraform state list` returns resources from remote backend |
| AC-00-11 | Concurrent apply blocked by DynamoDB lock | Second `terraform apply` returns lock acquisition error |
| AC-00-12 | S3 access logging active | Log entries appear in logs bucket within 15 minutes |
| AC-00-13 | Bootstrap KMS key has rotation enabled | `aws kms get-key-rotation-status` → `true` |
| AC-00-14 | Bootstrap script is safe for controlled re-execution | A second run in a recovery or validation scenario completes without duplicate resources or destructive side effects |
| AC-00-15 | `tfsec` passes with zero HIGH/CRITICAL findings | `tfsec modules/bootstrap/` → clean output |
| AC-00-16 | `checkov` passes with zero HIGH/CRITICAL findings | `checkov -d modules/bootstrap/` → clean output |

---

## 15. RISKS & MITIGATIONS

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| State bucket name collision (S3 global namespace) | Low | High | Include AWS account ID in bucket name — guarantees uniqueness |
| Bootstrap KMS key accidentally scheduled for deletion | Low | Critical | ALARM-00-01 triggers on `ScheduleKeyDeletion`; 14-day window provides recovery time |
| GitHub OIDC trust policy too permissive | Medium | High | Execution role trust policy restricts to specific org, repo, branches, and environments via `StringLike` condition on `token.actions.githubusercontent.com:sub` |
| State lock not released after crashed apply | Medium | Medium | Document `terraform force-unlock {lock_id}` runbook; ALARM-00-03 detects sustained locks |
| Bootstrap local state lost before remote migration | Low | High | Bootstrap script verifies remote state list before exit; keep local `.tfstate` until verified |
| Two engineers run bootstrap simultaneously | Low | High | Document as single-person, one-time operation; add calendar coordination note to bootstrap script header |
| Per-environment KMS key not yet provisioned when workspace backend first initializes | Medium | Medium | PRD-02 must be applied before any environment workspace is first initialized; document this dependency explicitly in PRD-02 |

---

## 16. OPEN QUESTIONS

| ID | Question | Status | Resolution |
|---|---|---|---|
| OQ-00-01 | Should the state S3 bucket use Object Lock for SOC 2 immutability? | **Closed** | Deferred to PRD-140 (optional Layer 14) as a manual change-controlled procedure only. S3 versioning is the baseline. Governance-mode or compliance-mode Object Lock is not programmed by Terraform in the baseline platform. |
| OQ-00-02 | Single shared KMS key vs. separate key per environment? | **Closed** | Separate key per environment confirmed. Bootstrap key in PRD-00; dev/staging/prod keys in PRD-02. Per-object `kms_key_id` in backend blocks provides isolation without requiring separate buckets. |
| OQ-00-03 | GitHub organization and repository name for OIDC trust policy? | **Open** | Required before PRD-00 apply. Placeholder values `{github_org}` and `{github_repo}` used throughout. Platform engineer to supply before first run. |

---

## 17. REVISION HISTORY

| Version | Date | Author | Notes |
|---|---|---|---|
| 1.0.0 | 2026-03-16 | — | Initial draft |
| 1.1.0 | 2026-03-16 | — | AMD-00-01: KMS architecture revised — bootstrap key only in PRD-00, per-environment keys moved to PRD-02. AMD-00-02: Downstream consumption note added. AMD-00-03: OQ-00-01 closed, Object Lock deferred to PRD-140. AMD-00-04: OQ-00-02 closed, separate key per environment confirmed. |
| 1.3.0 | 2026-04-06 | — | Clarified that any future Object Lock posture deferred to PRD-140 is manual change-controlled rather than Terraform-programmed. |
| 1.2.0 | 2026-03-21 | — | AMD-00-05: OIDC architecture simplified — removed intermediate OIDC role and role chaining, execution role trusts GitHub OIDC provider directly. AMD-00-06: Execution role policies expanded for Terraform AWS provider v6 refresh reads. |
