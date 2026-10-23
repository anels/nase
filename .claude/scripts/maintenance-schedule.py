#!/usr/bin/env python3
"""
maintenance-schedule.py - Keep the `## Scheduled Maintenance` lines in workspace/tasks/todo.md honest.

A recurring skill records that it ran with `done`, which moves the line's due date forward.
`/nase:today` reads the lines with `list`. Neither command needs the model to edit the file.

Usage:
  python3 .claude/scripts/maintenance-schedule.py list [--date YYYY-MM-DD] [--root PATH]
  python3 .claude/scripts/maintenance-schedule.py done <skill> [--date YYYY-MM-DD] [--root PATH]

A schedule line is one `- [ ]` bullet under `## Scheduled Maintenance`:

  - [ ] 📅 2026-10-23 — `/nase:kb-review` — Weekly KB hygiene (every 7d) (last run 2026-10-16)

The date is the next due day. `(every Nd)` is the cadence. Both separators `—` and `--` are
accepted, and the leading pause or calendar sign is optional. A line with the pause sign, a
ticked box, or no leading date is not scheduled work and is never listed or changed.

list  prints `scheduled=<n> due=<n>` then `due <skill> <date> (<reason>)` per due line, where the
      reason is `due-today` or `overdue-<n>d`. Exit 0, also when the file or section is absent.
done  sets the due date to the run day plus the cadence and rewrites `(last run ...)`. `<skill>` is
      `kb-review` or `/nase:kb-review`. Exit 0 and no change when the skill has no schedule line,
      since most skills also run ad hoc. Exit 3 when the line has no `(every Nd)`: guessing a
      cadence would hide the drift this script exists to prevent.

The file is replaced atomically. A bad --date exits 2.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import date, timedelta
from pathlib import Path

from nase_fs import atomic_write
from nase_time import local_today

NASE_ROOT = Path(__file__).resolve().parents[2]
TODO_PATH = Path("workspace") / "tasks" / "todo.md"
SECTION = "## Scheduled Maintenance"
PARK_SIGN = "⏸"

HEADING = re.compile(r"#{1,2} ")
LINE = re.compile(
    r"^(?P<head>- \[(?P<box>[ xX])\] (?:📅 )?)"
    r"(?P<date>\d{4}-\d{2}-\d{2})"
    r"(?P<sep> (?:—|--) )`/nase:(?P<skill>[^`]+)`"
    r"(?P<rest>.*)$"
)
EVERY = re.compile(r"\(every (\d+)d\)")
LAST_RUN = re.compile(r" ?\(last run [^)]*\)")


def parse(line: str) -> re.Match[str] | None:
    match = LINE.match(line)
    if not match or match.group("box") != " " or PARK_SIGN in line:
        return None
    try:
        date.fromisoformat(match.group("date"))
    except ValueError:
        return None
    return match


def section_lines(lines: list[str]) -> list[int]:
    """Indexes of the lines inside the Scheduled Maintenance section."""
    indexes: list[int] = []
    in_section = False
    for i, line in enumerate(lines):
        if HEADING.match(line):
            in_section = line.rstrip() == SECTION
            continue
        if in_section:
            indexes.append(i)
    return indexes


def list_due(text: str, today: date) -> str:
    lines = text.splitlines()
    scheduled = due = 0
    out: list[str] = []
    for i in section_lines(lines):
        match = parse(lines[i])
        if not match:
            continue
        scheduled += 1
        due_day = date.fromisoformat(match.group("date"))
        if due_day > today:
            continue
        due += 1
        late = (today - due_day).days
        out.append(f"due {match.group('skill')} {due_day} ({'due-today' if late == 0 else f'overdue-{late}d'})")
    return "\n".join([f"scheduled={scheduled} due={due}", *out])


def mark_done(text: str, skill: str, today: date) -> tuple[str, str, int]:
    """Return (new text, message, exit code)."""
    wanted = skill.removeprefix("/nase:")
    lines = text.splitlines()
    for i in section_lines(lines):
        match = parse(lines[i])
        if not match or match.group("skill") != wanted:
            continue
        every = EVERY.search(match.group("rest"))
        if not every:
            return text, f"{wanted}: schedule line has no (every Nd) cadence, left unchanged", 3
        next_due = today + timedelta(days=int(every.group(1)))
        rest = LAST_RUN.sub("", match.group("rest")) + f" (last run {today})"
        lines[i] = f"{match.group('head')}{next_due}{match.group('sep')}`/nase:{wanted}`{rest}"
        trailing = "\n" if text.endswith("\n") else ""
        return "\n".join(lines) + trailing, f"{wanted}: next due {next_due}", 0
    return text, f"{wanted}: no schedule line, nothing to update", 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("list", "done"))
    parser.add_argument("skill", nargs="?")
    parser.add_argument("--date", type=date.fromisoformat, default=None, help="local calendar day, YYYY-MM-DD (default: today)")
    parser.add_argument("--root", default=str(NASE_ROOT))
    args = parser.parse_args(argv)
    if args.command == "done" and not args.skill:
        parser.error("done needs a skill name")

    path = Path(args.root) / TODO_PATH
    today = args.date or local_today()
    text = path.read_text(encoding="utf-8") if path.is_file() else ""

    if args.command == "list":
        print(list_due(text, today))
        return 0

    new_text, message, code = mark_done(text, args.skill, today)
    if new_text != text:
        atomic_write(path, new_text.encode("utf-8"))
    print(message, file=sys.stderr if code else sys.stdout)
    return code


if __name__ == "__main__":
    sys.exit(main())
