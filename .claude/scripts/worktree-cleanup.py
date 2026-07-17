#!/usr/bin/env python3
"""Remove a linked Git worktree only after proving it is safe to delete."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


RETAINED = 3
INVALID = 2
OID_RE = re.compile(r"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")
IN_PROGRESS = (
    "MERGE_HEAD",
    "CHERRY_PICK_HEAD",
    "REVERT_HEAD",
    "BISECT_LOG",
    "rebase-apply",
    "rebase-merge",
    "sequencer",
)


class GitError(RuntimeError):
    pass


def git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise GitError(f"git {' '.join(args)}: {detail}")
    return result


def parse_worktrees(repo: Path) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    current: dict[str, object] = {}
    for line in git(repo, "worktree", "list", "--porcelain").stdout.splitlines():
        if not line:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        if key in current:
            raise GitError(f"duplicate {key!r} in worktree registry")
        current[key] = value if value else True
    if current:
        records.append(current)
    if not records or any("worktree" not in record for record in records):
        raise GitError("could not parse worktree registry")
    return records


def normalized(path: str | Path) -> Path:
    return Path(os.path.realpath(os.path.abspath(path)))


def dirty_items(worktree: Path) -> list[str]:
    items = [line for line in git(
        worktree,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        "--ignored=matching",
    ).stdout.splitlines() if line]

    submodule_status = git(worktree, "submodule", "status", "--recursive", check=False)
    if submodule_status.returncode != 0:
        raise GitError(submodule_status.stderr.strip() or "could not inspect submodules")
    for line in submodule_status.stdout.splitlines():
        if line and line[0] in "-+U":
            items.append(f"submodule-state:{line}")

    # ponytail: one fixed shell probe covers nested submodules; replace only if Git adds a structured recursive status API.
    probe = git(
        worktree,
        "submodule",
        "foreach",
        "--quiet",
        "--recursive",
        'dirty=$(git status --porcelain=v1 --untracked-files=all --ignored=matching); '
        'if test -n "$dirty"; then printf "%s\\n" "$dirty" | sed "s#^#$displaypath:#"; exit 3; fi',
        check=False,
    )
    if probe.returncode not in (0, 3, 128):
        raise GitError(probe.stderr.strip() or "could not inspect submodule dirtiness")
    items.extend(line for line in probe.stdout.splitlines() if line)
    if probe.returncode == 128 and not items:
        raise GitError(probe.stderr.strip() or "could not inspect nested submodules")
    return items


def git_path(worktree: Path, name: str) -> Path:
    value = git(worktree, "rev-parse", "--git-path", name).stdout.strip()
    if not value:
        raise GitError(f"could not resolve git path {name}")
    path = Path(value)
    return path if path.is_absolute() else worktree / path


def retained(message: str, items: list[str] | None = None) -> int:
    print(f"RETAINED: {message}", file=sys.stderr)
    for item in (items or [])[:20]:
        print(f"  {item}", file=sys.stderr)
    if items and len(items) > 20:
        print(f"  ... {len(items) - 20} more", file=sys.stderr)
    return RETAINED


def cleanup(args: argparse.Namespace) -> int:
    repo = normalized(args.repo)
    worktree = normalized(args.worktree)
    if not repo.is_dir() or not worktree.is_dir():
        raise GitError("repo and worktree must be existing directories")
    if not args.remote_ref.startswith("refs/heads/"):
        raise GitError("--remote-ref must start with refs/heads/")
    if not OID_RE.fullmatch(args.expected_head):
        raise GitError("--expected-head must be a full 40- or 64-character OID")

    records = parse_worktrees(repo)
    matches = [record for record in records if normalized(str(record["worktree"])) == worktree]
    if len(matches) != 1:
        return retained(f"{worktree} is not exactly one registered worktree")
    if normalized(str(records[0]["worktree"])) == worktree:
        return retained(f"refusing to remove primary worktree {worktree}")
    record = matches[0]
    if "locked" in record:
        return retained(f"worktree is locked: {record.get('locked') or 'no reason given'}")

    for state in IN_PROGRESS:
        if git_path(worktree, state).exists():
            return retained(f"Git operation in progress: {state}")

    head = git(worktree, "rev-parse", "--verify", "HEAD").stdout.strip().lower()
    expected = args.expected_head.lower()
    if head != expected:
        return retained(f"HEAD {head} does not match expected {expected}")

    remote = git(repo, "ls-remote", "--exit-code", "--", args.remote, args.remote_ref, check=False)
    if remote.returncode != 0:
        return retained(
            f"could not verify {args.remote}/{args.remote_ref}: "
            f"{remote.stderr.strip() or 'remote ref unavailable'}"
        )
    remote_matches = []
    for line in remote.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == args.remote_ref:
            remote_matches.append(fields[0].lower())
    if remote_matches != [expected]:
        return retained(
            f"remote {args.remote_ref} does not resolve exactly to expected {expected}",
            remote_matches,
        )

    dirty = dirty_items(worktree)
    if dirty:
        return retained(f"worktree has tracked, untracked, ignored, or submodule changes: {worktree}", dirty)

    removed = git(repo, "worktree", "remove", str(worktree), check=False)
    if removed.returncode != 0:
        return retained(
            f"plain git worktree remove refused {worktree}: "
            f"{removed.stderr.strip() or removed.stdout.strip() or 'unknown error'}"
        )
    remaining = parse_worktrees(repo)
    if worktree.exists() or any(normalized(str(r["worktree"])) == worktree for r in remaining):
        raise GitError(f"postcondition failed after removing {worktree}")
    print(f"REMOVED: {worktree}")
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", required=True)
    result.add_argument("--worktree", required=True)
    result.add_argument("--remote", required=True)
    result.add_argument("--remote-ref", required=True)
    result.add_argument("--expected-head", required=True)
    return result


def main() -> int:
    try:
        return cleanup(parser().parse_args())
    except (GitError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return INVALID


if __name__ == "__main__":
    raise SystemExit(main())
