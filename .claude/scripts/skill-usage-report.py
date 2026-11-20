#!/usr/bin/env python3
"""Generate a skill usage and context-cost report from local JSONL telemetry."""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from pathlib import Path
from typing import cast

from nase_json import parse_jsonl_objects
from nase_skill_usage import dedupe_uses, normalize_skill
from nase_time import local_today, parse_ts


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
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parents[2]
    )
    parser.add_argument("--jsonl", type=Path)
    parser.add_argument("--date", type=date.fromisoformat, default=local_today())
    parser.add_argument("--window", type=int, default=60)
    parser.add_argument("--top", type=int, default=10)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--print-report", action="store_true")
    return parser.parse_args()


def parse_timestamp(raw: object) -> datetime | None:
    if not isinstance(raw, str) or not raw:
        return None
    value = parse_ts(raw)
    return value.astimezone() if value else None


def read_events(path: Path) -> tuple[list[dict[str, object]], int]:
    events: list[dict[str, object]] = []
    with path.open(encoding="utf-8", errors="replace") as handle:
        objects, malformed = parse_jsonl_objects(handle)
    for data in objects:
        skill = data.get("skill")
        timestamp = parse_timestamp(data.get("ts"))
        if not isinstance(skill, str) or not skill or timestamp is None:
            malformed += 1
            continue
        events.append(
            {
                "skill": normalize_skill(skill),
                "dt": timestamp,
                "event_type": data.get("event_type", ""),
                "source": data.get("source", ""),
                "session": data.get("session_id") or "legacy",
            }
        )
    return sorted(events, key=lambda item: item["dt"]), malformed


def aggregate(
    events: list[dict[str, object]], report_date: date
) -> dict[str, dict[str, object]]:
    outcomes: defaultdict[str, dict[str, int]] = defaultdict(
        lambda: {"success": 0, "failure": 0}
    )
    end = datetime.combine(report_date, time.max).astimezone()
    in_window = [event for event in events if cast(datetime, event["dt"]) <= end]

    for event in in_window:
        event_type = event["event_type"]
        if event_type in ("tool_succeeded", "tool_failed"):
            outcomes[str(event["skill"])][
                "success" if event_type == "tool_succeeded" else "failure"
            ] += 1

    # The counting rule lives in nase_skill_usage so /nase:wrap-up and /nase:stats
    # (today-stats.py) report the same number as this report.
    uses: defaultdict[str, list[datetime]] = defaultdict(list)
    for event in dedupe_uses(in_window):
        uses[str(event["skill"])].append(event["dt"])

    result: dict[str, dict[str, object]] = {}
    for skill in sorted(set(uses) | set(outcomes)):
        timestamps = uses[skill]
        successes = outcomes[skill]["success"]
        failures = outcomes[skill]["failure"]
        observed = successes + failures
        last = max(timestamps, default=None)
        result[skill] = {
            "total": len(timestamps),
            "last_30d": sum(
                end - value <= timedelta(days=30)
                for value in timestamps
                if value <= end
            ),
            "last_7d": sum(
                end - value <= timedelta(days=7) for value in timestamps if value <= end
            ),
            "last_used": last.date().isoformat() if last else "never",
            "days_since_last": max(0, (report_date - last.date()).days)
            if last
            else None,
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
            entries[name] = CatalogEntry(
                name, source, path, len(text.encode()), len(text.splitlines())
            )
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
    # Telemetry for a skill that is no longer on disk is history, not a skill: listing
    # it inflates "used" and reads as a deprecation candidate for something already gone.
    for name in sorted(entries):
        entry = entries[name]
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
                "source": entry.source,
                "bytes": entry.bytes,
                "lines": entry.lines,
                "estimated_tokens": entry.estimated_tokens,
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
    lines.extend(
        f"| {row['skill']} | {row['total']} | {row['last_7d']} | {row['last_30d']} | "
        f"{row['last_used']} | {rate(row['tool_success_rate'])} |"
        for row in rows
    )
    return lines


def render(
    rows: list[dict[str, object]], report_date: date, window: int, malformed: int
) -> str:
    counts = {
        name: sum(row["tier"] == name for row in rows)
        for name in ("hot", "active", "cold", "inactive", "unused")
    }
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

    hotspots = sorted(
        rows,
        key=lambda row: (int(row["weighted_tokens"]), int(row["bytes"])),
        reverse=True,
    )
    lines.extend(
        [
            "",
            "## Context Hotspots",
            "",
            "Approximate raw first-load tokens use `entry bytes / 4`; weighted tokens multiply that by observed uses. Tokenizer, caching, and compaction can change billed usage.",
            "",
            "| Skill | Uses | Entry bytes | Est. tokens/load | Weighted tokens |",
            "|---|--:|--:|--:|--:|",
        ]
    )
    lines.extend(
        f"| {row['skill']} | {row['total']} | {row['bytes']} | "
        f"{row['estimated_tokens']} | {row['weighted_tokens']} |"
        for row in hotspots[:15]
    )

    candidates = [row for row in rows if row["tier"] in {"cold", "unused"}]
    lines.extend(["", "## Suggested deprecation candidates", ""])
    if not candidates:
        lines.append("None.")
    for row in candidates:
        reason = (
            "unused"
            if row["tier"] == "unused"
            else f"last used {row['days_since_last']} days ago"
        )
        lines.append(
            f"- {row['skill']} - {reason}; validate independent value before removal"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    if args.window < 1 or args.top < 1:
        raise SystemExit("--window and --top must be positive")
    root = args.root.resolve()
    jsonl = (args.jsonl or root / "workspace" / "stats" / "skill-usage.jsonl").resolve()
    if not jsonl.is_file():
        print(
            json.dumps(
                {"ok": False, "reason": "No skill usage data", "jsonl": str(jsonl)}
            )
        )
        return 0

    events, malformed = read_events(jsonl)
    rows = merged_rows(aggregate(events, args.date), catalog(root), args.window)
    report = render(rows, args.date, args.window, malformed)
    output = (
        args.output
        or root / "workspace" / "stats" / f"skill-usage-{args.date.isoformat()}.md"
    ).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(report, encoding="utf-8")
    if args.print_report:
        print(report, end="")

    ordered = sorted(
        rows, key=lambda row: (int(row["total"]), int(row["last_7d"])), reverse=True
    )
    counts = {
        name: sum(row["tier"] == name for row in rows)
        for name in ("hot", "active", "cold", "inactive", "unused")
    }
    print(
        json.dumps(
            {
                "ok": True,
                "output": str(output),
                "counts": counts,
                "top": [
                    {"skill": row["skill"], "total": row["total"]}
                    for row in ordered[: args.top]
                ],
                "malformed": malformed,
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
