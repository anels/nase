#!/usr/bin/env python3
"""Build a KB usage report from workspace/stats/kb-usage.jsonl."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any


KB_EXTENSIONS = {".md", ".sql"}
VALID_ACCESS = {"read", "resolve", "search-result"}
VALID_SOURCE = {"read-hook", "kb-domain-resolve", "kb-search"}


def resolve_root(explicit: str | None = None) -> pathlib.Path:
    candidate = explicit or os.environ.get("NASE_ROOT")
    if candidate:
        return pathlib.Path(candidate).expanduser().resolve()
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return pathlib.Path(proc.stdout.strip()).resolve()
    except Exception:
        pass
    return pathlib.Path.cwd().resolve()


def parse_ts(value: str) -> datetime | None:
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except Exception:
        return None


def parse_now(value: str | None) -> datetime:
    if not value:
        return datetime.now(timezone.utc)
    parsed = parse_ts(value)
    if parsed is None:
        raise SystemExit(f"invalid --now value: {value}")
    return parsed


def normalize_kb_file(value: str) -> str | None:
    path = pathlib.PurePosixPath(value)
    parts = path.parts
    if len(parts) < 3 or parts[0] != "workspace" or parts[1] != "kb":
        return None
    normalized = path.as_posix()
    if normalized == "workspace/kb/.domain-map.md":
        return None
    if path.suffix.lower() not in KB_EXTENSIONS:
        return None
    return normalized


def load_events(root: pathlib.Path, now: datetime, window: str) -> tuple[list[dict[str, Any]], int]:
    jsonl = root / "workspace" / "stats" / "kb-usage.jsonl"
    if not jsonl.exists():
        return [], 0

    cutoff: datetime | None = None
    if window != "all":
        cutoff = now - timedelta(days=int(window))

    events: list[dict[str, Any]] = []
    malformed = 0
    for line in jsonl.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            payload = json.loads(line)
        except Exception:
            malformed += 1
            continue

        ts = parse_ts(str(payload.get("ts", "")))
        file_path = normalize_kb_file(str(payload.get("file", "")))
        skill = str(payload.get("skill", "") or "unknown")
        access = str(payload.get("access", ""))
        source = str(payload.get("source", ""))
        session = str(payload.get("session", "") or "unknown")
        if ts is None or file_path is None or access not in VALID_ACCESS or source not in VALID_SOURCE:
            malformed += 1
            continue
        if cutoff is not None and ts < cutoff:
            continue
        events.append(
            {
                "ts": ts,
                "skill": skill,
                "file": file_path,
                "access": access,
                "source": source,
                "session": session,
            }
        )
    return events, malformed


def load_mapped_files(root: pathlib.Path) -> set[str]:
    path = root / "workspace" / "kb" / ".domain-map.md"
    if not path.exists():
        return set()
    mapped: set[str] = set()
    pattern = re.compile(r"workspace/kb/[^\s`)]+?\.(?:md|sql)\b")
    for line in path.read_text(encoding="utf-8").splitlines():
        for match in pattern.findall(line):
            normalized = normalize_kb_file(match)
            if normalized:
                mapped.add(normalized)
    return mapped


def sorted_counter(counter: Counter[str]) -> list[tuple[str, int]]:
    return sorted(counter.items(), key=lambda item: (-item[1], item[0]))


def last_used(events: list[dict[str, Any]], key: str, value: str) -> str:
    timestamps = [event["ts"] for event in events if event[key] == value]
    if not timestamps:
        return "-"
    return max(timestamps).strftime("%Y-%m-%dT%H:%M:%SZ")


def table(headers: list[str], rows: list[list[str]]) -> list[str]:
    lines = [
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    if rows:
        lines.extend("| " + " | ".join(row) + " |" for row in rows)
    else:
        lines.append("| none |" + " |".join([""] * (len(headers) - 1)) + " |")
    return lines


def build_report(root: pathlib.Path, args: argparse.Namespace) -> tuple[str, dict[str, Any]]:
    now = parse_now(args.now)
    events, malformed = load_events(root, now, args.window)
    mapped = load_mapped_files(root)
    used_files = {event["file"] for event in events}
    used_skills = {event["skill"] for event in events}
    unused_mapped = sorted(mapped - used_files)

    file_counts = Counter(event["file"] for event in events)
    skill_counts = Counter(event["skill"] for event in events)
    source_counts = Counter((event["access"], event["source"]) for event in events)
    skills_by_file: dict[str, set[str]] = defaultdict(set)
    files_by_skill: dict[str, set[str]] = defaultdict(set)
    for event in events:
        skills_by_file[event["file"]].add(event["skill"])
        files_by_skill[event["skill"]].add(event["file"])

    top_n = int(args.top)
    top_files = sorted_counter(file_counts)[:top_n]
    top_skills = sorted_counter(skill_counts)[:top_n]
    source_rows = sorted(source_counts.items(), key=lambda item: (item[0][0], item[0][1]))
    report_date = now.date().isoformat()
    window_label = "all time" if args.window == "all" else f"last {args.window} days"

    lines: list[str] = [
        f"# KB Usage - {report_date}",
        "",
        "## Summary",
        f"- Window: {window_label}",
        f"- Events: {len(events)}",
        f"- KB files used: {len(used_files)}",
        f"- Skills using KB: {len(used_skills)}",
        f"- Unused mapped KB files: {len(unused_mapped)}",
        f"- Malformed lines skipped: {malformed}",
        "",
    ]

    if not events:
        lines.extend(["No KB usage data yet.", ""])

    file_rows = [
        [
            f"`{file_path}`",
            str(count),
            ", ".join(sorted(skills_by_file[file_path])) or "unknown",
            last_used(events, "file", file_path),
        ]
        for file_path, count in top_files
    ]
    lines.extend(["## Top KB Files", *table(["File", "Events", "Skills", "Last used"], file_rows), ""])

    skill_rows = [
        [
            f"`{skill}`",
            str(count),
            str(len(files_by_skill[skill])),
            last_used(events, "skill", skill),
        ]
        for skill, count in top_skills
    ]
    lines.extend(["## Top Skills", *table(["Skill", "Events", "Files", "Last used"], skill_rows), ""])

    source_table_rows = [[access, source, str(count)] for (access, source), count in source_rows]
    lines.extend(["## Access Source Breakdown", *table(["Access", "Source", "Events"], source_table_rows), ""])

    lines.append("## Unused Mapped KB Files")
    if unused_mapped:
        for file_path in unused_mapped:
            lines.append(f"- `{file_path}`")
    else:
        lines.append("- none")
    lines.append("")

    summary = {
        "window_label": window_label,
        "events": len(events),
        "kb_files": len(used_files),
        "skills": len(used_skills),
        "unused": len(unused_mapped),
        "top_files": top_files,
        "top_skills": top_skills,
        "malformed": malformed,
    }
    return "\n".join(lines), summary


def format_summary(summary: dict[str, Any], output: pathlib.Path | None) -> str:
    def render_top(items: list[tuple[str, int]]) -> str:
        if not items:
            return "none"
        return ", ".join(f"{name} ({count})" for name, count in items[:5])

    lines = [
        f"KB usage summary ({summary['window_label']})",
        f"- Events: {summary['events']}",
        f"- KB files used: {summary['kb_files']}",
        f"- Skills using KB: {summary['skills']}",
        f"- Unused mapped KB files: {summary['unused']}",
        f"- Top files: {render_top(summary['top_files'])}",
        f"- Top skills: {render_top(summary['top_skills'])}",
    ]
    if summary["malformed"]:
        lines.append(f"- Malformed lines skipped: {summary['malformed']}")
    if output is not None:
        lines.append(f"- Report: {output.as_posix()}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate KB usage telemetry report")
    parser.add_argument("--root")
    parser.add_argument("--window", default="30", help="day window, or all")
    parser.add_argument("--top", default=10, type=int)
    parser.add_argument("--output")
    parser.add_argument("--now", help="test-only current timestamp")
    parser.add_argument("--verbose", action="store_true", help="print the full report to stdout")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.window != "all":
        try:
            if int(args.window) < 0:
                raise ValueError
        except ValueError:
            parser.error("--window must be a non-negative integer or all")
    if args.top < 1:
        parser.error("--top must be a positive integer")

    root = resolve_root(args.root)
    report, summary = build_report(root, args)
    output_path = pathlib.Path(args.output).expanduser() if args.output else None
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(report + "\n", encoding="utf-8")

    if args.verbose or output_path is None:
        print(report)
    else:
        print(format_summary(summary, output_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
