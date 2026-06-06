#!/usr/bin/env bash
set -euo pipefail

ROLE_NAME="AWSServiceRoleForAmazonConnect"
SERVICE_NAME="connect.amazonaws.com"
ACTION="${1:-lookup}"

lookup_role() {
  local output
  local status

  set +e
  output="$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text --no-cli-pager 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    printf '{"exists":"true","arn":"%s"}\n' "$output"
    return 0
  fi

  if [[ "$output" == *"NoSuchEntity"* ]]; then
    printf '{"exists":"false","arn":""}\n'
    return 0
  fi

  printf '%s\n' "$output" >&2
  return "$status"
}

ensure_role() {
  local current
  local create_output
  local create_status

  current="$(lookup_role)"
  if [[ "$current" == *'"exists":"true"'* ]]; then
    printf '%s\n' "$current"
    return 0
  fi

  set +e
  create_output="$(aws iam create-service-linked-role --aws-service-name "$SERVICE_NAME" --no-cli-pager 2>&1)"
  create_status=$?
  set -e

  if [ "$create_status" -ne 0 ] && [[ "$create_output" != *"has been taken in this account"* ]]; then
    printf '%s\n' "$create_output" >&2
    return "$create_status"
  fi

  local attempt
  for attempt in 1 2 3 4 5 6; do
    current="$(lookup_role)"
    if [[ "$current" == *'"exists":"true"'* ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    sleep 5
  done

  echo "Amazon Connect service-linked role was requested but could not be confirmed afterward." >&2
  return 1
}

case "$ACTION" in
  lookup)
    lookup_role
    ;;
  ensure)
    ensure_role
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 1
    ;;
esac
