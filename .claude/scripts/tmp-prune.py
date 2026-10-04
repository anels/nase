#!/usr/bin/env python3
"""Prune top-level entries of workspace/tmp/. Dry-run unless --apply.

An entry is deleted only when both hold:
  - its newest file is older than --days,
  - no durable location references it (efforts, kb, tasks, journals, recaps,
    stats, context, communication style, workspace skills, the Confluence
    publication ledger, .claude/, and the last --log-days daily logs).
Never deleted, because something reads them later by a templated name no
durable file spells out: keep/, external-actions/, .content-hashes, prune
manifests, workspace-write-guard.py move-recovery/rollback files (the only copy
of a source after a failed move), and fsd phase, research, QA state, and secret-allowlist files
(kept for diagnosis next to a retained worktree).

Deletion is permanent. stop-backup.sh excludes workspace/tmp/ from every
archive, so no backup can restore a pruned entry. The manifest is the only
record of what was removed.

--manifest appends one `<path>\t<bytes>` line per deleted (or would-delete)
entry before anything is deleted, so several runs on one day share a file. A
relative manifest path resolves against --root. --json lists the target paths.
Exits 0 on success, including when some entries could not be deleted (they are
listed under `failed`), and 2 on an invalid invocation, a missing workspace/tmp/,
a reference scan that could not read every source, or an unwritable manifest
(nothing is deleted in those cases).
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

NEVER = {"keep", "external-actions", ".content-hashes"}
NEVER_PREFIXES = (
    "tmp-prune-",
    "move-recovery-",
    "move-rollback-",
    "fsd-phases-",
    "fsd-research-",
    "fsd-secret-allowlist-",
)
DURABLE = [
    "workspace/efforts",
    "workspace/kb",
    "workspace/tasks",
    "workspace/journals",
    "workspace/recaps",
    "workspace/stats",
    "workspace/context.md",
    "workspace/communication-style.md",
    "workspace/confluence-publications.jsonl",
    "workspace/skills",
    ".claude",
]
PLAIN_NAME = r"[A-Za-z0-9._-]+"


def protected(name: str) -> bool:
    return (
        name in NEVER
        or name.startswith(NEVER_PREFIXES)
        or (name.startswith("fsd-qa-") and name.endswith("-state.json"))
    )


def _grep(args: list[str], sources: list[Path], stdin: str | None = None) -> set[str] | None:
    proc = subprocess.run(
        ["grep", "-rhoI", *args, *map(str, sources)],
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode > 1:
        return None
    return {line.removeprefix("workspace/tmp/") for line in proc.stdout.splitlines()}


def referenced(root: Path, log_days: int, names: list[str]) -> set[str] | None:
    """The names cited as workspace/tmp/<name> by a durable source, or None when grep
    could not read every source. Plain names go through one fast regex scan; names
    with spaces or other punctuation get a fixed-string scan of their own, because
    `grep -F -f` with every name is far slower over the same sources."""
    sources = [root / p for p in DURABLE if (root / p).exists()]
    if log_days > 0:
        sources += sorted((root / "workspace" / "logs").glob("20[0-9][0-9]-[0-9][0-9]-[0-9][0-9].md"))[-log_days:]
    if not sources:
        return set()
    found = _grep(["-E", f"workspace/tmp/{PLAIN_NAME}"], sources)
    if found is None:
        return None
    # A sentence-final period is captured with the name.
    found |= {t.rstrip(".") for t in found}
    unusual = [n for n in names if not re.fullmatch(PLAIN_NAME, n)]
    if unusual:
        extra = _grep(["-F", "-f", "-"], sources, "".join(f"workspace/tmp/{n}\n" for n in unusual))
        if extra is None:
            return None
        found |= extra
    return found


def tree_stats(path: Path) -> tuple[float, int]:
    """Newest mtime and total bytes of an entry, without following symlinks."""
    st = path.lstat()
    if not path.is_dir() or path.is_symlink():
        return st.st_mtime, st.st_size
    newest, total = st.st_mtime, 0
    for dirpath, _, files in os.walk(path):
        for name in files:
            with contextlib.suppress(OSError):
                fst = os.lstat(os.path.join(dirpath, name))
                newest = max(newest, fst.st_mtime)
                total += fst.st_size
    return newest, total


def main() -> int:
    parser = argparse.ArgumentParser(description="Prune top-level entries of workspace/tmp/.")
    parser.add_argument("--root", default=".", help="nase repository root")
    parser.add_argument("--days", type=float, default=3, help="minimum age of an entry's newest file")
    parser.add_argument("--log-days", type=int, default=7, help="recent daily logs that protect references")
    parser.add_argument("--apply", action="store_true", help="delete permanently; default is a dry-run")
    parser.add_argument("--manifest", help="append deleted entries as <path>\\t<bytes> lines")
    parser.add_argument("--json", action="store_true", help="print the summary as JSON")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    tmp = root / "workspace" / "tmp"
    if not tmp.is_dir():
        print(f"tmp-prune: {tmp} not found", file=sys.stderr)
        return 2
    if not args.days > 0:  # also rejects nan, which would make every entry old
        print("tmp-prune: --days must be positive", file=sys.stderr)
        return 2

    cutoff = time.time() - args.days * 86400
    kept = {"never": 0, "referenced": 0, "recent": 0}
    old: list[tuple[str, int]] = []
    for entry in sorted(tmp.iterdir()):
        if protected(entry.name):
            kept["never"] += 1
            continue
        try:
            newest, size = tree_stats(entry)
        except FileNotFoundError:
            continue
        if newest >= cutoff:
            kept["recent"] += 1
        else:
            old.append((entry.name, size))

    # A name with a newline cannot be a grep pattern line, so it is never a target.
    old = [(n, b) for n, b in old if "\n" not in n]
    refs = referenced(root, args.log_days, [n for n, _ in old]) if old else set()
    if refs is None:
        print("tmp-prune: reference scan failed; nothing deleted", file=sys.stderr)
        return 2
    targets = [(name, size) for name, size in old if name not in refs]
    kept["referenced"] = len(old) - len(targets)

    if args.manifest:
        # Written before deleting, so an interrupted run still leaves its record.
        try:
            with open(root / args.manifest, "a", encoding="utf-8") as handle:
                handle.writelines(f"workspace/tmp/{n}\t{b}\n" for n, b in targets)
        except OSError as exc:
            print(f"tmp-prune: cannot write manifest: {exc}; nothing deleted", file=sys.stderr)
            return 2

    failed: dict[str, str] = {}
    if args.apply:
        for name, _ in targets:
            path = tmp / name
            try:
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            except OSError as exc:
                failed[name] = str(exc)

    summary = {
        "mode": "apply" if args.apply else "dry-run",
        "days": args.days,
        "targets": len(targets),
        "bytes": sum(b for n, b in targets if n not in failed),
        "removed": len(targets) - len(failed) if args.apply else 0,
        "failed": [f"{n}: {e}" for n, e in failed.items()],
        "target_paths": [f"workspace/tmp/{n}" for n, _ in targets],
        "kept": kept,
    }
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"mode: {summary['mode']}  days: {args.days:g}")
        print(f"targets: {len(targets)}  size: {summary['bytes'] / 1e6:.1f} MB  removed: {summary['removed']}")
        print("kept: " + "  ".join(f"{k}={v}" for k, v in kept.items()))
        for line in summary["failed"]:
            print(f"FAILED {line}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
