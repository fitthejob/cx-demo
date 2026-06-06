#!/usr/bin/env python3
"""Resolve an existing Connect phone number claimed to the target instance.

Reads the Terraform external provider query from stdin and returns a string-only
JSON object. If the requested phone number is already claimed to the target
Connect instance, the script returns its id/arn/details so PRD-11 can reuse it
instead of claiming a replacement number.

When no explicit existing_phone_number is provided, the script attempts to
recover a previously Terraform-managed number by matching the NumberKey tag to
the phone-number inventory key from tfvars.
"""

from __future__ import annotations

import json
import subprocess
import sys


def fail(message: str, *, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def run_aws(command: list[str]) -> dict:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        fail(result.stderr.strip() or result.stdout.strip() or "AWS CLI command failed")

    try:
        return json.loads(result.stdout or "{}")
    except json.JSONDecodeError as exc:
        fail(f"AWS CLI returned invalid JSON: {exc}")


def emit_match(match: dict, match_source: str) -> int:
    print(
        json.dumps(
            {
                "exists": "true",
                "match_source": match_source,
                "phone_number": str(match.get("PhoneNumber", "")),
                "phone_number_id": str(match.get("PhoneNumberId", "")),
                "phone_number_arn": str(match.get("PhoneNumberArn", "")),
                "phone_number_type": str(match.get("PhoneNumberType", "")),
                "country_code": str(match.get("PhoneNumberCountryCode", "")),
                "phone_number_description": str(match.get("PhoneNumberDescription", "")),
            }
        )
    )
    return 0


def emit_missing() -> int:
    print(
        json.dumps(
            {
                "exists": "false",
                "match_source": "",
                "phone_number": "",
                "phone_number_id": "",
                "phone_number_arn": "",
                "phone_number_type": "",
                "country_code": "",
                "phone_number_description": "",
            }
        )
    )
    return 0


def main() -> int:
    try:
        query = json.loads(sys.stdin.read() or "{}")
    except json.JSONDecodeError as exc:
        fail(f"Invalid external query JSON: {exc}")

    number_key = str(query.get("number_key", "")).strip()
    phone_number = str(query.get("phone_number", "")).strip()
    target_arn = str(query.get("target_arn", "")).strip()
    aws_region = str(query.get("aws_region", "")).strip() or "us-east-1"

    if not number_key:
        fail("number_key is required")
    if not target_arn:
        fail("target_arn is required")

    command = [
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
    if phone_number:
        command.extend(["--phone-number-prefix", phone_number])

    payload = run_aws(command)
    summaries = payload.get("ListPhoneNumbersSummaryList", [])

    if phone_number:
        matches = [summary for summary in summaries if summary.get("PhoneNumber") == phone_number]

        if len(matches) > 1:
            fail(f"Multiple claimed Connect numbers matched {phone_number}; refusing ambiguous reuse.")

        if not matches:
            return emit_missing()

        return emit_match(matches[0], "explicit-phone-number")

    tagged_matches = []
    for summary in summaries:
        phone_number_arn = str(summary.get("PhoneNumberArn", "")).strip()
        if not phone_number_arn:
            continue

        tags_payload = run_aws([
            "aws",
            "connect",
            "list-tags-for-resource",
            "--resource-arn",
            phone_number_arn,
            "--region",
            aws_region,
            "--no-cli-pager",
            "--output",
            "json",
        ])
        tags = tags_payload.get("tags", {}) or {}
        if str(tags.get("NumberKey", "")).strip() == number_key:
            tagged_matches.append(summary)

    if len(tagged_matches) > 1:
        fail(f"Multiple claimed Connect numbers are tagged with NumberKey={number_key}; refusing ambiguous reuse.")

    if not tagged_matches:
        return emit_missing()

    return emit_match(tagged_matches[0], "number-key-tag")


if __name__ == "__main__":
    raise SystemExit(main())
