#!/usr/bin/env python3
"""
today-stats.py — Emit a single date's skill-usage counts.

Used by /nase:wrap-up Step 4d. Token/session accounting was removed: it read
~/.claude/usage-data/session-meta/, which is not populated in every harness, so
the numbers were unreliable. Skill ranking comes from workspace/stats/skill-usage.jsonl
(written by the skill-tracking hooks) and is reliable.

Usage: python3 .claude/scripts/today-stats.py [--date YYYY-MM-DD] [--root PATH]

Defaults:
  --date  today (YYYY-MM-DD)
  --root  auto — derived from script location (`__file__`'s grandparent)

Output (stdout, key=value lines):
  total_invocations=<int>
  unique_skills=<int>
  skill <name> <count>          # repeated, descending; absent when no invocations

Exit 0 always — missing inputs degrade to zeros so the caller can render
"no data yet" without failing the wrap-up.
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

NASE_ROOT = Path(__file__).resolve().parents[2]
PROMPT_TOOL_DEDUPE_WINDOW = timedelta(seconds=60)


def collect_skill_usage(root: Path, today: str) -> dict:
    """Tolerant JSON parser for mixed-shape JSONL (compact + pretty-printed)."""
    path = root / "workspace" / "stats" / "skill-usage.jsonl"
    records: list[dict] = []
    if not path.is_file():
        return {}
    text = path.read_text(errors="ignore")
    decoder = json.JSONDecoder()
    idx = 0
    n = len(text)
    today_seen = False
    while idx < n:
        while idx < n and text[idx] in " \t\r\n,":
            idx += 1
        if idx >= n:
            break
        try:
            d, end = decoder.raw_decode(text, idx)
        except json.JSONDecodeError:
            nl = text.find("\n", idx)
            if nl == -1:
                break
            idx = nl + 1
            continue
        idx = end
        if isinstance(d, dict):
            ts = d.get("ts", "")
            if ts.startswith(today):
                today_seen = True
                skill = d.get("skill")
                if skill:
                    records.append({
                        "skill": skill,
                        "ts": ts,
                        "source": d.get("source", ""),
                        "dt": parse_event_ts(ts),
                    })
            elif today_seen and ts > today:
                break
    counts: dict[str, int] = {}
    for event in dedupe_prompt_tool_events(records):
        skill = event["skill"]
        counts[skill] = counts.get(skill, 0) + 1
    return counts


def dedupe_prompt_tool_events(records: list[dict]) -> list[dict]:
    prompt_times: dict[str, list[datetime]] = {}
    kept: list[dict] = []
    for event in sorted(records, key=lambda e: e["ts"]):
        skill = event["skill"]
        dt = event["dt"]
        if event["source"] == "prompt":
            kept.append(event)
            if dt is not None:
                prompt_times.setdefault(skill, []).append(dt)
            continue
        if dt is not None:
            recent_prompt = any(
                timedelta(0) <= (dt - prompt_dt) <= PROMPT_TOOL_DEDUPE_WINDOW
                for prompt_dt in prompt_times.get(skill, [])
            )
            if recent_prompt:
                continue
        kept.append(event)
    return kept


def parse_event_ts(ts: str) -> datetime | None:
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except ValueError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Emit today's skill-usage counts as key=value lines.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--date", default=date.today().isoformat(),
                        help="ISO date to query (default: today)")
    parser.add_argument("--root", default=None,
                        help="nase repo root (default: derived from script location via __file__)")
    parser.add_argument("--workspace", default=None, help=argparse.SUPPRESS)
    args = parser.parse_args()

    root = Path(args.root) if args.root else NASE_ROOT

    counts = collect_skill_usage(root, args.date)
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    print(f"total_invocations={sum(counts.values())}")
    print(f"unique_skills={len(counts)}")
    for skill, n in ranked:
        print(f"skill {skill} {n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
