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
HISTORY_TTL_DAYS = int(os.environ.get("HISTORY_TTL_DAYS", "365"))
REPUTATION_STALENESS_DAYS = int(os.environ.get("REPUTATION_STALENESS_DAYS", "30"))
SPAM_THRESHOLD_RISK = int(os.environ.get("SPAM_THRESHOLD_RISK", "30"))
SPAM_THRESHOLD_SPAM = int(os.environ.get("SPAM_THRESHOLD_SPAM", "70"))
REPUTATION_PROVIDER_MODE = os.environ.get("REPUTATION_PROVIDER_MODE", "mock").strip().lower()
REPUTATION_PROVIDERS = json.loads(os.environ.get("REPUTATION_PROVIDERS", "[]"))
REPUTATION_API_SECRETS = json.loads(os.environ.get("REPUTATION_API_SECRETS", "{}"))
PHONE_NUMBERS_STATE_BUCKET = os.environ["PHONE_NUMBERS_STATE_BUCKET"]
PHONE_NUMBERS_STATE_KEY = os.environ["PHONE_NUMBERS_STATE_KEY"]
TF_WORKSPACE = os.environ["TF_WORKSPACE"]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", f"ConnectPBX/{TF_WORKSPACE}")
BATCH_SIZE = int(os.environ.get("BATCH_SIZE", "50"))
BATCH_DELAY_MS = int(os.environ.get("BATCH_DELAY_MS", "100"))
ALARM_ON_RISK_LABEL = os.environ.get("ALARM_ON_RISK_LABEL", "false").strip().lower() == "true"
REPUTATION_THRESHOLD = int(os.environ.get("REPUTATION_THRESHOLD", "50"))

VALID_OPERATIONS = {
    "CHECK_NUMBERS",
    "CHECK_INVENTORY",
    "VALIDATE_ASSIGNMENT_ELIGIBILITY",
    "RECORD_REMEDIATION_ACTION",
}

ALLOWED_REMEDIATION_TRANSITIONS = {
    "NONE": {"DISPUTE_SUBMITTED", "REPLACEMENT_REQUIRED"},
    "DISPUTE_SUBMITTED": {"NONE", "REPLACEMENT_REQUIRED"},
    "REPLACEMENT_REQUIRED": {"REPLACED"},
    "REPLACED": set(),
}

MOCK_PROVIDER_SCORES = {
    "clean": {"hiya": 12, "first_orion": 18, "tns": 15},
    "risk": {"hiya": 42, "first_orion": 57, "tns": 50},
    "spam": {"hiya": 84, "first_orion": 79, "tns": 88},
}


class ProviderError(Exception):
    pass


def utc_now():
    return datetime.now(UTC)


def isoformat_z(dt):
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_isoformat(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def epoch_seconds(dt):
    return int(dt.timestamp())


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


def default_mock_scenario(phone_number):
    suffix = phone_number[-2:]
    if suffix == "01":
        return "risk"
    if suffix == "02":
        return "spam"
    if suffix == "03":
        return "provider_error"
    if suffix == "04":
        return "incomplete"
    return "clean"


def state_key_candidates():
    return [f"env:/{TF_WORKSPACE}/{PHONE_NUMBERS_STATE_KEY}", PHONE_NUMBERS_STATE_KEY]


def load_state_document():
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


def load_phone_number_inventory():
    state_doc = load_state_document()
    outputs = state_doc.get("outputs", {})
    inventory = outputs.get("phone_number_inventory", {}).get("value", {})

    entries = []
    for number_key, item in inventory.items():
        phone_number = item.get("phone_number")
        if not phone_number:
            continue
        entries.append(
            {
                "phone_number": normalize_phone_number(phone_number),
                "number_key": number_key,
                "purpose": item.get("purpose", ""),
            }
        )
    return entries


def inventory_lookup():
    return {entry["phone_number"]: entry for entry in load_phone_number_inventory()}


def safe_inventory_lookup():
    try:
        return inventory_lookup()
    except Exception as exc:  # noqa: BLE001
        LOGGER.warning("Falling back to explicit-number mode without inventory enrichment: %s", exc)
        return {}


def parse_numbers_payload(event, inventory_map):
    numbers = event.get("numbers")
    if numbers is None:
        single = event.get("phone_number")
        if single:
            numbers = [single]
        else:
            raise ValueError("Provide either numbers or phone_number")

    scenario_map = event.get("mock_scenarios", {}) or {}
    parsed = []

    for entry in numbers:
        if isinstance(entry, str):
            normalized = normalize_phone_number(entry)
            inventory_entry = inventory_map.get(normalized, {})
            parsed.append(
                {
                    "phone_number": normalized,
                    "scenario": scenario_map.get(normalized),
                    "assigned_to": inventory_entry.get("number_key", ""),
                }
            )
            continue

        if not isinstance(entry, dict):
            raise ValueError("numbers entries must be strings or objects")

        normalized = normalize_phone_number(entry.get("phone_number"))
        inventory_entry = inventory_map.get(normalized, {})
        parsed.append(
            {
                "phone_number": normalized,
                "scenario": entry.get("scenario") or scenario_map.get(normalized),
                "assigned_to": entry.get("assigned_to") or inventory_entry.get("number_key", ""),
            }
        )

    return parsed


def inventory_numbers(event):
    scenario_map = event.get("mock_scenarios", {}) or {}
    parsed = []

    for entry in load_phone_number_inventory():
        parsed.append(
            {
                "phone_number": entry["phone_number"],
                "scenario": scenario_map.get(entry["phone_number"]),
                "assigned_to": entry.get("number_key", ""),
            }
        )

    return parsed


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


def mock_lookup(provider, item):
    scenario = (item.get("scenario") or default_mock_scenario(item["phone_number"])).strip().lower()
    if scenario == "provider_error":
        raise ProviderError(f"Mock {provider} lookup failed.")
    if scenario == "incomplete":
        return None
    if scenario not in MOCK_PROVIDER_SCORES:
        raise ProviderError(f"Unsupported mock scenario: {scenario}")
    return MOCK_PROVIDER_SCORES[scenario][provider]


def live_lookup(provider, phone_number):
    secret = secret_dict(REPUTATION_API_SECRETS.get(provider, ""))
    static_scores = secret.get("static_scores", {})
    configured = static_scores.get(phone_number) or static_scores.get("default")
    if configured is None:
        raise ProviderError(f"Live mode is enabled for {provider}, but no static_scores entry is configured.")
    return int(configured)


def query_provider(provider, item):
    if REPUTATION_PROVIDER_MODE == "mock":
        return mock_lookup(provider, item)
    return live_lookup(provider, item["phone_number"])


def get_current_record(phone_number):
    response = TABLE.get_item(Key={"phone_number": phone_number, "check_date": "CURRENT"})
    return response.get("Item")


def label_from_score(spam_score):
    if spam_score >= SPAM_THRESHOLD_SPAM:
        return "SPAM"
    if spam_score >= SPAM_THRESHOLD_RISK:
        return "RISK"
    return "CLEAN"


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


def compose_check_result(item):
    phone_number = item["phone_number"]
    current = get_current_record(phone_number) or {}
    checked_at = utc_now()
    checked_at_str = isoformat_z(checked_at)

    provider_scores = {}
    provider_errors = []
    for provider in REPUTATION_PROVIDERS:
        try:
            score = query_provider(provider, item)
            if score is not None:
                provider_scores[provider] = int(score)
            else:
                provider_errors.append(provider)
        except Exception as exc:  # noqa: BLE001
            LOGGER.exception("Reputation lookup failed for %s via %s", phone_number, provider)
            provider_errors.append(provider)
            LOGGER.warning("Provider failure: %s", exc)

    if provider_scores:
        spam_score = int(round(sum(provider_scores.values()) / len(provider_scores)))
        spam_label = label_from_score(spam_score)
    else:
        spam_score = 0
        spam_label = "CLEAN"

    provider_data_complete = len(provider_scores) == len(REPUTATION_PROVIDERS)
    current_ref = checked_at_str

    return {
        "phone_number": phone_number,
        "check_date": checked_at_str,
        "spam_score": spam_score,
        "spam_label": spam_label,
        "hiya_score": provider_scores.get("hiya"),
        "first_orion_score": provider_scores.get("first_orion"),
        "tns_score": provider_scores.get("tns"),
        "stir_shaken_attestation": current.get("stir_shaken_attestation", "UNKNOWN"),
        "attestation_check_date": current.get("attestation_check_date"),
        "remediation_status": current.get("remediation_status", "NONE"),
        "dispute_submitted_date": current.get("dispute_submitted_date"),
        "assigned_to": item.get("assigned_to") or current.get("assigned_to", ""),
        "current_ref": current_ref,
        "provider_data_complete": provider_data_complete,
        "provider_errors": provider_errors,
        "last_operation": "CHECK",
        "updated_by": "PRD16_REPUTATION_CHECK",
        "checked_at": checked_at_str,
    }


def persist_check_result(result):
    history_time = parse_isoformat(result["check_date"])

    history_item = dict(result)
    history_item["expires_epoch"] = epoch_seconds(history_time + timedelta(days=HISTORY_TTL_DAYS))

    current_item = dict(result)
    current_item["check_date"] = "CURRENT"
    current_item["record_scope"] = "CURRENT"

    TABLE.put_item(Item=history_item)
    TABLE.put_item(Item=current_item)

    response = dict(current_item)
    response["history_ref"] = result["check_date"]
    return response


def evaluate_assignment(phone_number):
    current = get_current_record(phone_number)
    if not current:
        return {
            "phone_number": phone_number,
            "eligibility_status": "INELIGIBLE",
            "reason_codes": ["MISSING_CURRENT_RECORD"],
            "warnings": [],
        }

    reason_codes = []
    warnings = []

    stale = False
    try:
        checked_at = parse_isoformat(current["checked_at"])
        if utc_now() - checked_at > timedelta(days=REPUTATION_STALENESS_DAYS):
            stale = True
            reason_codes.append("REPUTATION_CHECK_STALE")
    except Exception:  # noqa: BLE001
        stale = True
        reason_codes.append("INELIGIBLE_STALE")

    if current.get("spam_label") == "RISK":
        reason_codes.append("SPAM_LABEL_RISK")
    if current.get("spam_label") == "SPAM":
        reason_codes.append("SPAM_LABEL_SPAM")

    remediation_status = current.get("remediation_status", "NONE")
    if remediation_status == "DISPUTE_SUBMITTED":
        reason_codes.append("REMEDIATION_IN_PROGRESS")
    if remediation_status in {"REPLACEMENT_REQUIRED", "REPLACED"}:
        reason_codes.append("REPLACEMENT_REQUIRED")

    if not current.get("provider_data_complete", False):
        reason_codes.append("PROVIDER_DATA_INCOMPLETE")

    if current.get("stir_shaken_attestation") in {"B", "C"}:
        warnings.append("ATTESTATION_DEGRADED")

    reason_codes = sorted(set(reason_codes))
    eligibility_status = "ELIGIBLE" if not reason_codes else "INELIGIBLE"
    return {
        "phone_number": phone_number,
        "eligibility_status": eligibility_status,
        "reason_codes": reason_codes,
        "warnings": warnings,
        "current_record": {
            "spam_score": current.get("spam_score"),
            "spam_label": current.get("spam_label"),
            "reputation_threshold": REPUTATION_THRESHOLD,
            "remediation_status": remediation_status,
            "checked_at": current.get("checked_at"),
            "stir_shaken_attestation": current.get("stir_shaken_attestation", "UNKNOWN"),
        },
    }


def build_mutated_record(current, target_status, payload):
    mutation_time = utc_now()
    mutation_ref = isoformat_z(mutation_time)
    current_status = current.get("remediation_status", "NONE")

    if current.get("last_request_id") == payload["request_id"] and current_status == target_status:
        response = dict(current)
        response["idempotent"] = True
        return None, response

    if target_status not in ALLOWED_REMEDIATION_TRANSITIONS.get(current_status, set()):
        return {
            "phone_number": current["phone_number"],
            "status": "REJECTED",
            "reason_code": "INVALID_REMEDIATION_TRANSITION",
            "current_status": current_status,
            "target_status": target_status,
        }, None

    dispute_submitted_date = current.get("dispute_submitted_date")
    if target_status == "DISPUTE_SUBMITTED":
        dispute_submitted_date = payload.get("effective_date") or mutation_ref.split("T")[0]
    elif target_status == "NONE":
        dispute_submitted_date = None

    base_record = dict(current)
    base_record.update(
        {
            "check_date": mutation_ref,
            "remediation_status": target_status,
            "dispute_submitted_date": dispute_submitted_date,
            "provider": payload.get("provider", ""),
            "ticket_ref": payload.get("ticket_ref", ""),
            "notes": payload.get("notes", ""),
            "effective_date": payload.get("effective_date", ""),
            "operator_identity": payload["operator_identity"],
            "last_request_id": payload["request_id"],
            "last_operation": "RECORD_REMEDIATION_ACTION",
            "updated_by": payload["operator_identity"],
            "updated_at": mutation_ref,
            "current_ref": mutation_ref,
        }
    )

    history_record = dict(base_record)
    history_record.pop("record_scope", None)
    history_record["expires_epoch"] = epoch_seconds(mutation_time + timedelta(days=HISTORY_TTL_DAYS))

    current_record = dict(base_record)
    current_record["check_date"] = "CURRENT"
    current_record["record_scope"] = "CURRENT"

    TABLE.put_item(Item=history_record)
    TABLE.put_item(Item=current_record)

    response = dict(current_record)
    response["history_ref"] = mutation_ref
    response["idempotent"] = False
    return None, response


def handle_check_numbers(event):
    inventory_map = safe_inventory_lookup()
    items = parse_numbers_payload(event, inventory_map)
    return run_checks(items)


def handle_check_inventory(event):
    return run_checks(inventory_numbers(event))


def run_checks(items):
    results = []
    total_errors = 0

    for index in range(0, len(items), BATCH_SIZE):
        batch = items[index:index + BATCH_SIZE]
        batch_results = []

        for item in batch:
            result = persist_check_result(compose_check_result(item))
            batch_results.append(result)
            if result.get("provider_errors"):
                total_errors += len(result["provider_errors"])

        results.extend(batch_results)
        emit_metrics(
            [
                ("ReputationBatchProgress", len(batch_results), "Count"),
                ("ReputationBatchErrors", total_errors, "Count"),
            ]
        )

        if index + BATCH_SIZE < len(items) and BATCH_DELAY_MS > 0:
            time.sleep(BATCH_DELAY_MS / 1000.0)

    high_spam_count = 0
    clean_count = 0
    remediation_count = 0
    for result in results:
        if result.get("spam_label") == "SPAM":
            high_spam_count += 1
        elif ALARM_ON_RISK_LABEL and result.get("spam_label") == "RISK":
            high_spam_count += 1

        if result.get("spam_label") == "CLEAN":
            clean_count += 1

        if result.get("remediation_status", "NONE") != "NONE":
            remediation_count += 1

    emit_metrics(
        [
            ("NumbersWithHighSpamRisk", high_spam_count, "Count"),
            ("NumbersClean", clean_count, "Count"),
            ("NumbersNeedingRemediation", remediation_count, "Count"),
        ]
    )

    return {
        "operation": "CHECK",
        "count": len(results),
        "results": results,
    }


def handle_validate_assignment(event):
    inventory_map = safe_inventory_lookup()
    results = []
    for item in parse_numbers_payload(event, inventory_map):
        results.append(evaluate_assignment(item["phone_number"]))
    return {
        "operation": "VALIDATE_ASSIGNMENT_ELIGIBILITY",
        "results": results,
    }


def handle_record_remediation_action(event):
    phone_number = normalize_phone_number(event.get("phone_number"))
    target_status = str(event.get("target_status", "")).strip().upper()
    operator_identity = str(event.get("operator_identity", "")).strip()
    request_id = str(event.get("request_id", "")).strip()

    if not target_status:
        raise ValueError("target_status is required")
    if not operator_identity:
        raise ValueError("operator_identity is required")
    if not request_id:
        raise ValueError("request_id is required")

    current = get_current_record(phone_number)
    if not current:
        return {
            "operation": "RECORD_REMEDIATION_ACTION",
            "result": {
                "phone_number": phone_number,
                "status": "REJECTED",
                "reason_code": "MISSING_CURRENT_RECORD",
            },
        }

    error, result = build_mutated_record(
        current,
        target_status,
        {
            "operator_identity": operator_identity,
            "request_id": request_id,
            "provider": str(event.get("provider", "")).strip(),
            "ticket_ref": str(event.get("ticket_ref", "")).strip(),
            "notes": str(event.get("notes", "")).strip(),
            "effective_date": str(event.get("effective_date", "")).strip(),
        },
    )

    if error:
        return {
            "operation": "RECORD_REMEDIATION_ACTION",
            "result": error,
        }

    return {
        "operation": "RECORD_REMEDIATION_ACTION",
        "result": result,
    }


def handler(event, _context):
    LOGGER.info("Received event: %s", json.dumps(event or {}))
    operation = str((event or {}).get("operation", "CHECK_NUMBERS")).strip().upper()
    if operation not in VALID_OPERATIONS:
        raise ValueError(f"operation must be one of: {', '.join(sorted(VALID_OPERATIONS))}")

    if operation == "CHECK_NUMBERS":
        return handle_check_numbers(event or {})
    if operation == "CHECK_INVENTORY":
        return handle_check_inventory(event or {})
    if operation == "VALIDATE_ASSIGNMENT_ELIGIBILITY":
        return handle_validate_assignment(event or {})
    return handle_record_remediation_action(event or {})
