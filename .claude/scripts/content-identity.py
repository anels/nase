#!/usr/bin/env python3
"""Prove that the content which shipped is the content that was verified.

Two checks, because no single one fits both situations.

`same-tree` compares `<rev>^{tree}` and is exact. Use it whenever the base is unchanged,
such as a squash of the verified range or a push of the reviewed commit. A bare tree OID
is accepted for `--expect`, which is how a recorded candidate tree is checked.

`same-patch` compares `git patch-id --stable` of `old_base..old_head` against
`new_base..new_head`. Use it after a rebase, where the tree legitimately changes because
the base moved but the branch's own diff must not. It has two blind spots. It ignores
whitespace, so a whitespace-only edit passes. It also says nothing about how the new base
interacts with the branch, so a clean rebase onto a moved base still needs the repo's own
checks. A binary-only change has no patch-id, which is an error and not a match.

Exit 0 means same, 1 means differs, 2 means a revision, git call, or argument problem.
A caller must treat 2 as unverified, never as a match.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import nase_git

EXIT_SAME = 0
EXIT_DIFFERS = 1
EXIT_ERROR = 2


class IdentityError(Exception):
    pass


def git_text(repo: str, *args: str) -> str:
    try:
        completed = nase_git.run(*args, repo=repo, text=True)
    except (nase_git.GitTimeout, OSError) as exc:
        raise IdentityError(str(exc)) from exc
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit {completed.returncode}"
        raise IdentityError(f"git {' '.join(args)}: {detail}")
    return completed.stdout


def tree_oid(repo: str, rev: str) -> str:
    return git_text(repo, "rev-parse", "--verify", "--end-of-options", f"{rev}^{{tree}}").strip()


def patch_id(repo: str, base: str, head: str) -> str:
    diff = git_text(repo, "diff", "--no-color", "--no-ext-diff", base, head)
    try:
        completed = subprocess.run(
            ["git", "-C", repo, "patch-id", "--stable"],
            input=diff,
            check=False,
            capture_output=True,
            text=True,
            timeout=nase_git.GIT_TIMEOUT_SECONDS,
        )
    except (subprocess.SubprocessError, OSError) as exc:
        raise IdentityError(f"git patch-id: {exc}") from exc
    if completed.returncode != 0:
        raise IdentityError(f"git patch-id: {completed.stderr.strip() or completed.returncode}")
    fields = completed.stdout.split()
    if not fields:
        raise IdentityError(f"no patch-id for {base}..{head}: empty or binary-only diff")
    return fields[0]


def report(kind: str, expect: str, actual: str) -> int:
    verdict = "same" if expect == actual else "differs"
    print(json.dumps({"verdict": verdict, "kind": kind, "expect": expect, "actual": actual}))
    return EXIT_SAME if verdict == "same" else EXIT_DIFFERS


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Prove that the content which shipped is the content that was verified."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    tree = sub.add_parser("same-tree", help="exact tree comparison on an unchanged base")
    tree.add_argument("--repo", required=True)
    tree.add_argument("--expect", required=True, help="verified commit or tree OID")
    tree.add_argument("--actual", required=True, help="commit about to ship")

    patch = sub.add_parser("same-patch", help="patch-id comparison across a rebase")
    patch.add_argument("--repo", required=True)
    for name in ("old-base", "old-head", "new-base", "new-head"):
        patch.add_argument(f"--{name}", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as exc:
        return EXIT_ERROR if exc.code else EXIT_SAME
    try:
        if args.command == "same-tree":
            return report("tree", tree_oid(args.repo, args.expect), tree_oid(args.repo, args.actual))
        return report(
            "patch-id",
            patch_id(args.repo, args.old_base, args.old_head),
            patch_id(args.repo, args.new_base, args.new_head),
        )
    except IdentityError as exc:
        print(f"content-identity: {exc}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
