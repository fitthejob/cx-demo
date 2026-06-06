"""Phone number to contact flow association Lambda — PRD-14.

Invoked by terraform_data local-exec to associate or disassociate
a phone number with a contact flow via the Connect API.

Input payload:
  {
    "phone_number_id": "...",
    "contact_flow_id": "...",
    "action": "associate" | "disassociate"
  }
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

connect = boto3.client("connect")


def handler(event, context):
    instance_id = os.environ["CONNECT_INSTANCE_ID"]
    phone_number_id = event["phone_number_id"]
    contact_flow_id = event.get("contact_flow_id", "")
    action = event.get("action", "associate")

    logger.info(
        "Phone association: action=%s phone=%s flow=%s instance=%s",
        action, phone_number_id, contact_flow_id, instance_id,
    )

    if action == "disassociate":
        connect.disassociate_phone_number_contact_flow(
            PhoneNumberId=phone_number_id,
            InstanceId=instance_id,
        )
        logger.info("Disassociated phone number %s", phone_number_id)
        return {"status": "disassociated", "phone_number_id": phone_number_id}

    connect.associate_phone_number_contact_flow(
        PhoneNumberId=phone_number_id,
        InstanceId=instance_id,
        ContactFlowId=contact_flow_id,
    )
    logger.info("Associated phone %s with flow %s", phone_number_id, contact_flow_id)
    return {
        "status": "associated",
        "phone_number_id": phone_number_id,
        "contact_flow_id": contact_flow_id,
    }
