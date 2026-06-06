#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_SLUG="$(basename "${REPO_ROOT}")"
MODULE_CATALOG="${REPO_ROOT}/modules/dependency-order.json"
MANIFEST_HELPER="${REPO_ROOT}/scripts/module_manifest.py"

if [[ -n "${CONNECT_PBX_BOOTSTRAP_DIR:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${CONNECT_PBX_BOOTSTRAP_DIR}"
elif [[ -n "${LOCALAPPDATA:-}" ]]; then
  BOOTSTRAP_ARTIFACT_DIR="${LOCALAPPDATA}/connect-pbx/${REPO_SLUG}/bootstrap"
else
  BOOTSTRAP_ARTIFACT_DIR="${HOME}/.connect-pbx/${REPO_SLUG}/bootstrap"
fi

ENVIRONMENT=""
BACKEND_CONFIG_PATH=""
PROFILE_NAME="${AWS_PROFILE:-default}"

usage() {
  cat <<'EOF'
Usage:
  scripts/pre-destroy-audit-buckets.sh --env <dev|staging|prod> [--backend-config <path>]

Behavior:
  - Initializes l0-audit-pipeline against the remote backend
  - Selects the requested Terraform workspace in l0-audit-pipeline
  - Derives audit bucket names from org_name + account id
  - Attempts to assume the bootstrap terraform execution role when available
  - Empties audit buckets, including versioned objects and delete markers

Notes:
  - Intended for the PRD-03 destroy path when bucket policies block local object deletion
  - Requires AWS CLI and Python
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

strip_cr() {
  tr -d '\r'
}

global_tfvars_field() {
  local field_name="$1"
  local tfvars_path="${REPO_ROOT}/environments/${ENVIRONMENT}/global.tfvars"

  python - "${tfvars_path}" "${field_name}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
field = sys.argv[2]

if not path.exists():
    sys.exit(1)

pattern = re.compile(rf'^\s*{re.escape(field)}\s*=\s*"([^"]*)"\s*$')
for line in path.read_text(encoding="utf-8").splitlines():
    match = pattern.match(line)
    if match:
        print(match.group(1))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

principal_matches_role_arn() {
  local principal_arn="$1"
  local role_arn="$2"
  local role_name="${role_arn##*/}"

  if [[ "${principal_arn}" == "${role_arn}" ]]; then
    return 0
  fi

  if [[ "${principal_arn}" == arn:aws:sts::*:assumed-role/"${role_name}"/* ]]; then
    return 0
  fi

  return 1
}

while [[ "${#}" -gt 0 ]]; do
  case "$1" in
    --env|--environment)
      ENVIRONMENT="${2:-}"
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

if ! command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is required."
  exit 1
fi

if ! command -v python >/dev/null 2>&1; then
  echo "Python is required."
  exit 1
fi

AUDIT_MODULE="${REPO_ROOT}/modules/l0-audit-pipeline"
AUDIT_STATE_KEY="$(catalog_module_field "modules/l0-audit-pipeline" "state_key")"

terraform -chdir="${AUDIT_MODULE}" init \
  -reconfigure \
  "-backend-config=${BACKEND_CONFIG_PATH}" \
  "-backend-config=key=${AUDIT_STATE_KEY}" \
  "-backend-config=use_lockfile=true" >/dev/null

terraform -chdir="${AUDIT_MODULE}" workspace select "${ENVIRONMENT}" >/dev/null

ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text | strip_cr)"
CURRENT_PRINCIPAL_ARN="$(aws sts get-caller-identity --query 'Arn' --output text | strip_cr)"
ORG_NAME="$(global_tfvars_field org_name | strip_cr)"

if [[ -z "${ORG_NAME}" ]]; then
  echo "Unable to determine org_name from environments/${ENVIRONMENT}/global.tfvars" >&2
  exit 1
fi

TF_EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ORG_NAME}-terraform-execution-role"
AUDIT_BUCKET_NAME="${ORG_NAME}-audit-${ACCOUNT_ID}"
AUDIT_ACCESS_LOGS_BUCKET_NAME="${ORG_NAME}-audit-access-logs-${ACCOUNT_ID}"

echo
echo "Preparing audit bucket cleanup for destroy"
echo "Environment             : ${ENVIRONMENT}"
echo "Audit bucket            : ${AUDIT_BUCKET_NAME}"
echo "Audit access logs bucket: ${AUDIT_ACCESS_LOGS_BUCKET_NAME}"
echo "Assume role             : ${TF_EXEC_ROLE_ARN}"
echo "Current principal       : ${CURRENT_PRINCIPAL_ARN}"

if principal_matches_role_arn "${CURRENT_PRINCIPAL_ARN}" "${TF_EXEC_ROLE_ARN}"; then
  echo "Using current credentials because the operator session already matches the Terraform execution role."
else
  ASSUME_ROLE_STDERR="$(mktemp)"
  if read -r ASSUMED_ACCESS_KEY ASSUMED_SECRET_KEY ASSUMED_SESSION_TOKEN < <(
    aws sts assume-role \
      --role-arn "${TF_EXEC_ROLE_ARN}" \
      --role-session-name "connect-pbx-audit-destroy-${ENVIRONMENT}" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
      --output text 2>"${ASSUME_ROLE_STDERR}" | strip_cr
  ); then
    export AWS_ACCESS_KEY_ID="$(printf '%s' "${ASSUMED_ACCESS_KEY}" | strip_cr)"
    export AWS_SECRET_ACCESS_KEY="$(printf '%s' "${ASSUMED_SECRET_KEY}" | strip_cr)"
    export AWS_SESSION_TOKEN="$(printf '%s' "${ASSUMED_SESSION_TOKEN}" | strip_cr)"
    echo "AssumeRole succeeded. Bucket cleanup will run as the Terraform execution role."
  else
    echo "AssumeRole failed for ${TF_EXEC_ROLE_ARN}. Attempting fallback with current operator credentials..."
    cat "${ASSUME_ROLE_STDERR}" >&2
    echo "Removing the audit bucket policy so the current operator session can empty object versions during destroy."
    if ! aws s3api delete-bucket-policy --bucket "${AUDIT_BUCKET_NAME}" >/dev/null 2>&1; then
      echo "Failed to delete the audit bucket policy with current credentials." >&2
      echo "Current principal ${CURRENT_PRINCIPAL_ARN} must be able to either assume ${TF_EXEC_ROLE_ARN} or delete the bucket policy on ${AUDIT_BUCKET_NAME}." >&2
      rm -f "${ASSUME_ROLE_STDERR}"
      exit 1
    fi
    echo "Audit bucket policy removed for destroy cleanup fallback."
  fi
  rm -f "${ASSUME_ROLE_STDERR}"
fi

purge_bucket_versions() {
  local bucket="$1"
  local key_marker=""
  local version_id_marker=""

  while true; do
    local page_json
    page_json="$(mktemp)"

    local args=(aws s3api list-object-versions --bucket "${bucket}" --output json)
    if [[ -n "${key_marker}" ]]; then
      args+=(--key-marker "${key_marker}")
    fi
    if [[ -n "${version_id_marker}" ]]; then
      args+=(--version-id-marker "${version_id_marker}")
    fi

    local list_versions_stderr
    list_versions_stderr="$(mktemp)"
    if ! "${args[@]}" > "${page_json}" 2>"${list_versions_stderr}"; then
      if grep -qiE 'NoSuchBucket|NotFound|404' "${list_versions_stderr}"; then
        echo "Bucket s3://${bucket} does not exist. Skipping version cleanup."
        rm -f "${page_json}" "${list_versions_stderr}"
        return 0
      fi
      cat "${list_versions_stderr}" >&2
      rm -f "${page_json}" "${list_versions_stderr}"
      return 1
    fi
    rm -f "${list_versions_stderr}"

    mapfile -t page_meta < <(
      python - "${page_json}" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
objects = []
for collection in ("Versions", "DeleteMarkers"):
    for item in data.get(collection, []) or []:
        key = item.get("Key")
        version_id = item.get("VersionId")
        if key is not None and version_id is not None:
            objects.append({"Key": key, "VersionId": version_id})
print(len(objects))
print(data.get("NextKeyMarker") or "")
print(data.get("NextVersionIdMarker") or "")
print("true" if data.get("IsTruncated") else "false")
for index in range(0, len(objects), 1000):
    payload = {"Objects": objects[index:index + 1000], "Quiet": True}
    print(json.dumps(payload))
PY
    )

    local object_count="$(printf '%s' "${page_meta[0]}" | strip_cr)"
    key_marker="$(printf '%s' "${page_meta[1]}" | strip_cr)"
    version_id_marker="$(printf '%s' "${page_meta[2]}" | strip_cr)"
    local truncated="$(printf '%s' "${page_meta[3]}" | strip_cr)"

    if (( object_count > 0 )); then
      local i
      for (( i = 4; i < ${#page_meta[@]}; i++ )); do
        local delete_payload
        delete_payload="$(printf '%s' "${page_meta[$i]}" | strip_cr)"
        aws s3api delete-objects --bucket "${bucket}" --delete "${delete_payload}" >/dev/null
      done
    fi

    rm -f "${page_json}"

    if [[ "${truncated}" != "true" ]]; then
      break
    fi
  done
}

empty_bucket() {
  local bucket="$1"

  if [[ -z "${bucket}" ]]; then
    echo "Encountered an empty bucket name during destroy cleanup." >&2
    exit 1
  fi

  echo "Emptying s3://${bucket}"
  aws s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  purge_bucket_versions "${bucket}"
}

empty_bucket "${AUDIT_BUCKET_NAME}"
empty_bucket "${AUDIT_ACCESS_LOGS_BUCKET_NAME}"

echo
echo "Audit buckets emptied successfully."
