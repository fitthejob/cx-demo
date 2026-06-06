#!/usr/bin/env bash

read_tfvar_string_from_file() {
  local tfvars_path="$1"
  local key="$2"

  if [[ ! -f "${tfvars_path}" ]]; then
    return 0
  fi

  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$/\\1/p" "${tfvars_path}" | head -n 1 | tr -d '\r'
}

bootstrap_tfvars_path() {
  local repo_root="$1"
  printf '%s\n' "${repo_root}/modules/bootstrap/bootstrap.tfvars"
}

bootstrap_repo_name_from_tfvars() {
  local tfvars_path="$1"
  local github_repo=""

  github_repo="$(read_tfvar_string_from_file "${tfvars_path}" "github_repo")"
  if [[ -z "${github_repo}" ]]; then
    echo "github_repo is not set in ${tfvars_path}. Update bootstrap.tfvars or set CONNECT_PBX_BOOTSTRAP_DIR explicitly." >&2
    return 1
  fi

  printf '%s\n' "${github_repo}"
}

resolve_bootstrap_artifact_dir() {
  local github_repo="$1"

  if [[ -n "${CONNECT_PBX_BOOTSTRAP_DIR:-}" ]]; then
    printf '%s\n' "${CONNECT_PBX_BOOTSTRAP_DIR}"
  elif [[ -n "${LOCALAPPDATA:-}" ]]; then
    printf '%s\n' "${LOCALAPPDATA}/connect-pbx/${github_repo}/bootstrap"
  else
    printf '%s\n' "${HOME}/.connect-pbx/${github_repo}/bootstrap"
  fi
}

resolve_bootstrap_artifact_dir_from_repo_root() {
  local repo_root="$1"
  local tfvars_path="${2:-}"
  local github_repo=""

  if [[ -z "${tfvars_path}" ]]; then
    tfvars_path="$(bootstrap_tfvars_path "${repo_root}")"
  fi

  github_repo="$(bootstrap_repo_name_from_tfvars "${tfvars_path}")" || return 1
  resolve_bootstrap_artifact_dir "${github_repo}"
}

resolve_bootstrap_backend_config_path() {
  local repo_root="$1"
  local profile_name="${2:-${AWS_PROFILE:-default}}"
  local tfvars_path="${3:-}"
  local artifact_dir=""

  artifact_dir="$(resolve_bootstrap_artifact_dir_from_repo_root "${repo_root}" "${tfvars_path}")" || return 1
  printf '%s\n' "${artifact_dir}/backend-${profile_name}.hcl"
}
