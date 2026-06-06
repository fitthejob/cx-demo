import json
import os

import boto3

from common import confirmation_token, emit_metric, env_bool, iso_now, normalize_item, require_fields, table_from_env, today_iso


SES = boto3.client("ses")


def get_item(agent_id):
    return table_from_env().get_item(Key={"agent_id": agent_id}).get("Item")


def is_idempotent(existing_item, operation, request_id):
    return (
        existing_item is not None
        and existing_item.get("last_operation") == operation
        and existing_item.get("last_request_id") == request_id
    )


def send_registration_email(agent_email, agent_id, request_id, token):
    mode = os.environ.get("REGISTRATION_EMAIL_DELIVERY_MODE", "mock")
    if mode == "mock":
        return {
            "email_delivery_mode": "mock",
            "email_sent": False,
            "confirmation_token": token,
            "preview_target": agent_email,
            "preview_url": f"https://mock.invalid/e911/confirm?agent_id={agent_id}&token={token}",
        }

    if not env_bool("ALLOW_LIVE_EXTERNAL_NOTIFICATIONS"):
        raise RuntimeError("Live registration email delivery is disabled by ALLOW_LIVE_EXTERNAL_NOTIFICATIONS.")

    template_name = os.environ.get("SES_TEMPLATE_NAME", "")
    confirmation_url = f"https://connect.internal/e911/confirm?agent_id={agent_id}&token={token}"
    deadline_date = "30 days from registration"

    if template_name:
        SES.send_templated_email(
            Source=os.environ["REMOTE_REGISTRATION_SENDER_EMAIL"],
            Destination={"ToAddresses": [agent_email]},
            Template=template_name,
            TemplateData=json.dumps({
                "employee_name": agent_id,
                "confirmation_url": confirmation_url,
                "deadline_date": deadline_date,
            }),
        )
    else:
        SES.send_email(
            Source=os.environ["REMOTE_REGISTRATION_SENDER_EMAIL"],
            Destination={"ToAddresses": [agent_email]},
            Message={
                "Subject": {"Data": "Action Required: Confirm Your E911 Dispatchable Location"},
                "Body": {
                    "Text": {
                        "Data": (
                            f"Hello,\n\n"
                            f"Please confirm your dispatchable location for E911 compliance.\n\n"
                            f"Confirmation link: {confirmation_url}\n\n"
                            f"Deadline: {deadline_date}\n\n"
                            f"If you have questions, contact your administrator."
                        )
                    }
                },
            },
        )
    return {
        "email_delivery_mode": "live",
        "email_sent": True,
        "confirmation_token": token,
        "preview_target": agent_email,
    }


def handle_upsert_office_location(payload):
    location_id = payload.get("location_id")
    agent_id = payload.get("agent_id") or (f"OFFICE_{location_id}" if location_id else None)
    require_fields(payload | {"agent_id": agent_id}, ["agent_id", "street_address", "city", "state", "zip", "floor", "phone_number", "request_id", "operator_identity"])

    existing = get_item(agent_id)
    if is_idempotent(existing, "UPSERT_OFFICE_LOCATION", payload["request_id"]):
        return {
            "operation": "UPSERT_OFFICE_LOCATION",
            "agent_id": agent_id,
            "idempotent": True,
            "item": normalize_item(existing),
        }

    item = {
        "agent_id": agent_id,
        "location_type": "OFFICE",
        "street_address": payload["street_address"],
        "city": payload["city"],
        "state": payload["state"],
        "zip": payload["zip"],
        "building": payload.get("building"),
        "floor": payload["floor"],
        "room": payload.get("room"),
        "phone_number": payload["phone_number"],
        "address_verified": True,
        "last_verified_date": today_iso(),
        "provider_sync_status": "PENDING",
        "sync_status_scope": "PENDING",
        "updated_at": payload.get("confirmed_at") or iso_now(),
        "updated_by": payload["operator_identity"],
        "last_request_id": payload["request_id"],
        "last_operation": "UPSERT_OFFICE_LOCATION",
    }
    table_from_env().put_item(Item=item)
    emit_metric("E911OfficeLocationUpsert", 1)
    return {
        "operation": "UPSERT_OFFICE_LOCATION",
        "agent_id": agent_id,
        "idempotent": False,
        "provider_sync_status": "PENDING",
    }


def handle_start_remote_registration(payload):
    require_fields(payload, ["agent_id", "phone_number", "agent_email", "request_id", "operator_identity"])
    existing = get_item(payload["agent_id"])
    if is_idempotent(existing, "START_REMOTE_REGISTRATION", payload["request_id"]):
        return {
            "operation": "START_REMOTE_REGISTRATION",
            "agent_id": payload["agent_id"],
            "idempotent": True,
            "item": normalize_item(existing),
        }

    token = confirmation_token(payload["agent_id"], payload["request_id"])
    email_result = send_registration_email(
        payload["agent_email"],
        payload["agent_id"],
        payload["request_id"],
        token,
    )

    item = {
        "agent_id": payload["agent_id"],
        "location_type": "REMOTE",
        "phone_number": payload["phone_number"],
        "agent_email": payload["agent_email"],
        "address_verified": False,
        "provider_sync_status": "NOT_SUBMITTED",
        "sync_status_scope": "NOT_SUBMITTED",
        "confirmation_token": token,
        "updated_at": iso_now(),
        "updated_by": payload["operator_identity"],
        "last_request_id": payload["request_id"],
        "last_operation": "START_REMOTE_REGISTRATION",
    }
    table_from_env().put_item(Item=item)
    emit_metric("E911RemoteRegistrationStarted", 1)
    return {
        "operation": "START_REMOTE_REGISTRATION",
        "agent_id": payload["agent_id"],
        "idempotent": False,
        **email_result,
    }


def handle_record_remote_confirmation(payload):
    require_fields(payload, ["agent_id", "street_address", "city", "state", "zip", "floor", "phone_number", "request_id", "operator_identity"])
    existing = get_item(payload["agent_id"])
    if existing is None:
        raise ValueError(f"No remote registration record found for {payload['agent_id']}")
    if is_idempotent(existing, "RECORD_REMOTE_CONFIRMATION", payload["request_id"]):
        return {
            "operation": "RECORD_REMOTE_CONFIRMATION",
            "agent_id": payload["agent_id"],
            "idempotent": True,
            "item": normalize_item(existing),
        }

    supplied_token = payload.get("confirmation_token")
    stored_token = existing.get("confirmation_token")
    if supplied_token and stored_token and supplied_token != stored_token:
        raise ValueError("confirmation_token does not match the pending registration record.")

    item = {
        **existing,
        "location_type": "REMOTE",
        "street_address": payload["street_address"],
        "city": payload["city"],
        "state": payload["state"],
        "zip": payload["zip"],
        "building": payload.get("building"),
        "floor": payload["floor"],
        "room": payload.get("room"),
        "phone_number": payload["phone_number"],
        "address_verified": True,
        "last_verified_date": today_iso(),
        "provider_sync_status": "PENDING",
        "sync_status_scope": "PENDING",
        "updated_at": payload.get("confirmed_at") or iso_now(),
        "updated_by": payload["operator_identity"],
        "last_request_id": payload["request_id"],
        "last_operation": "RECORD_REMOTE_CONFIRMATION",
    }
    table_from_env().put_item(Item=item)
    emit_metric("E911RemoteConfirmationRecorded", 1)
    return {
        "operation": "RECORD_REMOTE_CONFIRMATION",
        "agent_id": payload["agent_id"],
        "idempotent": False,
        "provider_sync_status": "PENDING",
    }


def handle_mark_location_reverified(payload):
    require_fields(payload, ["agent_id", "request_id", "operator_identity"])
    existing = get_item(payload["agent_id"])
    if existing is None:
        raise ValueError(f"No location record found for {payload['agent_id']}")
    if is_idempotent(existing, "MARK_LOCATION_REVERIFIED", payload["request_id"]):
        return {
            "operation": "MARK_LOCATION_REVERIFIED",
            "agent_id": payload["agent_id"],
            "idempotent": True,
            "item": normalize_item(existing),
        }

    item = {
        **existing,
        "address_verified": True,
        "last_verified_date": today_iso(),
        "updated_at": iso_now(),
        "updated_by": payload["operator_identity"],
        "last_request_id": payload["request_id"],
        "last_operation": "MARK_LOCATION_REVERIFIED",
    }
    table_from_env().put_item(Item=item)
    emit_metric("E911LocationReverified", 1)
    return {
        "operation": "MARK_LOCATION_REVERIFIED",
        "agent_id": payload["agent_id"],
        "idempotent": False,
    }


def handler(event, _context):
    payload = event or {}
    operation = payload.get("operation")
    if operation == "UPSERT_OFFICE_LOCATION":
        return handle_upsert_office_location(payload)
    if operation == "START_REMOTE_REGISTRATION":
        return handle_start_remote_registration(payload)
    if operation == "RECORD_REMOTE_CONFIRMATION":
        return handle_record_remote_confirmation(payload)
    if operation == "MARK_LOCATION_REVERIFIED":
        return handle_mark_location_reverified(payload)
    raise ValueError(f"Unsupported operation: {operation}")
