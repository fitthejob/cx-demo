#!/usr/bin/env python3
"""Preflight-search available Connect phone numbers before claim.

Reads the Terraform external provider query from stdin and returns a string-only
JSON object. This lets PRD-11 fail early with a clearer error when the requested
country/type/prefix combination has no currently claimable inventory.
"""

from __future__ import annotations

import json
import subprocess
import sys


def fail(message: str, *, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def build_scope(country_code: str, phone_number_type: str, phone_number_prefix: str) -> str:
    scope = f"{country_code} {phone_number_type}"
    if phone_number_prefix:
        scope = f"{scope} with prefix {phone_number_prefix}"
    return scope


def emit(
    *,
    available: bool,
    candidate_numbers: list[str],
    message: str,
    lookup_status: str,
) -> int:
    print(
        json.dumps(
            {
                "available": "true" if available else "false",
                "candidate_count": str(len(candidate_numbers)),
                "candidate_numbers": ",".join(candidate_numbers),
                "message": message,
                "lookup_status": lookup_status,
            }
        )
    )
    return 0


def main() -> int:
    try:
        query = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid external query JSON: {exc}")

    number_key = str(query.get("number_key", "")).strip() or "unnamed-phone-number"
    target_arn = str(query.get("target_arn", "")).strip()
    aws_region = str(query.get("aws_region", "")).strip() or "us-east-1"
    country_code = str(query.get("country_code", "")).strip()
    phone_number_type = str(query.get("phone_number_type", "")).strip()
    phone_number_prefix = str(query.get("phone_number_prefix", "")).strip()

    if not target_arn:
        fail("target_arn is required")
    if not country_code:
        fail("country_code is required")
    if not phone_number_type:
        fail("phone_number_type is required")

    scope = build_scope(country_code, phone_number_type, phone_number_prefix)

    command = [
        "aws",
        "connect",
        "search-available-phone-numbers",
        "--target-arn",
        target_arn,
        "--phone-number-country-code",
        country_code,
        "--phone-number-type",
        phone_number_type,
        "--max-items",
        "5",
        "--region",
        aws_region,
        "--no-cli-pager",
        "--output",
        "json",
    ]

    if phone_number_prefix:
        command.extend(["--phone-number-prefix", phone_number_prefix])

    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "aws connect search-available-phone-numbers failed"
        return emit(
            available=False,
            candidate_numbers=[],
            message=(
                f"Amazon Connect phone number preflight failed for '{number_key}' ({scope}) "
                f"before claim attempt: {detail}"
            ),
            lookup_status="error",
        )

    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        return emit(
            available=False,
            candidate_numbers=[],
            message=(
                f"Amazon Connect phone number preflight returned invalid JSON for '{number_key}' "
                f"({scope}) before claim attempt: {exc}"
            ),
            lookup_status="error",
        )

    candidate_numbers = [
        str(summary.get("PhoneNumber", "")).strip()
        for summary in payload.get("AvailableNumbersList", [])
        if str(summary.get("PhoneNumber", "")).strip()
    ]

    if candidate_numbers:
        return emit(
            available=True,
            candidate_numbers=candidate_numbers,
            message=(
                f"Found {len(candidate_numbers)} available Amazon Connect candidate number(s) for "
                f"'{number_key}' ({scope}) before claim attempt."
            ),
            lookup_status="success",
        )

    guidance = "Try a different prefix or set prefix = null to accept any available number."
    if not phone_number_prefix:
        guidance = "AWS reported no currently available numbers for this request."

    return emit(
        available=False,
        candidate_numbers=[],
        message=(
            f"No available Amazon Connect phone numbers were found for '{number_key}' ({scope}) on "
            f"target {target_arn} before claim attempt. {guidance}"
        ),
        lookup_status="no_matches",
    )


if __name__ == "__main__":
    raise SystemExit(main())
