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


def _owner_path(lock_dir: Path) -> Path:
    return lock_dir / "owner.json"


def _require_directory(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise LockError(f"{label} cannot be inspected: {path}: {exc}") from exc
    if not stat.S_ISDIR(metadata.st_mode) or path.is_symlink():
        raise LockError(f"{label} is not a lexical directory: {path}")
    return metadata


def _ensure_locks_root(root: Path) -> Path:
    _require_directory(root, "repository root")
    locks_root = root / ".nase-locks"
    try:
        locks_root.mkdir()
    except FileExistsError:
        pass
    except OSError as exc:
        raise LockError(f"lock parent cannot be created: {locks_root}: {exc}") from exc
    _require_directory(locks_root, "lock parent")
    return locks_root


def _require_regular(path: Path, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as exc:
        raise LockError(f"{label} cannot be inspected: {path}: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise LockError(f"{label} is not a lexical regular file: {path}")
    return metadata


def _open_existing_regular(path: Path, label: str, flags: int = os.O_RDONLY) -> int:
    metadata = _require_regular(path, label)
    safe_flags = flags | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, safe_flags)
    except OSError as exc:
        raise LockError(f"{label} cannot be opened safely: {path}: {exc}") from exc
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_dev != metadata.st_dev
        or opened.st_ino != metadata.st_ino
    ):
        os.close(descriptor)
        raise LockError(f"{label} changed while opening: {path}")
    return descriptor


def _open_recovery_guard(path: Path) -> int:
    flags = os.O_RDWR | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        return os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        return _open_existing_regular(path, "recovery guard", flags=os.O_RDWR)
    except OSError as exc:
        raise LockError(f"recovery guard cannot be created safely: {path}: {exc}") from exc


def _validate_lock_contents(lock_dir: Path) -> None:
    _require_directory(lock_dir, "workspace mutation lock")
    try:
        children = list(lock_dir.iterdir())
    except OSError as exc:
        raise LockError(f"workspace mutation lock cannot be listed: {lock_dir}: {exc}") from exc
    for child in children:
        if child.name != "owner.json":
            raise LockError(f"workspace mutation lock has an unexpected entry: {child}")
        _require_regular(child, "workspace mutation lock owner")


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _read_owner(lock_dir: Path) -> dict[str, object] | None:
    owner_path = _owner_path(lock_dir)
    try:
        owner_path.lstat()
    except FileNotFoundError:
        return None
    descriptor = _open_existing_regular(owner_path, "workspace mutation lock owner")
    try:
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (UnicodeError, json.JSONDecodeError):
        return None
    except OSError as exc:
        raise LockError(f"lock owner cannot be read safely: {owner_path}: {exc}") from exc
    return data if isinstance(data, dict) else None


def _quarantine_stale(lock_dir: Path) -> bool:
    _validate_lock_contents(lock_dir)
    recovery_guard = lock_dir.with_name("workspace-mutation.recovery.guard")
    guard_descriptor = _open_recovery_guard(recovery_guard)
    try:
        fcntl.flock(guard_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(guard_descriptor)
        return False
    try:
        _validate_lock_contents(lock_dir)
        owner = _read_owner(lock_dir)
        try:
            age = time.time() - _require_directory(
                lock_dir, "workspace mutation lock"
            ).st_mtime
        except FileNotFoundError:
            return True
        pid = owner.get("pid") if owner else None
        if age <= STALE_AFTER_SECONDS or (isinstance(pid, int) and _pid_alive(pid)):
            return False
        while True:
            stale = lock_dir.with_name(f"{lock_dir.name}.stale-{uuid.uuid4().hex}")
            try:
                stale.lstat()
            except FileNotFoundError:
                break
            except OSError as exc:
                raise LockError(f"stale lock path cannot be inspected: {stale}: {exc}") from exc
        try:
            lock_dir.rename(stale)
        except FileNotFoundError:
            return True
        except OSError as exc:
            raise LockError(f"stale lock cannot be quarantined: {lock_dir}: {exc}") from exc
        _validate_lock_contents(stale)
        owner_path = _owner_path(stale)
        try:
            owner_path.lstat()
        except FileNotFoundError:
            pass
        else:
            owner_descriptor = _open_existing_regular(
                owner_path, "quarantined lock owner"
            )
            os.close(owner_descriptor)
            try:
                owner_path.unlink()
            except OSError as exc:
                raise LockError(
                    f"quarantined lock owner cannot be removed: {owner_path}: {exc}"
                ) from exc
        try:
            stale.rmdir()
        except OSError as exc:
            raise LockError(f"quarantined lock cannot be removed: {stale}: {exc}") from exc
        return True
    finally:
        fcntl.flock(guard_descriptor, fcntl.LOCK_UN)
        os.close(guard_descriptor)


def acquire(root: Path, timeout_ms: int, owner_pid: int | None = None) -> Lease:
    root = root.expanduser().resolve()
    locks_root = _ensure_locks_root(root)
    lock_dir = locks_root / "workspace-mutation.lock"
    deadline = time.monotonic() + max(timeout_ms, 0) / 1000
    nonce = uuid.uuid4().hex
    while True:
        _require_directory(locks_root, "lock parent")
        try:
            lock_dir.mkdir()
        except FileExistsError:
            _validate_lock_contents(lock_dir)
            _quarantine_stale(lock_dir)
            if time.monotonic() >= deadline:
                raise LockError("workspace mutation lock is busy")
            time.sleep(0.05)
            continue
        except OSError as exc:
            raise LockError(
                f"workspace mutation lock cannot be created: {lock_dir}: {exc}"
            ) from exc
        owner = {
            "pid": owner_pid if owner_pid is not None else os.getpid(),
            "nonce": nonce,
            "created_at": time.time(),
            "root": str(root),
        }
        owner_path = _owner_path(lock_dir)
        try:
            flags = (
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0)
            )
            descriptor = os.open(owner_path, flags, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(owner, handle, sort_keys=True)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            try:
                _validate_lock_contents(lock_dir)
                try:
                    owner_metadata = owner_path.lstat()
                except FileNotFoundError:
                    pass
                else:
                    if stat.S_ISREG(owner_metadata.st_mode) and not owner_path.is_symlink():
                        owner_path.unlink()
                lock_dir.rmdir()
            except (LockError, OSError):
                pass
            raise LockError(f"lock owner cannot be created safely: {owner_path}: {exc}") from exc
        return Lease(root=root, nonce=nonce)


def release(lease: Lease) -> None:
    root = lease.root.expanduser().resolve()
    locks_root = _ensure_locks_root(root)
    lock_dir = locks_root / "workspace-mutation.lock"
    _validate_lock_contents(lock_dir)
    owner = _read_owner(lock_dir)
    if not owner or owner.get("nonce") != lease.nonce:
        raise LockError("workspace mutation lock ownership changed")
    owner_path = _owner_path(lock_dir)
    owner_descriptor = _open_existing_regular(
        owner_path, "workspace mutation lock owner"
    )
    os.close(owner_descriptor)
    try:
        owner_path.unlink()
        lock_dir.rmdir()
    except OSError as exc:
        raise LockError(f"workspace mutation lock cannot be released: {lock_dir}: {exc}") from exc


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
