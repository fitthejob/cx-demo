import json
import os

import boto3

from common import emit_metric, env_bool


SNS = boto3.client("sns")


def handler(event, _context):
    payload = event or {}
    operation = payload.get("operation", "SEND_NOTIFICATION")
    if operation not in {"SEND_NOTIFICATION", "SELF_TEST_NOTIFICATION"}:
        raise ValueError(f"Unsupported operation: {operation}")

    message = {
        "operation": operation,
        "request_id": payload.get("request_id"),
        "operator_identity": payload.get("operator_identity"),
        "agent_id": payload.get("agent_id"),
        "agent_name": payload.get("agent_name"),
        "registered_location": payload.get("registered_location"),
        "timestamp": payload.get("timestamp"),
        "connect_instance_id": payload.get("connect_instance_id"),
        "source_of_notification_evidence": payload.get("source_of_notification_evidence"),
        "workspace": os.environ.get("TF_WORKSPACE"),
    }

    if os.environ.get("NOTIFICATION_DELIVERY_MODE", "mock") == "mock":
        emit_metric("EmergencyNotificationMock", 1)
        return {
            "operation": operation,
            "delivery_mode": "mock",
            "published": False,
            "reason": "mock-delivery-mode",
            "message": message,
        }

    if not env_bool("ALLOW_LIVE_EXTERNAL_NOTIFICATIONS"):
        raise RuntimeError("Live external notifications are disabled by ALLOW_LIVE_EXTERNAL_NOTIFICATIONS.")

    SNS.publish(
        TopicArn=os.environ["SECURITY_ALERTS_TOPIC_ARN"],
        Subject=f"E911 {operation}",
        Message=json.dumps(message),
    )
    emit_metric("EmergencyNotificationSuccess", 1)
    return {
        "operation": operation,
        "delivery_mode": "live",
        "published": True,
        "topic_arn": os.environ["SECURITY_ALERTS_TOPIC_ARN"],
    }
