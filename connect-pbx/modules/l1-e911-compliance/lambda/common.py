import json
import os
from datetime import date, datetime, timedelta, timezone

import boto3


DYNAMODB = boto3.resource("dynamodb")
S3 = boto3.client("s3")
CLOUDWATCH = boto3.client("cloudwatch")
SECRETS_MANAGER = boto3.client("secretsmanager")


def table_from_env():
    return DYNAMODB.Table(os.environ["TABLE_NAME"])


def utc_now():
    return datetime.now(timezone.utc)


def iso_now():
    return utc_now().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def today_iso():
    return date.today().isoformat()


def env_bool(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def env_int(name, default):
    value = os.environ.get(name, "")
    return int(value) if value else default


def emit_metric(metric_name, value, unit="Count"):
    CLOUDWATCH.put_metric_data(
        Namespace=os.environ["METRIC_NAMESPACE"],
        MetricData=[{
            "MetricName": metric_name,
            "Timestamp": utc_now(),
            "Value": value,
            "Unit": unit,
        }],
    )


def load_json_secret(secret_arn):
    if not secret_arn:
        return {}
    response = SECRETS_MANAGER.get_secret_value(SecretId=secret_arn)
    secret_text = response.get("SecretString", "{}")
    return json.loads(secret_text)


def load_state_document(bucket, key, workspace):
    candidate_keys = []
    if workspace:
        candidate_keys.append(f"env:/{workspace}/{key}")
    candidate_keys.append(key)

    last_error = None
    for candidate in candidate_keys:
        try:
            response = S3.get_object(Bucket=bucket, Key=candidate)
            return json.loads(response["Body"].read())
        except Exception as exc:  # pragma: no cover - exercised in Lambda
            last_error = exc

    raise last_error


def load_phone_number_inventory():
    state_doc = load_state_document(
        os.environ["PHONE_NUMBERS_STATE_BUCKET"],
        os.environ["PHONE_NUMBERS_STATE_KEY"],
        os.environ.get("TF_WORKSPACE", ""),
    )
    outputs = state_doc.get("outputs", {})
    return outputs.get("phone_number_inventory", {}).get("value", {})


def parse_date(date_text):
    if not date_text:
        return None
    try:
        return datetime.strptime(date_text, "%Y-%m-%d").date()
    except ValueError:
        return None


def is_stale(date_text, interval_days):
    parsed = parse_date(date_text)
    if parsed is None:
        return True
    return parsed <= (date.today() - timedelta(days=interval_days))


def require_fields(payload, field_names):
    missing = [field for field in field_names if not payload.get(field)]
    if missing:
        raise ValueError(f"Missing required field(s): {', '.join(sorted(missing))}")


def normalize_item(item):
    if item is None:
        return None
    return json.loads(json.dumps(item, default=str))


def confirmation_token(agent_id, request_id):
    safe_agent = (agent_id or "agent").replace(" ", "-")
    safe_request = (request_id or "request").replace(" ", "-")
    return f"mock-confirm-{safe_agent}-{safe_request}"


def mock_elin(agent_id, phone_number):
    suffix_source = "".join(ch for ch in (phone_number or agent_id or "0000") if ch.isdigit())
    suffix = (suffix_source[-6:] if suffix_source else "000000").rjust(6, "0")
    return f"MOCK-ELIN-{suffix}"
