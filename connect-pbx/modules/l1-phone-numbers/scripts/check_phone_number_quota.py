#!/usr/bin/env python3
"""Preflight-check Connect phone number quota headroom before claim."""

from __future__ import annotations

import json
import subprocess
import sys


PHONE_NUMBERS_PER_INSTANCE_QUOTA_CODE = "L-8F812903"


def fail(message: str, *, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def run_aws(command: list[str]) -> dict:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "AWS CLI command failed"
        fail(detail)

    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid JSON from AWS CLI: {exc}")


def emit(
    *,
    allowed: bool,
    message: str,
    lookup_status: str,
    quota_value: float,
    current_claimed_count: int,
    requested_claim_count: int,
) -> int:
    remaining_headroom = max(int(quota_value) - current_claimed_count, 0)
    print(
        json.dumps(
            {
                "allowed": "true" if allowed else "false",
                "message": message,
                "lookup_status": lookup_status,
                "quota_value": str(quota_value),
                "current_claimed_count": str(current_claimed_count),
                "requested_claim_count": str(requested_claim_count),
                "remaining_headroom": str(remaining_headroom),
            }
        )
    )
    return 0


def main() -> int:
    try:
        query = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid external query JSON: {exc}")

    target_arn = str(query.get("target_arn", "")).strip()
    aws_region = str(query.get("aws_region", "")).strip() or "us-east-1"
    requested_claim_count_raw = str(query.get("requested_claim_count", "")).strip() or "0"

    if not target_arn:
        fail("target_arn is required")

    try:
        requested_claim_count = int(requested_claim_count_raw)
    except ValueError:
        fail(f"requested_claim_count must be an integer, got {requested_claim_count_raw!r}")

    quota_command = [
        "aws",
        "service-quotas",
        "get-service-quota",
        "--service-code",
        "connect",
        "--quota-code",
        PHONE_NUMBERS_PER_INSTANCE_QUOTA_CODE,
        "--context-id",
        target_arn,
        "--region",
        aws_region,
        "--no-cli-pager",
        "--output",
        "json",
    ]

    inventory_command = [
        "aws",
        "connect",
        "list-phone-numbers-v2",
        "--target-arn",
        target_arn,
        "--region",
        aws_region,
        "--no-cli-pager",
        "--output",
        "json",
    ]

    try:
        quota_payload = run_aws(quota_command)
        inventory_payload = run_aws(inventory_command)
    except SystemExit as exc:
        detail = str(exc) or "Unable to verify Amazon Connect phone number quota headroom"
        return emit(
            allowed=False,
            message=(
                "Amazon Connect phone number quota preflight failed before claim attempt for "
                f"target {target_arn}: {detail}"
            ),
            lookup_status="error",
            quota_value=0.0,
            current_claimed_count=0,
            requested_claim_count=requested_claim_count,
        )

    quota_value = float(quota_payload.get("Quota", {}).get("Value", 0.0))
    current_claimed_count = len(inventory_payload.get("ListPhoneNumbersSummaryList", []))
    remaining_headroom = quota_value - current_claimed_count

    if requested_claim_count <= remaining_headroom:
        return emit(
            allowed=True,
            message=(
                "Amazon Connect phone number quota preflight passed before claim attempt for "
                f"target {target_arn}: requested {requested_claim_count}, currently claimed "
                f"{current_claimed_count}, quota {quota_value}."
            ),
            lookup_status="success",
            quota_value=quota_value,
            current_claimed_count=current_claimed_count,
            requested_claim_count=requested_claim_count,
        )

    return emit(
        allowed=False,
        message=(
            "Amazon Connect phone number quota preflight failed before claim attempt for "
            f"target {target_arn}: requested {requested_claim_count} new number(s), but only "
            f"{max(int(remaining_headroom), 0)} slot(s) remain. The instance quota "
            f"({PHONE_NUMBERS_PER_INSTANCE_QUOTA_CODE}) is {quota_value} and "
            f"{current_claimed_count} number(s) are already claimed. If this is unexpected, "
            "verify Service Quotas for the exact Connect instance ARN and resolve any pending "
            "quota increase request before retrying."
        ),
        lookup_status="insufficient_headroom",
        quota_value=quota_value,
        current_claimed_count=current_claimed_count,
        requested_claim_count=requested_claim_count,
    )


if __name__ == "__main__":
    raise SystemExit(main())
