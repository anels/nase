#!/usr/bin/env python3
"""Collect HEAD state, publish state, and commitlint config for commit-message rewrites.

One JSON document on stdout, so the caller runs a single command instead of a git sequence
plus reading commitlint config files into context.

Usage:
  python3 .claude/scripts/git-commit-context.py [--repo PATH] [--no-fetch]

Publish state is fail-closed: every configured remote is refreshed first, and a refresh
that fails - or is skipped with `--no-fetch` - yields `push_state: "unknown"` (treated as
published) rather than a silent "not pushed". Only a successful refresh with no containing
remote branch yields `not-pushed`, because that value is what authorizes an unattended
amend of history.

Commitlint discovery reports every candidate in documented priority order and parses the
JSON ones. It never picks a winner: when CI loads a specific config, the caller confirms
that against the commitlint job log.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

CONFIG_FILES = (
    ".commitlintrc.json",
    ".commitlintrc.js",
    ".commitlintrc.yml",
    "commitlint.config.js",
    "commitlint.config.mjs",
    "commitlint.config.cjs",
    "commitlint.config.ts",
)

RULE_KEYS = ("header-max-length", "type-enum", "subject-case", "subject-full-stop")


class ContextError(RuntimeError):
    pass


def git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def git_out(repo: Path, *args: str) -> str:
    result = git(repo, *args)
    if result.returncode != 0:
        raise ContextError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.rstrip("\n")


def head_state(repo: Path) -> dict[str, Any]:
    full_message = git_out(repo, "log", "-1", "--format=%B")
    parents = git_out(repo, "log", "-1", "--format=%P").split()
    rev_list_count = int(git_out(repo, "rev-list", "--count", "HEAD"))
    lines = full_message.splitlines()
    return {
        "sha": git_out(repo, "rev-parse", "HEAD"),
        "subject": lines[0] if lines else "",
        "body": "\n".join(lines[1:]).strip("\n"),
        "full_message": full_message,
        "parent_count": len(parents),
        "is_merge": len(parents) > 1,
        "rev_list_count": rev_list_count,
        "is_initial_commit": rev_list_count == 1,
    }


def push_state(repo: Path, fetch: bool) -> dict[str, Any]:
    remotes = [r for r in git_out(repo, "remote").splitlines() if r]
    state = "not-pushed"
    if remotes:
        # Skipping the refresh is the same epistemic state as a failed one: the
        # remote-tracking refs may be stale, so freshness is not established. Only a
        # successful refresh may produce "not-pushed", because that value is what
        # authorizes an unattended amend of history.
        fetch_ok = fetch
        if fetch:
            for remote in remotes:
                result = git(
                    repo,
                    "fetch",
                    "--prune",
                    remote,
                    f"+refs/heads/*:refs/remotes/{remote}/*",
                )
                if result.returncode != 0:
                    fetch_ok = False
        if not fetch_ok:
            state = "unknown"
        else:
            contains = git(repo, "branch", "-r", "--contains", "HEAD")
            if contains.returncode != 0:
                # A query that errored says nothing about containment. Reading that as
                # "not pushed" would be fail-open on the value that authorizes an
                # unattended amend.
                state = "unknown"
            elif contains.stdout.strip():
                state = "pushed"
    return {
        "remotes": remotes,
        "fetched": fetch,
        "push_state": state,
        "is_pushed": state in ("pushed", "unknown"),
    }


def commitlint(repo: Path) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for name in CONFIG_FILES:
        path = repo / name
        if not path.is_file():
            continue
        entry: dict[str, Any] = {"file": name, "parsed": False, "rules": None, "note": None}
        if name.endswith(".json"):
            try:
                config = json.loads(path.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, OSError) as exc:
                entry["note"] = f"parse error: {exc}"
            else:
                # Valid JSON that is not an object, or carries no rules object, reports as
                # parsed with nothing extracted rather than failing the whole run.
                if not isinstance(config, dict):
                    config = {}
                rules = config.get("rules")
                if not isinstance(rules, dict):
                    rules = {}
                entry["parsed"] = True
                entry["extends"] = config.get("extends")
                entry["rules"] = {key: rules[key] for key in RULE_KEYS if key in rules}
        else:
            entry["note"] = "non-JSON config: read it directly if CI loads this file"
        candidates.append(entry)
    return {"candidates": candidates, "found": bool(candidates)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument(
        "--no-fetch",
        action="store_true",
        help="skip the remote refresh; a repo with remotes then reports push_state=unknown",
    )
    args = parser.parse_args()
    repo = Path(args.repo).expanduser().resolve(strict=False)
    try:
        payload = head_state(repo)
        payload.update(push_state(repo, fetch=not args.no_fetch))
        payload["commitlint"] = commitlint(repo)
    except (ContextError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
