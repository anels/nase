#!/usr/bin/env python3
"""Shared digest and durable-write primitives.

Per-script copies of these drift on the detail that decides whether they work: an atomic
write that fsyncs the file but not its parent directory makes the data durable and the
rename not, so a crash between the two leaves the old file in place after the caller has
already reported success. One implementation is the only way that stays fixed.
"""

from __future__ import annotations

import hashlib
import os
import pathlib
import stat
import tempfile


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path | str) -> str:
    """Digest a file without loading it whole; archives here reach hundreds of megabytes."""
    with open(path, "rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def fsync_dir(path: pathlib.Path | str) -> None:
    """Flush a directory entry, which is what makes a rename survive a crash."""
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _replacement_mode(target: pathlib.Path) -> int:
    """The mode the replacement should land with, mirroring an ordinary write.

    An existing file keeps the mode it had; a new one gets what a plain
    `open(..., "wb")` would have given it.
    """
    try:
        return stat.S_IMODE(target.stat().st_mode)
    except FileNotFoundError:
        current = os.umask(0)
        os.umask(current)
        return 0o666 & ~current


def atomic_write(path: pathlib.Path | str, data: bytes) -> None:
    """Replace `path` with `data` so a reader sees either the old bytes or all the new ones.

    The temporary file is created in the destination directory so `os.replace` is a
    rename within one filesystem, which is the part that is atomic. Both the file and its
    parent directory are fsynced: without the second one the rename can be lost even
    though the bytes were written. The destination's existing mode is preserved, because
    a rename carries the temporary file's permissions and would otherwise narrow it.
    """
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    mode = _replacement_mode(target)
    descriptor, raw_temporary = tempfile.mkstemp(
        prefix=f".{target.name}.", dir=target.parent
    )
    temporary = pathlib.Path(raw_temporary)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        # Before the rename, so no reader can ever observe the destination at 0600.
        os.chmod(temporary, mode)
        os.replace(temporary, target)
        fsync_dir(target.parent)
    finally:
        temporary.unlink(missing_ok=True)
