#!/usr/bin/env python3
"""
log-range.py — Emit existing daily-log file paths for a date range.

Used by /nase:recap Step 4.5. Replaces the `{LOG_FILES}` prose placeholder that
previously expected the model to expand a cross-month range — LLMs silently
drop tail dates, causing partial recaps.

Usage: python3 .claude/scripts/log-range.py START_DATE END_DATE [--root PATH] [--logs-dir REL]

  START_DATE / END_DATE  YYYY-MM-DD (inclusive on both ends)
  --root                 nase repo root (default: derived from script location via `__file__`)
  --logs-dir             relative path under root for log files (default: workspace/logs)
  --separator            output separator: 'space' (default) or 'newline'

Output (stdout): paths to log files that actually exist, separated by the chosen separator.
                  Non-existent dates are silently dropped — grep would error on them.

Exit codes:
  0  success (output may be empty if no logs exist in range)
  1  invalid arguments
"""
from __future__ import annotations

import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

NASE_ROOT = Path(__file__).resolve().parents[2]


def parse_iso(s: str) -> date:
    try:
        return date.fromisoformat(s)
    except ValueError as e:
        raise SystemExit(f"log-range.py: invalid date '{s}' (expected YYYY-MM-DD): {e}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Emit existing daily-log file paths for a date range.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("start", help="START_DATE YYYY-MM-DD")
    parser.add_argument("end", help="END_DATE YYYY-MM-DD")
    parser.add_argument("--root", default=None,
                        help="nase repo root (default: derived from script location via __file__)")
    parser.add_argument("--logs-dir", default="workspace/logs")
    parser.add_argument("--separator", choices=("space", "newline"), default="space")
    args = parser.parse_args()

    start = parse_iso(args.start)
    end = parse_iso(args.end)
    if end < start:
        print("log-range.py: END_DATE precedes START_DATE", file=sys.stderr)
        return 1

    root = Path(args.root) if args.root else NASE_ROOT
    logs_dir = root / args.logs_dir

    paths: list[str] = []
    cur = start
    while cur <= end:
        p = logs_dir / f"{cur.isoformat()}.md"
        if p.is_file():
            paths.append(str(p))
        cur += timedelta(days=1)

    sep = " " if args.separator == "space" else "\n"
    sys.stdout.write(sep.join(paths))
    if paths and sep == "\n":
        sys.stdout.write("\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
