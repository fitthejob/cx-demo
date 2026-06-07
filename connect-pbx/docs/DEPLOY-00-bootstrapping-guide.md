# Bootstrap Guide - PRD-00 Terraform State Backend

This guide covers the one-time sequence to deploy the Terraform state backend and migrate to permanent remote state. Run it once per AWS account unless you are intentionally rebuilding from scratch.

## What this deploys

| Resource | Purpose |
|---|---|
| **S3 bucket** (`<org>-tfstate-<account_id>`) | Stores Terraform state for this account. Versioned, KMS-encrypted, TLS-enforced, and public access blocked. |
| **S3 bucket** (`<org>-tfstate-logs-<account_id>`) | Access logs for the state bucket. AES-256 encrypted with 90-day retention. |
| **KMS key** (`alias/<org>-tfstate-bootstrap`) | Encrypts the state bucket and S3 lockfiles. |
| **IAM OIDC provider** (GitHub) | Trust anchor for GitHub Actions OIDC. |
| **IAM role** (`<org>-github-actions-oidc`) | GitHub Actions role with permission to assume the Terraform execution role. |
| **IAM role** (`<org>-terraform-execution-role`) | Terraform execution role with S3 state access, KMS access, and IAM management under the org prefix. |

All resources are tagged `PRD = "PRD-00"`. No application infrastructure is deployed here.

## Prerequisites

- AWS CLI installed and pointed at the correct account: `aws sts get-caller-identity`
- Terraform `>= 1.6.0`
- GitHub org and repo names known
- `.gitignore` updated so `bootstrap.tfstate` and `bootstrap.tfvars` are never committed

## Prepare `bootstrap.tfvars`

Create `connect-pbx/modules/bootstrap/bootstrap.tfvars`:

```hcl
org_name    = "your-org-name"
github_org  = "your-github-org"
github_repo = "your-github-repo"
```

`aws_region` defaults to `us-east-1` unless overridden.

## Confirm Phase 1 backend

Before running the bootstrap script, `connect-pbx/modules/bootstrap/backend.tf` should still use the local backend:

```hcl
terraform {
  backend "local" {
    path = "bootstrap.tfstate"
  }
}
```

## Run bootstrap

```bash
cd connect-pbx/modules/bootstrap
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

The script performs:

| Stage | What happens |
|---|---|
| `1/5 - Init` | `terraform init` against the local backend |
| `2/5 - Apply` | Creates the S3 buckets, KMS key, and IAM roles |
| `3/5 - Capture outputs` | Reads `state_bucket_name` and `bootstrap_kms_key_arn` |
| `4/5 - Migrate` | Rewrites `backend.tf`, writes the local backend artifact, and runs `terraform init -migrate-state` |
| `5/5 - Verify` | Runs `terraform state list` against the remote backend |

After a successful run, the script also writes a profile-scoped backend artifact outside the repo:

- Windows Git Bash: `${LOCALAPPDATA}/connect-pbx/<github_repo>/bootstrap/backend-<aws_profile>.hcl`
- Fallback: `${HOME}/.connect-pbx/<github_repo>/bootstrap/backend-<aws_profile>.hcl`
- Override: `CONNECT_PBX_BOOTSTRAP_DIR`

That backend artifact is consumed by the dashboard and local runner scripts and should not be committed.

## Remote backend shape after migration

After migration, `backend.tf` should look like:

```hcl
terraform {
  backend "s3" {
    bucket       = "<org_name>-tfstate-<account_id>"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "<bootstrap_kms_key_arn>"
    use_lockfile = true
  }
}
```

The repo now uses **native S3 lockfiles** for state locking. Deprecated DynamoDB-based backend settings are no longer part of the active backend contract.

## Verify bootstrap

After the script completes:

```bash
terraform state list
aws s3 ls s3://<org_name>-tfstate-<account_id>/bootstrap/
aws kms get-key-rotation-status --key-id alias/<org_name>-tfstate-bootstrap
```

## Record outputs for downstream PRDs

```bash
terraform output
```

| Output | Consumed By |
|---|---|
| `state_bucket_name` | All downstream module backends |
| `state_bucket_arn` | IAM policies in downstream foundations |
| `bootstrap_kms_key_arn` | Reference output for later environment key work |
| `terraform_execution_role_arn` | GitHub Actions OIDC workflows |
| `github_oidc_provider_arn` | Workflow trust configuration |

## GitHub bootstrap secrets

After bootstrap, the repo can scaffold GitHub environments and sync only these bootstrap-owned secrets:

- `AWS_ACCOUNT_ID`
- `AWS_REGION`
- `STATE_BUCKET`
- `TF_EXEC_ROLE_ARN`

No DynamoDB lock-setting secret is part of the GitHub secret contract anymore.

## What comes next

| PRD | Depends on bootstrap outputs |
|---|---|
| **PRD-01** - GitHub Actions CI/CD | `terraform_execution_role_arn`, `github_oidc_provider_arn`, `state_bucket_name` |
| **PRD-02** - Account Baseline / KMS | `state_bucket_arn`, `bootstrap_kms_key_arn` |

## Recovery notes

### Stale S3 lockfile

If a Terraform process crashes and leaves a stale `.tflock` object behind, confirm no apply is still running. Then use `terraform force-unlock <lock_id>` if Terraform provides a lock ID, or remove the stale `.tflock` object only after confirming the lock is abandoned.

### Deleted state bucket

Recreate the bucket, re-enable versioning, re-apply encryption, and restore state objects from backup if available. Without backup, affected modules must be rebuilt with `terraform import`.

### KMS key scheduled for deletion

Cancel the deletion immediately:

```bash
aws kms cancel-key-deletion --key-id alias/<org_name>-tfstate-bootstrap
aws kms enable-key --key-id alias/<org_name>-tfstate-bootstrap
aws kms describe-key --key-id alias/<org_name>-tfstate-bootstrap --query 'KeyMetadata.KeyState'
```

### Complete teardown

For full teardown, migrate bootstrap state back to local, remove the S3 bucket `prevent_destroy` guards, empty the buckets, destroy via Terraform, then remove local state and backend artifacts. The bootstrap backend remains a manual teardown path because it owns the active state bucket.

## Acceptance checks

| Check | Command |
|---|---|
| Versioning enabled | `aws s3api get-bucket-versioning --bucket <bucket>` |
| Default encryption SSE-KMS | `aws s3api get-bucket-encryption --bucket <bucket>` |
| Public access blocked | `aws s3api get-public-access-block --bucket <bucket>` |
| S3 lockfile enabled in backend | `backend.tf` or the generated backend artifact includes `use_lockfile = true` |
| OIDC provider registered | `aws iam list-open-id-connect-providers` |
| KMS rotation enabled | `aws kms get-key-rotation-status --key-id alias/<org>-tfstate-bootstrap` |
| Remote state readable | `terraform state list` |
