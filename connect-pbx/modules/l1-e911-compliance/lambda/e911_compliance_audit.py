import json
import os

import boto3

from common import emit_metric, is_stale, iso_now, table_from_env


CONNECT = boto3.client("connect")
S3 = boto3.client("s3")


def list_connect_users(instance_id):
    users = []
    token = None
    while True:
        kwargs = {"InstanceId": instance_id, "MaxResults": 100}
        if token:
            kwargs["NextToken"] = token
        response = CONNECT.list_users(**kwargs)
        users.extend(response.get("UserSummaryList", []))
        token = response.get("NextToken")
        if not token:
            return users


def get_record(agent_id):
    return table_from_env().get_item(Key={"agent_id": agent_id}).get("Item")


def write_artifact(payload):
    bucket_name = os.environ.get("COMPLIANCE_ARTIFACT_BUCKET", "").strip()
    if not bucket_name:
        return None
    artifact_key = f"e911/compliance/{iso_now().replace(':', '-')}.json"
    S3.put_object(
        Bucket=bucket_name,
        Key=artifact_key,
        Body=json.dumps(payload, indent=2).encode("utf-8"),
        ContentType="application/json",
        ServerSideEncryption="aws:kms",
    )
    return artifact_key


def handler(event, _context):
    instance_id = os.environ["CONNECT_INSTANCE_ID"]
    verification_interval_days = int(os.environ["LOCATION_VERIFICATION_INTERVAL_DAYS"])
    users = list_connect_users(instance_id)

    without_record = []
    expired = []
    awaiting_confirmation = []

    for user in users:
        agent_id = user["Id"]
        record = get_record(agent_id)
        if record is None:
            without_record.append({"agent_id": agent_id, "username": user.get("Username")})
            continue

        if record.get("location_type") == "REMOTE" and not record.get("address_verified", False):
            awaiting_confirmation.append({
                "agent_id": agent_id,
                "username": user.get("Username"),
                "provider_sync_status": record.get("provider_sync_status"),
            })

        if is_stale(record.get("last_verified_date"), verification_interval_days):
            expired.append({
                "agent_id": agent_id,
                "username": user.get("Username"),
                "last_verified_date": record.get("last_verified_date"),
            })

    emit_metric("AgentsWithNoE911Record", len(without_record))
    emit_metric("AgentsWithExpiredE911Record", len(expired))
    emit_metric("AgentsAwaitingRemoteConfirmation", len(awaiting_confirmation))

    response = {
        "operation": "COMPLIANCE_AUDIT",
        "audited_at": iso_now(),
        "instance_id": instance_id,
        "agent_count": len(users),
        "agents_without_record": without_record,
        "agents_with_expired_record": expired,
        "agents_awaiting_remote_confirmation": awaiting_confirmation,
    }
    artifact_key = write_artifact(response)
    if artifact_key:
        response["compliance_artifact_key"] = artifact_key
    return response
