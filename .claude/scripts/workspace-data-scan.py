#!/usr/bin/env python3
"""Emit compact workspace activity data for recap and wrap-up workflows.

The script keeps deterministic filtering outside the model context. It preserves
source paths and truncation markers so callers can read exact source files only
when the compact payload is not enough.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date, timedelta
from pathlib import Path
from typing import Any

NASE_ROOT = Path(__file__).resolve().parents[2]
LESSON_HEADER_RE = re.compile(r"^## .+ -- (\d{4}-\d{2}-\d{2}) -- .+", re.MULTILINE)
SIGNAL_RE = re.compile(
    r"(https?://|github\.com|atlassian\.net|PR|Jira|Confluence|KB|decision|decided|"
    r"blocked|completed|done|merged|pushed|error|incident|lesson|follow[- ]?up)",
    re.IGNORECASE,
)


def parse_iso(value: str) -> date:
    try:
        return date.fromisoformat(value)
    except ValueError as exc:
        raise SystemExit(f"workspace-data-scan.py: invalid date '{value}': {exc}")


def iter_days(start: date, end: date):
    cur = start
    while cur <= end:
        yield cur
        cur += timedelta(days=1)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def rel(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def compact_text(text: str, max_chars: int) -> dict[str, Any]:
    if len(text) <= max_chars:
        return {"content": text, "truncated": False, "chars": len(text)}

    lines = text.splitlines()
    keep: set[int] = set(range(min(8, len(lines))))
    keep.update(range(max(0, len(lines) - 8), len(lines)))

    for idx, line in enumerate(lines):
        if line.startswith("#") or SIGNAL_RE.search(line):
            keep.add(idx)

    out: list[str] = []
    previous: int | None = None
    for idx in sorted(keep):
        if previous is not None and idx != previous + 1:
            out.append("... [omitted lines] ...")
        out.append(lines[idx])
        previous = idx
        if len("\n".join(out)) >= max_chars:
            break

    content = "\n".join(out)
    if len(content) > max_chars:
        content = content[: max(0, max_chars - 18)].rstrip() + "\n... [truncated] ..."

    return {
        "content": content,
        "truncated": True,
        "chars": len(text),
        "excerpt_strategy": "headers, links, signal lines, first/last lines",
    }


def file_payload(path: Path, root: Path, max_chars: int) -> dict[str, Any]:
    if not path.is_file():
        return {"path": rel(path, root), "exists": False}
    payload = compact_text(read_text(path), max_chars)
    payload.update({"path": rel(path, root), "exists": True})
    return payload


def skipped_payload(path: Path, root: Path, reason: str) -> dict[str, Any]:
    return {
        "path": rel(path, root),
        "exists": path.is_file(),
        "skipped": True,
        "reason": reason,
    }


def activity_level(text: str) -> str:
    meaningful = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        meaningful.append(line)
    return "substantive" if meaningful else "low-activity"


def split_sections(text: str) -> list[str]:
    starts = [match.start() for match in re.finditer(r"^## ", text, re.MULTILINE)]
    if not starts:
        return []
    starts.append(len(text))
    return [text[starts[i]:starts[i + 1]].strip() for i in range(len(starts) - 1)]


def lessons_payload(path: Path, root: Path, start: date, end: date, max_chars: int) -> dict[str, Any]:
    if not path.is_file():
        return {"path": rel(path, root), "exists": False, "matching_sections": []}

    text = read_text(path)
    matches: list[dict[str, Any]] = []
    for section in split_sections(text):
        header = section.splitlines()[0] if section else ""
        match = LESSON_HEADER_RE.match(header)
        if not match:
            continue
        section_date = parse_iso(match.group(1))
        if start <= section_date <= end:
            compacted = compact_text(section, max_chars)
            compacted["header"] = header
            matches.append(compacted)

    return {
        "path": rel(path, root),
        "exists": True,
        "chars": len(text),
        "matching_sections": matches,
    }


def day_payload(root: Path, cur: date, max_chars: int) -> dict[str, Any]:
    journal = root / "workspace" / "journals" / f"{cur.isoformat()}.md"
    log = root / "workspace" / "logs" / f"{cur.isoformat()}.md"
    if journal.is_file():
        source = "journal"
        path = journal
    elif log.is_file():
        source = "log"
        path = log
    else:
        return {"date": cur.isoformat(), "source": "none", "activity_level": "no-activity"}

    text = read_text(path)
    payload = compact_text(text, max_chars)
    payload.update({
        "date": cur.isoformat(),
        "source": source,
        "path": rel(path, root),
        "activity_level": activity_level(text),
    })
    return payload


def build_payload(args: argparse.Namespace) -> dict[str, Any]:
    start = parse_iso(args.start)
    end = parse_iso(args.end)
    if end < start:
        raise SystemExit("workspace-data-scan.py: END_DATE precedes START_DATE")

    root = Path(args.root).resolve() if args.root else NASE_ROOT
    workspace = root / "workspace"
    tasks = workspace / "tasks"
    kb = workspace / "kb"
    include_broad_state = args.scope == "range"

    return {
        "date_range": {"start": start.isoformat(), "end": end.isoformat()},
        "scope": args.scope,
        "workspace_state": {
            "context_md": (
                file_payload(workspace / "context.md", root, args.max_state_chars)
                if include_broad_state
                else skipped_payload(workspace / "context.md", root, "scope=day")
            ),
            "todo_md": file_payload(tasks / "todo.md", root, args.max_state_chars),
            "domain_map_md": (
                file_payload(kb / ".domain-map.md", root, args.max_state_chars)
                if include_broad_state
                else skipped_payload(kb / ".domain-map.md", root, "scope=day")
            ),
            "lessons_md": lessons_payload(
                tasks / "lessons.md",
                root,
                start,
                end,
                args.max_lesson_section_chars,
            ),
        },
        "days": [day_payload(root, cur, args.max_day_chars) for cur in iter_days(start, end)],
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("start", help="START_DATE YYYY-MM-DD")
    parser.add_argument("end", help="END_DATE YYYY-MM-DD")
    parser.add_argument("--root", help="nase repo root")
    parser.add_argument("--scope", choices=("day", "range"), default="range")
    parser.add_argument("--max-state-chars", type=int, default=8000)
    parser.add_argument("--max-day-chars", type=int, default=12000)
    parser.add_argument("--max-lesson-section-chars", type=int, default=4000)
    parser.add_argument("--compact", action="store_true", help="Emit compact JSON without indentation")
    args = parser.parse_args(argv)

    payload = build_payload(args)
    if args.compact:
        json.dump(payload, sys.stdout, sort_keys=True, separators=(",", ":"))
    else:
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
