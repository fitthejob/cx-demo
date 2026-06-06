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
        entry = json.loads(obj['Body'].read())

        if entry.get('outcome') == 'failure':
            sns.publish(
                TopicArn=ALERT_TOPIC_ARN,
                Subject=f"APPLY FAILURE: {entry.get('module_path')} in prod",
                Message=json.dumps({
                    'alarm': 'ALARM-01-01',
                    'environment': entry.get('environment'),
                    'module_path': entry.get('module_path'),
                    'github_run_id': entry.get('github_run_id'),
                    'github_actor': entry.get('github_actor'),
                    'workflow_run_url': entry.get('workflow_run_url'),
                    'timestamp': entry.get('timestamp')
                }, indent=2),
            )
            logger.info("Published apply-failure alert for run %s", entry.get('github_run_id'))

        _processed_keys.add(key)
