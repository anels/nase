#!/usr/bin/env python3
"""Append a `## Commits` block to a daily log under the shared daily-log lock.

Usage: commit-log-append.py --root DIR --date YYYY-MM-DD < input

The first stdin line is the fingerprint and the rest is the block. The fingerprint
grows with the commit count, so argv could not carry it. Under
`workspace/logs/.daily-log.lock` (the lock `daily-log-append.py` takes) the script
skips when `.last-commit-fingerprint` already holds `DATE:FINGERPRINT`; otherwise it
appends a `## Commits` section holding the block and rewrites the fingerprint file
atomically. Prints `appended` or `unchanged`.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from nase_fs import atomic_write, lock_exclusive


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--date", required=True)
    args = parser.parse_args()
    fingerprint = sys.stdin.buffer.readline().decode("utf-8").rstrip("\r\n")
    block = sys.stdin.buffer.read()

    logs = pathlib.Path(args.root) / "workspace" / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / f"{args.date}.md"
    fp_file = logs / ".last-commit-fingerprint"
    stamp = f"{args.date}:{fingerprint}"

    with open(logs / ".daily-log.lock", "a") as lock:
        lock_exclusive(lock)
        try:
            last = fp_file.read_bytes().decode("utf-8", errors="replace").strip()
        except FileNotFoundError:
            last = ""
        if last == stamp:
            print("unchanged")
            return 0
        with open(log, "ab") as handle:
            handle.write(b"\n## Commits\n" + block + b"\n")
        atomic_write(fp_file, (stamp + "\n").encode("utf-8"))
    print("appended")
    return 0


if __name__ == "__main__":
    sys.exit(main())
