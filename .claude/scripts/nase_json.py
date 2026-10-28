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
"""

from __future__ import annotations

import json
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
