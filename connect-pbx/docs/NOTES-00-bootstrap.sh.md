# bootstrap.sh - Line by Line

---

### Line 1 - `#!/bin/bash`

Shebang - tells the OS to execute this file using bash.

---

### Line 2 - `#run from: connect-pbx/modules/bootstrap/`

Comment reminding you where to run the script from. Terraform commands are relative to the working directory, so running from the wrong location will fail.

---

### Line 4 - `set -euo pipefail`

Three safety flags combined:

| Flag | Behaviour |
|---|---|
| `-e` | Exit immediately if any command returns a non-zero exit code (fail fast) |
| `-u` | Treat unset variables as an error rather than silently substituting an empty string |
| `-o pipefail` | If a command in a pipe fails, the whole pipe fails - not just the last command |

---

### Line 6 - `ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)`

Calls AWS to get the currently authenticated account ID and stores it in `ACCOUNT_ID`.

- `--query Account` - extracts just the account number field from the JSON response
- `--output text` - returns it as a plain string rather than JSON

---

### Line 7 - `echo "Bootstrapping account: ${ACCOUNT_ID}"`

Prints the account ID so you can visually confirm you're deploying to the right account before anything is created.

---

### Line 10 - `terraform init`

Initialises Terraform with the local backend defined in `backend.tf` Phase 1. Downloads the AWS provider and sets up the `.terraform/` directory.

---

### Line 13 - `terraform apply -auto-approve`

Creates all bootstrap resources - S3 buckets, KMS key, IAM roles, and the legacy retained lock-table resource.

- `-auto-approve` - skips the interactive yes/no prompt
- State is written to `bootstrap.tfstate` locally at this stage

---

### Capture outputs

```bash
BUCKET_NAME=$(terraform output -raw state_bucket_name)
KMS_KEY_ARN=$(terraform output -raw bootstrap_kms_key_arn)
```

Reads the key bootstrap outputs from local state and stores them as shell variables. `-raw` strips surrounding quotes from the string values. These values are used in the migration step below.

---

### Migration backend config

The script rewrites `backend.tf` to use the S3 backend and native S3 lockfiles:

```hcl
terraform {
  backend "s3" {
    bucket       = "<bucket>"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "<kms-key-arn>"
    use_lockfile = true
  }
}
```

It also writes the same values to the generated backend artifact file used by the dashboard and local runner scripts.

---

### `terraform init -migrate-state -force-copy -backend-config=...`

Re-initialises Terraform with the new S3 backend, passing all parameters at the command line:

| Flag | Purpose |
|---|---|
| `-migrate-state` | Tells Terraform to copy existing local state to the new remote backend |
| `-force-copy` | Suppresses the interactive confirmation prompt for the migration |
| `-backend-config="bucket=..."` | S3 bucket name |
| `-backend-config="key=..."` | S3 object key path for the state file |
| `-backend-config="region=..."` | AWS region - defaults to `us-east-1` if `AWS_REGION` is not set |
| `-backend-config="encrypt=true"` | Enables server-side encryption |
| `-backend-config="kms_key_id=..."` | KMS key ARN to use for encryption |
| `-backend-config="use_lockfile=true"` | Enables native S3 lockfile-based state locking |

---

### `terraform state list`

Reads from the remote backend and lists all resources in state. If this succeeds the migration worked - Terraform can authenticate to S3, decrypt the state with the KMS key, and read the contents.

---

### Completion messages

Reminder instructions printed at the end:

- Commit the updated `backend.tf`
- Do not commit `bootstrap.tfstate`
- Add `bootstrap.tfstate` to `.gitignore` immediately
