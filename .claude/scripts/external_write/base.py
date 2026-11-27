from __future__ import annotations

import os
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

from nase_fs import sha256_bytes
from nase_json import canonical_bytes
from nase_time import parse_ts


class ActionError(Exception):
    """A caller supplied an unsafe or invalid action."""


def sha256(value: Any) -> str:
    return sha256_bytes(canonical_bytes(value, ensure_ascii=True))


def parse_timestamp(value: str) -> datetime:
    parsed = parse_ts(value)
    if parsed is None:
        raise ActionError("token created_at is invalid")
    return parsed


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp-{uuid.uuid4().hex}")
    temporary.write_bytes(canonical_bytes(value, ensure_ascii=True, trailing_newline=True))
    os.chmod(temporary, 0o600)
    temporary.replace(path)
