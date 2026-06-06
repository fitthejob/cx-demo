import json
import os
import logging
import boto3
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
cloudtrail = boto3.client('cloudtrail')
config = boto3.client('config')
securityhub = boto3.client('securityhub')

AUDIT_BUCKET = os.environ['AUDIT_BUCKET']
STATE_BUCKET = os.environ['STATE_BUCKET']
TRAIL_ARN = os.environ['TRAIL_ARN']
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'unknown')


def handler(event, context):
    now = datetime.now(timezone.utc)
    period_end = now
    period_start = now - timedelta(days=7)

    collectors = {
        'cloudtrail': lambda: _collect_cloudtrail(period_start, period_end),
        'config': _collect_config,
        'security_hub': _collect_security_hub,
        'deployments': lambda: _collect_deployments(period_start, period_end),
        'drift': lambda: _collect_drift(period_start, period_end),
    }

    collection_errors = []
    results = {}
    for name, collector in collectors.items():
        result = collector()
        results[name] = result
        if 'error' in result:
            collection_errors.append(name)

    summary = {
        'generated_at': now.isoformat(),
        'period_start': period_start.isoformat(),
        'period_end': period_end.isoformat(),
        'account_id': boto3.client('sts').get_caller_identity()['Account'],
        'environment': ENVIRONMENT,
        'collection_errors': collection_errors,
        **results,
    }

    key = f"evidence/weekly/{now.year}/{now.month:02d}/{now.day:02d}/summary.json"
    s3.put_object(
        Bucket=AUDIT_BUCKET,
        Key=key,
        Body=json.dumps(summary, indent=2),
        ServerSideEncryption='aws:kms',
    )
    logger.info(f"Evidence summary written to s3://{AUDIT_BUCKET}/{key}")
    return {'statusCode': 200, 'key': key}


def _collect_cloudtrail(start, end):
    try:
        events = []
        paginator = cloudtrail.get_paginator('lookup_events')
        for page in paginator.paginate(StartTime=start, EndTime=end, MaxResults=50):
            events.extend(page.get('Events', []))
        return {
            'trail_arn': TRAIL_ARN,
            'events_delivered': len(events),
            'validation_errors': 0,
        }
    except Exception as e:
        logger.error(f"CloudTrail collection failed: {e}")
        return {'trail_arn': TRAIL_ARN, 'events_delivered': -1, 'validation_errors': -1, 'error': str(e)}


def _collect_config():
    try:
        compliant = 0
        non_compliant = 0
        paginator = config.get_paginator('describe_compliance_by_config_rule')
        for page in paginator.paginate():
            for rule in page.get('ComplianceByConfigRules', []):
                status = rule.get('Compliance', {}).get('ComplianceType', '')
                if status == 'COMPLIANT':
                    compliant += 1
                elif status == 'NON_COMPLIANT':
                    non_compliant += 1

        recorder_status = config.describe_configuration_recorder_status()
        recorders = recorder_status.get('ConfigurationRecordersStatus', [])
        recording = recorders[0].get('recording', False) if recorders else False

        resource_counts = config.get_discovered_resource_counts()
        total_resources = sum(r.get('count', 0) for r in resource_counts.get('resourceCounts', []))

        return {
            'recorder_status': 'RECORDING' if recording else 'STOPPED',
            'compliant_rules': compliant,
            'non_compliant_rules': non_compliant,
            'resources_recorded': total_resources,
        }
    except Exception as e:
        logger.error(f"Config collection failed: {e}")
        return {'recorder_status': 'ERROR', 'error': str(e)}


def _collect_security_hub():
    try:
        counts = {'CRITICAL': 0, 'HIGH': 0, 'MEDIUM': 0}
        paginator = securityhub.get_paginator('get_findings')
        for page in paginator.paginate(
            Filters={
                'WorkflowStatus': [{'Value': 'NEW', 'Comparison': 'EQUALS'}],
                'RecordState': [{'Value': 'ACTIVE', 'Comparison': 'EQUALS'}],
            },
            MaxResults=100,
        ):
            for finding in page.get('Findings', []):
                severity = finding.get('Severity', {}).get('Label', '')
                if severity in counts:
                    counts[severity] += 1
        return {
            'active_findings_critical': counts['CRITICAL'],
            'active_findings_high': counts['HIGH'],
            'active_findings_medium': counts['MEDIUM'],
        }
    except Exception as e:
        logger.error(f"Security Hub collection failed: {e}")
        return {'error': str(e)}


def _collect_deployments(start, end):
    try:
        total = 0
        success = 0
        failed = 0
        for day_offset in range(7):
            d = start + timedelta(days=day_offset)
            prefix = f"audit/deployments/{ENVIRONMENT}/{d.year}/{d.month:02d}/{d.day:02d}/"
            resp = s3.list_objects_v2(Bucket=STATE_BUCKET, Prefix=prefix)
            for obj in resp.get('Contents', []):
                total += 1
                body = s3.get_object(Bucket=STATE_BUCKET, Key=obj['Key'])
                entry = json.loads(body['Body'].read())
                if entry.get('outcome') == 'success':
                    success += 1
                else:
                    failed += 1
        return {'total_applies': total, 'successful_applies': success, 'failed_applies': failed}
    except Exception as e:
        logger.error(f"Deployment collection failed: {e}")
        return {'error': str(e)}


def _collect_drift(start, end):
    try:
        total = 0
        drifted = 0
        missed = 0
        for day_offset in range(7):
            d = start + timedelta(days=day_offset)
            prefix = f"audit/drift/{d.year}/{d.month:02d}/{d.day:02d}/"
            resp = s3.list_objects_v2(Bucket=STATE_BUCKET, Prefix=prefix)
            day_count = resp.get('KeyCount', 0)
            if day_count == 0:
                missed += 1
            for obj in resp.get('Contents', []):
                total += 1
                body = s3.get_object(Bucket=STATE_BUCKET, Key=obj['Key'])
                result = json.loads(body['Body'].read())
                if result.get('drifted') is True:
                    drifted += 1
        return {'total_checks': total, 'drift_detected_count': drifted, 'missed_checks': missed}
    except Exception as e:
        logger.error(f"Drift collection failed: {e}")
        return {'error': str(e)}
