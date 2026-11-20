#!/usr/bin/env python3
"""Shared rule for counting skill uses in workspace/stats/skill-usage.jsonl.

One invocation can write several records: a typed `/nase:x` emits `requested` and
`activated`, and the Skill tool then emits `tool_succeeded` or `tool_failed` for the
same run. Counting every record over-counts, so every script that reports a use count
calls `dedupe_uses` and reads the same number. Do not copy this logic into a report.

An event is a dict with `skill`, `dt` (timezone-aware datetime), `event_type`,
`source` and `session`. Records without an `event_type` are the legacy shape.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timedelta

PROMPT_TOOL_DEDUPE_WINDOW = timedelta(seconds=60)
PROMPT_SOURCES = frozenset({"prompt", "prompt-expansion"})
LEGACY_SESSION = "legacy"


def normalize_skill(name: str) -> str:
    """The ledger sometimes carries the `nase:` namespace and sometimes not."""
    return name.removeprefix("nase:")


def _within_window(dt: datetime, anchors: list[datetime]) -> bool:
    return any(timedelta(0) <= dt - anchor <= PROMPT_TOOL_DEDUPE_WINDOW for anchor in anchors)


def dedupe_uses(events: list[dict]) -> list[dict]:
    """Return the events that count as one use each, in time order.

    - `activated` is a use and the anchor a later tool outcome may duplicate. It comes
      from UserPromptExpansion, so it never duplicates anything itself.
    - `tool_succeeded` and `tool_failed` are uses unless they fall within 60s after an
      anchor in the same session. A skill reached through the Skill tool (model-invoked
      or nested) emits only these, so they must count, and a failed call was still a use.
    - `requested` and unknown event types are not evidence of a run.
    - Legacy records (no `event_type`) dedupe against each other, because one run could
      write up to three of them.
    """
    anchors: defaultdict[tuple[str, str], list[datetime]] = defaultdict(list)
    legacy: defaultdict[tuple[str, str], list[datetime]] = defaultdict(list)
    kept: list[dict] = []
    # Sort on the datetime, not the raw stamp: a string sort over mixed `Z` and `+HH:MM`
    # stamps compares wall clocks and can put an outcome ahead of its prompt.
    # At equal times the anchor goes first, so an outcome never beats its own prompt.
    for event in sorted(events, key=lambda e: (e["dt"], e["event_type"] != "activated")):
        key = (event["skill"], str(event["session"] or LEGACY_SESSION))
        dt = event["dt"]
        event_type = str(event["event_type"] or "")
        if event_type == "activated":
            anchors[key].append(dt)
            kept.append(event)
        elif event_type in ("tool_succeeded", "tool_failed"):
            if not _within_window(dt, anchors[key]):
                kept.append(event)
        elif event_type:
            continue
        else:
            if _within_window(dt, legacy[key]):
                continue
            legacy[key].append(dt)
            if str(event["source"]) in PROMPT_SOURCES:
                anchors[key].append(dt)
            kept.append(event)
    return kept
