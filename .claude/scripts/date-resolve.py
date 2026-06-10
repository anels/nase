#!/usr/bin/env python3
"""
date-resolve.py — Resolve a human date spec to a START_DATE END_DATE pair.

Usage: python3 .claude/scripts/date-resolve.py <spec>

Output (stdout): "YYYY-MM-DD YYYY-MM-DD"  (start end, space-separated)
Exit 0: success (always — unrecognised specs fall back to last 7 days with a stderr warning)
Exit 1: missing argument (usage error)

Supported specs:
  N / Nd / last N days          → last N days (today-(N-1) → today)
  all                           → earliest log file date → today
  week / last week              → Mon–Sun of last week
  this week                     → Mon of current week → today
  month / last month            → 1st–last day of last month
  this month                    → 1st of current month → today
  today                         → today → today
  yesterday                     → yesterday → yesterday
  YYYY-MM-DD to YYYY-MM-DD      → explicit range (inclusive)

Examples:
  python3 .claude/scripts/date-resolve.py "last week"
  python3 .claude/scripts/date-resolve.py "10d"
  python3 .claude/scripts/date-resolve.py "2026-04-01 to 2026-04-30"
"""

from __future__ import annotations

import datetime
import glob
import os
import sys


def find_earliest_log(workspace_root: str) -> datetime.date:
    pattern = os.path.join(workspace_root, "workspace", "logs", "????-??-??.md")
    files = sorted(glob.glob(pattern))
    fallback = datetime.date.today() - datetime.timedelta(days=6)
    if not files:
        return fallback
    name = os.path.basename(files[0]).replace(".md", "")
    try:
        return datetime.date.fromisoformat(name)
    except ValueError:
        print(
            f"WARNING: earliest log filename '{name}' is not ISO-8601, "
            f"defaulting 'all' range to last 7 days",
            file=sys.stderr,
        )
        return fallback


def last_days_range(today: datetime.date, days: int) -> tuple[datetime.date, datetime.date]:
    return today - datetime.timedelta(days=days - 1), today


def fallback_range(today: datetime.date) -> tuple[datetime.date, datetime.date]:
    return last_days_range(today, 7)


def resolve(spec: str) -> tuple[datetime.date, datetime.date]:
    today = datetime.date.today()
    s = spec.strip().lower()

    # Explicit range: YYYY-MM-DD to YYYY-MM-DD
    if " to " in s:
        parts = s.split(" to ", 1)
        try:
            start = datetime.date.fromisoformat(parts[0].strip())
            end = datetime.date.fromisoformat(parts[1].strip())
        except ValueError:
            print(f"WARNING: invalid date range '{spec}', defaulting to last 7 days", file=sys.stderr)
            return fallback_range(today)
        if end < start:
            print(f"WARNING: invalid date range '{spec}' (end before start), defaulting to last 7 days", file=sys.stderr)
            return fallback_range(today)
        return start, end

    # Numeric days
    days_text = ""
    if s.isdigit():
        days_text = s
    elif s.endswith("d") and s[:-1].isdigit():
        days_text = s[:-1]
    elif s.startswith("last ") and s.endswith(" days") and s[5:-5].strip().isdigit():
        days_text = s[5:-5].strip()
    if days_text:
        days = int(days_text)
        if days > 0:
            try:
                return last_days_range(today, days)
            except OverflowError:
                pass
        print(f"WARNING: invalid day count '{spec}', defaulting to last 7 days", file=sys.stderr)
        return fallback_range(today)

    # Today / yesterday
    if s == "today":
        return today, today
    if s == "yesterday":
        y = today - datetime.timedelta(days=1)
        return y, y

    # This week (Mon → today)
    if s == "this week":
        monday = today - datetime.timedelta(days=today.weekday())
        return monday, today

    # Last week (Mon → Sun)
    if s in ("week", "last week"):
        last_monday = today - datetime.timedelta(days=today.weekday() + 7)
        last_sunday = last_monday + datetime.timedelta(days=6)
        return last_monday, last_sunday

    # This month
    if s == "this month":
        return today.replace(day=1), today

    # Last month
    if s in ("month", "last month"):
        first_of_this = today.replace(day=1)
        last_of_prev = first_of_this - datetime.timedelta(days=1)
        return last_of_prev.replace(day=1), last_of_prev

    # All time
    if s == "all":
        # script lives at <workspace_root>/.claude/scripts/date-resolve.py
        workspace_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        return find_earliest_log(workspace_root), today

    # Try parsing as a bare date
    try:
        d = datetime.date.fromisoformat(s)
        return d, d
    except ValueError:
        pass

    # Fallback: warn and use last 7 days
    print(f"WARNING: unrecognised date spec '{spec}', defaulting to last 7 days", file=sys.stderr)
    return fallback_range(today)


def main() -> None:
    if len(sys.argv) < 2:
        print("Usage: date-resolve.py <spec>", file=sys.stderr)
        print("Example specs: 7, 10d, all, 'last week', 'last month', '2026-04-01 to 2026-04-30'", file=sys.stderr)
        sys.exit(1)

    spec = " ".join(sys.argv[1:])
    start, end = resolve(spec)
    print(f"{start.isoformat()} {end.isoformat()}")


if __name__ == "__main__":
    main()
