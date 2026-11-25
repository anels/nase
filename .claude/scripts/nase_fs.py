#!/usr/bin/env python3
"""Shared digest and durable-write primitives.

Per-script copies of these drift on the detail that decides whether they work: an atomic
write that fsyncs the file but not its parent directory makes the data durable and the
rename not, so a crash between the two leaves the old file in place after the caller has
already reported success. One implementation is the only way that stays fixed.
"""

from __future__ import annotations

import errno
import hashlib
import os
import pathlib
import stat
import sys
import tempfile
import time
import typing


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: pathlib.Path | str) -> str:
    """Digest a file without loading it whole; archives here reach hundreds of megabytes.

    Chunked on purpose: `hashlib.file_digest` needs Python 3.11 and this repo
    supports 3.10.
    """
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def zip_member_name(info: typing.Any) -> str:
    """Name of a `zipfile.ZipInfo` member, as the archiver meant it.

    Apple's `zip` stores UTF-8 names without setting the UTF-8 flag, so `zipfile` decodes
    them as cp437 and a non-ASCII name comes back as mojibake. Bytes that are not valid
    UTF-8 keep the cp437 reading.
    """
    name = info.filename
    if info.flag_bits & 0x800 or name.isascii():
        return name
    try:
        return name.encode("cp437").decode("utf-8")
    except UnicodeError:
        return name


try:
    import fcntl
except ImportError:  # Windows has no fcntl; msvcrt byte-range locking stands in.
    fcntl = None
    import msvcrt


def lock_exclusive(handle: typing.IO[typing.Any], timeout_seconds: float = 30.0) -> None:
    """Block until `handle` holds an exclusive lock; closing the handle releases it.

    On Windows only a contended lock is retried, and only until the deadline, so a
    filesystem that rejects byte-range locks fails instead of spinning.
    """
    if fcntl is not None:
        fcntl.flock(handle, fcntl.LOCK_EX)
        return
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
            return
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EDEADLK) or (
                time.monotonic() >= deadline
            ):
                raise
            time.sleep(0.05)


def fsync_dir(path: pathlib.Path | str) -> None:
    """Flush a directory entry, which is what makes a rename survive a crash.

    A no-op on Windows: it cannot open a directory with os.open and has no directory
    fsync, so a rename there is as durable as NTFS journaling makes it.
    """
    if sys.platform == "win32":
        return
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
