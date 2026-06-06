import json
import logging
import os
import re
from datetime import UTC, datetime, timedelta

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError


LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

DYNAMODB = boto3.resource("dynamodb")
S3 = boto3.client("s3")
CONNECT = boto3.client("connect")
CLOUDTRAIL = boto3.client("cloudtrail")
CLOUDWATCH = boto3.client("cloudwatch")

TABLE = DYNAMODB.Table(os.environ["DRIFT_TABLE"])
STATUS_GSI_NAME = os.environ["STATUS_GSI_NAME"]
MODULE_STATE_RESOLUTION = json.loads(os.environ["MODULE_STATE_RESOLUTION_JSON"])
METRIC_NAMESPACE = os.environ["METRIC_NAMESPACE"]
TF_WORKSPACE = os.environ.get("TF_WORKSPACE", "default").strip() or "default"
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", "30"))

HISTORY_TTL_DAYS = 90
VALID_OPERATIONS = {"SCAN_ALL", "SCAN_NUMBERS"}
ROUTING_EVENT_NAMES = {
    "AssociatePhoneNumberContactFlow",
    "DisassociatePhoneNumberContactFlow",
}
INVENTORY_EVENT_NAMES = {"ClaimPhoneNumber", "ReleasePhoneNumber"}


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


def extract_output_value(state_doc, output_name, default=None):
    outputs = state_doc.get("outputs", {}) or {}
    output = outputs.get(output_name) or {}
    return output.get("value", default)


def load_state_document(bucket, key):
    last_error = None
    candidate_keys = [key]

    if TF_WORKSPACE != "default" and not key.startswith("env:/"):
        candidate_keys.insert(0, f"env:/{TF_WORKSPACE}/{key}")

    for candidate_key in candidate_keys:
        try:
            response = S3.get_object(Bucket=bucket, Key=candidate_key)
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as exc:
            last_error = exc
            error_code = exc.response.get("Error", {}).get("Code", "")
            if error_code not in {"AccessDenied", "NoSuchKey"}:
                raise

    raise last_error


def parse_contact_flow_arns(state_doc):
    flow_arn_by_id = {}
    for resource in state_doc.get("resources", []) or []:
        if resource.get("type") != "aws_connect_contact_flow":
            continue

        for instance in resource.get("instances", []) or []:
            attrs = instance.get("attributes", {}) or {}
            flow_id = attrs.get("contact_flow_id") or attrs.get("id")
            flow_arn = attrs.get("arn")
            if flow_id and flow_arn:
                flow_arn_by_id[flow_id] = flow_arn

    return flow_arn_by_id


def parse_expected_associations(state_doc):
    associations = {}

    for resource in state_doc.get("resources", []) or []:
        resource_type = resource.get("type")
        resource_name = resource.get("name")

        if resource_type == "aws_connect_phone_number_contact_flow_association":
            for instance in resource.get("instances", []) or []:
                attrs = instance.get("attributes", {}) or {}
                phone_number_id = attrs.get("phone_number_id")
                contact_flow_id = attrs.get("contact_flow_id")
                if phone_number_id and contact_flow_id:
                    associations[phone_number_id] = contact_flow_id
            continue

        if resource_type == "terraform_data" and resource_name == "phone_number_flow_associations":
            for instance in resource.get("instances", []) or []:
                attrs = instance.get("attributes", {}) or {}
                triggers_replace = attrs.get("triggers_replace") or {}
                if not isinstance(triggers_replace, dict):
                    continue

                phone_number_id = triggers_replace.get("phone_number_id")
                contact_flow_id = triggers_replace.get("contact_flow_id")
                if phone_number_id and contact_flow_id:
                    associations[phone_number_id] = contact_flow_id

    return associations


def build_managed_inventory(phone_numbers_state):
    phone_inventory = extract_output_value(phone_numbers_state, "phone_number_inventory", {}) or {}
    phone_number_ids = extract_output_value(phone_numbers_state, "phone_number_ids", {}) or {}

    managed = {}
    for logical_key, inventory_entry in phone_inventory.items():
        phone_number = inventory_entry.get("phone_number")
        if not phone_number:
            continue

        normalized = normalize_phone_number(phone_number)
        managed[normalized] = {
            "phone_number_id": phone_number_ids.get(logical_key),
            "logical_key": logical_key,
        }

    return managed


def build_expected_routes(phone_numbers_state, contact_flow_state):
    managed_inventory = build_managed_inventory(phone_numbers_state)
    explicit_routes = extract_output_value(contact_flow_state, "expected_number_flow_routes", {}) or {}

    if explicit_routes:
        normalized_routes = {}
        for phone_number, route in explicit_routes.items():
            normalized_routes[normalize_phone_number(phone_number)] = {
                "phone_number_id": route.get("phone_number_id"),
                "expected_flow_id": route.get("expected_flow_id"),
                "expected_flow_arn": route.get("expected_flow_arn"),
            }
        return managed_inventory, normalized_routes

    flow_arn_by_id = parse_contact_flow_arns(contact_flow_state)
    expected_associations = parse_expected_associations(contact_flow_state)
    number_by_phone_id = {
        item["phone_number_id"]: phone_number
        for phone_number, item in managed_inventory.items()
        if item.get("phone_number_id")
    }

    expected = {}
    for phone_number_id, contact_flow_id in expected_associations.items():
        phone_number = number_by_phone_id.get(phone_number_id)
        if not phone_number:
            continue

        expected[phone_number] = {
            "phone_number_id": phone_number_id,
            "expected_flow_id": contact_flow_id,
            "expected_flow_arn": flow_arn_by_id.get(contact_flow_id),
        }

    return managed_inventory, expected


def list_connect_numbers(instance_id):
    paginator = CONNECT.get_paginator("list_phone_numbers_v2")
    inventory = {}

    for page in paginator.paginate(InstanceId=instance_id, MaxResults=100):
        summaries = page.get("ListPhoneNumbersSummaryList") or []
        for summary in summaries:
            phone_number = summary.get("PhoneNumber")
            if not phone_number:
                continue

            normalized = normalize_phone_number(phone_number)
            inventory[normalized] = {
                "phone_number_id": summary.get("PhoneNumberId"),
                "instance_id": instance_id,
            }

    return inventory


def extract_instance_id_from_arn(arn):
    if not arn:
        return None

    match = re.search(r":instance/([^/]+)/", arn)
    if match:
        return match.group(1)
    return None


def parse_number_scope(event):
    numbers = event.get("numbers")
    if numbers is None:
        single = event.get("phone_number")
        if single:
            numbers = [single]
        else:
            raise ValueError("Provide either numbers or phone_number for SCAN_NUMBERS")

    return {normalize_phone_number(number) for number in numbers}


def resolved_by_for_event(event, operation):
    explicit = str((event or {}).get("resolved_by", "")).strip()
    if explicit:
        return explicit
    return "manual" if operation == "SCAN_NUMBERS" else "terraform-apply"


def lookup_recent_events(event_name, start_time, end_time):
    events = []
    next_token = None

    while True:
        kwargs = {
            "LookupAttributes": [
                {"AttributeKey": "EventName", "AttributeValue": event_name}
            ],
            "StartTime": start_time,
            "EndTime": end_time,
            "MaxResults": 50,
        }
        if next_token:
            kwargs["NextToken"] = next_token

        response = CLOUDTRAIL.lookup_events(**kwargs)
        events.extend(response.get("Events", []))
        next_token = response.get("NextToken")
        if not next_token:
            break

    return events


def extract_principal_arn(detail, fallback_username):
    identity = detail.get("userIdentity") or {}
    arn = identity.get("arn")
    if arn:
        return arn
    return fallback_username or None


def parse_cloudtrail_events(phone_id_to_number):
    end_time = utc_now()
    start_time = end_time - timedelta(minutes=LOOKBACK_MINUTES)
    events = []

    for event_name in sorted(ROUTING_EVENT_NAMES | INVENTORY_EVENT_NAMES):
        for raw_event in lookup_recent_events(event_name, start_time, end_time):
            try:
                detail = json.loads(raw_event.get("CloudTrailEvent") or "{}")
            except json.JSONDecodeError:
                LOGGER.warning("Skipping CloudTrail event with invalid JSON: %s", raw_event.get("EventId"))
                continue

            request_parameters = detail.get("requestParameters") or {}
            phone_number_id = request_parameters.get("phoneNumberId")
            phone_number = phone_id_to_number.get(phone_number_id)

            if not phone_number:
                continue

            events.append({
                "event_id": raw_event.get("EventId"),
                "event_name": raw_event.get("EventName"),
                "event_time": isoformat_z(raw_event["EventTime"]),
                "phone_number_id": phone_number_id,
                "phone_number": phone_number,
                "contact_flow_id": request_parameters.get("contactFlowId"),
                "principal_arn": extract_principal_arn(detail, raw_event.get("Username")),
            })

    events.sort(key=lambda item: (item["event_time"], item["event_id"] or ""))
    return events


def latest_events_by_number(events):
    latest_routing = {}
    latest_inventory = {}

    for event in events:
        phone_number = event["phone_number"]
        if event["event_name"] in ROUTING_EVENT_NAMES:
            latest_routing[phone_number] = event
        elif event["event_name"] in INVENTORY_EVENT_NAMES:
            latest_inventory[phone_number] = event

    return latest_routing, latest_inventory


def actual_flow_arn_from_event(expected_flow_arn, contact_flow_id):
    if not expected_flow_arn or not contact_flow_id:
        return None

    if "/contact-flow/" not in expected_flow_arn:
        return None

    prefix = expected_flow_arn.rsplit("/contact-flow/", 1)[0]
    return f"{prefix}/contact-flow/{contact_flow_id}"


def event_drift_for_number(phone_number, expected_route, event):
    if not expected_route or not event:
        return None

    event_name = event["event_name"]
    expected_flow_id = expected_route.get("expected_flow_id")
    expected_flow_arn = expected_route.get("expected_flow_arn")

    if event_name == "DisassociatePhoneNumberContactFlow":
        return {
            "phone_number": phone_number,
            "drift_type": "NO_FLOW",
            "instance_id": extract_instance_id_from_arn(expected_flow_arn),
            "expected_flow_arn": expected_flow_arn,
            "actual_flow_arn": None,
            "source_event_name": event_name,
            "source_event_time": event["event_time"],
            "source_principal_arn": event["principal_arn"],
            "last_source_event_id": event["event_id"],
        }

    if event_name == "AssociatePhoneNumberContactFlow":
        actual_flow_id = event.get("contact_flow_id")
        if actual_flow_id == expected_flow_id:
            return {"status": "HEALTHY", "phone_number": phone_number}

        return {
            "phone_number": phone_number,
            "drift_type": "WRONG_FLOW",
            "instance_id": extract_instance_id_from_arn(expected_flow_arn),
            "expected_flow_arn": expected_flow_arn,
            "actual_flow_arn": actual_flow_arn_from_event(expected_flow_arn, actual_flow_id),
            "source_event_name": event_name,
            "source_event_time": event["event_time"],
            "source_principal_arn": event["principal_arn"],
            "last_source_event_id": event["event_id"],
        }

    return None


def query_open_records():
    records = []
    params = {
        "IndexName": STATUS_GSI_NAME,
        "KeyConditionExpression": Key("status_scope").eq("OPEN"),
    }

    while True:
        response = TABLE.query(**params)
        records.extend(response.get("Items", []))
        last_key = response.get("LastEvaluatedKey")
        if not last_key:
            break
        params["ExclusiveStartKey"] = last_key

    return records


def put_open_record(drift, now_iso):
    current = TABLE.get_item(
        Key={
            "phone_number": drift["phone_number"],
            "drift_type": drift["drift_type"],
        }
    ).get("Item")

    same_source_event = (
        current
        and current.get("record_status") == "OPEN"
        and drift.get("last_source_event_id")
        and current.get("last_source_event_id") == drift.get("last_source_event_id")
    )

    if current and current.get("record_status") == "OPEN":
        first_detected_at = current.get("first_detected_at", now_iso)
        consecutive = int(current.get("consecutive_detections", 0))
        if same_source_event and drift.get("source_event_name") != "INVENTORY_RECONCILIATION":
            consecutive = max(consecutive, 1)
        else:
            consecutive += 1
    else:
        first_detected_at = now_iso
        consecutive = 1

    item = {
        "phone_number": drift["phone_number"],
        "drift_type": drift["drift_type"],
        "instance_id": drift.get("instance_id"),
        "expected_flow_arn": drift.get("expected_flow_arn"),
        "actual_flow_arn": drift.get("actual_flow_arn"),
        "first_detected_at": first_detected_at,
        "last_detected_at": now_iso,
        "consecutive_detections": consecutive,
        "record_status": "OPEN",
        "status_scope": "OPEN",
        "resolved_at": None,
        "resolved_by": None,
        "source_event_name": drift.get("source_event_name"),
        "source_event_time": drift.get("source_event_time"),
        "source_principal_arn": drift.get("source_principal_arn"),
        "last_source_event_id": drift.get("last_source_event_id"),
    }

    TABLE.put_item(Item=item)
    return item


def resolve_record(existing, resolved_at, resolved_by):
    item = dict(existing)
    item["record_status"] = "RESOLVED"
    item["status_scope"] = "RESOLVED"
    item["resolved_at"] = resolved_at
    item["resolved_by"] = resolved_by
    item["ttl_epoch"] = epoch_seconds(utc_now() + timedelta(days=HISTORY_TTL_DAYS))
    TABLE.put_item(Item=item)
    return item


def is_legacy_prototype_record(record):
    source_event_name = record.get("source_event_name")
    last_source_event_id = record.get("last_source_event_id")
    actual_flow_arn = record.get("actual_flow_arn")
    instance_id = record.get("instance_id")

    if source_event_name or last_source_event_id:
        return False

    if not actual_flow_arn or not instance_id:
        return False

    return actual_flow_arn.endswith(f":instance/{instance_id}")


def publish_metrics(counts, success):
    CLOUDWATCH.put_metric_data(
        Namespace=METRIC_NAMESPACE,
        MetricData=[
            {"MetricName": "RoutingDriftCount", "Value": counts["total"], "Unit": "Count"},
            {"MetricName": "WrongFlowDriftCount", "Value": counts["wrong_flow"], "Unit": "Count"},
            {"MetricName": "NoFlowDriftCount", "Value": counts["no_flow"], "Unit": "Count"},
            {"MetricName": "UnexpectedNumberCount", "Value": counts["unexpected_number"], "Unit": "Count"},
            {"MetricName": "DriftDetectionExecutionSuccess", "Value": 1 if success else 0, "Unit": "Count"},
        ],
    )


def summarize_open_counts():
    open_records = query_open_records()
    counts = {
        "total": len(open_records),
        "wrong_flow": 0,
        "no_flow": 0,
        "unexpected_number": 0,
    }

    for record in open_records:
        drift_type = str(record.get("drift_type", "")).upper()
        if drift_type == "WRONG_FLOW":
            counts["wrong_flow"] += 1
        elif drift_type == "NO_FLOW":
            counts["no_flow"] += 1
        elif drift_type == "UNEXPECTED_NUMBER":
            counts["unexpected_number"] += 1

    return counts


def inventory_drifts(managed_inventory, actual_inventory, latest_inventory_events, scope_numbers, now_iso):
    drifts = {}
    managed_numbers = set(managed_inventory)
    unexpected_numbers = (set(actual_inventory) - managed_numbers) & scope_numbers

    for phone_number in sorted(unexpected_numbers):
        inventory_event = latest_inventory_events.get(phone_number)
        drifts[(phone_number, "UNEXPECTED_NUMBER")] = {
            "phone_number": phone_number,
            "drift_type": "UNEXPECTED_NUMBER",
            "instance_id": actual_inventory[phone_number].get("instance_id"),
            "expected_flow_arn": None,
            "actual_flow_arn": None,
            "source_event_name": inventory_event.get("event_name") if inventory_event else "INVENTORY_RECONCILIATION",
            "source_event_time": inventory_event.get("event_time") if inventory_event else now_iso,
            "source_principal_arn": inventory_event.get("principal_arn") if inventory_event else None,
            "last_source_event_id": inventory_event.get("event_id") if inventory_event else None,
        }

    return drifts, unexpected_numbers


def handle_scan(event):
    operation = str((event or {}).get("operation", "SCAN_ALL")).strip().upper()
    state_bucket = MODULE_STATE_RESOLUTION["state_bucket"]

    try:
        phone_numbers_state = load_state_document(state_bucket, MODULE_STATE_RESOLUTION["phone_numbers_state_key"])
        contact_flow_state = load_state_document(state_bucket, MODULE_STATE_RESOLUTION["contact_flow_state_key"])
    except ClientError as exc:
        LOGGER.exception("Unable to read Terraform state objects")
        publish_metrics({"total": 0, "wrong_flow": 0, "no_flow": 0, "unexpected_number": 0}, success=False)
        return {
            "operation": operation,
            "status": "STATE_UNAVAILABLE",
            "error": str(exc),
            "results": [],
        }

    managed_inventory, expected_routes = build_expected_routes(phone_numbers_state, contact_flow_state)

    actual_inventory = {}
    for instance_id in MODULE_STATE_RESOLUTION["connect_instance_ids"]:
        actual_inventory.update(list_connect_numbers(instance_id))

    phone_id_to_number = {}
    for phone_number, route in expected_routes.items():
        if route.get("phone_number_id"):
            phone_id_to_number[route["phone_number_id"]] = phone_number
    for phone_number, item in actual_inventory.items():
        if item.get("phone_number_id"):
            phone_id_to_number[item["phone_number_id"]] = phone_number

    cloudtrail_events = parse_cloudtrail_events(phone_id_to_number)
    latest_routing_events, latest_inventory_events = latest_events_by_number(cloudtrail_events)

    scope_numbers = parse_number_scope(event or {}) if operation == "SCAN_NUMBERS" else (set(managed_inventory) | set(actual_inventory))
    now_iso = isoformat_z(utc_now())

    drifts = {}
    healthy_numbers = set()

    for phone_number in sorted(scope_numbers & set(expected_routes)):
        event_drift = event_drift_for_number(phone_number, expected_routes.get(phone_number), latest_routing_events.get(phone_number))
        if not event_drift:
            continue
        if event_drift.get("status") == "HEALTHY":
            healthy_numbers.add(phone_number)
            continue
        drifts[(phone_number, event_drift["drift_type"])] = event_drift

    inventory_open, unexpected_numbers = inventory_drifts(
        managed_inventory=managed_inventory,
        actual_inventory=actual_inventory,
        latest_inventory_events=latest_inventory_events,
        scope_numbers=scope_numbers,
        now_iso=now_iso,
    )
    drifts.update(inventory_open)

    open_results = [put_open_record(drift, now_iso) for drift in drifts.values()]

    resolved_results = []
    resolved_by = resolved_by_for_event(event or {}, operation)
    for existing in query_open_records():
        phone_number = existing.get("phone_number")
        drift_type = existing.get("drift_type")

        if phone_number not in scope_numbers:
            continue

        if drift_type == "UNEXPECTED_NUMBER":
            if phone_number not in unexpected_numbers:
                resolved_results.append(resolve_record(existing, now_iso, resolved_by))
            continue

        if drift_type in {"WRONG_FLOW", "NO_FLOW"}:
            if is_legacy_prototype_record(existing) and (phone_number, drift_type) not in drifts:
                resolved_results.append(resolve_record(existing, now_iso, "legacy-cleanup"))
                continue
            if phone_number not in expected_routes or phone_number in healthy_numbers:
                resolved_results.append(resolve_record(existing, now_iso, resolved_by))
            continue

    counts = summarize_open_counts()
    publish_metrics(counts, success=True)

    return {
        "operation": operation,
        "status": "OK",
        "drift_count": counts["total"],
        "open_results": [
            {
                "phone_number": item["phone_number"],
                "drift_type": item["drift_type"],
                "instance_id": item.get("instance_id"),
                "expected_flow_arn": item.get("expected_flow_arn"),
                "actual_flow_arn": item.get("actual_flow_arn"),
                "consecutive_detections": item["consecutive_detections"],
                "source_event_name": item.get("source_event_name"),
                "source_event_time": item.get("source_event_time"),
            }
            for item in open_results
        ],
        "resolved_results": [
            {
                "phone_number": item["phone_number"],
                "drift_type": item["drift_type"],
                "resolved_at": item["resolved_at"],
                "resolved_by": item["resolved_by"],
            }
            for item in resolved_results
        ],
    }


def handler(event, _context):
    LOGGER.info("Received event: %s", json.dumps(event))
    operation = str((event or {}).get("operation", "SCAN_ALL")).strip().upper()

    if operation not in VALID_OPERATIONS:
        raise ValueError(f"operation must be one of: {', '.join(sorted(VALID_OPERATIONS))}")

    return handle_scan(event or {})
