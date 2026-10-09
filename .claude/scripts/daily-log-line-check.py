#!/usr/bin/env python3
"""
daily-log-line-check.py - Reject non-canonical session lines written to a daily log.

Reads one PreToolUse payload (Edit, Write or MultiEdit) on stdin. When the target is
`workspace/logs/YYYY-MM-DD.md`, every line the call adds that looks like a session
entry (`- HH:MM ...`) must match the shape `daily-log-append.py` writes:

    - HH:MM | skill-tag: summary

Lines that were already in the file are never judged, so an old `[done]` entry does not
block an unrelated edit. Other files, including dated tracker logs such as
`2026-09-23-sre-tracker.md`, are ignored.

Exit codes:
  0  allowed, or the payload could not be checked (a quality check must not block a write
     on its own breakage)
  2  at least one added line is not canonical

Escape hatch is handled by the hook wrapper: NASE_DAILY_LOG_GUARD=0.
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import sys
from collections import Counter

_here = pathlib.Path(__file__).resolve().parent
try:
    _spec = importlib.util.spec_from_file_location("daily_log_append", _here / "daily-log-append.py")
    assert _spec and _spec.loader
    _writer = importlib.util.module_from_spec(_spec)
    sys.path.insert(0, str(_here))
    _spec.loader.exec_module(_writer)
except Exception as exc:
    print(f"[daily-log-format-guard] not checked: {type(exc).__name__}", file=sys.stderr)
    sys.exit(0)

LOG_PATH_RE = re.compile(r"(^|/)workspace/logs/\d{4}-\d{2}-\d{2}\.md$")
ENTRY_RE = re.compile(r"^- \d{1,2}:\d{2}\b")
CANONICAL_RE = re.compile(
    rf"^- {_writer.TIME_RE.pattern[1:-1]} \| {_writer.TAG_RE.pattern[1:-1]}: \S"
)
SHOW = 5
WIDTH = 90


def added_lines(old: str, new: str) -> list[str]:
    remaining = Counter(old.splitlines())
    added = []
    for line in new.splitlines():
        if remaining[line] > 0:
            remaining[line] -= 1
        else:
            added.append(line)
    return added


def edits_for(tool: str, tool_input: dict, path: str) -> list[tuple[str, str]]:
    if tool == "Write":
        try:
            old = pathlib.Path(path).read_text(encoding="utf-8")
        except OSError:
            old = ""
        return [(old, tool_input["content"])]
    if tool == "MultiEdit":
        return [(e["old_string"], e["new_string"]) for e in tool_input["edits"]]
    return [(tool_input["old_string"], tool_input["new_string"])]


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        tool_input = payload.get("tool_input") or {}
        path = str(tool_input.get("file_path", ""))
        if not LOG_PATH_RE.search(path.replace("\\", "/")):
            return 0
        bad = []
        for old, new in edits_for(str(payload.get("tool_name", "")), tool_input, path):
            bad += [
                line
                for line in added_lines(old, new)
                if ENTRY_RE.match(line) and not CANONICAL_RE.match(line)
            ]
    except Exception as exc:
        print(f"[daily-log-format-guard] not checked: {type(exc).__name__}", file=sys.stderr)
        return 0
    if not bad:
        return 0
    print("BLOCKED by daily-log-format-guard: session lines must be `- HH:MM | skill-tag: summary`.", file=sys.stderr)
    for line in bad[:SHOW]:
        print(f"  {line[:WIDTH]}", file=sys.stderr)
    if len(bad) > SHOW:
        print(f"  ... and {len(bad) - SHOW} more", file=sys.stderr)
    print("Append with: python3 .claude/scripts/daily-log-append.py TAG \"one-line summary\"", file=sys.stderr)
    print("Tags and shape: .claude/docs/daily-log-format.md. Set NASE_DAILY_LOG_GUARD=0 only for a one-off repair.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
