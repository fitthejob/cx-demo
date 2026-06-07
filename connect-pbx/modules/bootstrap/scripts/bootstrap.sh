#!/bin/bash
#run from anywhere; the script anchors itself to connect-pbx/modules/bootstrap/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BOOTSTRAP_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_HELPER="${REPO_ROOT}/scripts/lib/bootstrap-artifacts.sh"
GITHUB_SCAFFOLD_HELPER="${REPO_ROOT}/scripts/github-env-bootstrap.sh"
# shellcheck source=/dev/null
source "${BOOTSTRAP_HELPER}"

BOOTSTRAP_TFVARS_PATH="${BOOTSTRAP_MODULE_DIR}/bootstrap.tfvars"
ACCOUNT_ID=""
PROFILE_NAME="${AWS_PROFILE:-default}"
BOOTSTRAP_ARTIFACT_DIR=""
BACKEND_ARTIFACT_PATH=""
CONFIGURE_GITHUB_MODE="prompt"
BOOTSTRAP_ORG_NAME=""
BOOTSTRAP_GITHUB_REPO=""

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --configure-github)
      CONFIGURE_GITHUB_MODE="required"
      shift
      ;;
    --skip-configure-github)
      CONFIGURE_GITHUB_MODE="skip"
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage:
  modules/bootstrap/scripts/bootstrap.sh [--configure-github] [--skip-configure-github]

Behavior:
  - Bootstraps the remote Terraform backend in AWS
  - Writes the repo-scoped local backend artifact
  - Optionally scaffolds GitHub environments and bootstrap-owned secrets

Flags:
  --configure-github       Run GitHub environment scaffold after bootstrap and fail non-zero if it fails
  --skip-configure-github  Skip the post-bootstrap GitHub scaffold prompt
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cd "${BOOTSTRAP_MODULE_DIR}"

read_tfvar_string() {
  read_tfvar_string_from_file "${BOOTSTRAP_TFVARS_PATH}" "$1"
}

upsert_tfvar_string_in_file() {
  local tfvars_path="$1"
  local key="$2"
  local value="$3"
  local tmp_path="${tfvars_path}.tmp"

  touch "${tfvars_path}"

  awk -v key="${key}" -v value="${value}" '
    BEGIN {
      updated = 0
      pattern = "^[[:space:]]*" key "[[:space:]]*="
    }
    $0 ~ pattern {
      print key " = \"" value "\""
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key " = \"" value "\""
      }
    }
  ' "${tfvars_path}" > "${tmp_path}"

  mv "${tmp_path}" "${tfvars_path}"
}

upsert_tfvar_string() {
  local key="$1"
  local value="$2"
  upsert_tfvar_string_in_file "${BOOTSTRAP_TFVARS_PATH}" "${key}" "${value}"
}

prompt_required_value() {
  local label="$1"
  local current_value="$2"
  local input=""
  local resolved_value=""

  while true; do
    if [[ -n "${current_value}" ]]; then
      read -r -p "${label} [${current_value}]: " input
      resolved_value="${input:-${current_value}}"
    else
      read -r -p "${label}: " input
      resolved_value="${input}"
    fi

    if [[ -z "${resolved_value}" ]]; then
      echo "${label} is required."
      continue
    fi

    break
  done

  printf '%s\n' "${resolved_value}"
}

resolve_bootstrap_artifact_context() {
  BOOTSTRAP_ARTIFACT_DIR="$(resolve_bootstrap_artifact_dir_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"
  BACKEND_ARTIFACT_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"
}

run_github_scaffold() {
  "${GITHUB_SCAFFOLD_HELPER}" --backend-config "${BACKEND_ARTIFACT_PATH}"
}

sync_environment_global_tfvars() {
  local env_name=""
  local global_tfvars_path=""

  echo ""
  echo "Syncing environment global.tfvars from bootstrap.tfvars"

  for env_name in dev staging prod; do
    global_tfvars_path="${REPO_ROOT}/environments/${env_name}/global.tfvars"
    upsert_tfvar_string_in_file "${global_tfvars_path}" "org_name" "${BOOTSTRAP_ORG_NAME}"
    upsert_tfvar_string_in_file "${global_tfvars_path}" "repo_name" "${BOOTSTRAP_GITHUB_REPO}"
    echo "  ${env_name}: ${global_tfvars_path}"
  done
}

verify_or_update_bootstrap_inputs() {
  local current_org_name
  local current_github_org
  local current_github_repo
  local current_aws_region
  local confirmation=""
  local persist_confirmation=""

  current_org_name="$(read_tfvar_string "org_name")"
  current_github_org="$(read_tfvar_string "github_org")"
  current_github_repo="$(read_tfvar_string "github_repo")"
  current_aws_region="$(read_tfvar_string "aws_region")"

  if [[ -z "${current_aws_region}" ]]; then
    current_aws_region="${AWS_REGION:-us-east-1}"
  fi

  echo ""
  echo "Bootstrap pre-flight"
  echo "  AWS account     : ${ACCOUNT_ID}"
  echo "  AWS profile     : ${PROFILE_NAME}"
  echo "  AWS region      : ${current_aws_region}"
  echo "  TF vars file    : ${BOOTSTRAP_TFVARS_PATH}"
  echo "  org_name        : ${current_org_name:-<unset>}"
  echo "  github_org      : ${current_github_org:-<unset>}"
  echo "  github_repo     : ${current_github_repo:-<unset>}"

  if [[ -n "${current_org_name}" && -n "${current_github_org}" && -n "${current_github_repo}" ]]; then
    read -r -p "Proceed with these bootstrap values? [Y/n]: " confirmation
  else
    confirmation="n"
  fi

  case "${confirmation:-Y}" in
    n|N|no|NO)
      echo ""
      echo "Manual entry mode"
      echo "  - Any values you enter next will be written back to ${BOOTSTRAP_TFVARS_PATH}."
      echo "  - These values control resource naming and GitHub OIDC trust scope."
      echo "  - Ensure there are no typos before you confirm the update."

      current_org_name="$(prompt_required_value "org_name" "${current_org_name}")"
      current_github_org="$(prompt_required_value "github_org" "${current_github_org}")"
      current_github_repo="$(prompt_required_value "github_repo" "${current_github_repo}")"
      current_aws_region="$(prompt_required_value "aws_region" "${current_aws_region}")"

      echo ""
      echo "Pending ${BOOTSTRAP_TFVARS_PATH} updates:"
      echo "  org_name    = ${current_org_name}"
      echo "  github_org  = ${current_github_org}"
      echo "  github_repo = ${current_github_repo}"
      echo "  aws_region  = ${current_aws_region}"
      read -r -p "Write these values to ${BOOTSTRAP_TFVARS_PATH} and continue? [y/N]: " persist_confirmation

      case "${persist_confirmation:-N}" in
        y|Y|yes|YES)
          ;;
        *)
          echo "Aborted before modifying ${BOOTSTRAP_TFVARS_PATH}."
          exit 1
          ;;
      esac

      upsert_tfvar_string "org_name" "${current_org_name}"
      upsert_tfvar_string "github_org" "${current_github_org}"
      upsert_tfvar_string "github_repo" "${current_github_repo}"
      upsert_tfvar_string "aws_region" "${current_aws_region}"

      export AWS_REGION="${current_aws_region}"

      echo ""
      echo "Updated ${BOOTSTRAP_TFVARS_PATH}:"
      echo "  org_name    = ${current_org_name}"
      echo "  github_org  = ${current_github_org}"
      echo "  github_repo = ${current_github_repo}"
      echo "  aws_region  = ${current_aws_region}"
      ;;
    *)
      export AWS_REGION="${current_aws_region}"
      ;;
  esac

  BOOTSTRAP_ORG_NAME="${current_org_name}"
  BOOTSTRAP_GITHUB_REPO="${current_github_repo}"
}

echo "Bootstrapping account: ${ACCOUNT_ID}"
verify_or_update_bootstrap_inputs
resolve_bootstrap_artifact_context
sync_environment_global_tfvars

echo "[1/5] Initializing with local backend..."
terraform init

echo "[2/5] Applying with local state..."
terraform apply -auto-approve -var-file="${BOOTSTRAP_TFVARS_PATH}"

echo "[3/5] Capturing outputs..."
BUCKET_NAME=$(terraform output -raw state_bucket_name)
KMS_KEY_ARN=$(terraform output -raw bootstrap_kms_key_arn)

echo " State bucket: ${BUCKET_NAME}"
echo " Bootstrap key: ${KMS_KEY_ARN}"
echo " Locking mode: S3 native lockfile"

echo "[4/5] Migrating state to remote backend..."

cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket       = "${BUCKET_NAME}"
    key          = "bootstrap/terraform.tfstate"
    region       = "${AWS_REGION:-us-east-1}"
    encrypt      = true
    kms_key_id   = "${KMS_KEY_ARN}"
    use_lockfile = true
  }
}
EOF

mkdir -p "${BOOTSTRAP_ARTIFACT_DIR}"

cat > "${BACKEND_ARTIFACT_PATH}" <<EOF
bucket       = "${BUCKET_NAME}"
key          = "bootstrap/terraform.tfstate"
region       = "${AWS_REGION:-us-east-1}"
encrypt      = true
kms_key_id   = "${KMS_KEY_ARN}"
use_lockfile = true
EOF

terraform init \
    -migrate-state \
    -force-copy \
    -backend-config="bucket=${BUCKET_NAME}" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${AWS_REGION:-us-east-1}" \
    -backend-config="encrypt=true" \
    -backend-config="kms_key_id=${KMS_KEY_ARN}" \
    -backend-config="use_lockfile=true"

echo "[5/5] Verifying remote state..."
terraform state list

echo ""
echo "Bootstrap complete."
echo "Bootstrap backend artifact: ${BACKEND_ARTIFACT_PATH}"
echo "AWS bootstrap is complete. PRD-02 account baseline is still required before ENV_KMS_KEY_ARN can be populated for CI/CD."

case "${CONFIGURE_GITHUB_MODE}" in
  required)
    echo ""
    echo "Running GitHub environment scaffold because --configure-github was requested..."
    if run_github_scaffold; then
      echo "GitHub environment scaffold complete."
    else
      echo "GitHub environment scaffold failed after AWS bootstrap succeeded." >&2
      echo "Bootstrap infrastructure is ready, but CI/CD scaffolding is incomplete." >&2
      exit 1
    fi
    ;;
  prompt)
    echo ""
    read -r -p "Create GitHub environments and sync bootstrap-owned secrets now? [y/N]: " github_scaffold_confirmation
    case "${github_scaffold_confirmation:-N}" in
      y|Y|yes|YES)
        if run_github_scaffold; then
          echo "GitHub environment scaffold complete."
        else
          echo "Warning: GitHub environment scaffold failed after AWS bootstrap succeeded." >&2
          echo "Bootstrap infrastructure is ready, but CI/CD scaffolding is incomplete." >&2
          echo "You can retry later with: ${GITHUB_SCAFFOLD_HELPER} --backend-config ${BACKEND_ARTIFACT_PATH}" >&2
        fi
        ;;
      *)
        echo "Skipped GitHub environment scaffold."
        echo "When you are ready, run: ${GITHUB_SCAFFOLD_HELPER} --backend-config ${BACKEND_ARTIFACT_PATH}"
        ;;
    esac
    ;;
  skip)
    echo "Skipped GitHub environment scaffold by flag."
    echo "When you are ready, run: ${GITHUB_SCAFFOLD_HELPER} --backend-config ${BACKEND_ARTIFACT_PATH}"
    ;;
esac

echo "Commit the updated backend.tf. DO NOT commit bootstrap.tfstate."
echo "Add bootstrap.tfstate to .gitignore immediately."
