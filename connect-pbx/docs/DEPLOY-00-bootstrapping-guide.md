# Bootstrap Guide — PRD-00 Terraform State Backend

This guide covers the one-time sequence to deploy the Terraform state backend and migrate to permanent remote state. This procedure is executed once per AWS account by the platform engineer. Do not re-run it unless rebuilding from scratch.

### What this deploys

| Resource | Purpose |
|---|---|
| **S3 bucket** (`<org>-tfstate-<account_id>`) | Stores all Terraform state files for this account. Versioned, KMS-encrypted, TLS-enforced, public access blocked. |
| **S3 bucket** (`<org>-tfstate-logs-<account_id>`) | Access logs for the state bucket. AES-256 encrypted, 90-day retention. |
| **KMS key** (`alias/<org>-tfstate-bootstrap`) | Encrypts the state bucket and DynamoDB table. Bootstrap-scoped — per-environment keys are provisioned later in PRD-02. |
| **DynamoDB table** (`<org>-tfstate-lock`) | State locking — prevents concurrent applies from corrupting state. KMS-encrypted, PITR enabled. |
| **IAM OIDC provider** (GitHub) | Registers `token.actions.githubusercontent.com` as a trusted identity provider in IAM so GitHub Actions can authenticate without static credentials. |
| **IAM role** (`<org>-github-actions-oidc`) | Assumed by GitHub Actions during CI/CD runs. Trust is scoped to specific branches in your repository. Can only assume the execution role — no direct AWS permissions. |
| **IAM role** (`<org>-terraform-execution-role`) | Assumed by the OIDC role to perform Terraform operations. Permissions are scoped to state bucket S3 access, DynamoDB lock table, KMS key usage, and IAM management within the org prefix. |

All resources are tagged `PRD = "PRD-00"`. No application infrastructure is deployed here — this layer exists solely to support safe, auditable Terraform state management for all downstream PRDs.

---

## Prerequisites

Before starting, confirm the following:

| Requirement | Verification |
|---|---|
| AWS CLI installed and configured | `aws sts get-caller-identity` returns the correct account |
| Target account is the intended member account (`<dev_account_id>` or `<prod_account_id>`) — never management | Confirm account ID in the output above |
| Terraform >= 1.6.0 installed | `terraform version` |
| You are the only person running this sequence right now | Coordinate with any other engineers before starting |
| GitHub organization and repository names are known | Required for OIDC trust policy scoping |
| A `.gitignore` exists or will be updated before committing | `bootstrap.tfstate` must never be committed |

---

## Pre-flight — Confirm target account

The bootstrap script uses whichever AWS credentials are active in your shell — it does not prompt. Deploying to the wrong account is not easily reversible. Confirm the correct account is active before running anything.

### Single account setup

If you are working with a single AWS account and a single credential set, confirm the active identity:

```bash
echo "Profile: ${AWS_PROFILE:-default}" && aws sts get-caller-identity
```

Check that the `Account` field in the output matches the account you intend to deploy to before proceeding.

### AWS Organizations / multi-account setup

If your AWS accounts are managed under AWS Organizations, you likely access child accounts by assuming a role from a management or tooling account rather than using long-term credentials directly in each account.

A typical `~/.aws/config` using `source_profile` and role chaining:

```ini
[profile management]
region = us-east-1

[profile dev]
role_arn = arn:aws:iam::<dev_account_id>:role/OrganizationAccountAccessRole
source_profile = management
region = us-east-1

[profile prod]
role_arn = arn:aws:iam::<prod_account_id>:role/OrganizationAccountAccessRole
source_profile = management
region = us-east-1
```

`OrganizationAccountAccessRole` is created automatically by AWS Organizations in each member account and trusts the management account by default.

Set the profile for your target account, then verify:

```bash
export AWS_PROFILE=dev    # substitute your profile name
echo "Profile: ${AWS_PROFILE}" && aws sts get-caller-identity
```

Confirm the `Account` value in the output matches the account you intend to deploy to. Do not proceed if it does not.

> **Note:** `AWS_PROFILE` set in the shell takes precedence over any default profile. The bootstrap script inherits this value — no additional configuration is needed.

---

## Pre-flight — Secure the local state file

Before running anything, add the state file and tfvars patterns to `.gitignore`. The local `bootstrap.tfstate` file is created during the script and `bootstrap.tfvars` contains your GitHub org/repo values — doing this now ensures neither is ever accidentally staged.

```bash
# Run from the repository root
echo "bootstrap.tfstate" >> .gitignore
echo "bootstrap.tfstate.backup" >> .gitignore
echo "*.tfstate" >> .gitignore
echo "*.tfstate.*" >> .gitignore
echo "bootstrap.tfvars" >> .gitignore
```

Confirm the patterns are present before proceeding:

```bash
grep -E "tfstate|tfvars" .gitignore
```

---

## Step 1 — Prepare your tfvars

Create a `bootstrap.tfvars` file in `connect-pbx/modules/bootstrap/`. Do not commit this file.

```hcl
org_name     = "your-org-name"    # your org identifier — used in all resource names
github_org   = "your-github-org"
github_repo  = "your-github-repo"
```

The following variables have defaults and do not need to be set unless overriding:

| Variable | Default | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | Change only if deploying to a different region |
| `allowed_branches` | `["main", "develop"]` | Branches permitted to assume the OIDC role |
| `terraform_execution_role_boundary_arn` | `""` | Leave empty unless your account requires permissions boundaries |
| `deployment_profile` | single/standalone defaults | Leave as-is for initial bootstrap |

When `bootstrap.sh` starts, it reads `bootstrap.tfvars`, shows the current values for `org_name`, `github_org`, `github_repo`, and `aws_region`, and asks for confirmation before apply. If you answer `no`, the script prompts you for corrected values and patches `bootstrap.tfvars` in place before continuing.

---

## Step 2 — Confirm backend.tf is set to Phase 1 (local)

`connect-pbx/modules/bootstrap/backend.tf` must contain the local backend before running the script:

```hcl
terraform {
  backend "local" {
    path = "bootstrap.tfstate"
  }
}
```

If `backend.tf` already contains an S3 backend block, the state has already been migrated — do not re-run this sequence.

---

## Step 3 — Run the bootstrap script

```bash
cd connect-pbx/modules/bootstrap
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

The script executes five stages:

| Stage | What happens |
|---|---|
| **1/5 — Init** | `terraform init` with local backend |
| **2/5 — Apply** | Creates S3 bucket, DynamoDB table, KMS key, IAM roles — state written to `bootstrap.tfstate` locally |
| **3/5 — Capture outputs** | Reads bucket name, KMS key ARN, lock table name from local state |
| **4/5 — Migrate** | Patches `backend.tf` to S3, writes a local backend artifact file for dashboard/runners, and runs `terraform init -migrate-state` to copy local state to the new remote backend |
| **5/5 — Verify** | Runs `terraform state list` against the remote backend to confirm state is readable |

The script will exit non-zero and stop at the failed stage if any step fails.

After a successful run, the script also writes a profile-scoped backend artifact file outside the repo. The directory name is taken from `github_repo` in `bootstrap.tfvars`:

- Windows Git Bash: `${LOCALAPPDATA}/connect-pbx/<github_repo>/bootstrap/backend-<aws_profile>.hcl`
- fallback: `${HOME}/.connect-pbx/<github_repo>/bootstrap/backend-<aws_profile>.hcl`
- override: `CONNECT_PBX_BOOTSTRAP_DIR`

This file is consumed by the dashboard and local runner scripts. It is local machine state and should not be committed.

After the AWS bootstrap completes, the script can also optionally scaffold GitHub environments and bootstrap-owned secrets:

- interactive default: prompts `Create GitHub environments and sync bootstrap-owned secrets now? [y/N]:`
- strict opt-in: `./scripts/bootstrap.sh --configure-github`
- skip the prompt: `./scripts/bootstrap.sh --skip-configure-github`

The GitHub scaffold step:
- ensures `dev`, `staging`, and `prod` environments exist
- syncs only `AWS_ACCOUNT_ID`, `AWS_REGION`, `STATE_BUCKET`, and `TF_EXEC_ROLE_ARN`
- does not configure protection rules, reviewers, or `ENV_KMS_KEY_ARN`

`ENV_KMS_KEY_ARN` remains a PRD-02 responsibility and is populated later by `scripts/sync-github-env-secrets.sh` or by the dashboard runner after account-baseline apply.

---

## Step 4 — Verify the migration

After the script completes, confirm the following manually:

```bash
# Remote state is readable
terraform state list

# S3 state object exists
aws s3 ls s3://<org_name>-tfstate-<account_id>/bootstrap/

# DynamoDB table exists
aws dynamodb describe-table --table-name <org_name>-tfstate-lock

# KMS key rotation is enabled
aws kms get-key-rotation-status --key-id alias/<org_name>-tfstate-bootstrap
```

---

## Step 5 — Commit the updated backend.tf

The `bootstrap.sh` script patches `backend.tf` in place. Review the diff, then commit:

```bash
git diff backend.tf
git add backend.tf
git commit -m "chore(bootstrap): migrate state backend to S3 remote"
```

`backend.tf` after migration should look like:

```hcl
terraform {
  backend "s3" {
    bucket         = "<org_name>-tfstate-<account_id>"
    key            = "bootstrap/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "<bootstrap_kms_key_arn>"
    dynamodb_table = "<org_name>-tfstate-lock"
  }
}
```

---

## Step 6 — Record outputs for downstream PRDs

Capture the module outputs — these are consumed by all downstream PRDs:

```bash
terraform output
```

| Output | Consumed By |
|---|---|
| `state_bucket_name` | All PRDs — `backend.tf` blocks |
| `state_bucket_arn` | PRD-02, PRD-03 — IAM policies |
| `lock_table_name` | All PRDs — `backend.tf` blocks |
| `lock_table_arn` | PRD-02 — IAM policies |
| `bootstrap_kms_key_arn` | PRD-02 — for reference; env keys provisioned there |
| `terraform_execution_role_arn` | PRD-01 — GitHub Actions workflows |
| `github_oidc_provider_arn` | PRD-01 — workflow trust configuration |

---

## What comes next

| PRD | Depends on bootstrap outputs |
|---|---|
| **PRD-01** — GitHub Actions CI/CD | `terraform_execution_role_arn`, `github_oidc_provider_arn`, `state_bucket_name`, `lock_table_name` |
| **PRD-02** — Account Baseline / KMS | `state_bucket_arn`, `lock_table_arn`, `bootstrap_kms_key_arn` |

PRD-02 must be applied before any environment workspace (`dev`, `staging`, `prod`) is first initialized, as it provisions the per-environment KMS keys required by those backend blocks.

---

## Rollback

> **`terraform destroy` will not work here.** Both S3 buckets have `prevent_destroy = true` — Terraform will refuse and error. Even if overridden, destroying the backend while it holds the active state and lock would corrupt or lose the state file. All recovery is performed manually via the AWS CLI.

### Scenario A — DynamoDB lock table accidentally deleted

The lock table holds no state data — it only tracks active locks. It is safe to recreate.

```bash
aws dynamodb create-table \
  --table-name <org_name>-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --sse-specification Enabled=true,SSEType=KMS,KMSMasterKeyId=alias/<org_name>-tfstate-bootstrap
```

After recreating, run `terraform init` in any module that was mid-apply to clear the stale lock.

---

### Scenario B — S3 state bucket accidentally deleted

S3 bucket names are globally unique and can be reclaimed if deleted by the same account quickly.

```bash
# 1. Recreate the bucket
aws s3api create-bucket \
  --bucket <org_name>-tfstate-<account_id> \
  --region us-east-1

# 2. Re-enable versioning
aws s3api put-bucket-versioning \
  --bucket <org_name>-tfstate-<account_id> \
  --versioning-configuration Status=Enabled

# 3. Re-apply encryption
aws s3api put-bucket-encryption \
  --bucket <org_name>-tfstate-<account_id> \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "alias/<org_name>-tfstate-bootstrap"
      },
      "BucketKeyEnabled": true
    }]
  }'

# 4. Block public access
aws s3api put-public-access-block \
  --bucket <org_name>-tfstate-<account_id> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

If the bucket was deleted but state objects were preserved via a backup or cross-region replication, restore them using `aws s3 cp` or `aws s3 sync`. If no backup exists, the state files are lost and each affected module must be rebuilt with `terraform import`.

---

### Scenario C — KMS bootstrap key scheduled for deletion

This is the most critical scenario. A deleted KMS key renders all state objects encrypted with it permanently unreadable.

**Act immediately — you have a 14-day window.**

```bash
# Cancel the pending deletion
aws kms cancel-key-deletion \
  --key-id alias/<org_name>-tfstate-bootstrap

# Re-enable the key
aws kms enable-key \
  --key-id alias/<org_name>-tfstate-bootstrap

# Confirm key is enabled
aws kms describe-key \
  --key-id alias/<org_name>-tfstate-bootstrap \
  --query 'KeyMetadata.KeyState'
```

If the 14-day window has passed and the key is permanently deleted, the bootstrap state object is unrecoverable. You must:
1. Recreate all bootstrap resources manually (S3, DynamoDB, KMS, IAM)
2. Reconstruct the state file using `terraform import` for each resource
3. Re-run `terraform init -migrate-state` to re-establish the remote backend

---

### Scenario D — Stale lock blocking all applies

If a Terraform process crashed without releasing its lock, all subsequent applies will fail with a lock acquisition error.

```bash
# Get the lock ID from the error message, then force-unlock
terraform force-unlock <lock_id>
```

Only run `force-unlock` if you are certain no apply is currently in progress. Unlocking while an apply is running will cause state corruption.

---

### After any restoration

Re-run `terraform init` in each module that uses this backend to reconnect:

```bash
cd connect-pbx/modules/bootstrap
terraform init

# Repeat for each downstream module once PRD-01/PRD-02 are applied
```

---

### Scenario E — Complete teardown (clean AWS environment)

Use this only when decommissioning the platform entirely or rebuilding from scratch. This is irreversible.

> **`terraform destroy` will not work directly** — `prevent_destroy = true` on both S3 buckets blocks it. You must remove that guard first, then migrate state back to local before destroying.

#### Phase 1 — Migrate state back to local

Before destroying anything, pull the remote state back to a local file so Terraform can track what it needs to delete.

```bash
cd connect-pbx/modules/bootstrap

# Update backend.tf back to Phase 1 (local)
# Replace the s3 backend block with:
terraform {
  backend "local" {
    path = "bootstrap.tfstate"
  }
}

# Migrate remote state to local
terraform init -migrate-state
```

Confirm local state is populated:

```bash
terraform state list
```

#### Phase 2 — Remove prevent_destroy guards

`prevent_destroy = true` is set on `aws_s3_bucket.tfstate` and `aws_s3_bucket.tfstate_logs` in `s3.tf`. Temporarily set both to `false`:

```hcl
# s3.tf — both bucket resources
lifecycle {
  prevent_destroy = false
}
```

#### Phase 3 — Empty the S3 buckets

S3 buckets cannot be deleted while they contain objects. Versioned buckets also retain delete markers and non-current versions — these must be purged too.

```bash
# Empty the state bucket (all versions and delete markers)
aws s3api delete-objects \
  --bucket <org_name>-tfstate-<account_id> \
  --delete "$(aws s3api list-object-versions \
    --bucket <org_name>-tfstate-<account_id> \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)"

# Remove delete markers
aws s3api delete-objects \
  --bucket <org_name>-tfstate-<account_id> \
  --delete "$(aws s3api list-object-versions \
    --bucket <org_name>-tfstate-<account_id> \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json)"

# Repeat for the logs bucket
aws s3api delete-objects \
  --bucket <org_name>-tfstate-logs-<account_id> \
  --delete "$(aws s3api list-object-versions \
    --bucket <org_name>-tfstate-logs-<account_id> \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)"

aws s3api delete-objects \
  --bucket <org_name>-tfstate-logs-<account_id> \
  --delete "$(aws s3api list-object-versions \
    --bucket <org_name>-tfstate-logs-<account_id> \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json)"
```

> If either bucket has many thousands of objects, use `aws s3 rm s3://<bucket> --recursive` first to remove current versions, then run the versioned delete commands above for non-current versions and delete markers.

#### Phase 4 — Destroy all resources via Terraform

With state local, `prevent_destroy` removed, and buckets empty, Terraform can now destroy everything cleanly:

```bash
terraform destroy -var-file="bootstrap.tfvars"
```

Review the plan carefully — confirm it lists only bootstrap resources before approving.

#### Phase 5 — Clean up local state, bootstrap artifacts, and revert s3.tf

```bash
# Remove local state files
rm -f bootstrap.tfstate bootstrap.tfstate.backup

# Remove the generated backend artifact for this AWS profile
rm -f "${CONNECT_PBX_BOOTSTRAP_DIR:-${LOCALAPPDATA}/connect-pbx/<github_repo>/bootstrap}/backend-${AWS_PROFILE:-default}.hcl"

# Remove the .terraform directory
rm -rf .terraform

# Remove the lock file
rm -f .terraform.lock.hcl
```

Revert `prevent_destroy` back to `true` in `s3.tf` and revert `backend.tf` back to the Phase 1 local backend before committing, so the module is in a clean re-deployable state. Removing the backend artifact file ensures the dashboard and local runners do not keep pointing at a backend that no longer exists.

#### Phase 6 — Verify clean environment

```bash
# Confirm S3 buckets are gone
aws s3api head-bucket --bucket <org_name>-tfstate-<account_id>
# Expected: An error occurred (404)

# Confirm DynamoDB table is gone
aws dynamodb describe-table --table-name <org_name>-tfstate-lock
# Expected: ResourceNotFoundException

# Confirm KMS key is scheduled for deletion (14-day window)
aws kms describe-key --key-id alias/<org_name>-tfstate-bootstrap
# Expected: KeyState = PendingDeletion

# Confirm IAM roles are gone
aws iam get-role --role-name <org_name>-github-actions-oidc
aws iam get-role --role-name <org_name>-terraform-execution-role
# Expected: NoSuchEntity for both
```

> The KMS key will not be immediately deleted — it enters a 14-day pending deletion window. This is by design and cannot be bypassed. The key is effectively unusable during this period. If you need to redeploy before 14 days, a new KMS key will be created with a new ARN.

---

## Acceptance checks (AC-00 from PRD-00)

| Check | Command |
|---|---|
| Versioning enabled | `aws s3api get-bucket-versioning --bucket <bucket>` → `Enabled` |
| Default encryption SSE-KMS | `aws s3api get-bucket-encryption --bucket <bucket>` → bootstrap KMS key ARN |
| Public access blocked | `aws s3api get-public-access-block --bucket <bucket>` → all four `true` |
| DynamoDB schema correct | `aws dynamodb describe-table --table-name <table>` → `LockID` string hash key |
| DynamoDB KMS encrypted | `aws dynamodb describe-table --table-name <table>` → SSEDescription KMS key ARN |
| OIDC provider registered | `aws iam list-open-id-connect-providers` → GitHub URL present |
| KMS rotation enabled | `aws kms get-key-rotation-status --key-id alias/<org>-tfstate-bootstrap` → `true` |
| Remote state readable | `terraform state list` returns resources from remote backend |
