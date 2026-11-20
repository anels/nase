#!/usr/bin/env python3
"""Record the KB's size and report growth since the last snapshot.

Appends one JSON line per run to workspace/stats/kb-size.jsonl. Prints the net change in non-blank lines, the files
that grew, and the files over the line budget. Exit 0 always: it reports, it never gates.

Usage: kb-size-snapshot.py [--root ROOT] [--max-kb-lines N] [--max-kb-bytes N] [--no-write]
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from datetime import datetime, timezone

from nase_json import read_jsonl_objects

DEFAULT_BUDGET = 800
# Line count misses files with very long paragraphs, so size in bytes is checked too (~15k tokens).
DEFAULT_BYTE_BUDGET = 60000


def count_lines(path: pathlib.Path) -> int:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            return sum(1 for line in handle if line.strip())
    except OSError:
        return 0


def snapshot(kb_dir: pathlib.Path, root: pathlib.Path) -> dict[str, int]:
    return {
        path.relative_to(root).as_posix(): count_lines(path)
        for path in sorted(kb_dir.rglob("*.md"))
        if path.is_file()
    }


def last_snapshot(ledger: pathlib.Path) -> dict | None:
    if not ledger.is_file():
        return None
    last = None
    entries, _ = read_jsonl_objects(ledger)
    for entry in entries:
        # A line like `{}` parses but is not a snapshot. Skip it, so the last
        # real snapshot stays the baseline instead of crashing the delta report.
        if (
            isinstance(entry.get("total"), int)
            and isinstance(entry.get("files"), dict)
            and isinstance(entry.get("ts"), str)
        ):
            last = entry
    return last


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--max-kb-lines", type=int, default=DEFAULT_BUDGET)
    parser.add_argument("--max-kb-bytes", type=int, default=DEFAULT_BYTE_BUDGET)
    parser.add_argument("--no-write", action="store_true")
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    kb_dir = root / "workspace" / "kb"
    if not kb_dir.is_dir():
        print("kb-size: no workspace/kb", file=sys.stderr)
        return 0

    files = snapshot(kb_dir, root)
    total = sum(files.values())
    ledger = root / "workspace" / "stats" / "kb-size.jsonl"
    prev = last_snapshot(ledger)

    over = sorted(((n, f) for f, n in files.items() if n > args.max_kb_lines), reverse=True)
    files_word = "file" if len(files) == 1 else "files"
    print(f"kb-size: {total} non-blank lines in {len(files)} {files_word}; {len(over)} over the {args.max_kb_lines} budget")
    if prev:
        delta = total - prev["total"]
        print(f"kb-size: net {delta:+d} lines since {prev['ts']}")
        grew = sorted(
            ((n - prev["files"].get(f, 0), f) for f, n in files.items() if n > prev["files"].get(f, 0)),
            reverse=True,
        )
        for diff, name in grew[:5]:
            print(f"  grew {diff:+d}  {name}")
    for n, name in over[:5]:
        print(f"  over  {n}  {name}")
    big = sorted(
        ((size, f) for f in files if (size := (root / f).stat().st_size) > args.max_kb_bytes),
        reverse=True,
    )
    print(f"kb-size: {len(big)} files over {args.max_kb_bytes} bytes")
    for size, name in big[:8]:
        print(f"  big   {size // 1024}KB  {name}")

    if not args.no_write:
        ledger.parent.mkdir(parents=True, exist_ok=True)
        entry = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "total": total, "files": files}
        with ledger.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
