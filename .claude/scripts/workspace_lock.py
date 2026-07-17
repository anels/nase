#!/usr/bin/env python3
"""Lease-based repository workspace mutation lock."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shutil
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


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _read_owner(lock_dir: Path) -> dict[str, object] | None:
    try:
        data = json.loads(_owner_path(lock_dir).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _quarantine_stale(lock_dir: Path) -> bool:
    recovery_guard = lock_dir.with_name("workspace-mutation.recovery.guard")
    guard_handle = recovery_guard.open("a+")
    try:
        fcntl.flock(guard_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        guard_handle.close()
        return False
    try:
        owner = _read_owner(lock_dir)
        try:
            age = time.time() - lock_dir.stat().st_mtime
        except FileNotFoundError:
            return True
        pid = owner.get("pid") if owner else None
        if age <= STALE_AFTER_SECONDS or (isinstance(pid, int) and _pid_alive(pid)):
            return False
        stale = lock_dir.with_name(f"{lock_dir.name}.stale-{uuid.uuid4().hex}")
        try:
            lock_dir.rename(stale)
        except FileNotFoundError:
            return True
        except OSError:
            return False
        shutil.rmtree(stale)
        return True
    finally:
        fcntl.flock(guard_handle.fileno(), fcntl.LOCK_UN)
        guard_handle.close()


def acquire(root: Path, timeout_ms: int, owner_pid: int | None = None) -> Lease:
    root = root.expanduser().resolve()
    lock_dir = root / ".nase-locks" / "workspace-mutation.lock"
    lock_dir.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + max(timeout_ms, 0) / 1000
    nonce = uuid.uuid4().hex
    while True:
        try:
            lock_dir.mkdir()
        except FileExistsError:
            _quarantine_stale(lock_dir)
            if time.monotonic() >= deadline:
                raise LockError("workspace mutation lock is busy")
            time.sleep(0.05)
            continue
        owner = {
            "pid": owner_pid if owner_pid is not None else os.getpid(),
            "nonce": nonce,
            "created_at": time.time(),
            "root": str(root),
        }
        try:
            _owner_path(lock_dir).write_text(json.dumps(owner, sort_keys=True), encoding="utf-8")
        except OSError:
            lock_dir.rmdir()
            raise
        return Lease(root=root, nonce=nonce)


def release(lease: Lease) -> None:
    lock_dir = lease.lock_dir
    owner = _read_owner(lock_dir)
    if not owner or owner.get("nonce") != lease.nonce:
        raise LockError("workspace mutation lock ownership changed")
    _owner_path(lock_dir).unlink()
    lock_dir.rmdir()


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
