#!/usr/bin/env python3
"""Lease-based repository workspace mutation lock."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import stat
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator


STALE_AFTER_SECONDS = 10.0
LOCKS_NAME = ".nase-locks"
LOCK_NAME = "workspace-mutation.lock"
OWNER_NAME = "owner.json"
GUARD_NAME = "workspace-mutation.recovery.guard"
DIR_FD_SUPPORTED = all(
    function in os.supports_dir_fd
    for function in (os.open, os.mkdir, os.stat, os.rename, os.unlink, os.rmdir)
)
FD_INSPECTION_SUPPORTED = (
    os.stat in os.supports_follow_symlinks and os.listdir in os.supports_fd
)
# ponytail: one repo-wide lock; split by path only if measured contention matters.


class LockError(RuntimeError):
    pass


@dataclass(frozen=True)
class Lease:
    root: Path
    nonce: str

    @property
    def lock_dir(self) -> Path:
        return self.root / ".nase-locks" / "workspace-mutation.lock"


def _directory_flags() -> int:
    if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
        raise LockError("platform lacks required no-follow directory open support")
    return os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def _no_follow_flag() -> int:
    if not hasattr(os, "O_NOFOLLOW"):
        raise LockError("platform lacks required no-follow open support")
    return os.O_NOFOLLOW


def _require_fd_platform() -> None:
    if not DIR_FD_SUPPORTED:
        raise LockError("platform lacks required dir_fd filesystem support")
    if not FD_INSPECTION_SUPPORTED:
        raise LockError("platform lacks required no-follow FD inspection support")


def _entry_metadata(
    parent_fd: int, name: str, label: str, *, missing_ok: bool = False
) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        if missing_ok:
            return None
        raise LockError(f"{label} does not exist: {name}")
    except OSError as exc:
        raise LockError(f"{label} cannot be inspected: {name}: {exc}") from exc


def _entry_matches(parent_fd: int, name: str, expected: os.stat_result) -> bool:
    current = _entry_metadata(parent_fd, name, name, missing_ok=True)
    return bool(
        current is not None
        and current.st_dev == expected.st_dev
        and current.st_ino == expected.st_ino
        and stat.S_IFMT(current.st_mode) == stat.S_IFMT(expected.st_mode)
    )


def _open_child_directory(parent_fd: int, name: str, label: str) -> tuple[int, os.stat_result]:
    expected = _entry_metadata(parent_fd, name, label)
    assert expected is not None
    if not stat.S_ISDIR(expected.st_mode):
        raise LockError(f"{label} is not a lexical directory: {name}")
    try:
        descriptor = os.open(name, _directory_flags(), dir_fd=parent_fd)
    except OSError as exc:
        raise LockError(f"{label} cannot be opened safely: {name}: {exc}") from exc
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(opened.st_mode)
        or opened.st_dev != expected.st_dev
        or opened.st_ino != expected.st_ino
        or not _entry_matches(parent_fd, name, opened)
    ):
        os.close(descriptor)
        raise LockError(f"{label} changed while opening: {name}")
    return descriptor, opened


def _open_lock_roots(
    root: Path, *, create: bool
) -> tuple[int, os.stat_result, int, os.stat_result]:
    _require_fd_platform()
    try:
        root_fd = os.open(root, _directory_flags())
    except OSError as exc:
        raise LockError(f"repository root cannot be opened safely: {root}: {exc}") from exc
    root_metadata = os.fstat(root_fd)
    if not stat.S_ISDIR(root_metadata.st_mode):
        os.close(root_fd)
        raise LockError(f"repository root is not a directory: {root}")
    try:
        locks_metadata = _entry_metadata(
            root_fd, LOCKS_NAME, "lock parent", missing_ok=True
        )
        if locks_metadata is None:
            if not create:
                raise LockError(f"lock parent does not exist: {root / LOCKS_NAME}")
            try:
                os.mkdir(LOCKS_NAME, dir_fd=root_fd)
            except FileExistsError:
                pass
            except OSError as exc:
                raise LockError(f"lock parent cannot be created safely: {exc}") from exc
        locks_fd, locks_metadata = _open_child_directory(
            root_fd, LOCKS_NAME, "lock parent"
        )
    except Exception:
        os.close(root_fd)
        raise
    return root_fd, root_metadata, locks_fd, locks_metadata


def _open_regular_at(
    parent_fd: int,
    name: str,
    label: str,
    *,
    flags: int = os.O_RDONLY,
    missing_ok: bool = False,
) -> int | None:
    expected = _entry_metadata(parent_fd, name, label, missing_ok=missing_ok)
    if expected is None:
        return None
    if not stat.S_ISREG(expected.st_mode):
        raise LockError(f"{label} is not a lexical regular file: {name}")
    safe_flags = flags | getattr(os, "O_NONBLOCK", 0) | _no_follow_flag()
    try:
        descriptor = os.open(name, safe_flags, dir_fd=parent_fd)
    except OSError as exc:
        raise LockError(f"{label} cannot be opened safely: {name}: {exc}") from exc
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_dev != expected.st_dev
        or opened.st_ino != expected.st_ino
        or not _entry_matches(parent_fd, name, opened)
    ):
        os.close(descriptor)
        raise LockError(f"{label} changed while opening: {name}")
    return descriptor


def _open_recovery_guard_at(locks_fd: int) -> int:
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NONBLOCK", 0)
        | _no_follow_flag()
    )
    try:
        descriptor = os.open(GUARD_NAME, flags, 0o600, dir_fd=locks_fd)
    except FileExistsError:
        existing = _open_regular_at(
            locks_fd, GUARD_NAME, "recovery guard", flags=os.O_RDWR
        )
        assert existing is not None
        return existing
    except OSError as exc:
        raise LockError(f"recovery guard cannot be created safely: {exc}") from exc
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or not _entry_matches(
        locks_fd, GUARD_NAME, opened
    ):
        os.close(descriptor)
        raise LockError("recovery guard changed while creating")
    return descriptor


def _validate_lock_contents_at(lock_fd: int) -> None:
    try:
        children = os.listdir(lock_fd)
    except OSError as exc:
        raise LockError(f"workspace mutation lock cannot be listed: {exc}") from exc
    for child in children:
        if child != OWNER_NAME:
            raise LockError(f"workspace mutation lock has an unexpected entry: {child}")
        metadata = _entry_metadata(lock_fd, child, "workspace mutation lock owner")
        assert metadata is not None
        if not stat.S_ISREG(metadata.st_mode):
            raise LockError("workspace mutation lock owner is not a lexical regular file")


def _read_owner_record_at(
    lock_fd: int,
) -> tuple[dict[str, object] | None, os.stat_result] | None:
    descriptor = _open_regular_at(
        lock_fd,
        OWNER_NAME,
        "workspace mutation lock owner",
        missing_ok=True,
    )
    if descriptor is None:
        return None
    owner_metadata = os.fstat(descriptor)
    try:
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (UnicodeError, json.JSONDecodeError):
        return None, owner_metadata
    except OSError as exc:
        raise LockError(f"lock owner cannot be read safely: {exc}") from exc
    return (data if isinstance(data, dict) else None), owner_metadata


def _read_owner_at(lock_fd: int) -> dict[str, object] | None:
    record = _read_owner_record_at(lock_fd)
    return record[0] if record is not None else None


def _claim_lock(
    locks_fd: int, expected: os.stat_result, tag: str
) -> str:
    while True:
        claim_name = f"{LOCK_NAME}.{tag}-{uuid.uuid4().hex}"
        if _entry_metadata(
            locks_fd, claim_name, f"{tag} claim", missing_ok=True
        ) is None:
            break
    if not _entry_matches(locks_fd, LOCK_NAME, expected):
        raise LockError(f"workspace mutation lock changed before {tag} claim")
    try:
        os.rename(
            LOCK_NAME,
            claim_name,
            src_dir_fd=locks_fd,
            dst_dir_fd=locks_fd,
        )
    except OSError as exc:
        raise LockError(f"workspace mutation lock cannot be claimed for {tag}: {exc}") from exc
    if not _entry_matches(locks_fd, claim_name, expected):
        raise LockError(
            f"{tag} claim does not match opened lock; preserved: {claim_name}"
        )
    return claim_name


def _quarantine_stale_at(
    root_fd: int,
    locks_fd: int,
    locks_metadata: os.stat_result,
) -> bool:
    if not _entry_matches(root_fd, LOCKS_NAME, locks_metadata):
        raise LockError("lock parent changed before stale recovery")
    guard_fd = _open_recovery_guard_at(locks_fd)
    try:
        fcntl.flock(guard_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(guard_fd)
        return False
    lock_fd: int | None = None
    try:
        guard_metadata = os.fstat(guard_fd)
        if not _entry_matches(locks_fd, GUARD_NAME, guard_metadata):
            raise LockError("recovery guard changed after flock")
        if not _entry_matches(root_fd, LOCKS_NAME, locks_metadata):
            raise LockError("lock parent changed during stale recovery")
        current = _entry_metadata(
            locks_fd, LOCK_NAME, "workspace mutation lock", missing_ok=True
        )
        if current is None:
            return True
        lock_fd, lock_metadata = _open_child_directory(
            locks_fd, LOCK_NAME, "workspace mutation lock"
        )
        _validate_lock_contents_at(lock_fd)
        owner = _read_owner_at(lock_fd)
        age = time.time() - os.fstat(lock_fd).st_mtime
        pid = owner.get("pid") if owner else None
        if age <= STALE_AFTER_SECONDS or (isinstance(pid, int) and _pid_alive(pid)):
            return False
        if (
            not _entry_matches(root_fd, LOCKS_NAME, locks_metadata)
            or not _entry_matches(locks_fd, LOCK_NAME, lock_metadata)
            or not _entry_matches(locks_fd, GUARD_NAME, guard_metadata)
        ):
            raise LockError("lock path changed before stale quarantine")
        stale_name = _claim_lock(locks_fd, lock_metadata, "stale")
        _validate_lock_contents_at(lock_fd)
        owner_fd = _open_regular_at(
            lock_fd,
            OWNER_NAME,
            "quarantined lock owner",
            missing_ok=True,
        )
        if owner_fd is not None:
            os.close(owner_fd)
            try:
                os.unlink(OWNER_NAME, dir_fd=lock_fd)
            except OSError as exc:
                raise LockError(f"quarantined lock owner cannot be removed: {exc}") from exc
        if not _entry_matches(locks_fd, stale_name, lock_metadata):
            raise LockError("stale lock changed before removal")
        try:
            os.rmdir(stale_name, dir_fd=locks_fd)
        except OSError as exc:
            raise LockError(f"quarantined lock cannot be removed: {exc}") from exc
        return True
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        fcntl.flock(guard_fd, fcntl.LOCK_UN)
        os.close(guard_fd)


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _valid_nonce(value: object) -> bool:
    return bool(
        isinstance(value, str)
        and len(value) == 32
        and all(character in "0123456789abcdef" for character in value)
    )


def _cleanup_created_lock(
    locks_fd: int, lock_fd: int, lock_metadata: os.stat_result
) -> None:
    if not _entry_matches(locks_fd, LOCK_NAME, lock_metadata):
        return
    claim_name = _claim_lock(locks_fd, lock_metadata, "acquire-failed")
    owner_fd = _open_regular_at(
        lock_fd,
        OWNER_NAME,
        "workspace mutation lock owner",
        missing_ok=True,
    )
    if owner_fd is not None:
        os.close(owner_fd)
        os.unlink(OWNER_NAME, dir_fd=lock_fd)
    if not _entry_matches(locks_fd, claim_name, lock_metadata):
        raise LockError("failed acquisition claim changed during cleanup")
    os.rmdir(claim_name, dir_fd=locks_fd)


def acquire(root: Path, timeout_ms: int, owner_pid: int | None = None) -> Lease:
    root = root.expanduser().resolve()
    root_fd, _, locks_fd, locks_metadata = _open_lock_roots(root, create=True)
    deadline = time.monotonic() + max(timeout_ms, 0) / 1000
    nonce = uuid.uuid4().hex
    try:
        while True:
            if not _entry_matches(root_fd, LOCKS_NAME, locks_metadata):
                raise LockError("lock parent changed before acquisition")
            try:
                os.mkdir(LOCK_NAME, dir_fd=locks_fd)
            except FileExistsError:
                _quarantine_stale_at(root_fd, locks_fd, locks_metadata)
                if time.monotonic() >= deadline:
                    raise LockError("workspace mutation lock is busy")
                time.sleep(0.05)
                continue
            except OSError as exc:
                raise LockError(
                    f"workspace mutation lock cannot be created: {exc}"
                ) from exc
            lock_fd, lock_metadata = _open_child_directory(
                locks_fd, LOCK_NAME, "workspace mutation lock"
            )
            owner = {
                "pid": owner_pid if owner_pid is not None else os.getpid(),
                "nonce": nonce,
                "created_at": time.time(),
                "root": str(root),
            }
            try:
                flags = (
                    os.O_WRONLY
                    | os.O_CREAT
                    | os.O_EXCL
                    | _no_follow_flag()
                )
                owner_fd = os.open(OWNER_NAME, flags, 0o600, dir_fd=lock_fd)
                with os.fdopen(owner_fd, "w", encoding="utf-8") as handle:
                    json.dump(owner, handle, sort_keys=True)
                    handle.flush()
                    os.fsync(handle.fileno())
                verified_owner = _read_owner_at(lock_fd)
                if (
                    not _entry_matches(root_fd, LOCKS_NAME, locks_metadata)
                    or not _entry_matches(locks_fd, LOCK_NAME, lock_metadata)
                    or not verified_owner
                    or verified_owner.get("nonce") != nonce
                ):
                    raise LockError("lock path changed before acquisition completed")
            except (LockError, OSError) as exc:
                try:
                    _cleanup_created_lock(locks_fd, lock_fd, lock_metadata)
                except (LockError, OSError):
                    pass
                if isinstance(exc, LockError):
                    raise
                raise LockError(f"lock owner cannot be created safely: {exc}") from exc
            finally:
                os.close(lock_fd)
            return Lease(root=root, nonce=nonce)
    finally:
        os.close(locks_fd)
        os.close(root_fd)


def release(lease: Lease) -> None:
    root = lease.root.expanduser().resolve()
    if not _valid_nonce(lease.nonce):
        raise LockError("workspace mutation lock nonce is invalid")
    root_fd, _, locks_fd, locks_metadata = _open_lock_roots(root, create=False)
    lock_fd: int | None = None
    try:
        lock_fd, lock_metadata = _open_child_directory(
            locks_fd, LOCK_NAME, "workspace mutation lock"
        )
        _validate_lock_contents_at(lock_fd)
        owner_record = _read_owner_record_at(lock_fd)
        if owner_record is None:
            raise LockError("workspace mutation lock ownership changed")
        owner, owner_metadata = owner_record
        if not owner or owner.get("nonce") != lease.nonce:
            raise LockError("workspace mutation lock ownership changed")
        if (
            not _entry_matches(root_fd, LOCKS_NAME, locks_metadata)
            or not _entry_matches(locks_fd, LOCK_NAME, lock_metadata)
            or not _entry_matches(lock_fd, OWNER_NAME, owner_metadata)
        ):
            raise LockError("workspace mutation lock changed before release")
        if (
            not _entry_matches(root_fd, LOCKS_NAME, locks_metadata)
            or not _entry_matches(locks_fd, LOCK_NAME, lock_metadata)
        ):
            raise LockError("workspace mutation lock changed before release claim")
        claim_name = _claim_lock(
            locks_fd, lock_metadata, f"release-{lease.nonce}"
        )
        try:
            os.unlink(OWNER_NAME, dir_fd=lock_fd)
        except OSError as exc:
            raise LockError(f"workspace mutation lock owner cannot be removed: {exc}") from exc
        if not _entry_matches(locks_fd, claim_name, lock_metadata):
            raise LockError("workspace mutation lock claim changed during release")
        try:
            os.rmdir(claim_name, dir_fd=locks_fd)
        except OSError as exc:
            raise LockError(f"workspace mutation lock cannot be released: {exc}") from exc
        if (
            _entry_metadata(
                locks_fd, claim_name, "workspace mutation lock claim", missing_ok=True
            )
            is not None
            or not _entry_matches(root_fd, LOCKS_NAME, locks_metadata)
        ):
            raise LockError("workspace mutation lock path changed after release")
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        os.close(locks_fd)
        os.close(root_fd)


@contextmanager
def held(root: Path, timeout_ms: int = 5000) -> Iterator[Lease]:
    lease = acquire(root, timeout_ms)
    try:
        yield lease
    finally:
        release(lease)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    acquire_parser = sub.add_parser("acquire")
    acquire_parser.add_argument("--root", required=True)
    acquire_parser.add_argument("--timeout-ms", type=int, default=5000)
    acquire_parser.add_argument("--owner-pid", type=int, required=True)
    release_parser = sub.add_parser("release")
    release_parser.add_argument("--root", required=True)
    release_parser.add_argument("--nonce", required=True)
    args = parser.parse_args()
    try:
        if args.command == "acquire":
            lease = acquire(Path(args.root), args.timeout_ms, owner_pid=args.owner_pid)
            print(json.dumps({"nonce": lease.nonce, "lock_dir": str(lease.lock_dir)}))
        else:
            release(Lease(Path(args.root).expanduser().resolve(), args.nonce))
    except LockError as exc:
        print(str(exc), file=os.sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
