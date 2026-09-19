#!/usr/bin/env python3
"""
today-stats.py — Emit skill-usage counts for one local day or a day range.

Used by /nase:wrap-up Step 8 for a single day and by /nase:stats for its range.
Token/session accounting was removed: it read ~/.claude/usage-data/session-meta/,
which is not populated in every harness, so the numbers were unreliable. Skill
ranking comes from workspace/stats/skill-usage.jsonl (written by the
skill-tracking hooks) and is reliable.

Usage: python3 .claude/scripts/today-stats.py [--since YYYY-MM-DD] [--date YYYY-MM-DD] [--root PATH]

Defaults:
  --since same as --date (a one-day window)
  --date  today (YYYY-MM-DD), the last day of the window
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
from datetime import date, datetime, time, timedelta
from pathlib import Path

from nase_time import local_today, parse_ts

NASE_ROOT = Path(__file__).resolve().parents[2]
PROMPT_TOOL_DEDUPE_WINDOW = timedelta(seconds=60)


def collect_skill_usage(root: Path, first_day: date, last_day: date) -> dict:
    """Tolerant JSON parser for mixed-shape JSONL (compact + pretty-printed).

    The bounds are local calendar days and every event carries a UTC instant, so
    the filter is a local-midnight window rather than a prefix test on the stamp.
    Both ends are inclusive, and the window closes at the next local midnight, so
    a 23-hour spring-forward day does not reach into the following day.
    """
    path = root / "workspace" / "stats" / "skill-usage.jsonl"
    records: list[dict] = []
    if not path.is_file():
        return {}
    window_start = datetime.combine(first_day, time.min).astimezone()
    window_end = datetime.combine(last_day + timedelta(days=1), time.min).astimezone()
    text = path.read_text(errors="ignore")
    decoder = json.JSONDecoder()
    idx = 0
    n = len(text)
    window_seen = False
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
            dt = parse_ts(ts)
            if dt is None:
                continue
            if window_start <= dt < window_end:
                window_seen = True
                skill = d.get("skill")
                if skill:
                    records.append(
                        {
                            "skill": skill,
                            "source": d.get("source", ""),
                            "event_type": d.get("event_type", ""),
                            "session_id": d.get("session_id", ""),
                            "dt": dt,
                        }
                    )
            elif window_seen and dt >= window_end:
                break
    counts: dict[str, int] = {}
    for event in dedupe_prompt_tool_events(records):
        skill = event["skill"]
        counts[skill] = counts.get(skill, 0) + 1
    return counts


def dedupe_prompt_tool_events(records: list[dict]) -> list[dict]:
    # A string sort over mixed `Z` and `+HH:MM` stamps compares wall clocks and can put a
    # tool outcome ahead of the prompt it belongs to, which inverts the dedupe window.
    prompt_times: dict[tuple[str, str], list[datetime]] = {}
    kept: list[dict] = []
    for event in sorted(records, key=lambda e: e["dt"]):
        skill = event["skill"]
        dt = event["dt"]
        event_type = event["event_type"]
        session = event["session_id"] or "legacy"
        if event_type == "requested" or event_type == "tool_failed":
            continue
        if event_type == "activated":
            kept.append(event)
            prompt_times.setdefault((skill, session), []).append(dt)
            continue
        if event_type == "tool_succeeded":
            if near_prompt(dt, prompt_times.get((skill, session), [])):
                continue
            kept.append(event)
            continue
        if event["source"] in {"prompt", "prompt-expansion"}:
            kept.append(event)
            prompt_times.setdefault((skill, session), []).append(dt)
            continue
        if near_prompt(dt, prompt_times.get((skill, session), [])):
            continue
        kept.append(event)
    return kept


def near_prompt(dt: datetime, prompt_times: list[datetime]) -> bool:
    """Whether a tool outcome is the same invocation as a prompt already counted."""
    return any(
        timedelta(0) <= (dt - prompt_dt) <= PROMPT_TOOL_DEDUPE_WINDOW
        for prompt_dt in prompt_times
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Emit a day or day-range of skill-usage counts as key=value lines.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--date",
        type=date.fromisoformat,
        default=local_today(),
        help="Last local ISO date of the window (default: today)",
    )
    parser.add_argument(
        "--since",
        type=date.fromisoformat,
        default=None,
        help="First local ISO date of the window (default: --date, a one-day window)",
    )
    parser.add_argument(
        "--root",
        default=None,
        help="nase repo root (default: derived from script location via __file__)",
    )
    args = parser.parse_args()
    first_day = args.since or args.date
    if first_day > args.date:
        parser.error("--since must not be later than --date")

    root = Path(args.root) if args.root else NASE_ROOT

    counts = collect_skill_usage(root, first_day, args.date)
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    print(f"total_invocations={sum(counts.values())}")
    print(f"unique_skills={len(counts)}")
    for skill, n in ranked:
        print(f"skill {skill} {n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
