#!/usr/bin/env python3
"""Verify and quarantine a linked Git worktree without recursive deletion."""

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


def git_bytes(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).decode(errors="backslashreplace").strip()
        raise GitError(f"git {' '.join(args)}: {detail or f'exit {result.returncode}'}")
    return result.stdout


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


def index_flag_items(worktree: Path) -> list[str]:
    flags: dict[bytes, set[str]] = {}

    def records(option: str) -> list[tuple[int, bytes]]:
        parsed = []
        for raw in git_bytes(worktree, "ls-files", option, "-z").split(b"\0"):
            if not raw:
                continue
            if len(raw) < 3 or raw[1:2] != b" ":
                raise GitError(f"could not parse git ls-files {option} record")
            parsed.append((raw[0], raw[2:]))
        return parsed

    for tag, path in records("-v"):
        labels = flags.setdefault(path, set())
        if tag == ord("S") or tag == ord("s"):
            labels.add("skip-worktree")
        if chr(tag).islower():
            labels.add("assume-unchanged")
    for tag, path in records("-f"):
        if chr(tag).islower():
            flags.setdefault(path, set()).add("fsmonitor-valid")

    return [
        f"index-flags:{','.join(sorted(labels))}:{os.fsdecode(path)!r}"
        for path, labels in flags.items()
        if labels
    ]


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

    hidden_index = index_flag_items(worktree)
    if hidden_index:
        return retained("worktree index contains hidden-change flags", hidden_index)

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

    locked = git(
        repo,
        "worktree",
        "lock",
        "--reason",
        "nase cleanup quarantine",
        str(claimed),
        check=False,
    )
    if locked.returncode != 0:
        raise GitError(
            f"could not lock quarantined worktree {claimed}; safety ref retained at {safety_ref}: "
            f"{locked.stderr.strip() or locked.stdout.strip()}"
        )

    quarantined_remote, remote_error = remote_oid(repo, args.remote, args.remote_ref)
    if quarantined_remote != expected:
        delete_safety_ref(repo, safety_ref, expected)
        return retained(
            f"remote proof changed after quarantine: {remote_error or quarantined_remote}",
            [f"registered-worktree:{claimed}", f"head:{expected}"],
        )

    delete_safety_ref(repo, safety_ref, expected)
    # ponytail: portable Git has no atomic delete-if-clean; quarantine until a human inspects it.
    return retained(
        "verified worktree quarantined; automatic recursive deletion is not race-safe",
        [f"registered-worktree:{claimed}", f"original-path:{worktree}", f"head:{expected}"],
    )


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
