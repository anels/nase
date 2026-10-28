#!/usr/bin/env python3
"""Load a hyphenated sibling script, and scan bytes with the shared secret scanner.

Scripts such as `verify-bundle.py` cannot be imported by name, so consumers load them by
path. The loader raises the caller's own exception type, because each consumer reports
failure through its own error class and an unrelated one would escape its handler.
"""

from __future__ import annotations

import importlib.util
import io
from pathlib import Path
from typing import Any


def load_script(name: str, path: Path, error: type[Exception] = ImportError) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise error(f"cannot load helper: {path.name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def stream_secret_kind(scanner: Any, data: bytes) -> str | None:
    """Kind of the first secret in `data`, scanned in chunks like a file or blob.

    `scanner` is the loaded `verify-bundle.py`. This is the streamed read, which is not
    the same call as that script's own whole-buffer `secret_kind`: the two can disagree
    on a large buffer, so a caller must keep the one it already used.
    """
    hit = scanner.scan_stream_for_secret(io.BytesIO(data))
    return str(hit[0]) if hit else None
