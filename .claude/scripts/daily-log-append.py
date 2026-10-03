#!/usr/bin/env python3
"""
daily-log-append.py - Append one canonical entry to today's daily log.

Owns the `.claude/docs/daily-log-format.md` shape so writers stop re-deriving it:
the file is created with its `# Work Log — {date}` header and `## Sessions`
section, and the entry lands at the end of `## Sessions` (before any later
section such as `## Commits`), formatted as `- {HH:MM} | {tag}: {summary}`.

Usage: python3 .claude/scripts/daily-log-append.py TAG SUMMARY [--root PATH] [--time HH:MM]

  TAG      skill tag from daily-log-format.md (e.g. `fsd`, `review`, `kb-review`)
  SUMMARY  one line; newlines are rejected
  --root   nase repo root (default: derived from script location)
  --time   override HH:MM (tests); default is local wall-clock time

An existing log that lacks `## Sessions` gets the section appended at its end;
its earlier content is never rewritten.

Exit codes:
  0  entry appended
  2  invalid arguments (bad tag, multi-line summary, bad --time)
"""

from __future__ import annotations

import argparse
import fcntl
import pathlib
import re
import sys

from nase_time import local_now

TAG_RE = re.compile(r"^[a-z0-9][a-z0-9:-]*$")
TIME_RE = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")


def insert_entry(text: str, entry: str, day: str) -> str:
    if not text.strip():
        return f"# Work Log — {day}\n\n## Sessions\n\n{entry}\n"
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == "## Sessions")
    except StopIteration:
        return text.rstrip("\n") + f"\n\n## Sessions\n\n{entry}\n"
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")),
        len(lines),
    )
    last = end
    while last > start + 1 and not lines[last - 1].strip():
        last -= 1
    lines[last:last] = [entry]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Append one canonical entry to today's daily log.")
    parser.add_argument("tag")
    parser.add_argument("summary")
    parser.add_argument("--root", default=str(pathlib.Path(__file__).resolve().parents[2]))
    parser.add_argument("--time")
    args = parser.parse_args()

    summary = args.summary.strip()
    if not TAG_RE.match(args.tag):
        print(f"invalid tag: {args.tag!r}", file=sys.stderr)
        return 2
    if not summary or "\n" in summary or "\r" in summary:
        print("summary must be a single non-empty line", file=sys.stderr)
        return 2
    if args.time is not None and not TIME_RE.match(args.time):
        print(f"invalid --time: {args.time!r} (expected HH:MM)", file=sys.stderr)
        return 2

    now = local_now()
    day = now.date().isoformat()
    entry = f"- {args.time or now.strftime('%H:%M')} | {args.tag}: {summary}"

    path = pathlib.Path(args.root) / "workspace" / "logs" / f"{day}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a+", encoding="utf-8") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        updated = insert_entry(handle.read(), entry, day)
        handle.seek(0)
        handle.truncate()
        handle.write(updated)
        handle.flush()
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
