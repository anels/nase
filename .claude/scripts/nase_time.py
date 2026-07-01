#!/usr/bin/env python3
"""Shared timestamp parsing for local nase helper scripts."""

from __future__ import annotations

from datetime import datetime, timezone


def parse_ts(value: str) -> datetime | None:
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        parsed = datetime.fromisoformat(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)
    except Exception:
        return None
