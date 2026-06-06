#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_HELPER="${REPO_ROOT}/scripts/lib/bootstrap-artifacts.sh"
# shellcheck source=/dev/null
source "${BOOTSTRAP_HELPER}"

BOOTSTRAP_TFVARS_PATH="$(bootstrap_tfvars_path "${REPO_ROOT}")"
PROFILE_NAME="${AWS_PROFILE:-default}"
BACKEND_CONFIG_PATH=""
REPO_SLUG="$(resolve_github_repo_slug_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"
declare -a TARGET_ENVIRONMENTS=()
declare -a CREATED_ENVIRONMENTS=()
declare -a EXISTING_ENVIRONMENTS=()
declare -a SYNCED_ENVIRONMENTS=()

usage() {
  cat <<'EOF'
Usage:
  scripts/github-env-bootstrap.sh [--repo <owner/name>] [--backend-config <path>] [--env <dev|staging|prod>]

Behavior:
  - Resolves the target GitHub repository from bootstrap.tfvars unless --repo is provided
  - Ensures the requested GitHub environments exist
  - Syncs bootstrap-owned secrets into each environment
  - Does not read PRD-02 outputs and does not write ENV_KMS_KEY_ARN
  - Does not configure protection rules, reviewers, or wait timers

Defaults:
  - If no --env flags are provided, scaffolds dev, staging, and prod

Notes:
  - Requires gh CLI authentication
  - Intended for bootstrap-adjacent CI/CD scaffolding only
EOF
}

require_command() {
  local name="$1"
  if ! command -v "${name}" >/dev/null 2>&1; then
    echo "Required command not found in PATH: ${name}" >&2
    exit 1
  fi
}

append_unique_environment() {
  local candidate="$1"
  local existing=""

  for existing in "${TARGET_ENVIRONMENTS[@]:-}"; do
    if [[ "${existing}" == "${candidate}" ]]; then
      return 0
    fi
  done

  TARGET_ENVIRONMENTS+=("${candidate}")
}

ensure_environment_exists() {
  local environment="$1"

  if gh api "repos/${REPO_SLUG}/environments/${environment}" >/dev/null 2>&1; then
    echo "GitHub environment already exists: ${environment}"
    EXISTING_ENVIRONMENTS+=("${environment}")
    return 0
  fi

  echo "Creating GitHub environment: ${environment}"
  gh api --method PUT "repos/${REPO_SLUG}/environments/${environment}" >/dev/null
  CREATED_ENVIRONMENTS+=("${environment}")
}

sync_bootstrap_secrets_for_environment() {
  local environment="$1"

  echo "Syncing bootstrap-owned secrets for environment: ${environment}"
  "${REPO_ROOT}/scripts/sync-github-bootstrap-secrets.sh" \
    --env "${environment}" \
    --repo "${REPO_SLUG}" \
    --backend-config "${BACKEND_CONFIG_PATH}"
  SYNCED_ENVIRONMENTS+=("${environment}")
}

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO_SLUG="${2:-}"
      shift 2
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --env|--environment)
      case "${2:-}" in
        dev|staging|prod)
          append_unique_environment "${2}"
          ;;
        *)
          echo "Unsupported environment: ${2:-}" >&2
          exit 1
          ;;
      esac
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${#TARGET_ENVIRONMENTS[@]}" -eq 0 ]]; then
  append_unique_environment "dev"
  append_unique_environment "staging"
  append_unique_environment "prod"
fi

if [[ -z "${BACKEND_CONFIG_PATH}" ]]; then
  BACKEND_CONFIG_PATH="$(resolve_bootstrap_backend_config_path "${REPO_ROOT}" "${PROFILE_NAME}" "${BOOTSTRAP_TFVARS_PATH}")"
fi

if [[ ! -f "${BACKEND_CONFIG_PATH}" ]]; then
  echo "Backend config file not found: ${BACKEND_CONFIG_PATH}" >&2
  echo "Run bootstrap first, or pass --backend-config explicitly." >&2
  exit 1
fi

require_command gh
gh auth status >/dev/null

echo
echo "GitHub environment scaffold"
echo "Repository          : ${REPO_SLUG}"
echo "AWS profile         : ${PROFILE_NAME}"
echo "Backend config      : ${BACKEND_CONFIG_PATH}"
echo "Target environments : ${TARGET_ENVIRONMENTS[*]}"
echo
echo "This helper will create missing GitHub environments and sync bootstrap-owned secrets only."
echo "It will not configure protection rules, reviewers, branch policies, or PRD-02 secrets."

for environment in "${TARGET_ENVIRONMENTS[@]}"; do
  echo
  ensure_environment_exists "${environment}"
  sync_bootstrap_secrets_for_environment "${environment}"
done

echo
echo "GitHub scaffold summary"
if [[ "${#CREATED_ENVIRONMENTS[@]}" -gt 0 ]]; then
  echo "  Created environments : ${CREATED_ENVIRONMENTS[*]}"
else
  echo "  Created environments : none"
fi

if [[ "${#EXISTING_ENVIRONMENTS[@]}" -gt 0 ]]; then
  echo "  Existing environments: ${EXISTING_ENVIRONMENTS[*]}"
else
  echo "  Existing environments: none"
fi

if [[ "${#SYNCED_ENVIRONMENTS[@]}" -gt 0 ]]; then
  echo "  Synced bootstrap secrets for: ${SYNCED_ENVIRONMENTS[*]}"
else
  echo "  Synced bootstrap secrets for: none"
fi

echo
echo "Bootstrap-owned GitHub secrets synced:"
echo "  - AWS_ACCOUNT_ID"
echo "  - AWS_REGION"
echo "  - STATE_BUCKET"
echo "  - LOCK_TABLE"
echo "  - TF_EXEC_ROLE_ARN"
echo
echo "PRD-02 account baseline is still required before ENV_KMS_KEY_ARN can be populated."
echo "Protection rules and approval gates remain manual by design."
