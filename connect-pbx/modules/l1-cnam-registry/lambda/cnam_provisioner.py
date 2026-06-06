import csv
import io
import json
import logging
import os
import re
import time
from datetime import UTC, datetime, timedelta

import boto3
from botocore.exceptions import ClientError


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DYNAMODB = boto3.resource("dynamodb")
SECRETS = boto3.client("secretsmanager")
S3 = boto3.client("s3")
CLOUDWATCH = boto3.client("cloudwatch")

TABLE = DYNAMODB.Table(os.environ["TABLE_NAME"])
REPUTATION_TABLE = DYNAMODB.Table(os.environ["REPUTATION_TABLE_NAME"])
PHONE_NUMBERS_STATE_BUCKET = os.environ["PHONE_NUMBERS_STATE_BUCKET"]
PHONE_NUMBERS_STATE_KEY = os.environ["PHONE_NUMBERS_STATE_KEY"]
TF_WORKSPACE = os.environ["TF_WORKSPACE"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", f"ConnectPBX/{TF_WORKSPACE}")
CNAM_POLICY = os.environ.get("CNAM_POLICY", "company").strip().lower()
CNAM_COMPANY_NAME = os.environ.get("CNAM_COMPANY_NAME", "").strip()
CNAM_PROVIDER = os.environ.get("CNAM_PROVIDER", "bandwidth").strip().lower()
CNAM_PROVIDER_MODE = os.environ.get("CNAM_PROVIDER_MODE", "mock").strip().lower()
CNAM_PROVIDER_SECRET_ARN = os.environ.get("CNAM_PROVIDER_SECRET_ARN", "").strip()
REPUTATION_STALENESS_DAYS = int(os.environ.get("REPUTATION_STALENESS_DAYS", "30"))
SUBMISSION_BATCH_SIZE = int(os.environ.get("SUBMISSION_BATCH_SIZE", "50"))

VALID_OPERATIONS = {
    "UPSERT_DESIRED_RECORDS",
    "SUBMIT_NUMBERS",
    "SUBMIT_PENDING",
    "REQUEUE_NUMBERS",
}

REQUEUE_ELIGIBLE_STATUSES = {"FAILED", "DRIFT_DETECTED"}
ALLOWED_REASONS = {
    "MISSING_REPUTATION_CURRENT",
    "REPUTATION_CHECK_STALE",
    "SPAM_LABEL_SPAM",
    "REPLACEMENT_REQUIRED",
    "PROVIDER_DATA_INCOMPLETE",
}


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


def require_request_fields(event, *extra_required):
    request_id = str(event.get("request_id", "")).strip()
    operator_identity = str(event.get("operator_identity", "")).strip()
    if not request_id:
        raise ValueError("request_id is required")
    if not operator_identity:
        raise ValueError("operator_identity is required")

    values = {"request_id": request_id, "operator_identity": operator_identity}
    for key in extra_required:
        value = event.get(key)
        if value in (None, "", []):
            raise ValueError(f"{key} is required")
        values[key] = value
    return values


def state_key_candidates():
    return [f"env:/{TF_WORKSPACE}/{PHONE_NUMBERS_STATE_KEY}", PHONE_NUMBERS_STATE_KEY]


def load_phone_numbers_state():
    for key in state_key_candidates():
        try:
            response = S3.get_object(Bucket=PHONE_NUMBERS_STATE_BUCKET, Key=key)
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as exc:
            error_code = exc.response.get("Error", {}).get("Code", "")
            if error_code in {"NoSuchKey", "404"}:
                continue
            raise

    raise ValueError("Unable to resolve PRD-11 state document for number inventory.")


def phone_number_inventory():
    state_doc = load_phone_numbers_state()
    outputs = state_doc.get("outputs", {})
    inventory = outputs.get("phone_number_inventory", {}).get("value", {})
    normalized = {}

    for number_key, item in inventory.items():
        phone_number = item.get("phone_number")
        if not phone_number:
            continue

        normalized_phone = normalize_phone_number(phone_number)
        normalized[normalized_phone] = {
            "phone_number": normalized_phone,
            "number_key": number_key,
            "purpose": item.get("purpose", ""),
            "cnam_name": item.get("cnam_name"),
        }

    return normalized


def parse_csv_payload(csv_payload):
    reader = csv.reader(io.StringIO(csv_payload))
    records = []
    for row in reader:
        if not row:
            continue
        if len(row) != 2:
            raise ValueError("CSV payload rows must be '<phone_number>,<cnam>'")
        records.append({"phone_number": row[0], "cnam": row[1]})
    return records


def normalize_desired_cnam(value):
    cnam = str(value or "").strip()
    if not cnam:
        raise ValueError("desired CNAM is required")
    if len(cnam) > 15:
        raise ValueError("desired CNAM must be 15 characters or fewer")
    return cnam


def build_records_from_inventory():
    inventory = phone_number_inventory()
    records = []
    errors = []

    for phone_number, item in inventory.items():
        try:
            if CNAM_POLICY == "company":
                desired_cnam = normalize_desired_cnam(CNAM_COMPANY_NAME)
            else:
                desired_cnam = normalize_desired_cnam(item.get("cnam_name"))

            records.append(
                {
                    "phone_number": phone_number,
                    "desired_cnam": desired_cnam,
                    "cnam_policy": CNAM_POLICY,
                }
            )
        except Exception as exc:  # noqa: BLE001
            errors.append(
                {
                    "phone_number": phone_number,
                    "status": "REJECTED",
                    "reason_code": "INVALID_DESIRED_CNAM",
                    "message": str(exc),
                }
            )

    return records, errors


def normalize_input_records(event):
    if event.get("records"):
        raw_records = event["records"]
    elif event.get("csv_payload"):
        raw_records = parse_csv_payload(event["csv_payload"])
    else:
        return build_records_from_inventory()

    records = []
    errors = []
    for record in raw_records:
        try:
            normalized_phone = normalize_phone_number(record.get("phone_number"))
            desired_cnam = normalize_desired_cnam(record.get("cnam") or record.get("desired_cnam"))
            records.append(
                {
                    "phone_number": normalized_phone,
                    "desired_cnam": desired_cnam,
                    "cnam_policy": record.get("cnam_policy") or CNAM_POLICY,
                }
            )
        except Exception as exc:  # noqa: BLE001
            errors.append(
                {
                    "phone_number": record.get("phone_number"),
                    "status": "REJECTED",
                    "reason_code": "INVALID_DESIRED_CNAM",
                    "message": str(exc),
                }
            )
    return records, errors


def get_cnam_record(phone_number):
    response = TABLE.get_item(Key={"phone_number": phone_number})
    return response.get("Item")


def get_reputation_current(phone_number):
    response = REPUTATION_TABLE.get_item(Key={"phone_number": phone_number, "check_date": "CURRENT"})
    return response.get("Item")


def emit_metrics(metric_values):
    if not metric_values:
        return

    CLOUDWATCH.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": name, "Value": float(value), "Unit": unit}
            for name, value, unit in metric_values
        ],
    )


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


def mock_submission_result(phone_number):
    suffix = phone_number[-2:]
    if suffix == "91":
        raise ProviderError("Mock CNAM provider submission failure.")
    return {"http_status": 202, "provider_request_id": f"mock-submit-{phone_number[-4:]}"}


def live_submission_result(phone_number, desired_cnam):
    secret = provider_secret()
    static = secret.get("submission_results", {})
    configured = static.get(phone_number, {"http_status": 202, "provider_request_id": f"live-submit-{desired_cnam}"})
    if int(configured.get("http_status", 500)) >= 400:
        raise ProviderError(configured.get("error_message", "Live CNAM provider submission failed."))
    return configured


def submit_to_provider(phone_number, desired_cnam):
    if CNAM_PROVIDER_MODE == "mock":
        return mock_submission_result(phone_number)
    return live_submission_result(phone_number, desired_cnam)


def evaluate_reputation_gate(phone_number):
    current = get_reputation_current(phone_number)
    if not current:
        return False, "MISSING_REPUTATION_CURRENT"

    try:
        checked_at = parse_isoformat(current["checked_at"])
        if utc_now() - checked_at > timedelta(days=REPUTATION_STALENESS_DAYS):
            return False, "REPUTATION_CHECK_STALE"
    except Exception:  # noqa: BLE001
        return False, "REPUTATION_CHECK_STALE"

    if current.get("spam_label") == "SPAM":
        return False, "SPAM_LABEL_SPAM"

    if current.get("remediation_status") in {"REPLACEMENT_REQUIRED", "REPLACED"}:
        return False, "REPLACEMENT_REQUIRED"

    if not current.get("provider_data_complete", False):
        return False, "PROVIDER_DATA_INCOMPLETE"

    return True, None


def persist_desired_record(record, request_id, operator_identity):
    current = get_cnam_record(record["phone_number"]) or {}
    desired_cnam = record["desired_cnam"]

    if (
        current.get("last_request_id") == request_id
        and current.get("desired_cnam") == desired_cnam
        and current.get("submission_status") == "PENDING"
    ):
        response = dict(current)
        response["idempotent"] = True
        return response

    item = dict(current)
    item.update(
        {
            "phone_number": record["phone_number"],
            "desired_cnam": desired_cnam,
            "cnam_policy": record["cnam_policy"],
            "submission_status": "PENDING",
            "status_scope": "PENDING",
            "provider": CNAM_PROVIDER,
            "reputation_gate_reason": None,
            "error_message": None,
            "last_request_id": request_id,
            "updated_at": isoformat_z(utc_now()),
            "updated_by": operator_identity,
        }
    )

    TABLE.put_item(Item=item)
    item["idempotent"] = False
    return item


def check_request_idempotency(request_id, records):
    """Check if all records were already processed by this request_id."""
    cached_results = []
    for record in records:
        existing = get_cnam_record(record["phone_number"])
        if not existing or existing.get("last_request_id") != request_id:
            return None
        cached_results.append({
            "phone_number": existing["phone_number"],
            "desired_cnam": existing["desired_cnam"],
            "submission_status": existing.get("submission_status"),
            "idempotent": True,
        })
    return cached_results


def upsert_desired_records(event):
    values = require_request_fields(event)
    records, errors = normalize_input_records(event)

    cached = check_request_idempotency(values["request_id"], records)
    if cached is not None:
        LOGGER.info("Idempotent replay detected for request_id=%s", values["request_id"])
        return {
            "operation": "UPSERT_DESIRED_RECORDS",
            "idempotent": True,
            "results": list(errors) + cached,
        }

    results = list(errors)
    success_count = 0

    for record in records:
        persisted = persist_desired_record(record, values["request_id"], values["operator_identity"])
        results.append(
            {
                "phone_number": persisted["phone_number"],
                "desired_cnam": persisted["desired_cnam"],
                "submission_status": persisted["submission_status"],
                "idempotent": persisted["idempotent"],
            }
        )
        success_count += 1

    emit_metrics([("CNAMDesiredRecordUpsert", success_count, "Count")])
    return {
        "operation": "UPSERT_DESIRED_RECORDS",
        "results": results,
    }


def parse_numbers_list(event):
    numbers = event.get("numbers")
    if numbers is None:
        single = event.get("phone_number")
        if single:
            numbers = [single]
        else:
            raise ValueError("Provide either numbers or phone_number")
    return [normalize_phone_number(item) for item in numbers]


def query_status_scope(status_scope):
    response = TABLE.query(
        IndexName="status-by-scope",
        KeyConditionExpression="status_scope = :scope",
        ExpressionAttributeValues={":scope": status_scope},
    )
    return response.get("Items", [])


def update_submission_result(record, status, request_id, operator_identity, http_status=None, error_message=None, gate_reason=None):
    item = dict(record)
    item.update(
        {
            "submission_status": status,
            "status_scope": status,
            "submission_date": isoformat_z(utc_now()),
            "last_request_id": request_id,
            "updated_at": isoformat_z(utc_now()),
            "updated_by": operator_identity,
            "last_submission_http_status": http_status,
            "error_message": error_message,
            "reputation_gate_reason": gate_reason,
        }
    )
    TABLE.put_item(Item=item)
    return item


def submit_records(records, request_id, operator_identity):
    results = []
    success_count = 0
    failure_count = 0

    for index in range(0, len(records), SUBMISSION_BATCH_SIZE):
        batch = records[index:index + SUBMISSION_BATCH_SIZE]
        for record in batch:
            if record.get("last_request_id") == request_id and record.get("submission_status") == "SUBMITTED":
                response = {
                    "phone_number": record["phone_number"],
                    "submission_status": record["submission_status"],
                    "idempotent": True,
                }
                results.append(response)
                continue

            gate_allowed, gate_reason = evaluate_reputation_gate(record["phone_number"])
            if not gate_allowed:
                updated = update_submission_result(
                    record,
                    "FAILED",
                    request_id,
                    operator_identity,
                    error_message=f"Blocked by PRD-16 gate: {gate_reason}",
                    gate_reason=gate_reason,
                )
                results.append(
                    {
                        "phone_number": updated["phone_number"],
                        "submission_status": updated["submission_status"],
                        "reason_code": gate_reason,
                    }
                )
                failure_count += 1
                continue

            try:
                provider_result = submit_to_provider(record["phone_number"], record["desired_cnam"])
                updated = update_submission_result(
                    record,
                    "SUBMITTED",
                    request_id,
                    operator_identity,
                    http_status=int(provider_result.get("http_status", 202)),
                    gate_reason=None,
                )
                results.append(
                    {
                        "phone_number": updated["phone_number"],
                        "submission_status": updated["submission_status"],
                        "provider_request_id": provider_result.get("provider_request_id"),
                    }
                )
                success_count += 1
            except Exception as exc:  # noqa: BLE001
                updated = update_submission_result(
                    record,
                    "FAILED",
                    request_id,
                    operator_identity,
                    http_status=500,
                    error_message=str(exc),
                    gate_reason=None,
                )
                results.append(
                    {
                        "phone_number": updated["phone_number"],
                        "submission_status": updated["submission_status"],
                        "error_message": updated.get("error_message"),
                    }
                )
                failure_count += 1

        if index + SUBMISSION_BATCH_SIZE < len(records):
            time.sleep(0.1)

    emit_metrics(
        [
            ("CNAMSubmissionSuccess", success_count, "Count"),
            ("CNAMSubmissionFailure", failure_count, "Count"),
        ]
    )
    return results


def submit_numbers(event):
    values = require_request_fields(event)
    numbers = parse_numbers_list(event)
    records = []
    results = []

    for phone_number in numbers:
        record = get_cnam_record(phone_number)
        if not record:
            results.append(
                {
                    "phone_number": phone_number,
                    "submission_status": "REJECTED",
                    "reason_code": "MISSING_DESIRED_RECORD",
                }
            )
            continue
        records.append(record)

    results.extend(submit_records(records, values["request_id"], values["operator_identity"]))
    return {
        "operation": "SUBMIT_NUMBERS",
        "results": results,
    }


def submit_pending(event):
    values = require_request_fields(event)
    pending = query_status_scope("PENDING")
    results = submit_records(pending, values["request_id"], values["operator_identity"])
    return {
        "operation": "SUBMIT_PENDING",
        "results": results,
    }


def requeue_numbers(event):
    values = require_request_fields(event)
    requested_status = str(event.get("status", "")).strip().upper()
    records = []

    if event.get("numbers"):
        for phone_number in parse_numbers_list(event):
            record = get_cnam_record(phone_number)
            if record:
                records.append(record)
    elif requested_status:
        if requested_status not in REQUEUE_ELIGIBLE_STATUSES:
            raise ValueError("status must be FAILED or DRIFT_DETECTED")
        records = query_status_scope(requested_status)
    else:
        raise ValueError("Provide either numbers or status")

    results = []
    for record in records:
        current_status = record.get("submission_status")
        if record.get("last_request_id") == values["request_id"] and current_status == "PENDING":
            results.append(
                {
                    "phone_number": record["phone_number"],
                    "submission_status": "PENDING",
                    "idempotent": True,
                }
            )
            continue

        if current_status not in REQUEUE_ELIGIBLE_STATUSES:
            results.append(
                {
                    "phone_number": record["phone_number"],
                    "submission_status": current_status,
                    "reason_code": "STATUS_NOT_REQUEUEABLE",
                }
            )
            continue

        record["submission_status"] = "PENDING"
        record["status_scope"] = "PENDING"
        record["last_request_id"] = values["request_id"]
        record["updated_at"] = isoformat_z(utc_now())
        record["updated_by"] = values["operator_identity"]
        record["error_message"] = None
        record["reputation_gate_reason"] = None
        TABLE.put_item(Item=record)

        results.append(
            {
                "phone_number": record["phone_number"],
                "submission_status": record["submission_status"],
                "idempotent": False,
            }
        )

    return {
        "operation": "REQUEUE_NUMBERS",
        "results": results,
    }


def handle_s3_event(event):
    """Process an S3 bulk CSV import trigger."""
    results = []
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]
        LOGGER.info("Processing bulk CSV import: s3://%s/%s", bucket, key)

        response = S3.get_object(Bucket=bucket, Key=key)
        csv_payload = response["Body"].read().decode("utf-8")

        import_event = {
            "operation": "UPSERT_DESIRED_RECORDS",
            "csv_payload": csv_payload,
            "request_id": f"s3-import-{key}",
            "operator_identity": f"s3://{bucket}/{key}",
        }
        result = upsert_desired_records(import_event)
        results.append(result)

    return {
        "operation": "S3_BULK_IMPORT",
        "files_processed": len(results),
        "results": results,
    }


def handler(event, _context):
    LOGGER.info("Received event: %s", json.dumps(event or {}))

    if event and "Records" in event and event["Records"]:
        first_record = event["Records"][0]
        if first_record.get("eventSource") == "aws:s3":
            return handle_s3_event(event)

    operation = str((event or {}).get("operation", "UPSERT_DESIRED_RECORDS")).strip().upper()
    if operation not in VALID_OPERATIONS:
        raise ValueError(f"operation must be one of: {', '.join(sorted(VALID_OPERATIONS))}")

    if operation == "UPSERT_DESIRED_RECORDS":
        return upsert_desired_records(event or {})
    if operation == "SUBMIT_NUMBERS":
        return submit_numbers(event or {})
    if operation == "SUBMIT_PENDING":
        return submit_pending(event or {})
    return requeue_numbers(event or {})
