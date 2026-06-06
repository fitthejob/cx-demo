import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_RETRIES = 1
RETRY_DELAY_SECONDS = 5


def env_or_none(name: str) -> str | None:
    value = os.environ.get(name)
    return value if value else None


def invoke_lambda(command: list[str], attempt: int, max_attempts: int) -> subprocess.CompletedProcess:
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode == 0:
        return result

    if attempt < max_attempts:
        sys.stderr.write(f"Attempt {attempt}/{max_attempts} failed (rc={result.returncode}), retrying in {RETRY_DELAY_SECONDS}s...\n")
        sys.stderr.write(result.stderr)
        time.sleep(RETRY_DELAY_SECONDS)
        return invoke_lambda(command, attempt + 1, max_attempts)

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Invoke the PRD-14 phone association Lambda.")
    parser.add_argument("--function-name", default=env_or_none("FUNCTION_NAME"))
    parser.add_argument("--phone-number-id", default=env_or_none("PHONE_NUMBER_ID"))
    parser.add_argument("--contact-flow-id", default=env_or_none("CONTACT_FLOW_ID"))
    parser.add_argument("--action", default=env_or_none("ACTION") or "associate")
    parser.add_argument("--output-path", default=env_or_none("OUTPUT_PATH"))
    parser.add_argument("--retries", type=int, default=int(os.environ.get("RETRIES", str(DEFAULT_RETRIES))))
    args = parser.parse_args()

    missing_args = []
    if not args.function_name:
        missing_args.append("--function-name / FUNCTION_NAME")
    if not args.phone_number_id:
        missing_args.append("--phone-number-id / PHONE_NUMBER_ID")
    if args.action == "associate" and not args.contact_flow_id:
        missing_args.append("--contact-flow-id / CONTACT_FLOW_ID")
    if not args.output_path:
        missing_args.append("--output-path / OUTPUT_PATH")
    if missing_args:
        parser.error(f"missing required inputs: {', '.join(missing_args)}")

    payload = json.dumps(
        {
            "phone_number_id": args.phone_number_id,
            "contact_flow_id": args.contact_flow_id,
            "action": args.action,
        }
    )

    output_path = Path(args.output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    command = [
        "aws",
        "lambda",
        "invoke",
        "--function-name",
        args.function_name,
        "--payload",
        payload,
        "--cli-binary-format",
        "raw-in-base64-out",
        str(output_path),
    ]

    result = invoke_lambda(command, attempt=1, max_attempts=max(1, args.retries))
    if result.returncode != 0:
        sys.stderr.write(f"All {args.retries} attempt(s) failed.\n")
        sys.stderr.write(result.stderr)
        return result.returncode

    if result.stdout:
        sys.stdout.write(result.stdout)

    # Verify Lambda response indicates success
    try:
        response = json.loads(output_path.read_text())
        if "errorMessage" in response:
            sys.stderr.write(f"Lambda returned error: {response['errorMessage']}\n")
            return 1
    except (json.JSONDecodeError, FileNotFoundError):
        pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
