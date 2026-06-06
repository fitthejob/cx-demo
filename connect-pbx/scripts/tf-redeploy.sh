#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="$(basename "${REPO_ROOT}")"
ENVIRONMENTS_ROOT="${REPO_ROOT}/environments"
MODULE_CATALOG="${REPO_ROOT}/modules/dependency-order.json"
MANIFEST_HELPER="${REPO_ROOT}/scripts/module_manifest.py"
TF_RUNNER="${REPO_ROOT}/scripts/tf-run.sh"

if [[ -n "${CONNECT_PBX_BOOTSTRAP_DIR:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${CONNECT_PBX_BOOTSTRAP_DIR}"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${LOCALAPPDATA}/connect-pbx/${REPO_SLUG}/bootstrap"
else
  BOOTSTRAP_ARTIFACT_DIR="${HOME}/.connect-pbx/${REPO_SLUG}/bootstrap"
fi

MODE=""
ENVIRONMENT=""
MANIFEST_PATH=""
BACKEND_CONFIG_PATH=""
EXECUTE=false

usage() {
  cat <<'EOF'
Usage:
  scripts/tf-redeploy.sh --mode <retain-stateful|retain-core|destroy-all> --env <dev|staging|prod> [--execute]

Modes:
  retain-stateful  Re-applies the modules that would be destroyed by retain-stateful teardown.
  retain-core      Re-applies the modules that would be destroyed by retain-core teardown.
  destroy-all      Re-applies all enabled modules except bootstrap, which requires separate backend/bootstrap recovery.

Behavior:
  Without --execute, prints a redeploy plan only.
  With --execute, applies target modules in forward dependency order.

Notes:
  - This is designed as the inverse of tf-teardown.sh.
  - Bootstrap is intentionally excluded from automated redeploy recovery here because it owns the backend itself.
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

in_retention_profile() {
  local mode="$1"
  local module_path="$2"

  case "${mode}" in
    retain-stateful)
      case "${module_path}" in
        modules/bootstrap|modules/l0-account-baseline|modules/l0-audit-pipeline|modules/l1-connect-instance|modules/l1-phone-numbers)
          return 0
          ;;
      esac
      ;;
    retain-core)
      case "${module_path}" in
        modules/bootstrap|modules/l0-account-baseline|modules/l1-connect-instance|modules/l1-phone-numbers)
          return 0
          ;;
      esac
      ;;
    destroy-all)
      ;;
    *)
      echo "Unsupported mode: ${mode}"
      exit 1
      ;;
  esac

  return 1
}

print_list() {
  local title="$1"
  shift
  local items=("$@")

  echo
  echo "${title}"
  if [[ "${#items[@]}" -eq 0 ]]; then
    echo "  (none)"
    return
  fi

  for item in "${items[@]}"; do
    echo "  - ${item}"
  done
}

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    --env|--environment)
      ENVIRONMENT="${2:-}"
      shift 2
      ;;
    --manifest)
      MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    --backend-config)
      BACKEND_CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --execute)
      EXECUTE=true
      shift
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

if [[ -z "${MODE}" || -z "${ENVIRONMENT}" ]]; then
  usage
  exit 1
fi

if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "staging" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Unsupported environment: ${ENVIRONMENT}"
  exit 1
fi

ENV_ROOT="${ENVIRONMENTS_ROOT}/${ENVIRONMENT}"
if [[ ! -d "${ENV_ROOT}" ]]; then
  echo "Environment directory does not exist: ${ENV_ROOT}"
  exit 1
fi

if [[ -z "${MANIFEST_PATH}" ]]; then
  MANIFEST_PATH="${ENV_ROOT}/deployment-manifest.json"
fi

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  echo "Deployment manifest not found: ${MANIFEST_PATH}"
  exit 1
fi

if [[ -z "${BACKEND_CONFIG_PATH}" ]]; then
  PROFILE_NAME="${AWS_PROFILE:-default}"
  BACKEND_CONFIG_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"
fi

python "${MANIFEST_HELPER}" validate \
  --catalog "${MODULE_CATALOG}" \
  --manifest "${MANIFEST_PATH}" >/dev/null

mapfile -t ENABLED_MODULES < <(
  python "${MANIFEST_HELPER}" eligible-modules \
    --catalog "${MODULE_CATALOG}" \
    --manifest "${MANIFEST_PATH}" \
    --action apply | tr -d '\r'
)

if [[ "${#ENABLED_MODULES[@]}" -eq 0 ]]; then
  echo "No enabled modules found in manifest: ${MANIFEST_PATH}"
  exit 1
fi

declare -a RETAINED_MODULES=()
declare -a REDEPLOY_TARGETS=()
declare -a BLOCKERS=()

for module_path in "${ENABLED_MODULES[@]}"; do
  if in_retention_profile "${MODE}" "${module_path}"; then
    RETAINED_MODULES+=("${module_path}")
    continue
  fi

  if [[ "${module_path}" == "modules/bootstrap" ]]; then
    BLOCKERS+=("${module_path} :: bootstrap recovery is excluded from automated redeploy because it owns the backend")
    continue
  fi

  REDEPLOY_TARGETS+=("${module_path}")
done

echo
echo "Terraform redeploy planner"
echo "Mode        : ${MODE}"
echo "Environment : ${ENVIRONMENT}"
echo "Manifest    : ${MANIFEST_PATH}"
echo "Backend     : ${BACKEND_CONFIG_PATH}"

print_list "Retained modules" "${RETAINED_MODULES[@]}"
print_list "Redeploy target modules (forward dependency order)" "${REDEPLOY_TARGETS[@]}"
print_list "Blockers / manual-prerequisite modules" "${BLOCKERS[@]}"

echo
echo "Guardrails:"
echo "  - This runner mirrors tf-teardown.sh retention modes."
echo "  - retain-stateful redeploy will re-apply modules that were destroyed while keeping audit/core modules retained."
echo "  - retain-core redeploy will re-apply audit and optional modules, including AWS Config and Security Hub via modules/l0-audit-pipeline."
echo "  - destroy-all redeploy excludes bootstrap because backend/bootstrap recovery is a separate procedure."

if [[ "${EXECUTE}" != "true" ]]; then
  echo
  echo "Dry run only. Re-run with --execute to apply the listed redeploy target modules."
  exit 0
fi

if [[ "${#REDEPLOY_TARGETS[@]}" -eq 0 ]]; then
  echo
  echo "No redeploy target modules selected for mode ${MODE}."
  exit 0
fi

echo
echo "About to apply ${#REDEPLOY_TARGETS[@]} modules in ${ENVIRONMENT}:"
for module_path in "${REDEPLOY_TARGETS[@]}"; do
  echo "  - ${module_path}"
done
echo

CONFIRMATION_PHRASE="REDEPLOY ${ENVIRONMENT} ${MODE}"
read -r -p "Type '${CONFIRMATION_PHRASE}' to continue: " confirmation
if [[ "${confirmation}" != "${CONFIRMATION_PHRASE}" ]]; then
  echo "Aborted."
  exit 1
fi

for module_path in "${REDEPLOY_TARGETS[@]}"; do
  echo
  echo "Applying ${module_path}..."
  bash "${TF_RUNNER}" apply "${ENVIRONMENT}" "${module_path}" "${BACKEND_CONFIG_PATH}" "${MANIFEST_PATH}"
done

echo
echo "Redeploy complete for mode ${MODE}."
