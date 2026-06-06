#!/bin/bash
#run from: connect-pbx/modules/bootstrap/

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_SLUG="$(basename "${REPO_ROOT}")"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROFILE_NAME="${AWS_PROFILE:-default}"

if [[ -n "${CONNECT_PBX_BOOTSTRAP_DIR:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${CONNECT_PBX_BOOTSTRAP_DIR}"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${LOCALAPPDATA}/connect-pbx/${REPO_SLUG}/bootstrap"
else
  BOOTSTRAP_ARTIFACT_DIR="${HOME}/.connect-pbx/${REPO_SLUG}/bootstrap"
fi

BACKEND_ARTIFACT_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"
BOOTSTRAP_TFVARS_PATH="bootstrap.tfvars"

read_tfvar_string() {
  local key="$1"
  if [[ ! -f "${BOOTSTRAP_TFVARS_PATH}" ]]; then
    return 0
  fi

  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\\1/p" "${BOOTSTRAP_TFVARS_PATH}" | head -n 1 | tr -d '\r'
}

upsert_tfvar_string() {
  local key="$1"
  local value="$2"
  local tmp_path="${BOOTSTRAP_TFVARS_PATH}.tmp"

  touch "${BOOTSTRAP_TFVARS_PATH}"

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
  ' "${BOOTSTRAP_TFVARS_PATH}" > "${tmp_path}"

  mv "${tmp_path}" "${BOOTSTRAP_TFVARS_PATH}"
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
  echo "  Repo slug       : ${REPO_SLUG}"
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
}

echo "Bootstrapping account: ${ACCOUNT_ID}"
verify_or_update_bootstrap_inputs

echo "[1/5] Initializing with local backend..."
terraform init

echo "[2/5] Applying with local state..."
terraform apply -auto-approve -var-file="${BOOTSTRAP_TFVARS_PATH}"

echo "[3/5] Capturing outputs..."
BUCKET_NAME=$(terraform output -raw state_bucket_name)
KMS_KEY_ARN=$(terraform output -raw bootstrap_kms_key_arn)
LOCK_TABLE=$(terraform output -raw lock_table_name)

echo " State bucket: ${BUCKET_NAME}"
echo " Bootstrap key: ${KMS_KEY_ARN}"
echo " Lock table: ${LOCK_TABLE}"

echo "[4/5] Migrating state to remote backend..."

cat > backend.tf <<EOF
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "bootstrap/terraform.tfstate"
    region         = "${AWS_REGION:-us-east-1}"
    encrypt        = true
    kms_key_id     = "${KMS_KEY_ARN}"
    dynamodb_table = "${LOCK_TABLE}"
  }
}
EOF

mkdir -p "${BOOTSTRAP_ARTIFACT_DIR}"

cat > "${BACKEND_ARTIFACT_PATH}" <<EOF
bucket         = "${BUCKET_NAME}"
key            = "bootstrap/terraform.tfstate"
region         = "${AWS_REGION:-us-east-1}"
encrypt        = true
kms_key_id     = "${KMS_KEY_ARN}"
dynamodb_table = "${LOCK_TABLE}"
EOF

terraform init \
    -migrate-state \
    -force-copy \
    -backend-config="bucket=${BUCKET_NAME}" \
    -backend-config="key=bootstrap/terraform.tfstate" \
    -backend-config="region=${AWS_REGION:-us-east-1}" \
    -backend-config="encrypt=true" \
    -backend-config="kms_key_id=${KMS_KEY_ARN}" \
    -backend-config="dynamodb_table=${LOCK_TABLE}"

echo "[5/5] Verifying remote state..."
terraform state list

echo ""
echo "Bootstrap complete."
echo "Bootstrap backend artifact: ${BACKEND_ARTIFACT_PATH}"
echo "Commit the updated backend.tf. DO NOT commit bootstrap.tfstate."
echo "Add bootstrap.tfstate to .gitignore immediately."
