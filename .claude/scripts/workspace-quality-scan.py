#!/usr/bin/env python3
"""Read-only quality scan for workspace content and state drift."""

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

from frontmatter_scalar import canonical_bool, extract_frontmatter_scalar, normalize_scalar
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
TMP_STALE_DAYS = 30
EFFORT_REF_RE = re.compile(r"workspace/efforts/[A-Za-z0-9_./-]+\.md")
TODO_CLOSED_RE = re.compile(r"^\s*-\s*\[[xX]\]")


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


def effort_status_vocabulary(root: pathlib.Path) -> tuple[set[str], set[str]]:
    path = root / ".claude" / "docs" / "effort-lifecycle.md"
    if not path.is_file():
        return set(), set()
    text = path.read_text(encoding="utf-8", errors="replace")
    section = re.search(r"^## Status Vocabulary\s*$\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    if not section:
        return set(), set()
    active, separator, done = section.group(1).partition("**Done**")
    if not separator:
        return set(), set()
    row = re.compile(r"^\|\s*`([^`]+)`\s*\|", re.MULTILINE)
    return set(row.findall(active)), set(row.findall(done))


def effort_scope_vocabulary(root: pathlib.Path) -> set[str]:
    path = root / ".claude" / "docs" / "effort-lifecycle.md"
    if not path.is_file():
        return set()
    text = path.read_text(encoding="utf-8", errors="replace")
    section = re.search(
        r"^## Scope Vocabulary\s*$\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL
    )
    if not section:
        return set()
    row = re.compile(r"^\|\s*`([^`]+)`\s*\|", re.MULTILINE)
    return set(row.findall(section.group(1)))


def scan_efforts(root: pathlib.Path) -> list[dict[str, Any]]:
    efforts = root / "workspace" / "efforts"
    if not efforts.is_dir():
        return []

    active_statuses, done_statuses = effort_status_vocabulary(root)
    if not active_statuses or not done_statuses:
        return [
            finding(
                "effort_status_contract_missing",
                ".claude/docs/effort-lifecycle.md",
                "Status Vocabulary cannot be parsed; effort validation is incomplete.",
            )
        ]

    canonical_scopes = effort_scope_vocabulary(root)

    issues: list[dict[str, Any]] = []
    if not canonical_scopes:
        issues.append(
            finding(
                "effort_scope_contract_missing",
                ".claude/docs/effort-lifecycle.md",
                "Scope Vocabulary cannot be parsed; scope validation is incomplete.",
            )
        )
    canonical = active_statuses | done_statuses
    candidates = [(path, active_statuses, "active") for path in sorted(efforts.glob("*.md"))]
    candidates.extend(
        (path, done_statuses, "done") for path in sorted((efforts / "done").glob("*.md"))
    )
    candidates.extend(
        (path, done_statuses, "archive")
        for path in sorted((efforts / "archive").glob("*/*.md"))
    )

    for path, expected, location in candidates:
        rel = path.relative_to(root)
        text = path.read_text(encoding="utf-8", errors="replace")
        raw_status = extract_frontmatter_scalar(text, "status")[0]
        status = None if raw_status is None else normalize_scalar(raw_status)
        if status is None:
            issues.append(finding("effort_missing_status", rel, "Effort frontmatter has no status."))
        elif status not in canonical:
            issues.append(
                finding(
                    "effort_invalid_status",
                    rel,
                    f"Effort status '{status}' is outside the canonical vocabulary.",
                )
            )
        elif status not in expected:
            issues.append(
                finding(
                    "effort_status_location_mismatch",
                    rel,
                    f"Effort status '{status}' does not match its {location} location.",
                )
            )
        if canonical_scopes:
            raw_scope = extract_frontmatter_scalar(text, "scope")[0]
            scope = None if raw_scope is None else normalize_scalar(raw_scope)
            if scope is None:
                issues.append(
                    finding("effort_missing_scope", rel, "Effort frontmatter has no scope.")
                )
            elif scope not in canonical_scopes:
                issues.append(
                    finding(
                        "effort_invalid_scope",
                        rel,
                        f"Effort scope '{scope}' is outside the canonical vocabulary.",
                    )
                )

        raw_tracking_only, singleton = extract_frontmatter_scalar(text, "tracking_only")
        tracking_only, tracking_only_valid = canonical_bool(raw_tracking_only)
        tracking_only_valid = tracking_only_valid and singleton
        if not tracking_only_valid:
            issues.append(
                finding(
                    "effort_invalid_tracking_only",
                    rel,
                    f"Effort tracking_only '{normalize_scalar(raw_tracking_only or '')}' must be unquoted true, false, or absent.",
                )
            )
        elif location == "done" and tracking_only:
            issues.append(
                finding(
                    "effort_tracking_only_destination_mismatch",
                    rel,
                    "Tracking-only effort is in done/ instead of the yearly archive.",
                )
            )
    return issues


def scan_todo(root: pathlib.Path) -> list[dict[str, Any]]:
    path = root / "workspace" / "tasks" / "todo.md"
    if not path.is_file():
        return []

    issues: list[dict[str, Any]] = []
    rel = path.relative_to(root)
    for idx, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if TODO_CLOSED_RE.match(line):
            issues.append(finding("todo_closed_item", rel, "Closed item remains in the open-work queue.", idx))
        for raw in EFFORT_REF_RE.findall(line):
            if not (root / raw).is_file():
                issues.append(
                    finding(
                        "todo_broken_effort_ref",
                        rel,
                        f"Effort reference does not resolve: {raw}",
                        idx,
                    )
                )
    return issues


def scan_tmp(root: pathlib.Path) -> tuple[list[dict[str, Any]], dict[str, int]]:
    tmp = root / "workspace" / "tmp"
    if not tmp.is_dir():
        return [], {"files": 0, "bytes": 0, "stale_files": 0, "stale_bytes": 0}

    cutoff = datetime.now(timezone.utc) - timedelta(days=TMP_STALE_DAYS)
    files = 0
    total_bytes = 0
    stale_files = 0
    stale_bytes = 0
    for path in tmp.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            stat = path.stat()
        except OSError:
            continue
        files += 1
        total_bytes += stat.st_size
        if datetime.fromtimestamp(stat.st_mtime, timezone.utc) < cutoff:
            stale_files += 1
            stale_bytes += stat.st_size

    summary = {
        "files": files,
        "bytes": total_bytes,
        "stale_files": stale_files,
        "stale_bytes": stale_bytes,
    }
    issues = []
    if stale_files:
        issues.append(
            finding(
                "tmp_stale_inventory",
                "workspace/tmp",
                f"Temporary storage has {stale_files} file(s) older than {TMP_STALE_DAYS} days; classify recoverable state before cleanup.",
            )
        )
    return issues, summary


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
    findings.extend(scan_efforts(root))
    findings.extend(scan_todo(root))
    tmp_findings, tmp_summary = scan_tmp(root)
    findings.extend(tmp_findings)
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
            "tmp": tmp_summary,
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
