#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP_HELPER="${REPO_ROOT}/scripts/lib/bootstrap-artifacts.sh"
# shellcheck source=/dev/null
source "${BOOTSTRAP_HELPER}"

BOOTSTRAP_TFVARS_PATH="$(bootstrap_tfvars_path "${REPO_ROOT}")"
ENVIRONMENTS_ROOT="${REPO_ROOT}/environments"
REPORTS_ROOT="${REPO_ROOT}/reports/plan-audits"
MODULE_CATALOG="${REPO_ROOT}/modules/dependency-order.json"
MANIFEST_HELPER="${REPO_ROOT}/scripts/module_manifest.py"
BOOTSTRAP_ARTIFACT_DIR="$(resolve_bootstrap_artifact_dir_from_repo_root "${REPO_ROOT}" "${BOOTSTRAP_TFVARS_PATH}")"

ENVIRONMENT="${1:-}"
REPORT_PATH="${2:-}"
BACKEND_CONFIG_PATH="${3:-}"
MANIFEST_PATH="${4:-}"

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

catalog_module_field() {
  local module_path="$1"
  local field_name="$2"
  python "${MANIFEST_HELPER}" module-field \
    --catalog "${MODULE_CATALOG}" \
    --module "${module_path}" \
    --field "${field_name}"
}

confirm_selection() {
  local environment="$1"
  local report_path="$2"
  local backend_path="$3"
  local manifest="$4"

  echo
  echo "About to run a read-only Terraform audit with:"
  echo "  Environment : ${environment}"
  echo "  Report      : ${report_path}"
  echo "  Manifest    : ${manifest}"
  echo "  Backend     : ${backend_path}"
  echo "  Locking     : disabled"
  echo "  Apply       : never"
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

append_report() {
  printf '%s\n' "$1" >> "${REPORT_PATH}"
}

append_report_file() {
  local file_path="$1"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" >> "${REPORT_PATH}"
  done < "${file_path}"
}

backend_config_field() {
  local field_name="$1"
  sed -nE "s/^[[:space:]]*${field_name}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\\1/p" "${BACKEND_CONFIG_PATH}" | head -n 1 | tr -d '\r'
}

workspace_missing() {
  local file_path="$1"
  grep -q "doesn't exist" "${file_path}"
}

if [[ -z "${ENVIRONMENT}" ]]; then
  ENVIRONMENT="$(select_from_list "Choose environment for audit" "dev" "staging" "prod")"
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

if [[ -z "${BACKEND_CONFIG_PATH}" ]]; then
  PROFILE_NAME="${AWS_PROFILE:-default}"
  BACKEND_CONFIG_PATH="${BOOTSTRAP_ARTIFACT_DIR}/backend-${PROFILE_NAME}.hcl"
fi

if [[ ! -f "${BACKEND_CONFIG_PATH}" ]]; then
  echo "Backend config file not found: ${BACKEND_CONFIG_PATH}"
  exit 1
fi

DERIVED_STATE_BUCKET="$(backend_config_field bucket)"
if [[ -z "${DERIVED_STATE_BUCKET}" ]]; then
  echo "Unable to derive state bucket from backend config: ${BACKEND_CONFIG_PATH}"
  exit 1
fi

mkdir -p "${REPORTS_ROOT}"

if [[ -z "${REPORT_PATH}" ]]; then
  TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
  REPORT_PATH="${REPORTS_ROOT}/tf-plan-audit-${ENVIRONMENT}-${TIMESTAMP}.md"
fi

mapfile -t MODULES < <(
  python "${MANIFEST_HELPER}" eligible-modules \
    --catalog "${MODULE_CATALOG}" \
    --manifest "${MANIFEST_PATH}" \
    --action audit
)

confirm_selection "${ENVIRONMENT}" "${REPORT_PATH}" "${BACKEND_CONFIG_PATH}" "${MANIFEST_PATH}"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

{
  echo "# Terraform Plan Audit"
  echo
  echo "- Environment: \`${ENVIRONMENT}\`"
  echo "- Generated: \`${STARTED_AT}\`"
  echo "- Manifest: \`${MANIFEST_PATH}\`"
  echo "- Backend config: \`${BACKEND_CONFIG_PATH}\`"
  echo "- Audit mode: read-only \`terraform plan\` only"
  echo "- State locking: disabled via \`-lock=false\`"
  echo
  echo "## Summary"
  echo
  echo "| Module | Status | Plan Summary |"
  echo "|---|---|---|"
} > "${REPORT_PATH}"

OVERALL_EXIT=0

for MODULE_PATH in "${MODULES[@]}"; do
  MODULE_ABS="${REPO_ROOT}/${MODULE_PATH}"
  STATE_KEY="$(catalog_module_field "${MODULE_PATH}" "state_key")"
  WORKSPACE_SCOPED="$(catalog_module_field "${MODULE_PATH}" "workspace_scoped")"
  DOMAIN_TFVARS_NAME="$(catalog_module_field "${MODULE_PATH}" "domain_tfvars")"
  DOMAIN_TFVARS=""

  if [[ -n "${DOMAIN_TFVARS_NAME}" ]]; then
    DOMAIN_TFVARS="${ENV_ROOT}/${DOMAIN_TFVARS_NAME}"
  fi

  if [[ ! -d "${MODULE_ABS}" ]]; then
    append_report "| \`${MODULE_PATH}\` | error | module directory missing |"
    append_report ""
    append_report "## ${MODULE_PATH}"
    append_report ""
    append_report "Module directory missing: \`${MODULE_ABS}\`"
    append_report ""
    OVERALL_EXIT=1
    continue
  fi

  INIT_ARGS=("-backend-config=${BACKEND_CONFIG_PATH}" "-backend-config=key=${STATE_KEY}")
  PLAN_ARGS=("-var-file=${GLOBAL_TFVARS}")

  if [[ -n "${DOMAIN_TFVARS}" ]]; then
    if [[ ! -f "${DOMAIN_TFVARS}" ]]; then
      append_report "| \`${MODULE_PATH}\` | error | missing tfvars \`${DOMAIN_TFVARS}\` |"
      append_report ""
      append_report "## ${MODULE_PATH}"
      append_report ""
      append_report "Missing required tfvars file: \`${DOMAIN_TFVARS}\`"
      append_report ""
      OVERALL_EXIT=1
      continue
    fi
    PLAN_ARGS+=("-var-file=${DOMAIN_TFVARS}")
  fi

  MODULE_TMP_DIR="${MODULE_ABS}/.plan-audit"
  mkdir -p "${MODULE_TMP_DIR}"
  INIT_LOG="${MODULE_TMP_DIR}/init-${ENVIRONMENT}.log"
  PLAN_LOG="${MODULE_TMP_DIR}/plan-${ENVIRONMENT}.log"
  PLAN_SHOW="${MODULE_TMP_DIR}/show-${ENVIRONMENT}.txt"
  PLAN_BINARY="${MODULE_TMP_DIR}/tfplan-${ENVIRONMENT}.binary"

  set +e
  (
    cd "${MODULE_ABS}"

    if [[ "${MODULE_PATH}" != "modules/bootstrap" ]]; then
      export TF_VAR_state_bucket="${DERIVED_STATE_BUCKET}"
    fi

    set +e
    terraform init "${INIT_ARGS[@]}" > "${INIT_LOG}" 2>&1
    INIT_EXIT=$?
    if [[ "${INIT_EXIT}" -ne 0 ]]; then
      exit 10
    fi

    if [[ "${WORKSPACE_SCOPED}" == "true" ]]; then
      terraform workspace select "${ENVIRONMENT}" > "${MODULE_TMP_DIR}/workspace-${ENVIRONMENT}.log" 2>&1
      WORKSPACE_EXIT=$?
      if [[ "${WORKSPACE_EXIT}" -ne 0 ]]; then
        if workspace_missing "${MODULE_TMP_DIR}/workspace-${ENVIRONMENT}.log"; then
          exit 12
        fi
        exit 11
      fi
    fi

    terraform plan \
      -lock=false \
      -input=false \
      -detailed-exitcode \
      -no-color \
      -out="${PLAN_BINARY}" \
      "${PLAN_ARGS[@]}" > "${PLAN_LOG}" 2>&1
    PLAN_EXIT=$?
    set -e

    if [[ "${PLAN_EXIT}" -eq 2 ]]; then
      terraform show -no-color "${PLAN_BINARY}" > "${PLAN_SHOW}"
    fi

    exit "${PLAN_EXIT}"
  )
  PLAN_EXIT=$?
  set -e

  case "${PLAN_EXIT}" in
    0)
      STATUS="no changes"
      SUMMARY_TEXT="No infrastructure changes."
      ;;
    2)
      STATUS="changes detected"
      SUMMARY_TEXT="$(grep '^Plan:' "${PLAN_LOG}" | tail -n 1 || true)"
      if [[ -z "${SUMMARY_TEXT}" ]]; then
        SUMMARY_TEXT="Changes detected. Review detailed diff below."
      fi
      ;;
    10)
      STATUS="error"
      SUMMARY_TEXT="Terraform init failed. Review error output below."
      OVERALL_EXIT=1
      ;;
    11)
      STATUS="error"
      SUMMARY_TEXT="Workspace selection failed. Review error output below."
      OVERALL_EXIT=1
      ;;
    12)
      STATUS="not yet deployed"
      SUMMARY_TEXT="Workspace does not exist for this module/environment yet."
      ;;
    *)
      STATUS="error"
      SUMMARY_TEXT="Plan failed. Review error output below."
      OVERALL_EXIT=1
      ;;
  esac

  SUMMARY_TEXT="${SUMMARY_TEXT//|/\\|}"
  append_report "| \`${MODULE_PATH}\` | ${STATUS} | ${SUMMARY_TEXT} |"
  append_report ""
  append_report "## ${MODULE_PATH}"
  append_report ""
  append_report "- Status: ${STATUS}"
  append_report "- Workspace: \`$([[ "${WORKSPACE_SCOPED}" == "true" ]] && echo "${ENVIRONMENT}" || echo "default")\`"
  append_report "- State key: \`${STATE_KEY}\`"
  append_report ""

  if [[ "${PLAN_EXIT}" -eq 2 ]]; then
    append_report "### Plan Summary"
    append_report ""
    append_report "\`\`\`text"
    append_report_file "${PLAN_LOG}"
    append_report "\`\`\`"
    append_report ""
    append_report "### Detailed Diff"
    append_report ""
    append_report "<details>"
    append_report "<summary>Expand plan diff</summary>"
    append_report ""
    append_report "\`\`\`text"
    append_report_file "${PLAN_SHOW}"
    append_report "\`\`\`"
    append_report ""
    append_report "</details>"
    append_report ""
  elif [[ "${PLAN_EXIT}" -eq 0 ]]; then
    append_report "### Plan Output"
    append_report ""
    append_report "\`\`\`text"
    append_report_file "${PLAN_LOG}"
    append_report "\`\`\`"
    append_report ""
  elif [[ "${PLAN_EXIT}" -eq 12 ]]; then
    append_report "### Audit Note"
    append_report ""
    append_report "\`\`\`text"
    append_report_file "${MODULE_TMP_DIR}/workspace-${ENVIRONMENT}.log"
    append_report "\`\`\`"
    append_report ""
  else
    append_report "### Error Output"
    append_report ""
    append_report "\`\`\`text"
    if [[ "${PLAN_EXIT}" -eq 10 ]]; then
      append_report_file "${INIT_LOG}"
    elif [[ "${PLAN_EXIT}" -eq 11 ]]; then
      append_report_file "${MODULE_TMP_DIR}/workspace-${ENVIRONMENT}.log"
    else
      append_report_file "${PLAN_LOG}"
    fi
    append_report "\`\`\`"
    append_report ""
  fi
done

FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
append_report "## Run Metadata"
append_report ""
append_report "- Completed: \`${FINISHED_AT}\`"
append_report "- Result: \`$([[ "${OVERALL_EXIT}" -eq 0 ]] && echo "completed" || echo "completed with errors")\`"
append_report ""

echo
echo "Audit complete."
echo "Report written to: ${REPORT_PATH}"

exit "${OVERALL_EXIT}"
