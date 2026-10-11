#!/usr/bin/env python3
"""
todo-staleness-scan.py - List the Independent items in workspace/tasks/todo.md that are due a re-check.

It reads dates, not live state, so it is cheap and gives the same answer for the same date.
The live checks that follow are in .claude/docs/todo-review.md.

Usage: python3 .claude/scripts/todo-staleness-scan.py [--date YYYY-MM-DD] [--max-age N] [--root PATH]

An item is one `- [ ]` or `- [x]` bullet under `## Independent` (continuation lines
indented under it belong to it). Two optional markers anywhere in the item set its dates:

  (verified YYYY-MM-DD)   last day the item was checked against live state; the latest wins
  (recheck YYYY-MM-DD)    parked items only: the day to look at the item again

State per item:
  checked  the box is ticked
  parked   the bullet contains the pause sign and is not due
  due      see below
  fresh    everything else

Due rules:
  open item                   due with no verified marker, or when it was verified more
                              than --max-age days ago (default 3)
  parked, has a recheck mark  due on or after that day; the verified marker is ignored
  parked, no recheck mark     due with no verified marker, or when it was verified more
                              than 14 days ago

Output (text, stdout):
  independent=<n> due=<n> fresh=<n> parked=<n> checked=<n>
  due <number> <title> (<reason>)       # repeated, file order; <number> is the 1-based
                                        # position among the section's bullets, ticked ones included

Exit 0 on a normal run. A missing file or section reads as zero items, so the caller can
say "nothing to review" without failing the morning plan. A bad --date exits 2, and an
unreadable file fails loudly.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from datetime import date
from pathlib import Path
from typing import NamedTuple

from nase_time import calendar_day, local_today

NASE_ROOT = Path(__file__).resolve().parents[2]
TODO_PATH = Path("workspace") / "tasks" / "todo.md"
SECTION = "## Independent"
PARK_SIGN = "⏸"
MAX_AGE_DAYS = 3
PARK_AGE_DAYS = 14

HEADING = re.compile(r"#{1,2} ")
BULLET = re.compile(r"^- \[([ xX])\] ?(.*)$")
TITLE = re.compile(r"\*\*(.+?)\*\*")
VERIFIED = re.compile(r"\(verified (\d{4}-\d{2}-\d{2})\)")
RECHECK = re.compile(r"\(recheck (\d{4}-\d{2}-\d{2})\)")


class Item(NamedTuple):
    number: int
    title: str
    state: str
    reason: str


def latest_day(pattern: re.Pattern[str], body: str) -> date | None:
    days = []
    for raw in pattern.findall(body):
        try:
            days.append(calendar_day(raw).date())
        except ValueError:
            continue
    return max(days, default=None)


def split_items(text: str) -> list[tuple[str, str]]:
    """Return (checkbox, body) for each bullet under the Independent section."""
    items: list[tuple[str, str]] = []
    in_section = False
    for line in text.splitlines():
        if HEADING.match(line):
            in_section = line.rstrip() == SECTION or line.startswith(SECTION + " ")
            continue
        if not in_section:
            continue
        match = BULLET.match(line)
        if match:
            items.append((match.group(1), match.group(2)))
        elif items and line.startswith((" ", "\t")) and line.strip():
            box, body = items[-1]
            items[-1] = (box, body + " " + line.strip())
    return items


def classify(box: str, body: str, number: int, today: date, max_age: int) -> Item:
    title_match = TITLE.search(body)
    title = title_match.group(1) if title_match else body[:80]
    verified = latest_day(VERIFIED, body)
    recheck = latest_day(RECHECK, body)
    age = max(0, (today - verified).days) if verified else None
    parked = PARK_SIGN in body

    if box.lower() == "x":
        state, reason = "checked", "ticked"
    elif parked and recheck:
        state, reason = ("due", "recheck-due") if recheck <= today else ("parked", f"recheck {recheck}")
    elif age is None:
        state, reason = "due", "no-verified-marker"
    elif age > (PARK_AGE_DAYS if parked else max_age):
        state, reason = "due", f"{'parked-' if parked else ''}age-{age}d"
    else:
        state, reason = ("parked" if parked else "fresh"), f"verified {age}d ago"
    return Item(number, title, state, reason)


def scan(root: Path, today: date, max_age: int) -> list[Item]:
    path = root / TODO_PATH
    if not path.is_file():
        return []
    items = split_items(path.read_text(encoding="utf-8", errors="ignore"))
    return [classify(box, body, i, today, max_age) for i, (box, body) in enumerate(items, start=1)]


def render_text(items: list[Item]) -> str:
    counts = Counter(item.state for item in items)
    lines = [
        f"independent={len(items)} due={counts['due']} fresh={counts['fresh']} "
        f"parked={counts['parked']} checked={counts['checked']}"
    ]
    lines += [f"due {item.number} {item.title} ({item.reason})" for item in items if item.state == "due"]
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--date", type=date.fromisoformat, default=None, help="local calendar day, YYYY-MM-DD (default: today)")
    parser.add_argument("--max-age", type=int, default=MAX_AGE_DAYS, help=f"days before an open item is due (default {MAX_AGE_DAYS})")
    parser.add_argument("--root", default=str(NASE_ROOT))
    args = parser.parse_args(argv)

    print(render_text(scan(Path(args.root), args.date or local_today(), args.max_age)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
