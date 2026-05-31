#!/usr/bin/env python3
"""Render a vertical ASCII column chart of session activity.

Picks bucket granularity from the date range:
- ≤ 14 days → per-day buckets (label: English weekday abbrev)
- > 14 days → per-week buckets (label: W{iso_week}), sum sessions in each week

Usage:
    stats-chart.py --daily-csv PATH --start YYYY-MM-DD --end YYYY-MM-DD

The daily.csv is the format produced by workspace/scripts/stats-collect.sh:
    date,sessions,commits,prs

Prints the chart to stdout. Used by /nase:stats.
"""

from __future__ import annotations

import argparse
import csv
import datetime
import math
import sys


WEEKDAY_ABBREV = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


BAR = "██"
EMPTY = "░"
BAR_WIDTH = 2
COL_SPACING = 4  # total width per column including padding
MAX_ROWS = 10


def load_sessions(path: str) -> dict[str, int]:
    sessions: dict[str, int] = {}
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if not row or len(row) < 2:
                continue
            try:
                sessions[row[0]] = int(row[1])
            except ValueError:
                continue
    return sessions


def build_buckets(
    start: datetime.date,
    end: datetime.date,
    sessions: dict[str, int],
) -> tuple[list[str], list[int]]:
    """Return (labels, counts) ordered chronologically."""
    span = (end - start).days + 1
    if span <= 14:
        labels: list[str] = []
        counts: list[int] = []
        d = start
        while d <= end:
            labels.append(WEEKDAY_ABBREV[d.weekday()])
            counts.append(sessions.get(d.isoformat(), 0))
            d += datetime.timedelta(days=1)
        return labels, counts

    # weekly buckets keyed by (iso_year, iso_week)
    week_totals: dict[tuple[int, int], int] = {}
    order: list[tuple[int, int]] = []
    d = start
    while d <= end:
        key = d.isocalendar()[:2]
        if key not in week_totals:
            week_totals[key] = 0
            order.append(key)
        week_totals[key] += sessions.get(d.isoformat(), 0)
        d += datetime.timedelta(days=1)
    labels = [f"W{w:02d}" for (_, w) in order]
    counts = [week_totals[k] for k in order]
    return labels, counts


def render_chart(labels: list[str], counts: list[int]) -> str:
    n = len(labels)
    if n == 0:
        return "(no data)"
    max_val = max(counts, default=0)
    heights = [math.ceil(c / max_val * MAX_ROWS) if c > 0 else 0 for c in counts]

    # y-axis labels: 0, max, plus up to 2 distinct mid values that appear in counts
    distinct_positive = sorted({c for c in counts if 0 < c < max_val}, reverse=True)
    mids = distinct_positive[:2]
    y_marks = sorted({0, max_val, *mids})
    y_width = max(len(str(v)) for v in y_marks)

    # Precompute row → label so the per-row loop is O(1) instead of O(marks).
    # When two marks round to the same row, the larger wins (mids are sorted desc).
    label_by_row: dict[int, str] = {}
    if max_val > 0:
        for v in sorted(y_marks):
            if v == 0:
                continue
            label_by_row.setdefault(math.ceil(v / max_val * MAX_ROWS), str(v))

    # bar column starts after `{y_width} {axis-char} ` (= y_width + 2 chars) plus a
    # two-space gap, so every row prefix occupies BAR_COL_OFFSET chars before bars
    BAR_COL_OFFSET = y_width + 2 + 2

    lines: list[str] = []
    for row in range(MAX_ROWS, 0, -1):
        label = label_by_row.get(row, "")
        prefix = f"{label:>{y_width}} ┤" if label else f"{' ':>{y_width}} │"
        cells = [BAR if h >= row else " " * BAR_WIDTH for h in heights]
        body = (" " * (COL_SPACING - BAR_WIDTH)).join(cells)
        lines.append(f"{prefix}  {body}")

    # zero row + x-axis (dashed line under every column slot)
    axis_width = n * BAR_WIDTH + (n - 1) * (COL_SPACING - BAR_WIDTH)
    lines.append(f"{0:>{y_width}} ┼{'─' * (2 + axis_width)}")

    label_width = max(max(len(lbl) for lbl in labels), BAR_WIDTH)
    pad = " " * BAR_COL_OFFSET
    label_cells = [
        f"{(EMPTY if h == 0 else lbl):^{label_width}}"
        for lbl, h in zip(labels, heights)
    ]
    lines.append(pad + " ".join(label_cells))
    lines.append(pad + " ".join(f"{c:^{label_width}}" for c in counts))

    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--daily-csv", required=True)
    ap.add_argument("--start", required=True, help="YYYY-MM-DD")
    ap.add_argument("--end", required=True, help="YYYY-MM-DD")
    args = ap.parse_args()

    try:
        start = datetime.date.fromisoformat(args.start)
        end = datetime.date.fromisoformat(args.end)
    except ValueError as e:
        print(f"error: bad date: {e}", file=sys.stderr)
        return 2
    if end < start:
        print("error: end < start", file=sys.stderr)
        return 2

    sessions = load_sessions(args.daily_csv)
    labels, counts = build_buckets(start, end, sessions)
    print(render_chart(labels, counts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
