#!/usr/bin/env python3
"""Generate a skill usage and context-cost report from local JSONL telemetry."""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path


LEGACY_DEDUPE = timedelta(seconds=60)


@dataclass(frozen=True)
class CatalogEntry:
    name: str
    source: str
    path: Path
    bytes: int
    lines: int

    @property
    def estimated_tokens(self) -> int:
        return math.ceil(self.bytes / 4)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--jsonl", type=Path)
    parser.add_argument("--date", type=date.fromisoformat, default=date.today())
    parser.add_argument("--window", type=int, default=60)
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--print-report", action="store_true")
    return parser.parse_args()


def parse_timestamp(raw: object) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    try:
        value = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone()


def read_events(path: Path) -> tuple[list[dict[str, object]], int]:
    events: list[dict[str, object]] = []
    malformed = 0
    with path.open(encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                malformed += 1
                continue
            skill = data.get("skill")
            timestamp = parse_timestamp(data.get("ts"))
            if not isinstance(skill, str) or not skill or timestamp is None:
                malformed += 1
                continue
            events.append(
                {
                    "skill": skill.removeprefix("nase:"),
                    "dt": timestamp,
                    "event_type": data.get("event_type", ""),
                    "source": data.get("source", ""),
                    "session": data.get("session_id") or "legacy",
                }
            )
    return sorted(events, key=lambda item: item["dt"]), malformed


def aggregate(events: list[dict[str, object]], report_date: date) -> dict[str, dict[str, object]]:
    uses: defaultdict[str, list[datetime]] = defaultdict(list)
    outcomes: defaultdict[str, dict[str, int]] = defaultdict(lambda: {"success": 0, "failure": 0})
    legacy_uses: defaultdict[tuple[str, str], list[datetime]] = defaultdict(list)
    end = datetime.combine(report_date, time.max).astimezone()

    for event in events:
        skill = str(event["skill"])
        event_type = str(event["event_type"])
        source = str(event["source"])
        session = str(event["session"])
        timestamp = event["dt"]
        assert isinstance(timestamp, datetime)
        if timestamp > end:
            continue

        if event_type:
            if event_type == "activated":
                uses[skill].append(timestamp)
            elif event_type == "tool_succeeded":
                outcomes[skill]["success"] += 1
            elif event_type == "tool_failed":
                outcomes[skill]["failure"] += 1
            continue

        key = (skill, session)
        if any(timedelta(0) <= timestamp - prior <= LEGACY_DEDUPE for prior in legacy_uses[key]):
            continue
        uses[skill].append(timestamp)
        legacy_uses[key].append(timestamp)

    result: dict[str, dict[str, object]] = {}
    for skill in sorted(set(uses) | set(outcomes)):
        timestamps = uses[skill]
        successes = outcomes[skill]["success"]
        failures = outcomes[skill]["failure"]
        observed = successes + failures
        last = max(timestamps, default=None)
        result[skill] = {
            "total": len(timestamps),
            "last_30d": sum(end - value <= timedelta(days=30) for value in timestamps if value <= end),
            "last_7d": sum(end - value <= timedelta(days=7) for value in timestamps if value <= end),
            "last_used": last.date().isoformat() if last else "never",
            "days_since_last": max(0, (report_date - last.date()).days) if last else None,
            "tool_successes": successes,
            "tool_failures": failures,
            "tool_success_rate": successes / observed if observed else None,
        }
    return result


def catalog(root: Path) -> dict[str, CatalogEntry]:
    entries: dict[str, CatalogEntry] = {}
    for source, base, prefix in (
        ("native", root / ".claude" / "commands" / "nase", ""),
        ("workspace", root / "workspace" / "skills", "workspace:"),
    ):
        if not base.is_dir():
            continue
        for path in sorted(base.glob("*.md")):
            name = f"{prefix}{path.stem}"
            text = path.read_text(encoding="utf-8", errors="replace")
            entries[name] = CatalogEntry(name, source, path, len(text.encode()), len(text.splitlines()))
    return entries


def tier(row: dict[str, object], window: int) -> str:
    total = int(row["total"])
    if int(row["last_7d"]) >= 3:
        return "hot"
    if int(row["last_30d"]) >= 1:
        return "active"
    days = row["days_since_last"]
    if total and isinstance(days, int) and days >= window:
        return "cold"
    if total == 0:
        return "unused"
    return "inactive"


def merged_rows(
    usage: dict[str, dict[str, object]], entries: dict[str, CatalogEntry], window: int
) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    for name in sorted(set(usage) | set(entries)):
        entry = entries.get(name)
        row = dict(
            usage.get(
                name,
                {
                    "total": 0,
                    "last_30d": 0,
                    "last_7d": 0,
                    "last_used": "never",
                    "days_since_last": None,
                    "tool_successes": 0,
                    "tool_failures": 0,
                    "tool_success_rate": None,
                },
            )
        )
        row.update(
            {
                "skill": name,
                "source": entry.source if entry else "telemetry-only",
                "bytes": entry.bytes if entry else 0,
                "lines": entry.lines if entry else 0,
                "estimated_tokens": entry.estimated_tokens if entry else 0,
            }
        )
        row["weighted_tokens"] = int(row["total"]) * int(row["estimated_tokens"])
        row["tier"] = tier(row, window)
        rows.append(row)
    return rows


def rate(value: object) -> str:
    return "n/a" if value is None else f"{float(value):.0%}"


def usage_table(rows: list[dict[str, object]]) -> list[str]:
    lines = [
        "| Skill | Total | 7d | 30d | Last used | Outcome |",
        "|---|--:|--:|--:|---|---:|",
    ]
    for row in rows:
        lines.append(
            f"| {row['skill']} | {row['total']} | {row['last_7d']} | {row['last_30d']} | "
            f"{row['last_used']} | {rate(row['tool_success_rate'])} |"
        )
    return lines


def render(rows: list[dict[str, object]], report_date: date, window: int, malformed: int) -> str:
    counts = {name: sum(row["tier"] == name for row in rows) for name in ("hot", "active", "cold", "inactive", "unused")}
    used = sum(int(row["total"]) > 0 for row in rows)
    native = sum(row["source"] == "native" for row in rows)
    workspace = sum(row["source"] == "workspace" for row in rows)
    lines = [
        f"# Skill Usage - {report_date.isoformat()}",
        "",
        "## Summary",
        "",
        f"- Total skills on disk: {native + workspace} (native: {native}, workspace: {workspace})",
        f"- Skills with at least one use: {used}",
        f"- Hot: {counts['hot']}; active: {counts['active']}; cold: {counts['cold']}; inactive: {counts['inactive']}; unused: {counts['unused']}",
        f"- Malformed telemetry records skipped: {malformed}",
    ]
    for name, heading in (
        ("hot", "Hot (last 7d)"),
        ("active", "Active (last 30d, not hot)"),
        ("cold", f"Cold ({window}+ days)"),
        ("inactive", f"Inactive (used, outside 30d but inside {window}d)"),
        ("unused", "Unused"),
    ):
        group = [row for row in rows if row["tier"] == name]
        lines.extend(["", f"## {heading}", ""])
        lines.extend(usage_table(group) if group else ["None."])

    hotspots = sorted(rows, key=lambda row: (int(row["weighted_tokens"]), int(row["bytes"])), reverse=True)
    lines.extend(
        [
            "",
            "## Context Hotspots",
            "",
            "Approximate raw first-load tokens use `entry bytes / 4`; weighted tokens multiply that by observed activations. Tokenizer, caching, and compaction can change billed usage.",
            "",
            "| Skill | Uses | Entry bytes | Est. tokens/load | Weighted tokens |",
            "|---|--:|--:|--:|--:|",
        ]
    )
    for row in hotspots[:15]:
        lines.append(
            f"| {row['skill']} | {row['total']} | {row['bytes']} | {row['estimated_tokens']} | {row['weighted_tokens']} |"
        )

    candidates = [row for row in rows if row["tier"] in {"cold", "unused"}]
    lines.extend(["", "## Suggested deprecation candidates", ""])
    if not candidates:
        lines.append("None.")
    for row in candidates:
        reason = "unused" if row["tier"] == "unused" else f"last used {row['days_since_last']} days ago"
        lines.append(f"- {row['skill']} - {reason}; validate independent value before removal")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    if args.window < 1 or args.top < 1:
        raise SystemExit("--window and --top must be positive")
    root = args.root.resolve()
    jsonl = (args.jsonl or root / "workspace" / "stats" / "skill-usage.jsonl").resolve()
    if not jsonl.is_file():
        print(json.dumps({"ok": False, "reason": "No skill usage data", "jsonl": str(jsonl)}))
        return 0

    events, malformed = read_events(jsonl)
    rows = merged_rows(aggregate(events, args.date), catalog(root), args.window)
    report = render(rows, args.date, args.window, malformed)
    output = (args.output or root / "workspace" / "stats" / f"skill-usage-{args.date.isoformat()}.md").resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(report, encoding="utf-8")
    if args.print_report:
        print(report, end="")

    ordered = sorted(rows, key=lambda row: (int(row["total"]), int(row["last_7d"])), reverse=True)
    counts = {name: sum(row["tier"] == name for row in rows) for name in ("hot", "active", "cold", "inactive", "unused")}
    print(
        json.dumps(
            {
                "ok": True,
                "output": str(output),
                "counts": counts,
                "top": [{"skill": row["skill"], "total": row["total"]} for row in ordered[: args.top]],
                "malformed": malformed,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
