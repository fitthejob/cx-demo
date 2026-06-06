import json
import logging
import os
import re
import time
from datetime import UTC, datetime

import boto3
from botocore.exceptions import ClientError


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DYNAMODB = boto3.resource("dynamodb")
SECRETS = boto3.client("secretsmanager")
S3 = boto3.client("s3")
CLOUDWATCH = boto3.client("cloudwatch")

TABLE = DYNAMODB.Table(os.environ["TABLE_NAME"])
ATTESTATION_PROVIDER_MODE = os.environ.get("ATTESTATION_PROVIDER_MODE", "mock").strip().lower()
ATTESTATION_PROVIDER_SECRET_ARN = os.environ.get("ATTESTATION_PROVIDER_SECRET_ARN", "").strip()
PHONE_NUMBERS_STATE_BUCKET = os.environ["PHONE_NUMBERS_STATE_BUCKET"]
PHONE_NUMBERS_STATE_KEY = os.environ["PHONE_NUMBERS_STATE_KEY"]
TF_WORKSPACE = os.environ["TF_WORKSPACE"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", f"ConnectPBX/{TF_WORKSPACE}")

BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "50"))
BATCH_DELAY_MS = int(os.environ.get("BATCH_DELAY_MS", "100"))

VALID_OPERATIONS = {"CHECK_NUMBERS", "CHECK_INVENTORY"}


class ProviderError(Exception):
    pass


def utc_now():
    return datetime.now(UTC)


def isoformat_z(dt):
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def normalize_phone_number(phone_number):
    if phone_number is None:
        raise ValueError("phone_number is required")

    digits = re.sub(r"\D", "", str(phone_number))
    if len(digits) == 10:
        return f"+1{digits}"
    if len(digits) == 11 and digits.startswith("1"):
        return f"+{digits}"
    if str(phone_number).startswith("+") and digits:
        return f"+{digits}"
    raise ValueError(f"Unsupported phone number format: {phone_number}")


def state_key_candidates():
    return [f"env:/{TF_WORKSPACE}/{PHONE_NUMBERS_STATE_KEY}", PHONE_NUMBERS_STATE_KEY]


def load_phone_number_inventory():
    for key in state_key_candidates():
        try:
            response = S3.get_object(Bucket=PHONE_NUMBERS_STATE_BUCKET, Key=key)
            state_doc = json.loads(response["Body"].read().decode("utf-8"))
            outputs = state_doc.get("outputs", {})
            inventory = outputs.get("phone_number_inventory", {}).get("value", {})
            return [normalize_phone_number(item["phone_number"]) for item in inventory.values() if item.get("phone_number")]
        except ClientError as exc:
            error_code = exc.response.get("Error", {}).get("Code", "")
            if error_code in {"NoSuchKey", "404"}:
                continue
            raise

    raise ValueError("Unable to resolve PRD-11 state document for number inventory.")


def parse_numbers_payload(event):
    numbers = event.get("numbers")
    if numbers is None:
        single = event.get("phone_number")
        if single:
            numbers = [single]
        else:
            raise ValueError("Provide either numbers or phone_number")

    parsed = []
    scenario_map = event.get("mock_scenarios", {}) or {}
    for number in numbers:
        if isinstance(number, str):
            normalized = normalize_phone_number(number)
            parsed.append({"phone_number": normalized, "scenario": scenario_map.get(normalized)})
            continue
        if not isinstance(number, dict):
            raise ValueError("numbers entries must be strings or objects")
        normalized = normalize_phone_number(number.get("phone_number"))
        parsed.append({"phone_number": normalized, "scenario": number.get("scenario") or scenario_map.get(normalized)})
    return parsed


def default_mock_attestation(phone_number):
    suffix = phone_number[-2:]
    if suffix == "01":
        return "B"
    if suffix == "02":
        return "C"
    if suffix == "03":
        return "UNKNOWN"
    return "A"


def secret_dict(secret_arn):
    if not secret_arn:
        raise ProviderError("Provider secret ARN is required for live provider mode.")

    response = SECRETS.get_secret_value(SecretId=secret_arn)
    secret_string = response.get("SecretString")
    if not secret_string:
        raise ProviderError("Provider secret is empty or binary-only.")

    try:
        return json.loads(secret_string)
    except json.JSONDecodeError as exc:
        raise ProviderError("Provider secret is not valid JSON.") from exc


def resolve_attestation(item):
    if ATTESTATION_PROVIDER_MODE == "mock":
        scenario = (item.get("scenario") or "").strip().upper()
        if scenario in {"A", "B", "C", "UNKNOWN"}:
            return scenario
        return default_mock_attestation(item["phone_number"])

    secret = secret_dict(ATTESTATION_PROVIDER_SECRET_ARN)
    static_levels = secret.get("static_attestation", {})
    return str(static_levels.get(item["phone_number"], static_levels.get("default", "UNKNOWN"))).strip().upper()


def get_current_record(phone_number):
    response = TABLE.get_item(Key={"phone_number": phone_number, "check_date": "CURRENT"})
    return response.get("Item")


def emit_degraded_metric(degraded_count):
    CLOUDWATCH.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "STIRSHAKENAttestationDegraded",
                "Value": float(degraded_count),
                "Unit": "Count",
            }
        ],
    )


def update_attestation(phone_number, attestation):
    current = get_current_record(phone_number)
    if not current:
        return {
            "phone_number": phone_number,
            "status": "REJECTED",
            "reason_code": "MISSING_CURRENT_RECORD",
        }

    checked_at = isoformat_z(utc_now())
    current["stir_shaken_attestation"] = attestation
    current["attestation_check_date"] = checked_at
    current["updated_at"] = checked_at
    current["updated_by"] = "PRD16_STIR_SHAKEN_CHECK"

    TABLE.put_item(Item=current)

    history_ref = current.get("current_ref")
    if history_ref and history_ref != "CURRENT":
        history_response = TABLE.get_item(Key={"phone_number": phone_number, "check_date": history_ref})
        history_item = history_response.get("Item")
        if history_item:
            history_item["stir_shaken_attestation"] = attestation
            history_item["attestation_check_date"] = checked_at
            TABLE.put_item(Item=history_item)

    return {
        "phone_number": phone_number,
        "attestation": attestation,
        "attestation_check_date": checked_at,
    }


def run_attestation(numbers):
    results = []
    degraded_count = 0

    for index in range(0, len(numbers), BATCH_SIZE):
        batch = numbers[index:index + BATCH_SIZE]
        for item in batch:
            attestation = resolve_attestation(item)
            if attestation in {"B", "C"}:
                degraded_count += 1
            results.append(update_attestation(item["phone_number"], attestation))

        if index + BATCH_SIZE < len(numbers) and BATCH_DELAY_MS > 0:
            time.sleep(BATCH_DELAY_MS / 1000.0)

    emit_degraded_metric(degraded_count)
    return {
        "operation": "STIR_SHAKEN_CHECK",
        "results": results,
    }


def handler(event, _context):
    LOGGER.info("Received event: %s", json.dumps(event or {}))
    operation = str((event or {}).get("operation", "CHECK_NUMBERS")).strip().upper()
    if operation not in VALID_OPERATIONS:
        raise ValueError("operation must be CHECK_NUMBERS or CHECK_INVENTORY")

    if operation == "CHECK_INVENTORY":
        numbers = [{"phone_number": number} for number in load_phone_number_inventory()]
        return run_attestation(numbers)

    return run_attestation(parse_numbers_payload(event or {}))
