#!/usr/bin/env python3
"""Read-only quality scan for workspace KB/log drift."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from typing import Any

from nase_time import parse_ts


LOG_NAME_RE = re.compile(r"^(20\d\d-\d\d-\d\d)\.md$")
CANONICAL_SESSION_RE = re.compile(r"^- \d{2}:\d{2} \| [a-z0-9][a-z0-9:-]*: .+")
PLACEHOLDER_RE = re.compile(r"\b(FILL_IN|TBD|TO_BE_FILLED|FIXME_PLACEHOLDER)\b", re.I)
REFRESH_RE = re.compile(r"^###\s+20\d\d-\d\d-\d\d\s+[—-]\s+refresh\b", re.I)
HEARTBEAT_RE = re.compile(
    r"\b(no new commits since|head remains|head verified|unchanged|no action needed|"
    r"\d+\s+commits?\s+since|commit-count|ownership-count)\b",
    re.I,
)
SESSION_LINE_LIMIT = 500
UNKNOWN_RATE_THRESHOLD = 0.20


def resolve_root(explicit: str | None) -> pathlib.Path:
    if explicit:
        return pathlib.Path(explicit).expanduser().resolve()
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


def finding(category: str, path: pathlib.Path | str, message: str, line: int | None = None) -> dict[str, Any]:
    item: dict[str, Any] = {
        "category": category,
        "path": pathlib.PurePath(path).as_posix(),
        "message": message,
    }
    if line is not None:
        item["line"] = line
    return item


def log_files(root: pathlib.Path, days: int) -> list[pathlib.Path]:
    logs = root / "workspace" / "logs"
    if not logs.is_dir():
        return []
    cutoff = date_cutoff(days)
    selected: list[pathlib.Path] = []
    for path in sorted(logs.glob("*.md")):
        if path.name.endswith("-sre-tracker.md"):
            continue
        match = LOG_NAME_RE.match(path.name)
        if not match:
            continue
        try:
            day = date.fromisoformat(match.group(1))
        except ValueError:
            continue
        if day >= cutoff:
            selected.append(path)
    return selected


def date_cutoff(days: int) -> date:
    try:
        return date.today() - timedelta(days=max(days, 0))
    except OverflowError:
        return date.min


def datetime_cutoff(days: int) -> datetime:
    try:
        return datetime.now(timezone.utc) - timedelta(days=max(days, 0))
    except OverflowError:
        return datetime.min.replace(tzinfo=timezone.utc)


def scan_daily_logs(root: pathlib.Path, days: int) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    for path in log_files(root, days):
        rel = path.relative_to(root)
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        if not lines or not lines[0].startswith("# Work Log"):
            issues.append(finding("daily_log_missing_header", rel, "Daily log must start with '# Work Log'."))
        if not any(line.strip() == "## Sessions" for line in lines):
            issues.append(finding("daily_log_missing_sessions", rel, "Daily log must contain a '## Sessions' section."))

        in_sessions = False
        for idx, line in enumerate(lines, 1):
            if line.strip() == "## Sessions":
                in_sessions = True
                continue
            if in_sessions and line.startswith("## "):
                in_sessions = False
            if not in_sessions or not line.startswith("- "):
                continue
            if not CANONICAL_SESSION_RE.match(line):
                issues.append(
                    finding(
                        "daily_log_noncanonical_session",
                        rel,
                        "Session entry must use '- HH:MM | skill: summary'.",
                        idx,
                    )
                )
            if len(line) > SESSION_LINE_LIMIT:
                issues.append(
                    finding(
                        "daily_log_oversized_session",
                        rel,
                        f"Session entry exceeds {SESSION_LINE_LIMIT} characters.",
                        idx,
                    )
                )
    return issues


def scan_kb(root: pathlib.Path) -> list[dict[str, Any]]:
    kb = root / "workspace" / "kb"
    if not kb.is_dir():
        return []
    issues: list[dict[str, Any]] = []
    for path in sorted(kb.rglob("*.md")):
        if path.name == ".domain-map.md":
            continue
        rel = path.relative_to(root)
        for idx, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if PLACEHOLDER_RE.search(line):
                issues.append(finding("kb_placeholder", rel, "Unresolved placeholder in KB content.", idx))
            if REFRESH_RE.match(line):
                issues.append(finding("kb_refresh_block", rel, "Low-value dated refresh block should be compacted.", idx))
            if HEARTBEAT_RE.search(line):
                issues.append(finding("kb_heartbeat", rel, "Git-recoverable heartbeat fact should not be durable KB.", idx))
    return issues


def scan_kb_usage(root: pathlib.Path, days: int) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    path = root / "workspace" / "stats" / "kb-usage.jsonl"
    if not path.is_file():
        return [], {"events": 0, "unknown": 0, "unknown_rate": 0.0}

    cutoff = datetime_cutoff(days)
    total = 0
    unknown = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            payload = json.loads(line)
        except Exception:
            continue
        ts = parse_ts(str(payload.get("ts", "")))
        if ts is None or ts < cutoff:
            continue
        skill = str(payload.get("skill", "") or "unknown")
        total += 1
        if skill == "unknown":
            unknown += 1

    rate = (unknown / total) if total else 0.0
    issues: list[dict[str, Any]] = []
    if total and rate > UNKNOWN_RATE_THRESHOLD:
        issues.append(
            finding(
                "kb_usage_unknown_rate",
                "workspace/stats/kb-usage.jsonl",
                f"KB usage attribution is {unknown}/{total} unknown ({rate:.0%}).",
            )
        )
    return issues, {"events": total, "unknown": unknown, "unknown_rate": rate}


def stale_active_skill_files(root: pathlib.Path) -> int:
    tmp = root / "workspace" / "tmp"
    if not tmp.is_dir():
        return 0
    cutoff = datetime.now(timezone.utc) - timedelta(days=7)
    count = 0
    for path in tmp.glob("kb-active-skill-*.json"):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            ts = parse_ts(str(payload.get("ts", "")))
            if ts is None:
                ts = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
        except Exception:
            try:
                ts = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc)
            except OSError:
                continue
        if ts < cutoff:
            count += 1
    return count


def build_report(root: pathlib.Path, days: int) -> dict[str, Any]:
    findings: list[dict[str, Any]] = []
    findings.extend(scan_daily_logs(root, days))
    findings.extend(scan_kb(root))
    usage_findings, usage_summary = scan_kb_usage(root, days)
    findings.extend(usage_findings)

    counts = Counter(item["category"] for item in findings)
    return {
        "root": str(root),
        "days": days,
        "summary": {
            "total": len(findings),
            "daily_log_findings": sum(count for cat, count in counts.items() if cat.startswith("daily_log_")),
            "kb_findings": sum(count for cat, count in counts.items() if cat.startswith("kb_")),
            "kb_usage": usage_summary,
            "stale_active_skill_files": stale_active_skill_files(root),
            "categories": dict(sorted(counts.items())),
        },
        "findings": sorted(findings, key=lambda item: (item["category"], item["path"], item.get("line", 0))),
    }


def print_text(report: dict[str, Any], limit: int = 20) -> None:
    summary = report["summary"]
    print(f"Workspace quality scan: {summary['total']} finding(s), days={report['days']}")
    print(f"- Daily log findings: {summary['daily_log_findings']}")
    print(f"- KB findings: {summary['kb_findings']}")
    usage = summary["kb_usage"]
    if usage["events"]:
        print(f"- KB usage unknown: {usage['unknown']}/{usage['events']} ({usage['unknown_rate']:.0%})")
    print(f"- Stale active-skill context files: {summary['stale_active_skill_files']}")
    for item in report["findings"][:limit]:
        line = f":{item['line']}" if "line" in item else ""
        print(f"  {item['category']}: {item['path']}{line} — {item['message']}")
    if len(report["findings"]) > limit:
        print(f"  ... {len(report['findings']) - limit} more finding(s)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", help="workspace root; defaults to git top-level")
    parser.add_argument("--days", type=int, default=30, help="daily-log lookback window")
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument("--strict", action="store_true", help="exit nonzero when findings exist")
    args = parser.parse_args(argv)

    report = build_report(resolve_root(args.root), args.days)
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print_text(report)
    return 1 if args.strict and report["summary"]["total"] else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
