#!/usr/bin/env python3
"""Publish a Jira approval token while holding the workspace mutation lock."""

from __future__ import annotations

import argparse
import os
import tempfile
from pathlib import Path

from workspace_lock import LockError, held


def write_token(root: Path, content: bytes, timeout_ms: int) -> None:
    root = root.expanduser().resolve()
    workspace = root / "workspace"
    if workspace.is_symlink() or (workspace.exists() and not workspace.is_dir()):
        raise LockError("workspace token directory is not a lexical directory")

    with held(root, timeout_ms):
        workspace.mkdir(mode=0o700, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(
            prefix=".jira-write-token.", dir=workspace
        )
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, workspace / ".jira-write-token")
            directory_fd = os.open(workspace, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--content-file", required=True)
    parser.add_argument("--timeout-ms", type=int, default=5000)
    args = parser.parse_args()
    try:
        write_token(
            Path(args.root), Path(args.content_file).read_bytes(), args.timeout_ms
        )
    except (LockError, OSError) as exc:
        print(str(exc), file=os.sys.stderr)
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
