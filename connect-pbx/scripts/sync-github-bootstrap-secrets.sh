#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_HELPER="${REPO_ROOT}/scripts/lib/bootstrap-artifacts.sh"
# shellcheck source=/dev/null
source "${BOOTSTRAP_HELPER}"

BOOTSTRAP_TFVARS_PATH="$(bootstrap_tfvars_path "${REPO_ROOT}")"
BOOTSTRAP_ARTIFACT_DIR="$(resolve_bootstrap_artifact_dir_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"

ENVIRONMENT=""
BACKEND_CONFIG_PATH=""
REPO_SLUG="$(resolve_github_repo_slug_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"
PROFILE_NAME="${AWS_PROFILE:-default}"
REGION="${AWS_REGION:-us-east-1}"

usage() {
  cat <<'EOF'
Usage:
  scripts/sync-github-bootstrap-secrets.sh --env <dev|staging|prod> [--repo <owner/name>] [--backend-config <path>]

Behavior:
  - Reads bootstrap outputs from modules/bootstrap
  - Writes only bootstrap-derived GitHub Actions environment secrets with gh secret set
  - Does not initialize or read modules/l0-account-baseline

Secrets written:
  AWS_ACCOUNT_ID
  AWS_REGION
  STATE_BUCKET
  LOCK_TABLE
  TF_EXEC_ROLE_ARN

Notes:
  - Requires gh CLI authentication
  - Run from anywhere inside the repo; the script resolves paths itself
  - The target GitHub Actions environment must already exist unless you create it separately
  - Use scripts/sync-github-env-secrets.sh later to add ENV_KMS_KEY_ARN after PRD-02 is deployed
EOF
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

echo
echo "Syncing bootstrap-derived GitHub Actions environment secrets"
echo "Environment : ${ENVIRONMENT}"
echo "AWS profile : ${PROFILE_NAME}"
echo "AWS region  : ${REGION}"
echo "Backend     : ${BACKEND_CONFIG_PATH}"
echo "Repository  : ${REPO_SLUG}"

terraform -chdir="${BOOTSTRAP_MODULE}" init \
  -reconfigure \
  "-backend-config=${BACKEND_CONFIG_PATH}"

STATE_BUCKET="$(terraform -chdir="${BOOTSTRAP_MODULE}" output -raw state_bucket_name)"
LOCK_TABLE="$(terraform -chdir="${BOOTSTRAP_MODULE}" output -raw lock_table_name)"
TF_EXEC_ROLE_ARN="$(terraform -chdir="${BOOTSTRAP_MODULE}" output -raw terraform_execution_role_arn)"

set_secret "AWS_ACCOUNT_ID" "${ACCOUNT_ID}"
set_secret "AWS_REGION" "${REGION}"
set_secret "STATE_BUCKET" "${STATE_BUCKET}"
set_secret "LOCK_TABLE" "${LOCK_TABLE}"
set_secret "TF_EXEC_ROLE_ARN" "${TF_EXEC_ROLE_ARN}"

echo
echo "Updated GitHub Actions environment secrets:"
echo "  - AWS_ACCOUNT_ID"
echo "  - AWS_REGION"
echo "  - STATE_BUCKET"
echo "  - LOCK_TABLE"
echo "  - TF_EXEC_ROLE_ARN"
echo
echo "Bootstrap-only sync complete."
