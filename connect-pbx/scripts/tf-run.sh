#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="$(basename "${REPO_ROOT}")"
ENVIRONMENTS_ROOT="${REPO_ROOT}/environments"
MODULE_CATALOG="${REPO_ROOT}/modules/dependency-order.json"
MANIFEST_HELPER="${REPO_ROOT}/scripts/module_manifest.py"
NONINTERACTIVE="${CONNECT_PBX_NONINTERACTIVE:-0}"

if [[ -n "${CONNECT_PBX_BOOTSTRAP_DIR:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${CONNECT_PBX_BOOTSTRAP_DIR}"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${LOCALAPPDATA}/connect-pbx/${REPO_SLUG}/bootstrap"
else
  BOOTSTRAP_ARTIFACT_DIR="${HOME}/.connect-pbx/${REPO_SLUG}/bootstrap"
fi

ACTION="${1:-}"
ENVIRONMENT="${2:-}"
MODULE_PATH="${3:-}"
BACKEND_CONFIG_PATH="${4:-}"
MANIFEST_PATH="${5:-}"

select_from_list() {
  local prompt="$1"
  shift
  local options=("$@")

  echo
  echo "${prompt}"
  for i in "${!options[@]}"; do
    printf '[%d] %s\n' "$((i + 1))" "${options[$i]}"
  done

  while true; do
    read -r -p "Enter number: " selection
    if [[ "${selection}" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#options[@]} )); then
      echo "${options[$((selection - 1))]}"
      return 0
    fi
    echo "Invalid selection. Try again."
  done
}

run_terraform() {
  echo
  echo "terraform $*"
  terraform "$@"
}

backend_config_field() {
  local field_name="$1"
  sed -nE "s/^[[:space:]]*${field_name}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\\1/p" "${BACKEND_CONFIG_PATH}" | head -n 1 | tr -d '\r'
}

resolve_python_executable() {
  local candidate=""

  # On Windows, prefer stable launcher names over resolved WindowsApps shim
  # paths so Terraform local-exec can invoke them through cmd.exe.
  if command -v cygpath >/dev/null 2>&1; then
    if command -v python >/dev/null 2>&1; then
      printf '%s\n' "python"
      return 0
    fi
    if command -v py >/dev/null 2>&1; then
      printf '%s\n' "py"
      return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
      printf '%s\n' "python3"
      return 0
    fi
    echo "Unable to find a Python interpreter in PATH. Expected python, py, or python3." >&2
    exit 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    candidate="python3"
  elif command -v python >/dev/null 2>&1; then
    candidate="python"
  else
    echo "Unable to find a Python interpreter in PATH. Expected python3 or python." >&2
    exit 1
  fi

  printf '%s\n' "${candidate}"
}

run_post_apply_secret_sync() {
  local module_path="$1"
  local environment="$2"
  local backend_config_path="$3"

  local sync_targets=()
  case "${module_path}" in
    modules/bootstrap)
      sync_targets+=("bootstrap")
      ;;
    modules/l0-account-baseline)
      sync_targets+=("env")
      ;;
    modules/l0-audit-pipeline)
      sync_targets+=("env" "audit")
      ;;
    *)
      return 0
      ;;
  esac

  echo
  echo "Detected post-apply GitHub secret sync targets: ${sync_targets[*]}"

  local target
  for target in "${sync_targets[@]}"; do
    case "${target}" in
      bootstrap)
        echo "Syncing bootstrap-derived GitHub Actions secrets..."
        if ! "${REPO_ROOT}/scripts/sync-github-bootstrap-secrets.sh" --env "${environment}" --backend-config "${backend_config_path}"; then
          echo "Warning: bootstrap GitHub secret sync failed. Infrastructure apply succeeded; rerun sync manually." >&2
        fi
        ;;
      env)
        echo "Syncing environment GitHub Actions secrets..."
        if ! "${REPO_ROOT}/scripts/sync-github-env-secrets.sh" --env "${environment}" --backend-config "${backend_config_path}"; then
          echo "Warning: environment GitHub secret sync failed. Infrastructure apply succeeded; rerun sync manually." >&2
        fi
        ;;
      audit)
        echo "Syncing audit GitHub Actions secrets..."
        if ! "${REPO_ROOT}/scripts/sync-github-audit-secrets.sh" --env "${environment}" --backend-config "${backend_config_path}"; then
          echo "Warning: audit GitHub secret sync failed. Infrastructure apply succeeded; rerun sync manually." >&2
        fi
        ;;
    esac
  done
}

run_pre_destroy_cleanup() {
  local module_path="$1"
  local environment="$2"
  local backend_config_path="$3"

  case "${module_path}" in
    modules/l0-audit-pipeline)
      echo
      echo "Running pre-destroy cleanup for PRD-03 audit buckets..."
      "${REPO_ROOT}/scripts/pre-destroy-audit-buckets.sh" --env "${environment}" --backend-config "${backend_config_path}"
      ;;
  esac
}

TEMP_DESTROY_WORKDIR=""
RUN_MODULE_ABS=""

cleanup_temp_destroy_workspace() {
  if [[ -n "${TEMP_DESTROY_WORKDIR}" && -d "${TEMP_DESTROY_WORKDIR}" ]]; then
    rm -rf "${TEMP_DESTROY_WORKDIR}"
  fi
}

trap cleanup_temp_destroy_workspace EXIT

prepare_operator_destroy_workspace() {
  local module_abs="$1"

  RUN_MODULE_ABS="${module_abs}"

  if [[ "${ACTION}" != "destroy" || "${SUPPORTS_OPERATOR_DESTROY}" != "true" || "${ALLOW_OPERATOR_DESTROY}" != "true" ]]; then
    return 0
  fi

  TEMP_DESTROY_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/connect-pbx-operator-destroy.XXXXXX")"
  cp -R "${module_abs}/." "${TEMP_DESTROY_WORKDIR}/"

  local replaced=0
  while IFS= read -r -d '' tf_file; do
    if grep -q 'prevent_destroy = true' "${tf_file}"; then
      sed -i.bak 's/prevent_destroy = true/prevent_destroy = false/g' "${tf_file}"
      rm -f "${tf_file}.bak"
      replaced=$((replaced + 1))
    fi
  done < <(find "${TEMP_DESTROY_WORKDIR}" -type f -name '*.tf' -print0)

  if [[ "${replaced}" -eq 0 ]]; then
    echo "Approved operator destroy requested, but no prevent_destroy guards were found in ${module_abs}" >&2
    exit 1
  fi

  echo
  echo "Prepared temporary operator-destroy workspace: ${TEMP_DESTROY_WORKDIR}"
  echo "Lifecycle guards were lifted only in this temporary copy for the approved destroy run."
  RUN_MODULE_ABS="${TEMP_DESTROY_WORKDIR}"
}

catalog_module_field() {
  local module_path="$1"
  local field_name="$2"
  python "${MANIFEST_HELPER}" module-field \
    --catalog "${MODULE_CATALOG}" \
    --module "${module_path}" \
    --field "${field_name}" | tr -d '\r'
}

confirm_selection() {
  local action="$1"
  local environment="$2"
  local module="$3"
  local manifest="$4"

  if [[ "${NONINTERACTIVE}" == "1" || "${NONINTERACTIVE}" == "true" || "${NONINTERACTIVE}" == "yes" ]]; then
    echo
    echo "Non-interactive mode enabled via CONNECT_PBX_NONINTERACTIVE; skipping confirmation prompt."
    return 0
  fi

  echo
  echo "About to run Terraform with:"
  echo "  Action      : ${action}"
  echo "  Environment : ${environment}"
  echo "  Module      : ${module}"
  echo "  Manifest    : ${manifest}"
  echo

  while true; do
    read -r -p "Continue? Type 'yes' to proceed: " confirmation
    case "${confirmation}" in
      yes) return 0 ;;
      no|"")
        echo "Aborted."
        exit 1
        ;;
      *)
        echo "Please type 'yes' to proceed or press Enter to abort."
        ;;
    esac
  done
}

if [[ -z "${ACTION}" ]]; then
  ACTION="$(select_from_list "Choose action" "plan" "apply" "destroy")"
fi

if [[ "${ACTION}" != "plan" && "${ACTION}" != "apply" && "${ACTION}" != "destroy" ]]; then
  echo "Unsupported action: ${ACTION}"
  exit 1
fi

if [[ -z "${ENVIRONMENT}" ]]; then
  ENVIRONMENT="$(select_from_list "Choose environment" "dev" "staging" "prod")"
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

python "${MANIFEST_HELPER}" validate \
  --catalog "${MODULE_CATALOG}" \
  --manifest "${MANIFEST_PATH}" >/dev/null

GLOBAL_TFVARS="${ENV_ROOT}/global.tfvars"
if [[ ! -f "${GLOBAL_TFVARS}" ]]; then
  echo "Missing required tfvars file: ${GLOBAL_TFVARS}"
  exit 1
fi

if [[ -z "${MODULE_PATH}" ]]; then
  mapfile -t ELIGIBLE_MODULES < <(
    python "${MANIFEST_HELPER}" eligible-modules \
      --catalog "${MODULE_CATALOG}" \
      --manifest "${MANIFEST_PATH}" \
      --action "${ACTION}" | tr -d '\r'
  )

  if [[ "${#ELIGIBLE_MODULES[@]}" -eq 0 ]]; then
    echo "No eligible modules found for action '${ACTION}' in manifest ${MANIFEST_PATH}"
    exit 1
  fi

  MODULE_PATH="$(select_from_list "Choose module" "${ELIGIBLE_MODULES[@]}")"
fi

mapfile -t ELIGIBLE_MODULES < <(
  python "${MANIFEST_HELPER}" eligible-modules \
    --catalog "${MODULE_CATALOG}" \
    --manifest "${MANIFEST_PATH}" \
    --action "${ACTION}" | tr -d '\r'
)

module_supported=false
for candidate in "${ELIGIBLE_MODULES[@]}"; do
  if [[ "${MODULE_PATH}" == "${candidate}" ]]; then
    module_supported=true
    break
  fi
done

SUPPORTS_OPERATOR_DESTROY="$(catalog_module_field "${MODULE_PATH}" "supports_operator_destroy")"

ALLOW_OPERATOR_DESTROY=false
case "${CONNECT_PBX_ALLOW_OPERATOR_DESTROY:-0}" in
  1|true|TRUE|yes|YES)
    ALLOW_OPERATOR_DESTROY=true
    ;;
esac

if [[ "${module_supported}" != "true" && "${ACTION}" == "destroy" && "${SUPPORTS_OPERATOR_DESTROY}" == "true" && "${ALLOW_OPERATOR_DESTROY}" == "true" ]]; then
  module_supported=true
fi

if [[ "${module_supported}" != "true" ]]; then
  echo "Module is not enabled for action '${ACTION}' in manifest: ${MODULE_PATH}"
  exit 1
fi

MODULE_ABS="${REPO_ROOT}/${MODULE_PATH}"
if [[ ! -d "${MODULE_ABS}" ]]; then
  echo "Module path does not exist: ${MODULE_ABS}"
  exit 1
fi

DOMAIN_TFVARS_NAME="$(catalog_module_field "${MODULE_PATH}" "domain_tfvars")"
DOMAIN_TFVARS=""
if [[ -n "${DOMAIN_TFVARS_NAME}" ]]; then
  DOMAIN_TFVARS="${ENV_ROOT}/${DOMAIN_TFVARS_NAME}"
fi

if [[ -n "${DOMAIN_TFVARS}" && ! -f "${DOMAIN_TFVARS}" ]]; then
  echo "Missing required tfvars file: ${DOMAIN_TFVARS}"
  exit 1
fi

if [[ -z "${BACKEND_CONFIG_PATH}" ]]; then
  PROFILE_NAME="${AWS_PROFILE:-default}"
  BACKEND_CONFIG_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"
fi

WORKSPACE_SCOPED="$(catalog_module_field "${MODULE_PATH}" "workspace_scoped")"
STATE_KEY="$(catalog_module_field "${MODULE_PATH}" "state_key")"
SUPPORTS_DESTROY="$(catalog_module_field "${MODULE_PATH}" "supports_destroy")"

IS_BOOTSTRAP=false
if [[ "${WORKSPACE_SCOPED}" == "false" ]]; then
  IS_BOOTSTRAP=true
fi

if [[ "${ACTION}" == "destroy" ]]; then
  DESTROY_ALLOWED=false
  if [[ "${SUPPORTS_DESTROY}" == "true" ]]; then
    DESTROY_ALLOWED=true
  elif [[ "${SUPPORTS_OPERATOR_DESTROY}" == "true" && "${ALLOW_OPERATOR_DESTROY}" == "true" ]]; then
    DESTROY_ALLOWED=true
  fi

  if [[ "${DESTROY_ALLOWED}" != "true" ]]; then
    if [[ "${SUPPORTS_OPERATOR_DESTROY}" == "true" ]]; then
      echo "Module requires an explicitly approved operator destroy run: ${MODULE_PATH}"
      echo "Set CONNECT_PBX_ALLOW_OPERATOR_DESTROY=1 only for the approved run that should lift the lifecycle guard."
    else
      echo "Module is not marked destroyable in the module catalog: ${MODULE_PATH}"
    fi
    exit 1
  fi
fi

if [[ ! -f "${BACKEND_CONFIG_PATH}" ]]; then
  if [[ "${IS_BOOTSTRAP}" == "true" ]]; then
    echo "Backend config file not found: ${BACKEND_CONFIG_PATH}"
    echo "For first-time bootstrap, use modules/bootstrap/scripts/bootstrap.sh."
    echo "If the backend already exists on another machine, regenerate or copy the backend file into ${BOOTSTRAP_ARTIFACT_DIR}"
    exit 1
  fi
  echo "Backend config file not found: ${BACKEND_CONFIG_PATH}"
  exit 1
fi

echo
echo "Terraform local runner"
echo "Action      : ${ACTION}"
echo "Environment : ${ENVIRONMENT}"
echo "Module      : ${MODULE_PATH}"
echo "Manifest    : ${MANIFEST_PATH}"
echo "Backend     : ${BACKEND_CONFIG_PATH}"
echo "Artifacts   : ${BOOTSTRAP_ARTIFACT_DIR}"

confirm_selection "${ACTION}" "${ENVIRONMENT}" "${MODULE_PATH}" "${MANIFEST_PATH}"

prepare_operator_destroy_workspace "${MODULE_ABS}"

cd "${RUN_MODULE_ABS}"

run_terraform init \
  -reconfigure \
  "-backend-config=${BACKEND_CONFIG_PATH}" \
  "-backend-config=key=${STATE_KEY}"

if [[ "${IS_BOOTSTRAP}" != "true" ]]; then
  TF_VAR_state_bucket="$(backend_config_field bucket)"
  if [[ -z "${TF_VAR_state_bucket}" ]]; then
    echo "Unable to derive state bucket from backend config: ${BACKEND_CONFIG_PATH}"
    exit 1
  fi
  export TF_VAR_state_bucket
  TF_VAR_python_executable="$(resolve_python_executable)"
  export TF_VAR_python_executable

  if ! terraform workspace select "${ENVIRONMENT}" >/dev/null 2>&1; then
    terraform workspace new "${ENVIRONMENT}"
  fi
fi

TF_ARGS=("${ACTION}" "-var-file=${GLOBAL_TFVARS}")
if [[ -n "${DOMAIN_TFVARS}" ]]; then
  TF_ARGS+=("-var-file=${DOMAIN_TFVARS}")
fi
if [[ "${NONINTERACTIVE}" == "1" || "${NONINTERACTIVE}" == "true" || "${NONINTERACTIVE}" == "yes" ]]; then
  TF_ARGS+=("-input=false")
  if [[ "${ACTION}" == "apply" || "${ACTION}" == "destroy" ]]; then
    TF_ARGS+=("-auto-approve")
  fi
fi

if [[ "${ACTION}" == "destroy" ]]; then
  run_pre_destroy_cleanup "${MODULE_PATH}" "${ENVIRONMENT}" "${BACKEND_CONFIG_PATH}"
fi

run_terraform "${TF_ARGS[@]}"

if [[ "${ACTION}" == "apply" ]]; then
  run_post_apply_secret_sync "${MODULE_PATH}" "${ENVIRONMENT}" "${BACKEND_CONFIG_PATH}"
fi
