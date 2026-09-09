#!/usr/bin/env python3
"""Shared time primitives, split by which clock the value came from.

This repo reads two kinds of timestamp and they are not interchangeable. Telemetry
(JSONL events, archive manifests, `gh` payloads) carries an instant, and the only
correct reading of an instant is UTC. Workspace state (daily log filenames, effort
frontmatter, `Last updated:` marks, `--date` arguments) carries a calendar day, and
the only correct reading of a calendar day is the user's local one.

Mixing them is silent: subtracting a UTC date from a local date is off by one for
part of every day at any non-zero offset, and the result is a plausible number, not
an error. Each function below names the clock it answers for, so a call site cannot
pick the wrong one by accident.
"""

from __future__ import annotations

from datetime import date, datetime, timezone


def parse_ts(value: str) -> datetime | None:
    """Read an instant from telemetry and return it in UTC, or None if unreadable.

    A value with no offset is read as UTC rather than local: everything this repo
    writes stamps UTC, so a missing offset is an omission, not a local reading.
    """
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except Exception:
        return None


def local_today() -> date:
    """The user's calendar day.

    This is what a `workspace/logs/YYYY-MM-DD.md` filename means and what a `--date`
    default should be. A `parse_ts` result is a UTC instant and is not comparable with
    this until `.astimezone().date()` has moved it onto the same clock.
    """
    return datetime.now().astimezone().date()


def local_now() -> datetime:
    """Local wall-clock time, timezone-aware.

    For comparing against a calendar date read by `calendar_day`. Use
    `datetime.now(timezone.utc)` instead when the other side is an instant.
    """
    return datetime.now().astimezone()


def calendar_day(raw: str) -> datetime:
    """Read a `YYYY-MM-DD` calendar date as local midnight, timezone-aware.

    Raises `ValueError` on a malformed value, exactly as `strptime` does, so callers
    keep their existing failure handling.
    """
    return datetime.strptime(raw, "%Y-%m-%d").astimezone()
