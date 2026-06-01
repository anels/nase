#!/usr/bin/env python3
"""
today-stats.py — Emit a single date's session, token, and skill-usage counts.

Used by /nase:wrap-up Step 4d. Replaces two inline python heredocs that
previously lived in wrap-up.md (sessions+tokens block, skill-usage block).

Usage: python3 .claude/scripts/today-stats.py [--date YYYY-MM-DD] [--workspace NAME] [--root PATH]

Defaults:
  --date       today (YYYY-MM-DD)
  --workspace  auto — parsed from workspace/config.md (`workspace:` line)
  --root       auto — derived from script location (`__file__`'s grandparent)

Output (stdout, key=value lines):
  sessions=<int>
  input_tokens=<int>
  output_tokens=<int>
  total_tokens=<int>
  note=<reason>                 # only present when sessions stayed 0 due to missing data
  total_invocations=<int>
  unique_skills=<int>
  skill <name> <count>          # repeated, descending; absent when no invocations

Exit 0 always — missing inputs degrade to zeros + a `note=` line so the
caller can render "no data yet" without failing the wrap-up.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date, datetime, time, timedelta
from pathlib import Path

NASE_ROOT = Path(__file__).resolve().parents[2]
PROMPT_TOOL_DEDUPE_WINDOW = timedelta(seconds=60)


def read_workspace_name(root: Path) -> str:
    cfg = root / "workspace" / "config.md"
    if not cfg.is_file():
        return ""
    for line in cfg.read_text(errors="ignore").splitlines():
        m = re.match(r"^\s*workspace:\s*(\S+)", line)
        if m:
            return m.group(1).strip().strip("/")
    return ""


def collect_session_tokens(today: str, workspace_name: str) -> dict:
    meta_dir = Path.home() / ".claude" / "usage-data" / "session-meta"
    if not meta_dir.is_dir():
        return {"sessions": 0, "input_tokens": 0, "output_tokens": 0,
                "total_tokens": 0, "note": "no-session-meta-dir"}
    today_epoch = datetime.combine(date.fromisoformat(today), time.min).timestamp()
    sessions = 0
    input_tok = 0
    output_tok = 0
    for f in meta_dir.glob("*.json"):
        try:
            if f.stat().st_mtime < today_epoch:
                continue
            d = json.loads(f.read_text())
        except Exception:
            continue
        if not d.get("start_time", "").startswith(today):
            continue
        if workspace_name and not d.get("project_path", "").endswith(workspace_name):
            continue
        sessions += 1
        input_tok += int(d.get("input_tokens", 0) or 0)
        output_tok += int(d.get("output_tokens", 0) or 0)
    return {"sessions": sessions, "input_tokens": input_tok,
            "output_tokens": output_tok, "total_tokens": input_tok + output_tok}


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
        description="Emit today's session/token/skill-usage counts as key=value lines.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--date", default=date.today().isoformat(),
                        help="ISO date to query (default: today)")
    parser.add_argument("--workspace", default=None,
                        help="workspace name (default: read from workspace/config.md)")
    parser.add_argument("--root", default=None,
                        help="nase repo root (default: derived from script location via __file__)")
    args = parser.parse_args()

    root = Path(args.root) if args.root else NASE_ROOT
    workspace_name = args.workspace if args.workspace is not None else read_workspace_name(root)

    sess = collect_session_tokens(args.date, workspace_name)
    print(f"sessions={sess['sessions']}")
    print(f"input_tokens={sess['input_tokens']}")
    print(f"output_tokens={sess['output_tokens']}")
    print(f"total_tokens={sess['total_tokens']}")
    if "note" in sess:
        print(f"note={sess['note']}")

    counts = collect_skill_usage(root, args.date)
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
    print(f"total_invocations={sum(counts.values())}")
    print(f"unique_skills={len(counts)}")
    for skill, n in ranked:
        print(f"skill {skill} {n}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
