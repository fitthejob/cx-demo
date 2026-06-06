"""Closure status check Lambda — PRD-14.

Invoked per-call by the main inbound contact flow. Checks:
  1. Emergency closure (SSM parameter from PRD-12)
  2. Daily closure status (DynamoDB table from PRD-12)

Returns contact attributes readable by the flow via $.External.<key>.
Both checks are fail-open: on any error, returns is_closure=false.
"""

import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm")
dynamodb = boto3.resource("dynamodb")


def handler(event, context):
    emergency_param = os.environ["EMERGENCY_CLOSURE_PARAM_NAME"]
    status_table_name = os.environ["DAILY_STATUS_TABLE_NAME"]

    # 1. Check emergency closure (takes priority)
    try:
        resp = ssm.get_parameter(Name=emergency_param, WithDecryption=True)
        emergency = json.loads(resp["Parameter"]["Value"])
        if emergency.get("active") is True:
            logger.info("Emergency closure active: %s", emergency.get("message", ""))
            return {
                "is_closure": "true",
                "closure_name": emergency.get("message", "Emergency Closure"),
                "closure_source": "emergency",
            }
    except Exception:
        logger.exception("Error reading emergency closure parameter — fail-open")

    # 2. Check daily closure status (pre-computed by PRD-12 Lambda)
    try:
        table = dynamodb.Table(status_table_name)
        resp = table.get_item(Key={"id": "today"})
        if "Item" in resp:
            item = resp["Item"]
            if item.get("is_closure") is True or str(item.get("is_closure")).lower() == "true":
                logger.info("Daily closure: %s (%s)", item.get("closure_name", ""), item.get("closure_source", ""))
                return {
                    "is_closure": "true",
                    "closure_name": item.get("closure_name", "Closure"),
                    "closure_source": str(item.get("closure_source", "daily")),
                }
    except Exception:
        logger.exception("Error reading daily closure status — fail-open")

    # 3. No closure
    return {
        "is_closure": "false",
        "closure_name": "",
        "closure_source": "none",
    }
