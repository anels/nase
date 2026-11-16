#!/usr/bin/env python3
"""Shared canonical JSON encoding for bytes that get hashed or bound into a record.

A digest only means something if every writer and every verifier encodes the same
value to the same bytes. The callers disagree on two details, and each disagreement is
part of a format already on disk, so both are parameters rather than a silent default:

- `ensure_ascii`: gate bundles and evidence files keep non-ASCII text as UTF-8;
  write-action manifests and restore inventories escape it.
- `trailing_newline`: evidence and receipt files end with a newline so they are
  well-formed text files; gate bundles hash the bare JSON.

Changing either for an existing caller changes its digests, so a verifier reading an
older artifact would report a mismatch rather than an error.

`parse_jsonl_objects` and `read_jsonl_objects` are the shared reader for JSON Lines
ledgers. A valid line that is not an object (`[1]`, `"x"`, `5`, `null`) would crash
a caller that goes on to call `.get`, so it is counted as skipped alongside bad JSON.
"""

from __future__ import annotations

import json
import os
from collections.abc import Iterable
from typing import Any


def canonical_bytes(
    value: Any, *, ensure_ascii: bool = False, trailing_newline: bool = False
) -> bytes:
    """Encode `value` with sorted keys and no whitespace, as UTF-8 bytes."""
    text = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=ensure_ascii
    )
    if trailing_newline:
        text += "\n"
    return text.encode("utf-8")


def parse_jsonl_objects(lines: Iterable[str]) -> tuple[list[dict[str, Any]], int]:
    """Return (objects, skipped) for JSON Lines text.

    Blank lines are ignored. A line that is not JSON, or is JSON but not an object, is
    counted as skipped, so callers can call `.get` on every returned row.
    """
    objects: list[dict[str, Any]] = []
    skipped = 0
    for line in lines:
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except ValueError:
            skipped += 1
            continue
        if isinstance(value, dict):
            objects.append(value)
        else:
            skipped += 1
    return objects, skipped


def read_jsonl_objects(path: str | os.PathLike[str]) -> tuple[list[dict[str, Any]], int]:
    with open(path, encoding="utf-8", errors="replace") as handle:
        return parse_jsonl_objects(handle)
