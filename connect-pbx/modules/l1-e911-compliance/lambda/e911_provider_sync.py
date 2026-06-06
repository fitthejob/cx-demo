import os

from boto3.dynamodb.conditions import Key

from common import emit_metric, env_bool, iso_now, load_json_secret, load_phone_number_inventory, mock_elin, require_fields, table_from_env


def get_item(agent_id):
    return table_from_env().get_item(Key={"agent_id": agent_id}).get("Item")


def query_status(status):
    response = table_from_env().query(
        IndexName=os.environ["SYNC_STATUS_GSI_NAME"],
        KeyConditionExpression=Key("sync_status_scope").eq(status),
    )
    return response.get("Items", [])


def all_items():
    items = []
    start_key = None
    while True:
        kwargs = {}
        if start_key:
            kwargs["ExclusiveStartKey"] = start_key
        response = table_from_env().scan(**kwargs)
        items.extend(response.get("Items", []))
        start_key = response.get("LastEvaluatedKey")
        if not start_key:
            return items


def live_provider_hook(record, provider_secret):
    if not env_bool("ALLOW_LIVE_PROVIDER_SYNC"):
        raise RuntimeError("Live provider synchronization is disabled by ALLOW_LIVE_PROVIDER_SYNC.")
    raise RuntimeError(
        "Live E911 provider synchronization hook is intentionally not implemented in the safe dev profile. "
        f"Provider={os.environ['E911_PROVIDER']} secret_keys={sorted(provider_secret.keys())}"
    )


def resolve_inventory_elin():
    inventory = load_phone_number_inventory()
    available = [
        value["phone_number"]
        for value in inventory.values()
        if value.get("purpose") == "e911-elin"
    ]
    if not available:
        raise RuntimeError("No phone numbers with purpose=e911-elin are available in PRD-11 inventory.")

    assigned = {item.get("elin") for item in all_items() if item.get("elin")}
    for number in available:
        if number not in assigned:
            return number
    raise RuntimeError("No unassigned ELIN numbers remain in PRD-11 inventory.")


def ensure_elin(record):
    if record.get("location_type") != "REMOTE" or record.get("elin"):
        return record.get("elin")
    if os.environ.get("ELIN_ASSIGNMENT_MODE", "mock") == "inventory":
        return resolve_inventory_elin()
    return mock_elin(record.get("agent_id"), record.get("phone_number"))


def sync_one(record, request_id, operator_identity):
    if record.get("location_type") == "REMOTE" and not record.get("address_verified"):
        return {
            "agent_id": record["agent_id"],
            "status": "SKIPPED",
            "reason": "remote-address-not-verified",
        }

    if record.get("last_operation") in {"SYNC_PENDING", "SYNC_AGENT", "SYNC_FAILED"} and record.get("last_request_id") == request_id:
        return {
            "agent_id": record["agent_id"],
            "status": record.get("provider_sync_status"),
            "idempotent": True,
        }

    provider_mode = os.environ.get("E911_PROVIDER_MODE", "mock")
    updated = {**record}
    updated["elin"] = ensure_elin(record)
    updated["updated_at"] = iso_now()
    updated["updated_by"] = operator_identity
    updated["last_request_id"] = request_id

    if provider_mode == "mock":
        updated["provider_sync_status"] = "SYNCED"
        updated["sync_status_scope"] = "SYNCED"
        updated["provider_sync_date"] = iso_now()
        updated["provider_sync_message"] = "mock-provider-sync"
        updated["provider_request_id"] = f"mock-sync-{record['agent_id']}"
        updated["last_operation"] = "SYNC_AGENT"
        table_from_env().put_item(Item=updated)
        return {
            "agent_id": record["agent_id"],
            "status": "SYNCED",
            "provider_mode": "mock",
            "elin": updated.get("elin"),
        }

    provider_secret = load_json_secret(os.environ.get("E911_PROVIDER_SECRET_ARN", ""))
    try:
        live_provider_hook(updated, provider_secret)
    except Exception as exc:
        updated["provider_sync_status"] = "FAILED"
        updated["sync_status_scope"] = "FAILED"
        updated["provider_failure_detail"] = str(exc)
        updated["last_operation"] = "SYNC_AGENT"
        table_from_env().put_item(Item=updated)
        emit_metric("E911ProviderSyncFailure", 1)
        return {
            "agent_id": record["agent_id"],
            "status": "FAILED",
            "provider_mode": "live",
            "error": str(exc),
        }


def handle_sync_agent(payload):
    require_fields(payload, ["agent_id", "request_id", "operator_identity"])
    record = get_item(payload["agent_id"])
    if record is None:
        raise ValueError(f"No location record found for {payload['agent_id']}")
    result = sync_one(record, payload["request_id"], payload["operator_identity"])
    if result.get("status") == "SYNCED":
        emit_metric("E911ProviderSyncSuccess", 1)
    return {"operation": "SYNC_AGENT", "results": [result]}


def handle_batch(operation, payload, statuses):
    require_fields(payload, ["request_id", "operator_identity"])
    records = []
    for status in statuses:
        records.extend(query_status(status))
    deduped = {record["agent_id"]: record for record in records}.values()

    results = [sync_one(record, payload["request_id"], payload["operator_identity"]) for record in deduped]
    success_count = sum(1 for result in results if result.get("status") == "SYNCED")
    failure_count = sum(1 for result in results if result.get("status") == "FAILED")
    if success_count:
        emit_metric("E911ProviderSyncSuccess", success_count)
    if failure_count:
        emit_metric("E911ProviderSyncFailure", failure_count)
    return {"operation": operation, "results": results}


def handler(event, _context):
    payload = event or {}
    operation = payload.get("operation")
    if operation == "SYNC_AGENT":
        return handle_sync_agent(payload)
    if operation == "SYNC_PENDING":
        return handle_batch("SYNC_PENDING", payload, ["PENDING"])
    if operation == "SYNC_FAILED":
        return handle_batch("SYNC_FAILED", payload, ["FAILED"])
    raise ValueError(f"Unsupported operation: {operation}")
