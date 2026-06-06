"""Daily holiday check Lambda — PRD-12.

Computes whether today is a US federal holiday or company-specific closure,
then writes the result to the daily-closure-status DynamoDB table.

Triggered by:
  1. EventBridge scheduled rule (daily at midnight local time)
  2. DynamoDB Streams on the company-closures table (immediate recomputation)

The daily-status item is read by Amazon Connect contact flows at call time —
this Lambda is never in the inbound call path.
"""

import datetime
import json
import logging
import os

import boto3
from zoneinfo import ZoneInfo

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
ssm = boto3.client("ssm")
cloudwatch = boto3.client("cloudwatch")


# ---------------------------------------------------------------------------
# US Federal Holiday computation
# ---------------------------------------------------------------------------

def nth_weekday(year: int, month: int, weekday: int, n: int) -> datetime.date:
    """Return the nth occurrence of a weekday in a given month.

    weekday: 0=Monday ... 6=Sunday (matching datetime.date.weekday())
    n: 1-based (1=first, 2=second, ...). Use -1 for last occurrence.
    """
    if n == -1:
        # Last occurrence: start from the last day of the month and go backward
        if month == 12:
            last_day = datetime.date(year, 12, 31)
        else:
            last_day = datetime.date(year, month + 1, 1) - datetime.timedelta(days=1)
        offset = (last_day.weekday() - weekday) % 7
        return last_day - datetime.timedelta(days=offset)

    # First day of the month
    first = datetime.date(year, month, 1)
    # Days until the first occurrence of the target weekday
    offset = (weekday - first.weekday()) % 7
    first_occurrence = first + datetime.timedelta(days=offset)
    return first_occurrence + datetime.timedelta(weeks=n - 1)


def observed_date(holiday: datetime.date) -> datetime.date:
    """Shift fixed-date holidays to the observed weekday.

    Saturday -> preceding Friday, Sunday -> following Monday.
    """
    if holiday.weekday() == 5:  # Saturday
        return holiday - datetime.timedelta(days=1)
    if holiday.weekday() == 6:  # Sunday
        return holiday + datetime.timedelta(days=1)
    return holiday


def get_federal_holidays(year: int) -> dict[datetime.date, str]:
    """Return a dict mapping observed date -> holiday name for the given year."""
    holidays = {}

    # Fixed-date holidays (with observed-date shifting)
    fixed = [
        (datetime.date(year, 1, 1), "New Year's Day"),
        (datetime.date(year, 7, 4), "Independence Day"),
        (datetime.date(year, 11, 11), "Veterans Day"),
        (datetime.date(year, 12, 25), "Christmas Day"),
    ]
    for date, name in fixed:
        holidays[observed_date(date)] = name

    # Nth-weekday holidays
    holidays[nth_weekday(year, 1, 0, 3)] = "Martin Luther King Jr. Day"
    holidays[nth_weekday(year, 2, 0, 3)] = "Presidents' Day"
    holidays[nth_weekday(year, 5, 0, -1)] = "Memorial Day"
    holidays[nth_weekday(year, 9, 0, 1)] = "Labor Day"
    holidays[nth_weekday(year, 10, 0, 2)] = "Columbus Day"
    holidays[nth_weekday(year, 11, 3, 4)] = "Thanksgiving Day"
    # Day after Thanksgiving = 4th Friday in November
    holidays[nth_weekday(year, 11, 4, 4)] = "Day After Thanksgiving"

    return holidays


# ---------------------------------------------------------------------------
# Handler
# ---------------------------------------------------------------------------

def handler(event, context):
    tz_name = os.environ.get("TIME_ZONE", "America/New_York")
    tz = ZoneInfo(tz_name)
    today = datetime.datetime.now(tz).date()
    today_str = today.isoformat()

    logger.info("Holiday check for %s (timezone: %s)", today_str, tz_name)

    # 1. Check US federal holidays
    federal_holidays = get_federal_holidays(today.year)
    if today in federal_holidays:
        result = {
            "is_closure": True,
            "closure_name": federal_holidays[today],
            "closure_source": "federal",
        }
        logger.info("Federal holiday: %s", federal_holidays[today])
    else:
        result = {
            "is_closure": False,
            "closure_name": "",
            "closure_source": "none",
        }

    # 2. Check company-specific closures (overrides "none", does not override "federal")
    if not result["is_closure"]:
        closures_table = dynamodb.Table(os.environ["CLOSURES_TABLE_NAME"])
        try:
            resp = closures_table.get_item(Key={"date": today_str})
            if "Item" in resp:
                item = resp["Item"]
                result = {
                    "is_closure": True,
                    "closure_name": item.get("name", "Company Closure"),
                    "closure_source": "company",
                }
                logger.info("Company closure: %s", result["closure_name"])
        except Exception:
            logger.exception("Error querying company closures table")

    # 3. Check emergency closure SSM parameter and publish staleness metric
    _publish_emergency_closure_metric(tz)

    # 4. Write result to daily-status table
    status_table = dynamodb.Table(os.environ["DAILY_STATUS_TABLE_NAME"])
    status_item = {
        "id": "today",
        "date": today_str,
        "is_closure": result["is_closure"],
        "closure_name": result["closure_name"],
        "closure_source": result["closure_source"],
    }

    try:
        status_table.put_item(Item=status_item)
        logger.info("Wrote daily status: %s", json.dumps(status_item, default=str))
    except Exception:
        logger.exception("Error writing daily status")
        raise

    return status_item


def _publish_emergency_closure_metric(tz):
    """Publish EmergencyClosureActiveHours metric for ALARM-12-03."""
    metric_namespace = os.environ.get("METRIC_NAMESPACE", "")
    ssm_param_name = os.environ.get("EMERGENCY_CLOSURE_SSM_PARAM", "")
    environment = os.environ.get("ENVIRONMENT", "unknown")

    if not metric_namespace or not ssm_param_name:
        return

    try:
        resp = ssm.get_parameter(Name=ssm_param_name, WithDecryption=True)
        value = json.loads(resp["Parameter"]["Value"])
        active = value.get("active", False)

        if not active:
            hours = 0.0
        else:
            updated_at = value.get("updated_at", "")
            if updated_at:
                activated = datetime.datetime.fromisoformat(updated_at)
                now = datetime.datetime.now(tz)
                hours = max(0.0, (now - activated).total_seconds() / 3600)
            else:
                hours = 999.0

        cloudwatch.put_metric_data(
            Namespace=metric_namespace,
            MetricData=[{
                "MetricName": "EmergencyClosureActiveHours",
                "Value": hours,
                "Unit": "Count",
                "Dimensions": [{"Name": "Environment", "Value": environment}],
            }],
        )
        logger.info("Published EmergencyClosureActiveHours=%.1f", hours)
    except Exception:
        logger.exception("Failed to publish emergency closure metric")
