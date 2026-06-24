#!/usr/bin/env python3
"""Render a compact Claude Code context status line."""

from __future__ import annotations

import json
import sys
from typing import Any


def get(data: dict[str, Any], path: str, default: Any = None) -> Any:
    cur: Any = data
    for part in path.split("."):
        if not isinstance(cur, dict):
            return default
        cur = cur.get(part)
        if cur is None:
            return default
    return cur


def intval(value: Any) -> int:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def main() -> int:
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        data = {}

    model = str(get(data, "model.display_name", "unknown"))
    pct = intval(get(data, "context_window.used_percentage", 0))
    usage = get(data, "context_window.current_usage", {}) or {}
    if not isinstance(usage, dict):
        usage = {}
    input_tokens = intval(usage.get("input_tokens"))
    cache_read = intval(usage.get("cache_read_input_tokens"))
    cache_write = intval(usage.get("cache_creation_input_tokens"))
    print(f"{model} | ctx {pct}% | in {input_tokens} | cache r{cache_read}/w{cache_write}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
