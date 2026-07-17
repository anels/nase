#!/usr/bin/env python3
"""Remove a linked Git worktree only after proving it is safe to delete."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import uuid
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


def remote_oid(repo: Path, remote_name: str, remote_ref: str) -> tuple[str | None, str]:
    result = git(repo, "ls-remote", "--exit-code", "--", remote_name, remote_ref, check=False)
    if result.returncode != 0:
        return None, result.stderr.strip() or "remote ref unavailable"
    matches = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == remote_ref:
            matches.append(fields[0].lower())
    if len(matches) != 1:
        return None, f"remote ref resolved {len(matches)} times"
    return matches[0], ""


def delete_safety_ref(repo: Path, safety_ref: str, expected: str) -> None:
    deleted = git(repo, "update-ref", "-d", safety_ref, expected, check=False)
    if deleted.returncode != 0:
        raise GitError(deleted.stderr.strip() or f"could not delete safety ref {safety_ref}")


def restore_after_remote_race(
    repo: Path,
    original: Path,
    expected: str,
    safety_ref: str,
    reason: str,
) -> int:
    restored = original
    if restored.exists():
        restored = original.parent / f"{original.name}-retained-{uuid.uuid4().hex}"
    result = git(repo, "worktree", "add", "--detach", str(restored), safety_ref, check=False)
    if result.returncode != 0:
        raise GitError(
            f"remote proof changed after removal and restore failed; commit remains at "
            f"{safety_ref}: {result.stderr.strip() or result.stdout.strip()}"
        )
    delete_safety_ref(repo, safety_ref, expected)
    return retained(reason, [f"restored-worktree:{restored}", f"head:{expected}"])


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

    verified_remote, remote_error = remote_oid(repo, args.remote, args.remote_ref)
    if verified_remote is None:
        return retained(
            f"could not verify {args.remote}/{args.remote_ref}: "
            f"{remote_error}"
        )
    if verified_remote != expected:
        return retained(
            f"remote {args.remote_ref} does not resolve exactly to expected {expected}",
            [verified_remote],
        )

    dirty = dirty_items(worktree)
    if dirty:
        return retained(f"worktree has tracked, untracked, ignored, or submodule changes: {worktree}", dirty)

    safety_ref = f"refs/nase/worktree-cleanup/{uuid.uuid4().hex}"
    created = git(repo, "update-ref", safety_ref, expected, "0" * len(expected), check=False)
    if created.returncode != 0:
        raise GitError(created.stderr.strip() or f"could not create safety ref {safety_ref}")

    claimed = worktree.parent / f".{worktree.name}.nase-cleanup-{uuid.uuid4().hex}"
    moved = git(repo, "worktree", "move", str(worktree), str(claimed), check=False)
    if moved.returncode != 0:
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            f"plain git worktree move could not claim {worktree}: "
            f"{moved.stderr.strip() or moved.stdout.strip() or 'unknown error'}"
        )

    if worktree.exists():
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            "worktree path was recreated during cleanup; preserving both paths",
            [f"registered-worktree:{claimed}", f"foreign-path:{worktree}"],
        )

    claimed_head = git(claimed, "rev-parse", "--verify", "HEAD").stdout.strip().lower()
    if claimed_head != expected:
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            f"claimed worktree HEAD changed to {claimed_head}",
            [f"registered-worktree:{claimed}"],
        )
    claimed_dirty = dirty_items(claimed)
    if claimed_dirty:
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            f"claimed worktree changed during cleanup: {claimed}",
            [f"registered-worktree:{claimed}", *claimed_dirty],
        )

    predelete_remote, remote_error = remote_oid(repo, args.remote, args.remote_ref)
    if predelete_remote != expected:
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            f"remote proof changed before deletion: {remote_error or predelete_remote}",
            [f"registered-worktree:{claimed}"],
        )

    removed = git(repo, "worktree", "remove", str(claimed), check=False)
    if removed.returncode != 0:
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            f"plain git worktree remove refused {claimed}: "
            f"{removed.stderr.strip() or removed.stdout.strip() or 'unknown error'}",
            [f"registered-worktree:{claimed}"],
        )
    remaining = parse_worktrees(repo)
    if claimed.exists() or any(normalized(str(r["worktree"])) == claimed for r in remaining):
        raise GitError(f"postcondition failed after removing {claimed}; safety ref retained at {safety_ref}")

    postdelete_remote, remote_error = remote_oid(repo, args.remote, args.remote_ref)
    if postdelete_remote != expected:
        return restore_after_remote_race(
            repo,
            worktree,
            expected,
            safety_ref,
            f"remote proof changed during deletion: {remote_error or postdelete_remote}",
        )
    delete_safety_ref(repo, safety_ref, expected)
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
