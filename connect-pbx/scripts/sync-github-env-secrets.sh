#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_HELPER="${REPO_ROOT}/scripts/lib/bootstrap-artifacts.sh"
# shellcheck source=/dev/null
source "${BOOTSTRAP_HELPER}"

BOOTSTRAP_TFVARS_PATH="$(bootstrap_tfvars_path "${REPO_ROOT}")"
MODULE_CATALOG="${REPO_ROOT}/modules/dependency-order.json"
MANIFEST_HELPER="${REPO_ROOT}/scripts/module_manifest.py"
BOOTSTRAP_ARTIFACT_DIR="$(resolve_bootstrap_artifact_dir_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"

ENVIRONMENT=""
BACKEND_CONFIG_PATH=""
REPO_SLUG="$(resolve_github_repo_slug_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"
PROFILE_NAME="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-east-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/sync-github-env-secrets.sh --env <dev|staging|prod> [--repo <owner/name>] [--backend-config <path>]

Behavior:
  - Reads bootstrap outputs from modules/bootstrap
  - Initializes modules/l0-account-baseline against the remote backend
  - Selects the requested Terraform workspace explicitly
  - Reads kms_key_arn for that workspace
  - Writes GitHub Actions environment secrets with gh secret set

Secrets written:
  AWS_ACCOUNT_ID
  AWS_REGION
  STATE_BUCKET
  TF_EXEC_ROLE_ARN
  ENV_KMS_KEY_ARN

Notes:
  - Requires gh CLI authentication
  - Run from anywhere inside the repo; the script resolves paths itself
  - The target GitHub Actions environment must already exist
  - Use this only after PRD-02 account baseline has been applied for the target environment
EOF
}

catalog_module_field() {
  local module_path="$1"
  local field_name="$2"
  python "${MANIFEST_HELPER}" module-field \
    --catalog "${MODULE_CATALOG}" \
    --module "${module_path}" \
    --field "${field_name}" | tr -d '\r'
}

set_secret() {
  local name="$1"
  local value="$2"

  if [[ -n "${REPO_SLUG}" ]]; then
    gh secret set "${name}" --env "${ENVIRONMENT}" --repo "${REPO_SLUG}" --body "${value}"
  else
    gh secret set "${name}" --env "${ENVIRONMENT}" --body "${value}"
  fi
}

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --env|--environment)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --repo)
      REPO_SLUG="${2:-}"
      shift 2
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${ENVIRONMENT}" ]]; then
  usage
  exit 1
fi

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "staging" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Unsupported environment: ${ENVIRONMENT}"
  exit 1
fi

if [[ -z "${BACKEND_CONFIG_PATH}" ]]; then
  BACKEND_CONFIG_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"
fi

if [[ ! -f "${BACKEND_CONFIG_PATH}" ]]; then
  echo "Backend config file not found: ${BACKEND_CONFIG_PATH}"
  echo "Run bootstrap first, or pass --backend-config explicitly."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required."
  exit 1
fi

gh auth status >/dev/null

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

BOOTSTRAP_MODULE="${REPO_ROOT}/modules/bootstrap"
ACCOUNT_BASELINE_MODULE="${REPO_ROOT}/modules/l0-account-baseline"
ACCOUNT_BASELINE_STATE_KEY="$(catalog_module_field "modules/l0-account-baseline" "state_key")"

echo
echo "Syncing GitHub Actions environment secrets"
echo "Environment : ${ENVIRONMENT}"
echo "AWS profile : ${PROFILE_NAME}"
echo "AWS region  : ${REGION}"
echo "Backend     : ${BACKEND_CONFIG_PATH}"
echo "Repository  : ${REPO_SLUG}"

terraform -chdir="${BOOTSTRAP_MODULE}" init \
  -reconfigure \
  "-backend-config=${BACKEND_CONFIG_PATH}"

STATE_BUCKET="$(terraform -chdir="${BOOTSTRAP_MODULE}" output -raw state_bucket_name)"
TF_EXEC_ROLE_ARN="$(terraform -chdir="${BOOTSTRAP_MODULE}" output -raw terraform_execution_role_arn)"

terraform -chdir="${ACCOUNT_BASELINE_MODULE}" init \
  -reconfigure \
  "-backend-config=${BACKEND_CONFIG_PATH}" \
  "-backend-config=key=${ACCOUNT_BASELINE_STATE_KEY}" \
  "-backend-config=use_lockfile=true"

terraform -chdir="${ACCOUNT_BASELINE_MODULE}" workspace select "${ENVIRONMENT}" >/dev/null
ENV_KMS_KEY_ARN="$(terraform -chdir="${ACCOUNT_BASELINE_MODULE}" output -raw kms_key_arn)"

set_secret "AWS_ACCOUNT_ID" "${ACCOUNT_ID}"
set_secret "AWS_REGION" "${REGION}"
set_secret "STATE_BUCKET" "${STATE_BUCKET}"
set_secret "TF_EXEC_ROLE_ARN" "${TF_EXEC_ROLE_ARN}"
set_secret "ENV_KMS_KEY_ARN" "${ENV_KMS_KEY_ARN}"

echo
echo "Updated GitHub Actions environment secrets:"
echo "  - AWS_ACCOUNT_ID"
echo "  - AWS_REGION"
echo "  - STATE_BUCKET"
echo "  - TF_EXEC_ROLE_ARN"
echo "  - ENV_KMS_KEY_ARN"
echo
echo "Workspace selected during lookup: ${ENVIRONMENT}"
