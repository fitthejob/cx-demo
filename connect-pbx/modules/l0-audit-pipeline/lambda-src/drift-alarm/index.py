import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client('sns')
s3 = boto3.client('s3')
ALERT_TOPIC_ARN = os.environ['ALERT_TOPIC_ARN']

_processed_keys = set()


def handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']

        if key in _processed_keys:
            logger.info("Skipping duplicate S3 event for key: %s", key)
            continue

        obj = s3.get_object(Bucket=bucket, Key=key)
        result = json.loads(obj['Body'].read())

        if result.get('drifted') is True:
            sns.publish(
                TopicArn=ALERT_TOPIC_ARN,
                Subject=f"DRIFT DETECTED: {result.get('module')} in {result.get('environment', 'unknown')}",
                Message=json.dumps({
                    'alarm': 'ALARM-01-02',
                    'module': result.get('module'),
                    'environment': result.get('environment'),
                    'timestamp': result.get('timestamp'),
                    'exit_code': result.get('exit_code')
                }, indent=2),
            )
            logger.info("Published drift alert for module %s", result.get('module'))

        _processed_keys.add(key)
