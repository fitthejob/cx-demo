import json
import logging
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime, timedelta

import boto3


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DYNAMODB = boto3.resource("dynamodb")
SECRETS = boto3.client("secretsmanager")

TABLE = DYNAMODB.Table(os.environ["TABLE_NAME"])
LOOKUP_PROVIDER = os.environ.get("LOOKUP_PROVIDER", "mock").strip().lower()
LOOKUP_PROVIDER_SECRET_ARN = os.environ.get("LOOKUP_PROVIDER_SECRET_ARN", "").strip()
CHECK_EXPIRY_DAYS = int(os.environ.get("CHECK_EXPIRY_DAYS", "30"))
HISTORY_TTL_DAYS = int(os.environ.get("HISTORY_TTL_DAYS", "365"))

TOLL_FREE_NPAS = {"800", "833", "844", "855", "866", "877", "888"}
OVERRIDE_ALLOWED_STATUSES = {
    "ELIGIBLE",
    "INELIGIBLE",
    "MANUAL_VERIFICATION_REQUIRED",
}

ALLOWED_OVERRIDE_REASONS = [
    "TF_RESPORG_VERIFIED_MANUALLY",
    "CARRIER_CONFIRMED_ELIGIBLE",
    "REGULATORY_EXCEPTION",
    "OPERATOR_OVERRIDE",
]


class ProviderError(Exception):
    pass


def utc_now():
    return datetime.now(UTC)


def isoformat_z(dt):
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


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


def is_toll_free(phone_number):
    digits = re.sub(r"\D", "", phone_number)
    if len(digits) == 11 and digits.startswith("1"):
        return digits[1:4] in TOLL_FREE_NPAS
    return False


def normalize_line_type(raw_value):
    if not raw_value:
        return "UNKNOWN"

    value = str(raw_value).strip().upper().replace("-", "_").replace(" ", "_")
    mapping = {
        "LANDLINE": "POTS",
        "WIRELINE": "POTS",
        "DID": "DID",
        "POTS": "POTS",
        "VOIP": "VOIP",
        "TOLL_FREE": "TOLL_FREE",
        "MOBILE": "MOBILE",
        "WIRELESS": "MOBILE",
        "UNKNOWN": "UNKNOWN",
    }
    return mapping.get(value, "UNKNOWN")


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

    for entry in numbers:
        if isinstance(entry, str):
            parsed.append({
                "phone_number": normalize_phone_number(entry),
                "scenario": scenario_map.get(normalize_phone_number(entry)),
            })
            continue

        if not isinstance(entry, dict):
            raise ValueError("numbers entries must be strings or objects")

        normalized_number = normalize_phone_number(entry.get("phone_number"))
        parsed.append({
            "phone_number": normalized_number,
            "scenario": entry.get("scenario") or scenario_map.get(normalized_number),
        })

    return parsed


def secret_dict(secret_arn):
    if not secret_arn:
        raise ProviderError("Provider secret ARN is required for non-mock providers")

    response = SECRETS.get_secret_value(SecretId=secret_arn)
    secret_string = response.get("SecretString")
    if not secret_string:
        raise ProviderError("Provider secret is empty or binary-only")

    try:
        return json.loads(secret_string)
    except json.JSONDecodeError as exc:
        raise ProviderError("Provider secret is not valid JSON") from exc


def mock_lookup(item, toll_free):
    scenario = (item.get("scenario") or "").strip().lower()
    if not scenario:
        suffix = item["phone_number"][-2:]
        if toll_free:
            scenario = "manual_tollfree" if suffix == "99" else "eligible_tollfree"
        else:
            scenario = {
                "00": "eligible_did",
                "01": "ineligible_voip",
                "02": "porting_freeze",
                "03": "check_failed",
            }.get(suffix, "eligible_did")

    if scenario == "check_failed":
        raise ProviderError("Mock provider forced failure")

    if scenario == "eligible_did":
        return {
            "line_type": "POTS",
            "ocn": "9101",
            "losing_carrier_name": "Bandwidth.com Inc",
            "porting_freeze": False,
        }
    if scenario == "ineligible_voip":
        return {
            "line_type": "VOIP",
            "ocn": "",
            "losing_carrier_name": "Example UCaaS",
            "porting_freeze": False,
        }
    if scenario == "porting_freeze":
        return {
            "line_type": "POTS",
            "ocn": "9101",
            "losing_carrier_name": "Bandwidth.com Inc",
            "porting_freeze": True,
        }
    if scenario == "eligible_tollfree":
        return {
            "line_type": "TOLL_FREE",
            "resp_org": "BANDW",
            "losing_carrier_name": "Bandwidth.com Inc",
            "porting_freeze": False,
        }
    if scenario == "manual_tollfree":
        return {
            "line_type": "TOLL_FREE",
            "manual_verification_required": True,
            "losing_carrier_name": "Unknown Toll-Free RespOrg",
            "porting_freeze": None,
        }

    raise ProviderError(f"Unsupported mock scenario: {scenario}")


def bandwidth_lookup(number, toll_free):
    secret = secret_dict(LOOKUP_PROVIDER_SECRET_ARN)
    base_url = secret.get("base_url", "").rstrip("/")
    path_key = "tollfree_lookup_path" if toll_free else "did_lookup_path"
    lookup_path = secret.get(path_key, "").strip()
    token = secret.get("api_token") or secret.get("api_key")
    auth_header_name = secret.get("auth_header_name", "Authorization")
    auth_prefix = secret.get("auth_header_value_prefix", "Bearer ")
    timeout_seconds = int(secret.get("timeout_seconds", 10))

    if not base_url or not lookup_path or not token:
        raise ProviderError("Bandwidth secret must contain base_url, lookup path, and api_token/api_key")

    url = f"{base_url}/{lookup_path.lstrip('/')}?number={urllib.parse.quote(number)}"
    headers = {
        "Accept": "application/json",
        auth_header_name: f"{auth_prefix}{token}",
    }
    request = urllib.request.Request(url, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise ProviderError(f"Bandwidth lookup HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise ProviderError(f"Bandwidth lookup failed: {exc.reason}") from exc
    except json.JSONDecodeError as exc:
        raise ProviderError("Bandwidth lookup returned invalid JSON") from exc

    normalized = {
        "line_type": payload.get("line_type") or payload.get("number_type"),
        "ocn": payload.get("ocn") or payload.get("carrier_ocn"),
        "losing_carrier_name": payload.get("losing_carrier_name") or payload.get("carrier_name"),
        "resp_org": payload.get("resp_org"),
        "porting_freeze": payload.get("porting_freeze"),
        "manual_verification_required": payload.get("manual_verification_required", False),
    }
    return normalized


def evaluate_result(phone_number, lookup_result, toll_free, verified_by):
    checked_at_dt = utc_now()
    expires_at_dt = checked_at_dt + timedelta(days=CHECK_EXPIRY_DAYS)
    line_type = normalize_line_type(lookup_result.get("line_type"))
    porting_freeze = lookup_result.get("porting_freeze")
    ocn = (lookup_result.get("ocn") or "").strip()
    losing_carrier_name = (lookup_result.get("losing_carrier_name") or "").strip()
    resp_org = (lookup_result.get("resp_org") or "").strip()

    if toll_free:
        if lookup_result.get("manual_verification_required"):
            status = "MANUAL_VERIFICATION_REQUIRED"
            reason = "Automated toll-free RespOrg verification requires manual review."
        elif line_type != "TOLL_FREE":
            status = "INELIGIBLE"
            reason = f"Line type is {line_type}. Toll-free verification requires a TOLL_FREE number."
        elif porting_freeze is True:
            status = "INELIGIBLE"
            reason = "Provider reported a porting freeze on this toll-free number."
        elif not resp_org:
            status = "INELIGIBLE"
            reason = "RespOrg could not be identified for this toll-free number."
        else:
            status = "ELIGIBLE"
            reason = None
    else:
        if line_type in {"VOIP", "MOBILE", "UNKNOWN"}:
            status = "INELIGIBLE"
            reason = f"Line type is {line_type}. Amazon Connect portability requires a POTS/DID number."
        elif porting_freeze is True:
            status = "INELIGIBLE"
            reason = "Provider reported a porting freeze on this number."
        elif not ocn:
            status = "INELIGIBLE"
            reason = "Losing carrier OCN could not be identified."
        else:
            status = "ELIGIBLE"
            reason = None

    return {
        "phone_number": phone_number,
        "provider_status": status,
        "effective_status": status,
        "effective_source": "PROVIDER",
        "lookup_provider": LOOKUP_PROVIDER,
        "line_type": line_type,
        "ocn": ocn,
        "losing_carrier_name": losing_carrier_name,
        "resp_org": resp_org,
        "porting_freeze": porting_freeze,
        "ineligibility_reason": reason,
        "checked_at": isoformat_z(checked_at_dt),
        "effective_at": isoformat_z(checked_at_dt),
        "expires_at": isoformat_z(expires_at_dt),
        "verified_by": verified_by,
    }


def persist_check_result(result):
    history_dt = datetime.strptime(result["checked_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    history_ref = f"CHECK#{result['checked_at']}"

    history_item = dict(result)
    history_item.update({
        "record_type": history_ref,
        "expires_epoch": epoch_seconds(history_dt + timedelta(days=HISTORY_TTL_DAYS)),
    })

    current_item = dict(result)
    current_item.update({
        "record_type": "CURRENT",
        "current_ref": history_ref,
    })
    current_item.pop("expires_epoch", None)

    TABLE.put_item(Item=history_item)
    TABLE.put_item(Item=current_item)

    response = dict(result)
    response["record_ref"] = history_ref
    return response


def handle_check(event, context):
    verified_by = getattr(context, "invoked_function_arn", "lambda:unknown")
    results = []

    for item in parse_numbers_payload(event):
        phone_number = item["phone_number"]
        toll_free = is_toll_free(phone_number)

        try:
            if LOOKUP_PROVIDER == "mock":
                lookup_result = mock_lookup(item, toll_free)
            elif LOOKUP_PROVIDER == "bandwidth":
                lookup_result = bandwidth_lookup(phone_number, toll_free)
            else:
                raise ProviderError(f"Unsupported lookup provider: {LOOKUP_PROVIDER}")

            evaluated = evaluate_result(phone_number, lookup_result, toll_free, verified_by)
        except Exception as exc:  # noqa: BLE001
            LOGGER.exception("Portability lookup failed for %s", phone_number)
            checked_at_dt = utc_now()
            evaluated = {
                "phone_number": phone_number,
                "provider_status": "CHECK_FAILED",
                "effective_status": "CHECK_FAILED",
                "effective_source": "PROVIDER",
                "lookup_provider": LOOKUP_PROVIDER,
                "line_type": "TOLL_FREE" if toll_free else "UNKNOWN",
                "ocn": "",
                "losing_carrier_name": "",
                "resp_org": "",
                "porting_freeze": None,
                "ineligibility_reason": str(exc),
                "checked_at": isoformat_z(checked_at_dt),
                "effective_at": isoformat_z(checked_at_dt),
                "expires_at": isoformat_z(checked_at_dt + timedelta(days=CHECK_EXPIRY_DAYS)),
                "verified_by": verified_by,
            }

        results.append(persist_check_result(evaluated))

    return {
        "action": "check",
        "lookup_provider": LOOKUP_PROVIDER,
        "results": results,
    }


def handle_override(event):
    phone_number = normalize_phone_number(event.get("phone_number"))
    effective_status = str(event.get("effective_status", "")).strip().upper()
    operator_identity = str(event.get("operator_identity", "")).strip()
    reason_code = str(event.get("reason_code", "")).strip()
    justification = str(event.get("justification", "")).strip()
    override_review_by = str(event.get("override_review_by", "")).strip()

    if effective_status not in OVERRIDE_ALLOWED_STATUSES:
        raise ValueError("effective_status must be ELIGIBLE, INELIGIBLE, or MANUAL_VERIFICATION_REQUIRED")
    if not operator_identity:
        raise ValueError("operator_identity is required for overrides")
    if not reason_code:
        raise ValueError("reason_code is required for overrides")
    if reason_code not in ALLOWED_OVERRIDE_REASONS:
        raise ValueError(
            f"reason_code must be one of: {', '.join(ALLOWED_OVERRIDE_REASONS)}"
        )
    if not justification:
        raise ValueError("justification is required for overrides")

    current = TABLE.get_item(Key={"phone_number": phone_number, "record_type": "CURRENT"}).get("Item", {})
    override_dt = utc_now()
    override_ref = f"OVERRIDE#{isoformat_z(override_dt)}"

    current_item = {
        "phone_number": phone_number,
        "record_type": "CURRENT",
        "provider_status": current.get("provider_status", "CHECK_FAILED"),
        "effective_status": effective_status,
        "effective_source": "OPERATOR_OVERRIDE",
        "lookup_provider": current.get("lookup_provider", LOOKUP_PROVIDER),
        "line_type": current.get("line_type", "UNKNOWN"),
        "ocn": current.get("ocn", ""),
        "losing_carrier_name": current.get("losing_carrier_name", ""),
        "resp_org": current.get("resp_org", ""),
        "porting_freeze": current.get("porting_freeze"),
        "ineligibility_reason": current.get("ineligibility_reason"),
        "checked_at": current.get("checked_at"),
        "effective_at": isoformat_z(override_dt),
        "expires_at": isoformat_z(override_dt + timedelta(days=CHECK_EXPIRY_DAYS)),
        "verified_by": operator_identity,
        "override_reason_code": reason_code,
        "override_justification": justification,
        "override_by": operator_identity,
        "override_at": isoformat_z(override_dt),
        "override_review_by": override_review_by,
        "current_ref": override_ref,
    }

    current_item.pop("expires_epoch", None)

    history_item = dict(current_item)
    history_item["record_type"] = override_ref
    history_item["expires_epoch"] = epoch_seconds(override_dt + timedelta(days=HISTORY_TTL_DAYS))

    TABLE.put_item(Item=history_item)
    TABLE.put_item(Item=current_item)

    response = dict(current_item)
    response["record_ref"] = override_ref
    return {
        "action": "override",
        "result": response,
    }


def handler(event, context):
    LOGGER.info("Received event: %s", json.dumps(event))
    action = str((event or {}).get("action", "check")).strip().lower()

    if action == "check":
        return handle_check(event or {}, context)
    if action == "override":
        return handle_override(event or {})

    raise ValueError("action must be check or override")
