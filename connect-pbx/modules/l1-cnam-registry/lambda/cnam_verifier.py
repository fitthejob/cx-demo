import json
import logging
import os
import re
from datetime import UTC, datetime, timedelta

import boto3
from botocore.exceptions import ClientError


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DYNAMODB = boto3.resource("dynamodb")
SECRETS = boto3.client("secretsmanager")
CLOUDWATCH = boto3.client("cloudwatch")

TABLE = DYNAMODB.Table(os.environ["TABLE_NAME"])
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "ConnectPBX/dev")
CNAM_PROVIDER_MODE = os.environ.get("CNAM_PROVIDER_MODE", "mock").strip().lower()
CNAM_PROVIDER_SECRET_ARN = os.environ.get("CNAM_PROVIDER_SECRET_ARN", "").strip()
VERIFICATION_PROPAGATION_HOURS = int(os.environ.get("VERIFICATION_PROPAGATION_HOURS", "72"))

VALID_OPERATIONS = {"VERIFY_ACTIVE", "VERIFY_NUMBERS", "VERIFY_INVENTORY"}


class ProviderError(Exception):
    pass


def utc_now():
    return datetime.now(UTC)


def isoformat_z(dt):
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_isoformat(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


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


def provider_secret():
    if CNAM_PROVIDER_MODE == "mock":
        return {}
    if not CNAM_PROVIDER_SECRET_ARN:
        raise ProviderError("CNAM provider secret ARN is required for live mode.")
    response = SECRETS.get_secret_value(SecretId=CNAM_PROVIDER_SECRET_ARN)
    secret_string = response.get("SecretString")
    if not secret_string:
        raise ProviderError("CNAM provider secret is empty.")
    return json.loads(secret_string)


def query_status_scope(status_scope):
    response = TABLE.query(
        IndexName="status-by-scope",
        KeyConditionExpression="status_scope = :scope",
        ExpressionAttributeValues={":scope": status_scope},
    )
    return response.get("Items", [])


def get_record(phone_number):
    response = TABLE.get_item(Key={"phone_number": phone_number})
    return response.get("Item")


def emit_drift_metric(drift_count):
    CLOUDWATCH.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "CNAMDriftDetected", "Value": float(drift_count), "Unit": "Count"}
        ],
    )


def lookup_actual_cnam(record, scenario_map):
    if CNAM_PROVIDER_MODE == "mock":
        scenario = (scenario_map.get(record["phone_number"]) or "").strip().lower()
        if scenario == "drift":
            return f"{record['desired_cnam']} X"[:15]
        if scenario == "provider_error":
            raise ProviderError("Mock verifier failed.")
        return record["desired_cnam"]

    secret = provider_secret()
    static = secret.get("verification_results", {})
    return static.get(record["phone_number"], record["desired_cnam"])


def should_skip_for_propagation(record):
    submission_date = record.get("submission_date")
    if not submission_date:
        return False
    try:
        submitted_at = parse_isoformat(submission_date)
    except Exception:  # noqa: BLE001
        return False
    return utc_now() - submitted_at < timedelta(hours=VERIFICATION_PROPAGATION_HOURS)


def update_verification(record, actual_cnam):
    now = isoformat_z(utc_now())
    record["actual_cnam"] = actual_cnam
    record["last_verified_date"] = now
    record["updated_at"] = now
    record["updated_by"] = "PRD17_CNAM_VERIFIER"
    if actual_cnam == record["desired_cnam"]:
        record["submission_status"] = "VERIFIED"
        record["status_scope"] = "VERIFIED"
    else:
        record["submission_status"] = "DRIFT_DETECTED"
        record["status_scope"] = "DRIFT_DETECTED"
    TABLE.put_item(Item=record)
    return record


def parse_numbers(event):
    numbers = event.get("numbers")
    if numbers is None:
        single = event.get("phone_number")
        if single:
            numbers = [single]
        else:
            return []
    return [normalize_phone_number(item) for item in numbers]


def run_verification(records, scenario_map):
    results = []
    drift_count = 0

    for record in records:
        if should_skip_for_propagation(record):
            results.append(
                {
                    "phone_number": record["phone_number"],
                    "submission_status": record.get("submission_status"),
                    "status": "SKIPPED_PROPAGATION_WINDOW",
                }
            )
            continue

        try:
            actual_cnam = lookup_actual_cnam(record, scenario_map)
            updated = update_verification(record, actual_cnam)
            if updated["submission_status"] == "DRIFT_DETECTED":
                drift_count += 1
            results.append(
                {
                    "phone_number": updated["phone_number"],
                    "submission_status": updated["submission_status"],
                    "desired_cnam": updated["desired_cnam"],
                    "actual_cnam": updated.get("actual_cnam"),
                }
            )
        except Exception as exc:  # noqa: BLE001
            LOGGER.exception("CNAM verification failed for %s", record.get("phone_number"))
            results.append(
                {
                    "phone_number": record.get("phone_number"),
                    "submission_status": record.get("submission_status"),
                    "status": "FAILED",
                    "error_message": str(exc),
                }
            )

    emit_drift_metric(drift_count)
    return {
        "operation": "VERIFY",
        "results": results,
    }


def handler(event, _context):
    LOGGER.info("Received event: %s", json.dumps(event or {}))
    operation = str((event or {}).get("operation", "VERIFY_ACTIVE")).strip().upper()
    if operation not in VALID_OPERATIONS:
        raise ValueError("operation must be VERIFY_ACTIVE, VERIFY_NUMBERS, or VERIFY_INVENTORY")

    scenario_map = event.get("mock_scenarios", {}) or {}

    if operation == "VERIFY_NUMBERS":
        records = [record for phone_number in parse_numbers(event or {}) if (record := get_record(phone_number))]
        return run_verification(records, scenario_map)

    if operation == "VERIFY_INVENTORY":
        all_records = (
            query_status_scope("SUBMITTED")
            + query_status_scope("VERIFIED")
            + query_status_scope("PENDING")
            + query_status_scope("DRIFT_DETECTED")
        )
        return run_verification(all_records, scenario_map)

    records = query_status_scope("SUBMITTED") + query_status_scope("VERIFIED")
    return run_verification(records, scenario_map)
