import json
import os
import boto3
from datetime import datetime, timezone

sns = boto3.client('sns')
s3 = boto3.client('s3')
ALERT_TOPIC_ARN = os.environ['ALERT_TOPIC_ARN']
STATE_BUCKET = os.environ['STATE_BUCKET']

def handler(event, context):
    today = datetime.now(timezone.utc)
    prefix = f"audit/drift/{today.year}/{today.month:02d}/{today.day:02d}/"

    response = s3.list_objects_v2(Bucket=STATE_BUCKET, Prefix=prefix)
    if response.get('KeyCount', 0) == 0:
        sns.publish(
            TopicArn=ALERT_TOPIC_ARN,
            Subject="ALERT: Nightly drift detection did not run",
            Message=json.dumps({
                'alarm': 'ALARM-01-03',
                'date': today.strftime('%Y-%m-%d'),
                'expected_prefix': prefix,
                'message': 'No drift detection results found for today. The nightly workflow may have failed.'
            }, indent=2)
        )
