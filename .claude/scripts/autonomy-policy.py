#!/usr/bin/env python3
"""Resolve the workspace autonomy level into one decision per mutation class.

`workspace/config.md` carries a `## Autonomy` section with `level: guided |
standard | auto`. A missing section or key means `guided`, so an unconfigured
workspace keeps the pre-autonomy behavior. An unrecognized level also degrades
to `guided` instead of guessing upward.

Classes and their per-level decisions are documented in
`.claude/docs/external-mutation-policy.md -> Autonomy level`. This script
mirrors that table so a skill never re-implements it; the two must change
together, and `tests/scripts/test-autonomy-policy.sh` fails when they drift.

Usage:
    python3 .claude/scripts/autonomy-policy.py --class jira-transition-progress
    python3 .claude/scripts/autonomy-policy.py --list

Output is one JSON object per line on stdout. The caller reads `decision`:
`auto` skips the human stop (never the manifest binding, drift checks, hooks,
or audit line), `ask` stops for a confirmation, `never` must always stop.
Exit codes: 0 for a resolved decision (including unknown class -> ask), 2 for a
usage error only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LEVELS = ("guided", "standard", "auto")

# class -> {level: decision}. Order is the documentation order.
CLASSES: dict[str, dict[str, str]] = {
    "workspace-append": {"guided": "ask", "standard": "auto", "auto": "auto"},
    "slack-draft": {"guided": "ask", "standard": "auto", "auto": "auto"},
    "jira-transition-progress": {"guided": "ask", "standard": "auto", "auto": "auto"},
    "jira-comment-approved": {"guided": "ask", "standard": "auto", "auto": "auto"},
    "pr-mark-ready": {"guided": "ask", "standard": "auto", "auto": "auto"},
    "worktree-cleanup": {"guided": "ask", "standard": "auto", "auto": "auto"},
    "workspace-durable-write": {"guided": "ask", "standard": "ask", "auto": "auto"},
    "pr-create-draft": {"guided": "ask", "standard": "ask", "auto": "auto"},
    "pr-label": {"guided": "ask", "standard": "ask", "auto": "auto"},
    "pr-request-review": {"guided": "ask", "standard": "ask", "auto": "auto"},
    "jira-transition-other": {"guided": "ask", "standard": "ask", "auto": "auto"},
    "slack-send": {"guided": "never", "standard": "never", "auto": "never"},
    "merge": {"guided": "never", "standard": "never", "auto": "never"},
    "force-push": {"guided": "never", "standard": "never", "auto": "never"},
    "confluence-publish": {"guided": "never", "standard": "never", "auto": "never"},
    "review-other-pr": {"guided": "never", "standard": "never", "auto": "never"},
    "cloud-resource": {"guided": "never", "standard": "never", "auto": "never"},
    "ado-trigger": {"guided": "never", "standard": "never", "auto": "never"},
}

AUTONOMY_SECTION_RE = re.compile(r"^##\s+Autonomy\s*$", re.MULTILINE)
LEVEL_RE = re.compile(r"^\s*level\s*:\s*(\S+)\s*$", re.MULTILINE)


def read_level(root: Path) -> tuple[str, str]:
    """Return (level, reason) for the workspace at root."""
    config = root / "workspace" / "config.md"
    try:
        text = config.read_text(encoding="utf-8")
    except FileNotFoundError:
        return "guided", "no-config"
    except OSError as exc:
        return "guided", f"unreadable-config:{exc.__class__.__name__}"

    section = AUTONOMY_SECTION_RE.search(text)
    if not section:
        return "guided", "no-autonomy-section"
    tail = text[section.end():]
    next_section = re.search(r"^##\s+", tail, re.MULTILINE)
    body = tail[: next_section.start()] if next_section else tail
    match = LEVEL_RE.search(body)
    if not match:
        return "guided", "no-level"
    value = match.group(1).strip().strip("\"'").lower()
    if value not in LEVELS:
        return "guided", f"invalid-level:{value}"
    return value, "configured"


def decide(level: str, name: str) -> dict[str, str]:
    table = CLASSES.get(name)
    if table is None:
        return {
            "level": level,
            "class": name,
            "decision": "ask",
            "reason": "unknown-class",
        }
    return {
        "level": level,
        "class": name,
        "decision": table[level],
        "reason": "table",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[2]),
        help="nase repo root (default: the repo this script lives in)",
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--class", dest="name", help="mutation class to resolve")
    group.add_argument("--list", action="store_true", help="print every class at the current level")
    args = parser.parse_args(argv)

    level, reason = read_level(Path(args.root))
    if args.list:
        for name in CLASSES:
            row = decide(level, name)
            row["level_reason"] = reason
            print(json.dumps(row, sort_keys=True))
        return 0

    row = decide(level, args.name)
    row["level_reason"] = reason
    print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
