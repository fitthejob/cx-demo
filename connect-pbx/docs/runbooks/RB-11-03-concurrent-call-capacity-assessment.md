# RB-11-03 — Concurrent Call Capacity Assessment

**Runbook ID:** RB-11-03
**Module:** l1-connect-instance (PRD-10), l1-phone-numbers (PRD-11)
**Audience:** Platform Engineer, Migration Lead
**Last Updated:** 2026-03-22

---

## Overview

Amazon Connect has a default service quota of 10 concurrent active calls per instance. This limit must be raised via an AWS Service Quotas request before go-live for any client with real call volume. Raising the quota requires submitting a justified request — AWS will ask for expected peak concurrent calls, number of agents, and supporting evidence from the current system.

This runbook covers how to pull peak concurrent call metrics from the most common legacy systems, how to interpret them, and how to package the data for the AWS quota increase request.

---

## What AWS Asks For

When you submit a quota increase request, AWS Support will ask:

| Question | What to Provide |
|---|---|
| Requested concurrent call limit | Your calculated peak + headroom (see Section 6) |
| Current peak concurrent calls | From legacy system metrics (Sections 1–5) |
| Number of agents | Total agent seats, including part-time |
| Business description | What the contact center does, inbound vs. outbound mix |
| Expected growth | 6–12 month projection if available |
| Go-live date | When you need the quota active |

Gather all of this before submitting. Incomplete requests slow the process.

---

## Section 1 — RingCentral

### 1.1 — Analytics Portal (preferred)

RingCentral's Analytics Portal provides historical call volume reports that include concurrent call peaks.

1. Log in to the RingCentral Admin Portal (`https://service.ringcentral.com`)
2. Navigate to **Analytics → Reports → Performance Reports**
3. Select report type: **Queue Performance** or **Company Numbers**
4. Set the date range: pull **90 days minimum**, ideally 6 months
5. Set the time interval to **15-minute buckets**
6. Export to CSV

Key columns to extract:
- **Max Concurrent Calls** — peak simultaneous calls in each 15-minute bucket
- **Total Calls Offered** — inbound volume
- **Avg Handle Time** — needed for Erlang-C modeling if concurrent metrics are unavailable

### 1.2 — RingCentral API (if portal access is unavailable)

```bash
# RingCentral REST API — requires OAuth token
# Replace CLIENT_ID, CLIENT_SECRET, ACCOUNT_ID, JWT with actual values

# Get OAuth token
TOKEN=$(curl -s -X POST "https://platform.ringcentral.com/restapi/oauth/token" \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${JWT}" \
  | jq -r '.access_token')

# Pull call log for last 90 days
curl -s -X GET \
  "https://platform.ringcentral.com/restapi/v1.0/account/~/call-log?dateFrom=$(date -d '90 days ago' +%Y-%m-%dT%H:%M:%SZ)&perPage=1000&view=Detailed" \
  -H "Authorization: Bearer ${TOKEN}" \
  | jq '.records[] | {startTime: .startTime, duration: .duration, direction: .direction}' \
  > ringcentral-call-log.json
```

Once you have the raw call log, use the concurrent call calculation script in Section 6.

### 1.3 — What to look for

Pull the busiest weeks of the year — avoid holiday periods unless the business is seasonal (e.g., retail during December). Look for:
- The single highest concurrent call count observed
- The time of day and day of week it occurred
- Whether it was an anomaly or repeatable

---

## Section 2 — 8x8

### 2.1 — 8x8 Analytics (X Series / Contact Center)

1. Log in to 8x8 Admin Console (`https://admin.8x8.com`)
2. Navigate to **Analytics → Historical Reports**
3. Select **Queue Activity Report** or **Agent Activity Report**
4. Set date range: 90 days minimum
5. Export to CSV or Excel

For 8x8 Contact Center (X6/X7/X8):
1. Navigate to **Contact Center Analytics → Historical**
2. Select **Channel Activity** report
3. Filter by queue/channel
4. Set interval to 15 or 30 minutes
5. Export

Key metrics:
- **Max In Queue** — peak callers waiting simultaneously
- **Max Handling** — peak calls being handled simultaneously
- **Max In Queue + Max Handling** = effective peak concurrent calls

### 2.2 — 8x8 Reporting API

```bash
# 8x8 Analytics API v2
# Requires API key from 8x8 Admin Console → Developer → API Keys

API_KEY="your-8x8-api-key"
TENANT_ID="your-tenant-id"

# Get historical queue statistics
curl -s -X GET \
  "https://api.8x8.com/analytics/v2/queues/statistics?startDate=$(date -d '90 days ago' +%Y-%m-%d)&endDate=$(date +%Y-%m-%d)&interval=PT15M" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "X-8x8-Tenant-Id: ${TENANT_ID}" \
  | jq '.' > 8x8-queue-stats.json
```

---

## Section 3 — Cisco Unified Communications Manager (CUCM) / Cisco Contact Center (UCCX/UCCE)

### 3.1 — CUCM CDR (Call Detail Records)

CUCM writes Call Detail Records (CDR) to a flat file repository. CDR analysis is the most reliable way to derive concurrent call peaks.

**Access CDR files:**

1. Log in to CUCM Serviceability (`https://<cucm-host>/ccmservice`)
2. Navigate to **Tools → CDR Analysis and Reporting (CAR)**
3. Select **Report → System → Top Talks** or **CDR Export**
4. Export raw CDR for the last 90 days

**Alternative — pull CDR files directly:**

```bash
# CUCM writes CDRs to the CDR repository server (CDR/CMR files)
# Access via SFTP to the CUCM publisher

sftp admin@<cucm-publisher-ip>
# Navigate to /var/log/active/cm/cdr/
# Files are named: Master_net_YYYYMMDD_HHMMSS_NNNNNNNN
# Download all files for the target date range
get Master_net_2025* ./cdr-files/
```

**Parse CDR for concurrent calls:**

CDR files are CSV with fixed column layout. Key fields:
- `dateTimeOrigination` — call start (Unix epoch)
- `dateTimeDisconnect` — call end (Unix epoch)
- `duration` — call duration in seconds
- `origDeviceName`, `destDeviceName` — identifies internal vs. external legs

Use the concurrent call calculation script in Section 6 against the extracted start/end times.

### 3.2 — Cisco Unified Contact Center Express (UCCX) — Historical Reports

1. Log in to UCCX Reporting (`https://<uccx-host>/uccxreporting`)
2. Navigate to **Historical Reports → CSQ Activity Report** (Contact Service Queue)
3. Set date range: 90 days
4. Report interval: 30 minutes
5. Export to CSV

Key column: **Max Calls In CSQ** — peak concurrent calls per queue per interval.

### 3.3 — Cisco Unified Contact Center Enterprise (UCCE) — Unified Intelligence Center

1. Log in to Cisco Unified Intelligence Center (`https://<cuic-host>/cuic`)
2. Navigate to **Reports → Historical → Call Type Historical All Fields**
3. Set date range and 30-minute intervals
4. Run and export

Key metric: **Calls Handled** + **Calls Abandoned** in peak intervals, combined with average handle time, gives Erlang-C concurrent load.

---

## Section 4 — Avaya

### 4.1 — Avaya Call Management System (CMS)

Avaya CMS is the primary reporting platform for Avaya Aura Contact Center.

1. Log in to Avaya CMS Supervisor
2. Navigate to **Reports → Historical → ACD Calls**
3. Select the ACD/split/skill groups being migrated
4. Set date range: 90 days, 30-minute intervals
5. Include columns: **Max Calls In Queue**, **Calls Handled**, **Avg Handle Time**
6. Export to CSV

### 4.2 — Avaya Aura Communication Manager — SMI / SAT

For non-ACD Avaya systems, pull trunk group utilization from the System Access Terminal (SAT):

```
# Connect to SAT (requires Avaya admin credentials)
ssh admin@<avaya-host>

# Display trunk group status
display trunk-group <trunk-group-number>

# Historical trunk utilization (requires CMS or BCMS)
list measurements trunk-group <number> last-hour
list measurements trunk-group <number> today
list measurements trunk-group <number> yesterday
```

Key metric from SAT: **%All** (percentage of time all trunks in a group were busy) — if this approaches 100%, the trunk group was a bottleneck and actual demand exceeded capacity. Adjust your concurrent call estimate upward.

### 4.3 — Avaya Oceana / Avaya Experience Platform

1. Log in to Avaya Experience Portal management console
2. Navigate to **Reports → Call Volume**
3. Export historical data for 90 days at 15-minute intervals

---

## Section 5 — Asterisk / FreePBX / On-Premises SIP

### 5.1 — Asterisk CDR Database

Asterisk writes CDRs to a MySQL/MariaDB database (default) or flat CSV file, depending on configuration.

**Query the CDR database:**

```sql
-- Connect to the Asterisk CDR database
-- Default database name: asteriskcdrdb, table: cdr

-- Find peak concurrent calls by 15-minute window (last 90 days)
SELECT
  FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(calldate) / 900) * 900) AS window_start,
  COUNT(*) AS calls_in_window,
  SUM(duration) / 900 AS avg_concurrent_estimate
FROM cdr
WHERE
  calldate >= DATE_SUB(NOW(), INTERVAL 90 DAY)
  AND disposition = 'ANSWERED'
GROUP BY window_start
ORDER BY calls_in_window DESC
LIMIT 50;
```

**For true concurrent call peaks** (more accurate than window counts):

```sql
-- This query finds maximum concurrent calls at any point in time
-- by counting overlapping call intervals
SELECT
  c1.calldate AS call_start,
  COUNT(*) AS concurrent_calls
FROM cdr c1
JOIN cdr c2 ON (
  c2.calldate <= DATE_ADD(c1.calldate, INTERVAL c1.duration SECOND)
  AND DATE_ADD(c2.calldate, INTERVAL c2.duration SECOND) >= c1.calldate
)
WHERE
  c1.calldate >= DATE_SUB(NOW(), INTERVAL 90 DAY)
  AND c1.disposition = 'ANSWERED'
GROUP BY c1.calldate
ORDER BY concurrent_calls DESC
LIMIT 20;
```

### 5.2 — Asterisk CDR flat files

If CDRs are written to flat files (typically `/var/log/asterisk/cdr-csv/Master.csv`):

```bash
# Copy CDR files to working directory
scp admin@<asterisk-host>:/var/log/asterisk/cdr-csv/Master.csv ./

# Fields: accountcode, src, dst, dcontext, clid, channel, dstchannel,
#         lastapp, lastdata, start, answer, end, duration, billsec,
#         disposition, amaflags, uniqueid, userfield

# Extract answered calls with start/end times
awk -F',' '$16 == "ANSWERED" {print $10, $12}' Master.csv \
  | sort > asterisk-calls.txt
# Column 10 = start time, Column 12 = end time
```

Use the concurrent call calculation script in Section 6 against this output.

### 5.3 — FreePBX / Sangoma

FreePBX uses the same Asterisk CDR backend. Additionally:

1. Log in to FreePBX Admin (`http://<host>/admin`)
2. Navigate to **Reports → Asterisk Logfiles → CDR Reports**
3. Set date range and export to CSV

---

## Section 6 — Concurrent Call Calculation Script

If your legacy system provides raw call start/end times but not concurrent call counts directly, use this script to derive the peak.

```python
#!/usr/bin/env python3
"""
concurrent_calls.py — Calculate peak concurrent calls from CDR data.

Input: CSV file with two columns: start_time, end_time
       Times in ISO 8601 format (YYYY-MM-DD HH:MM:SS) or Unix epoch.

Usage:
  python3 concurrent_calls.py calls.csv
  python3 concurrent_calls.py calls.csv --format epoch
  python3 concurrent_calls.py calls.csv --interval 15

Output:
  - Peak concurrent calls observed
  - Time of peak
  - Top 10 busiest windows
  - Recommended AWS quota request value
"""

import csv
import sys
import argparse
from datetime import datetime, timedelta
from collections import defaultdict


def parse_time(value, fmt):
    if fmt == "epoch":
        return datetime.fromtimestamp(float(value))
    return datetime.strptime(value.strip(), "%Y-%m-%d %H:%M:%S")


def calculate_concurrent(calls, interval_minutes=15):
    """
    For each call, increment a counter at start and decrement at end.
    Find the maximum value of the running counter.
    """
    events = []
    for start, end in calls:
        events.append((start, +1))
        events.append((end,   -1))

    events.sort(key=lambda x: (x[0], x[1]))

    max_concurrent = 0
    max_time = None
    current = 0

    for ts, delta in events:
        current += delta
        if current > max_concurrent:
            max_concurrent = current
            max_time = ts

    return max_concurrent, max_time


def bucket_by_interval(calls, interval_minutes=15):
    """Group calls into time buckets and find peak concurrent per bucket."""
    buckets = defaultdict(int)

    for start, end in calls:
        # Walk through the call duration in interval-sized steps
        bucket = start.replace(
            minute=(start.minute // interval_minutes) * interval_minutes,
            second=0, microsecond=0
        )
        while bucket <= end:
            buckets[bucket] += 1
            bucket += timedelta(minutes=interval_minutes)

    return sorted(buckets.items(), key=lambda x: x[1], reverse=True)


def main():
    parser = argparse.ArgumentParser(description="Calculate peak concurrent calls from CDR data.")
    parser.add_argument("file", help="CSV file with start_time and end_time columns")
    parser.add_argument("--format", choices=["iso", "epoch"], default="iso",
                        help="Time format: iso (YYYY-MM-DD HH:MM:SS) or epoch (Unix timestamp)")
    parser.add_argument("--interval", type=int, default=15,
                        help="Bucket interval in minutes (default: 15)")
    args = parser.parse_args()

    calls = []
    skipped = 0

    with open(args.file, newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) < 2:
                continue
            try:
                start = parse_time(row[0], args.format)
                end   = parse_time(row[1], args.format)
                if end > start:
                    calls.append((start, end))
                else:
                    skipped += 1
            except (ValueError, OSError):
                skipped += 1

    if not calls:
        print("ERROR: No valid call records found. Check file format and --format flag.")
        sys.exit(1)

    print(f"\nLoaded {len(calls)} call records ({skipped} skipped)")
    print(f"Date range: {min(c[0] for c in calls)} to {max(c[1] for c in calls)}\n")

    # True peak concurrent
    peak, peak_time = calculate_concurrent(calls)
    print(f"Peak concurrent calls (true):  {peak}")
    print(f"Time of peak:                  {peak_time}\n")

    # Bucketed view
    buckets = bucket_by_interval(calls, args.interval)
    print(f"Top 10 busiest {args.interval}-minute windows:")
    print(f"  {'Window Start':<25} {'Concurrent Calls':>18}")
    print(f"  {'-'*25} {'-'*18}")
    for ts, count in buckets[:10]:
        print(f"  {str(ts):<25} {count:>18}")

    # Recommendation
    headroom_factor = 1.25
    recommended = int(peak * headroom_factor) + 10
    print(f"\nRecommended AWS quota request: {recommended} concurrent calls")
    print(f"  (peak {peak} × 1.25 headroom + 10 burst buffer)")
    print(f"\nRound up to the nearest 50 for the actual quota request.")
    recommended_rounded = ((recommended // 50) + 1) * 50
    print(f"  Submit request for: {recommended_rounded} concurrent calls\n")


if __name__ == "__main__":
    main()
```

Save as `connect-pbx/docs/runbooks/scripts/concurrent_calls.py`.

**Example usage:**

```bash
# From Asterisk CDR extract (ISO timestamps)
python3 scripts/concurrent_calls.py asterisk-calls.csv

# From RingCentral API export (Unix epoch)
python3 scripts/concurrent_calls.py ringcentral-call-log.csv --format epoch

# With 30-minute buckets instead of default 15
python3 scripts/concurrent_calls.py calls.csv --interval 30
```

---

## Section 7 — Packaging the Data for AWS

### 7.1 — Required information summary

Compile the following before submitting the quota request:

```
CONCURRENT CALL QUOTA INCREASE — DATA PACKAGE
==============================================

CLIENT:               [client name]
CONNECT INSTANCE ID:  [instance ID]
ACCOUNT ID:           [AWS account ID]
GO-LIVE DATE:         [target date]
SUBMITTED BY:         [engineer name and email]

CURRENT SYSTEM:       [RingCentral / 8x8 / Cisco / Avaya / etc.]
DATA SOURCE:          [CDR database / Analytics Portal / etc.]
DATA RANGE:           [start date] to [end date] (N days)

PEAK CONCURRENT CALLS OBSERVED:    [N]
DATE/TIME OF PEAK:                 [timestamp]
SECOND-HIGHEST PEAK:               [N] on [date]
TYPICAL BUSY-HOUR CONCURRENT:      [N] (average of top 10 busy hours)

TOTAL AGENTS (all shifts):         [N]
AGENTS ON PEAK SHIFT:              [N]
INBOUND / OUTBOUND MIX:            [e.g., 80% inbound, 20% outbound]

BUSINESS DESCRIPTION:
  [2-3 sentences: what the contact center does, call types, hours of operation]

GROWTH PROJECTION (next 12 months):
  [expected % increase in call volume or agent headcount]

REQUESTED QUOTA:                   [N concurrent calls]
JUSTIFICATION FOR REQUESTED VALUE:
  Peak observed: N. Applied 1.25x headroom factor = N. Rounded to nearest 50 = N.
  Requested value accounts for growth projection and seasonal peaks.
```

### 7.2 — Submit the quota increase request

1. Log in to the AWS Console
2. Navigate to **Service Quotas → AWS Services → Amazon Connect**
3. Find **Concurrent active calls per instance**
4. Click **Request quota increase**
5. Enter the requested value
6. In the case description, paste the data package from Section 7.1
7. Submit

Alternatively via AWS CLI:

```bash
aws service-quotas request-service-quota-increase \
  --service-code connect \
  --quota-code L-D5E2E8E0 \
  --desired-value 500 \
  --region us-east-1
```

> The quota code `L-D5E2E8E0` is for **Concurrent active calls per instance**. Verify this is current before submitting — quota codes can change.

AWS Support typically responds within 1–3 business days. For urgent go-live timelines, open a Support case directly and reference the quota increase request number.

### 7.3 — Other quotas to request at the same time

While submitting the concurrent call increase, also request increases for any of these that apply:

| Quota | Default | Request If |
|---|---|---|
| Phone numbers per instance | 10 | Client has >10 numbers |
| Agents per instance | 500 | Client has >500 agents |
| Concurrent active chats per instance | 2,500 | Chat channel will be used |
| Contact flows per instance | 100 | Complex IVR with many flows |
| Queues per instance | 50 | Many business units or skills |

Request all needed increases before go-live. Each is a separate quota request.

---

## Section 8 — Interpreting Results and Setting the Right Number

### Headroom guidelines

| Scenario | Recommended Headroom |
|---|---|
| Stable, predictable call volume | Peak × 1.25, round up to nearest 50 |
| Seasonal peaks (retail, tax season, etc.) | Use seasonal peak × 1.5 |
| Business is growing >20%/year | Use peak × 1.5 + growth projection |
| Unknown or poorly documented history | Use agent count × 3 as a floor |
| Migration from a constrained legacy system (trunk group was often full) | Legacy peak is a floor, not a ceiling — add 30–50% |

### The trunk group constraint problem

If the legacy system had a fixed trunk group capacity (common in Cisco/Avaya deployments with PRI or limited SIP trunks), the CDR data may undercount true demand. When all trunks were busy, calls were blocked or went to overflow — they do not appear as concurrent calls in CDR. In this case:

- Look for **trunk group occupancy** or **%All busy** metrics
- If the trunk group was regularly at or near 100% occupancy, assume actual demand exceeded what CDR shows
- Inflate your concurrent call estimate by 20–30% to account for blocked demand
- Interview agents and supervisors about call volume — qualitative input matters here

### Using Erlang-C when concurrent data is unavailable

If you only have call volume (calls per hour) and average handle time, use the Erlang-C formula to estimate concurrent calls:

```
Erlang load (A) = (Calls per hour × Average Handle Time in seconds) / 3600

For a target service level of 80% answered within 20 seconds,
Erlang-C tables give you the number of agents (and thus approximate
concurrent calls) needed for a given load.
```

Online Erlang-C calculators are widely available. Input your busy-hour call volume and average handle time to get a concurrent call estimate.

---

## Section 9 — Verifying the Quota After Approval

---

## Related Documents

- [RB-00-01-runbook-index.md](RB-00-01-runbook-index.md)
- [RB-11-02-porting-and-cutover.md](RB-11-02-porting-and-cutover.md)

After AWS approves and applies the quota increase:

```bash
# Verify the new quota is active
aws service-quotas get-service-quota \
  --service-code connect \
  --quota-code L-D5E2E8E0 \
  --region us-east-1 \
  --query "Quota.{Value:Value,Adjustable:Adjustable,Unit:Unit}"
```

Also verify in the Connect console:
1. Navigate to **Amazon Connect → your instance → Overview**
2. Under **Telephony**, confirm the concurrent call limit reflects the approved value

Do not proceed to go-live until the quota is confirmed active. Approval email does not always mean the quota is immediately applied — verify via API or console.
