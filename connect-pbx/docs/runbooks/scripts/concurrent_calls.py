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


def calculate_concurrent(calls):
    """
    For each call, record a +1 event at start and -1 event at end.
    Walk the sorted event list and track the running maximum.
    """
    events = []
    for start, end in calls:
        events.append((start, +1))
        events.append((end,   -1))

    # Sort by time; on ties, process end events (-1) before start events (+1)
    # to avoid inflating the count when a call ends and another starts simultaneously
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
    """Group calls into time buckets and count how many calls overlap each bucket."""
    buckets = defaultdict(int)

    for start, end in calls:
        bucket = start.replace(
            minute=(start.minute // interval_minutes) * interval_minutes,
            second=0,
            microsecond=0
        )
        while bucket <= end:
            buckets[bucket] += 1
            bucket += timedelta(minutes=interval_minutes)

    return sorted(buckets.items(), key=lambda x: x[1], reverse=True)


def day_of_week_summary(calls):
    """Show average concurrent calls by day of week."""
    day_peaks = defaultdict(list)
    for start, _end in calls:
        day_peaks[start.strftime("%A")].append(start)

    order = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    return {day: len(day_peaks.get(day, [])) for day in order}


def main():
    parser = argparse.ArgumentParser(
        description="Calculate peak concurrent calls from CDR start/end time data.",
        epilog="""
Examples:
  python3 concurrent_calls.py asterisk-calls.csv
  python3 concurrent_calls.py ringcentral.csv --format epoch
  python3 concurrent_calls.py cisco-cdr.csv --interval 30 --skip-header
        """
    )
    parser.add_argument("file", help="CSV file with start_time and end_time columns")
    parser.add_argument(
        "--format", choices=["iso", "epoch"], default="iso",
        help="Time format: iso (YYYY-MM-DD HH:MM:SS) or epoch (Unix timestamp). Default: iso"
    )
    parser.add_argument(
        "--interval", type=int, default=15,
        help="Bucket interval in minutes for windowed analysis. Default: 15"
    )
    parser.add_argument(
        "--skip-header", action="store_true",
        help="Skip the first row of the CSV (header row)"
    )
    parser.add_argument(
        "--col-start", type=int, default=0,
        help="Zero-based column index for start time. Default: 0"
    )
    parser.add_argument(
        "--col-end", type=int, default=1,
        help="Zero-based column index for end time. Default: 1"
    )
    args = parser.parse_args()

    calls = []
    skipped = 0
    header_skipped = False

    with open(args.file, newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f)
        for row in reader:
            if args.skip_header and not header_skipped:
                header_skipped = True
                continue
            if len(row) <= max(args.col_start, args.col_end):
                skipped += 1
                continue
            try:
                start = parse_time(row[args.col_start], args.format)
                end   = parse_time(row[args.col_end],   args.format)
                if end > start:
                    calls.append((start, end))
                else:
                    skipped += 1  # zero-duration or negative calls
            except (ValueError, OSError, IndexError):
                skipped += 1

    if not calls:
        print("ERROR: No valid call records found.")
        print("  Check the file format, column indexes, and --format flag.")
        print("  Use --skip-header if your file has a header row.")
        sys.exit(1)

    date_min = min(c[0] for c in calls)
    date_max = max(c[1] for c in calls)
    date_range_days = (date_max - date_min).days

    print("\n" + "=" * 60)
    print("  CONCURRENT CALL CAPACITY ASSESSMENT")
    print("=" * 60)
    print(f"\n  Records loaded:  {len(calls)}")
    print(f"  Records skipped: {skipped}")
    print(f"  Date range:      {date_min.strftime('%Y-%m-%d')} to {date_max.strftime('%Y-%m-%d')} ({date_range_days} days)")

    if date_range_days < 60:
        print(f"\n  WARNING: Only {date_range_days} days of data. AWS recommends 90+ days for")
        print("  an accurate peak assessment. Consider pulling more history.")

    # True peak concurrent
    peak, peak_time = calculate_concurrent(calls)

    print(f"\n{'─' * 60}")
    print(f"  PEAK CONCURRENT CALLS")
    print(f"{'─' * 60}")
    print(f"  Peak (true):   {peak} concurrent calls")
    print(f"  Time of peak:  {peak_time.strftime('%Y-%m-%d %H:%M:%S') if peak_time else 'unknown'}")
    if peak_time:
        print(f"  Day of week:   {peak_time.strftime('%A')}")

    # Windowed view
    buckets = bucket_by_interval(calls, args.interval)

    print(f"\n{'─' * 60}")
    print(f"  TOP 10 BUSIEST {args.interval}-MINUTE WINDOWS")
    print(f"{'─' * 60}")
    print(f"  {'Window Start':<25} {'Concurrent Calls':>18}")
    print(f"  {'─' * 25} {'─' * 18}")
    for ts, count in buckets[:10]:
        print(f"  {ts.strftime('%Y-%m-%d %H:%M'):<25} {count:>18}")

    # Day of week summary
    dow = day_of_week_summary(calls)
    print(f"\n{'─' * 60}")
    print(f"  CALL VOLUME BY DAY OF WEEK (total calls)")
    print(f"{'─' * 60}")
    for day, count in dow.items():
        bar = "█" * min(count // max(1, max(dow.values()) // 30), 30)
        print(f"  {day:<12} {count:>6}  {bar}")

    # Quota recommendation
    print(f"\n{'─' * 60}")
    print(f"  AWS QUOTA RECOMMENDATION")
    print(f"{'─' * 60}")

    headroom_125 = int(peak * 1.25) + 10
    headroom_150 = int(peak * 1.50) + 10
    rounded_125  = ((headroom_125 // 50) + 1) * 50
    rounded_150  = ((headroom_150 // 50) + 1) * 50

    print(f"  Observed peak:              {peak}")
    print(f"  With 1.25x headroom + 10:   {headroom_125}  → request {rounded_125}")
    print(f"  With 1.50x headroom + 10:   {headroom_150}  → request {rounded_150}")
    print()
    print(f"  Standard deployments:   request {rounded_125}")
    print(f"  Seasonal / high-growth: request {rounded_150}")
    print()
    print("  If the legacy system had full trunk groups, true demand may")
    print("  exceed CDR records. Add 20-30% to the above if trunk group")
    print("  occupancy was regularly at or near 100%.")
    print()
    print("  Submit the quota increase request via:")
    print("  AWS Console → Service Quotas → Amazon Connect")
    print("  → Concurrent active calls per instance")
    print("=" * 60 + "\n")


if __name__ == "__main__":
    main()
