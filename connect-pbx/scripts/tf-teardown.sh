#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_HELPER="${REPO_ROOT}/scripts/lib/bootstrap-artifacts.sh"
# shellcheck source=/dev/null
source "${BOOTSTRAP_HELPER}"

BOOTSTRAP_TFVARS_PATH="$(bootstrap_tfvars_path "${REPO_ROOT}")"
ENVIRONMENTS_ROOT="${REPO_ROOT}/environments"
MODULE_CATALOG="${REPO_ROOT}/modules/dependency-order.json"
MANIFEST_HELPER="${REPO_ROOT}/scripts/module_manifest.py"
TF_RUNNER="${REPO_ROOT}/scripts/tf-run.sh"
BOOTSTRAP_ARTIFACT_DIR="$(resolve_bootstrap_artifact_dir_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"

MODE=""
ENVIRONMENT=""
MANIFEST_PATH=""
BACKEND_CONFIG_PATH=""
EXECUTE=false

usage() {
  cat <<'EOF'
Usage:
  scripts/tf-teardown.sh --mode <retain-stateful|retain-core|destroy-all> --env <dev|staging|prod> [--execute]

Modes:
  retain-stateful  Retains bootstrap, account baseline, audit pipeline, connect instance, and phone numbers.
  retain-core      Retains bootstrap, account baseline, connect instance, and phone numbers.
  destroy-all      Targets every enabled module, but still reports blockers for modules not marked destroyable.

Behavior:
  Without --execute, prints a teardown report only.
  With --execute, destroys destroyable target modules in reverse dependency order.

Notes:
  - Bootstrap destroy is intentionally reported as a blocker in automation today because it owns the remote backend.
  - Phone numbers are intentionally retained by default and are not auto-destroyable because PRD-11 uses prevent_destroy.
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

reverse_lines() {
  local -n input_ref=$1
  local -n output_ref=$2
  output_ref=()
  for (( idx=${#input_ref[@]}-1; idx>=0; idx-- )); do
    output_ref+=("${input_ref[idx]}")
  done
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
    --action plan | tr -d '\r'
)

if [[ "${#ENABLED_MODULES[@]}" -eq 0 ]]; then
  echo "No enabled modules found in manifest: ${MANIFEST_PATH}"
  exit 1
fi

declare -a RETAINED_MODULES=()
declare -a DESTROYABLE_TARGETS=()
declare -a BLOCKERS=()

for module_path in "${ENABLED_MODULES[@]}"; do
  if in_retention_profile "${MODE}" "${module_path}"; then
    RETAINED_MODULES+=("${module_path}")
    continue
  fi

  if [[ "${module_path}" == "modules/bootstrap" ]]; then
    BLOCKERS+=("${module_path} :: bootstrap owns the remote backend and requires a separate local-state destroy procedure")
    continue
  fi

  supports_destroy="$(catalog_module_field "${module_path}" "supports_destroy")"
  if [[ "${supports_destroy}" == "true" ]]; then
    DESTROYABLE_TARGETS+=("${module_path}")
  else
    BLOCKERS+=("${module_path} :: not marked supports_destroy=true in the module catalog")
  fi
done

declare -a DESTROY_ORDER=()
reverse_lines DESTROYABLE_TARGETS DESTROY_ORDER

echo
echo "Terraform teardown planner"
echo "Mode        : ${MODE}"
echo "Environment : ${ENVIRONMENT}"
echo "Manifest    : ${MANIFEST_PATH}"
echo "Backend     : ${BACKEND_CONFIG_PATH}"

print_list "Retained modules" "${RETAINED_MODULES[@]}"
print_list "Destroyable target modules" "${DESTROYABLE_TARGETS[@]}"
print_list "Destroy order (reverse dependency order)" "${DESTROY_ORDER[@]}"
print_list "Blockers / manual-prerequisite modules" "${BLOCKERS[@]}"

echo
echo "Guardrails:"
echo "  - PRD-11 phone numbers are retained by default and are not auto-destroyable."
echo "  - Bootstrap is not auto-destroyed here because it owns the remote backend."
echo "  - Use retain-stateful for the safest park profile."
echo "  - retain-stateful keeps AWS Config and Security Hub because it retains modules/l0-audit-pipeline."
echo "  - retain-core destroys AWS Config and Security Hub because modules/l0-audit-pipeline becomes a destroy target."
echo "  - destroy-all also destroys AWS Config and Security Hub because modules/l0-audit-pipeline becomes a destroy target."

if [[ "${EXECUTE}" != "true" ]]; then
  echo
  echo "Dry run only. Re-run with --execute to destroy the listed destroyable target modules."
  exit 0
fi

if [[ "${#BLOCKERS[@]}" -gt 0 ]]; then
  echo
  echo "Teardown aborted. Resolve blockers or choose a retention mode that keeps them."
  exit 1
fi

if [[ "${#DESTROY_ORDER[@]}" -eq 0 ]]; then
  echo
  echo "No destroyable modules selected for mode ${MODE}."
  exit 0
fi

echo
echo "About to destroy ${#DESTROY_ORDER[@]} modules in ${ENVIRONMENT}:"
for module_path in "${DESTROY_ORDER[@]}"; do
  echo "  - ${module_path}"
done
echo

CONFIRMATION_PHRASE="DESTROY ${ENVIRONMENT} ${MODE}"
read -r -p "Type '${CONFIRMATION_PHRASE}' to continue: " confirmation
if [[ "${confirmation}" != "${CONFIRMATION_PHRASE}" ]]; then
  echo "Aborted."
  exit 1
fi

for module_path in "${DESTROY_ORDER[@]}"; do
  echo
  echo "Destroying ${module_path}..."
  bash "${TF_RUNNER}" destroy "${ENVIRONMENT}" "${module_path}" "${BACKEND_CONFIG_PATH}" "${MANIFEST_PATH}"
done

echo
echo "Teardown complete for destroyable target modules in mode ${MODE}."
