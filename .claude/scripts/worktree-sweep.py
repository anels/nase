#!/usr/bin/env python3
"""Find and remove spent worktrees under the shared worktree root.

`worktree-cleanup.py` quarantines one worktree per run and never deletes, so the root
fills with locked `.{name}.nase-cleanup-{id}` directories and with live worktrees whose
PRs merged long ago. Left alone it reached 68G. This script is the second half of that
lifecycle: it decides which of those directories hold nothing that is not already on
GitHub, and removes only those.

`scan` is read-only. It classifies every directory under the root:

- `removable`       - clean, and the HEAD commit is part of a merged PR.
- `keep-open-pr`    - HEAD belongs to an open PR, so address-comments may still need it.
- `keep-dirty`      - uncommitted, untracked, or in-progress git state.
- `keep-unpushed`   - GitHub does not have the HEAD commit, so removal would lose it.
- `keep-no-pr`      - GitHub has the commit but no merged or open PR contains it.
- `keep-locked`     - locked by something other than this workflow's own quarantine.
- `keep-in-use`     - the current directory is inside it.
- `keep-unreadable` - git or GitHub could not answer; unknown is never removable.

Merged-PR evidence comes from `commits/{sha}/pulls`, not from branch names. A squash
merge deletes the remote branch, so "branch gone" and "work lost" look identical to a
ref check. The commit-to-PR association tells them apart.

`apply` takes a `scan` report and removes only its `removable` items, after
re-checking each one, because the minutes between scan and apply are long enough for a
session to commit into a worktree. It also refuses a report whose root does not match its
own `--root`, so a tampered report cannot widen the area it is allowed to delete in. It
never passes `--force`. The human gate lives in the calling skill, since deletion is
permanent.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import nase_git
from nase_gh import failure_category
from nase_gh import run as gh_run
from nase_script import load_script

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = Path.home() / ".nase-worktrees"
QUARANTINE_MARK = ".nase-cleanup-"
SLUG_RE = re.compile(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?$")
WORKERS = 8
REMOVE_TIMEOUT_SECONDS = 1800
LISTED_SKIPS = 20
# Always reported, so the calling skill can test `removable=0` instead of inferring a
# zero from a missing key.
CATEGORIES = (
    "removable",
    "keep-open-pr",
    "keep-dirty",
    "keep-unpushed",
    "keep-no-pr",
    "keep-locked",
    "keep-in-use",
    "keep-unreadable",
)

cleanup = load_script("worktree_cleanup", SCRIPT_DIR / "worktree-cleanup.py")


def git(path: Path, *args: str, timeout: float = nase_git.GIT_TIMEOUT_SECONDS):
    try:
        return nase_git.run(*args, repo=path, text=True, timeout=timeout)
    except nase_git.GitTimeout as exc:
        raise RuntimeError(str(exc)) from exc


def is_quarantine(name: str) -> bool:
    return name.startswith(".") and QUARANTINE_MARK in name


def common_repo(worktree: Path) -> tuple[Path | None, Path | None]:
    """Return (main repo, this worktree's admin dir), or (None, None) for a primary."""
    marker = worktree / ".git"
    if not marker.is_file():
        return None, None
    text = marker.read_text(errors="replace").strip()
    if not text.startswith("gitdir:"):
        return None, None
    admin = Path(text.removeprefix("gitdir:").strip())
    if not admin.is_absolute():
        admin = worktree / admin
    if admin.parent.name != "worktrees" or admin.parent.parent.name != ".git":
        return None, None
    return admin.parent.parent.parent, admin


def size_kb(path: Path) -> int:
    total = 0
    for item in path.rglob("*"):
        try:
            if not item.is_symlink() and item.is_file():
                total += item.stat().st_blocks * 512
        except OSError:
            continue
    return total // 1024


def inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
    except ValueError:
        return False
    return True


def pr_evidence(slug: str, head: str) -> tuple[str, str, int | None]:
    """Return (category, reason, pr number) from the PRs GitHub ties to `head`."""
    result = gh_run(["gh", "api", "-X", "GET", f"repos/{slug}/commits/{head}/pulls"])
    if result.returncode != 0:
        if "No commit found" in result.stderr:
            return "keep-unpushed", "GitHub has no such commit", None
        kind, _ = failure_category(result.stderr)
        return "keep-unreadable", f"gh {kind}", None
    try:
        prs = json.loads(result.stdout or "[]")
    except json.JSONDecodeError:
        return "keep-unreadable", "gh returned unparseable output", None
    if not isinstance(prs, list):
        return "keep-unreadable", "gh returned unexpected JSON", None
    prs = [p for p in prs if isinstance(p, dict)]
    open_prs = [p for p in prs if p.get("state") == "open"]
    if open_prs:
        return "keep-open-pr", "PR still open", open_prs[0].get("number")
    merged = [p for p in prs if p.get("merged_at")]
    if merged:
        return "removable", "commit is in a merged PR", merged[0].get("number")
    return "keep-no-pr", "no merged or open PR contains the commit", None


def classify(worktree: Path) -> dict[str, Any]:
    item: dict[str, Any] = {"name": worktree.name, "path": str(worktree)}

    def done(category: str, reason: str, **extra: Any) -> dict[str, Any]:
        return {**item, "category": category, "reason": reason, **extra}

    try:
        repo, admin = common_repo(worktree)
    except OSError as exc:
        return done("keep-unreadable", f".git unreadable: {exc.strerror or exc}")
    if repo is None or admin is None:
        return done("keep-unreadable", "not a linked worktree")
    item["repo"] = str(repo)
    if inside(Path.cwd(), worktree):
        return done("keep-in-use", "current directory is inside it")
    if (admin / "locked").exists() and not is_quarantine(worktree.name):
        return done("keep-locked", "locked outside this workflow")
    try:
        status = git(worktree, "status", "--porcelain")
        head = git(worktree, "rev-parse", "HEAD")
        origin = git(repo, "remote", "get-url", "origin")
    except RuntimeError as exc:
        return done("keep-unreadable", str(exc))
    if status.returncode != 0 or head.returncode != 0 or origin.returncode != 0:
        return done("keep-unreadable", "git could not read the worktree")
    item["head"] = head.stdout.strip()
    if status.stdout.strip():
        return done("keep-dirty", f"{len(status.stdout.splitlines())} changed paths")
    if any((admin / marker).exists() for marker in cleanup.IN_PROGRESS):
        return done("keep-dirty", "git operation in progress")
    match = SLUG_RE.search(origin.stdout.strip())
    if not match:
        return done("keep-unreadable", "origin is not a GitHub remote")
    category, reason, number = pr_evidence("/".join(match.groups()), item["head"])
    return done(category, reason, pr=number)


def scan(args: argparse.Namespace) -> int:
    root = Path(args.root)
    dirs = sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        items = list(pool.map(classify, dirs))
    counts: dict[str, int] = dict.fromkeys(CATEGORIES, 0)
    for item in items:
        category = str(item["category"])
        counts[category] = counts.get(category, 0) + 1
        if category == "removable":
            item["size_kb"] = size_kb(Path(str(item["path"])))
    freed_mb = sum(int(i.get("size_kb", 0)) for i in items) // 1024
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "root": str(root),
        "counts": counts,
        "removable_mb": freed_mb,
        "items": items,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=1) + "\n")
    summary = ", ".join(f"{k}={v}" for k, v in sorted(counts.items()))
    print(f"worktree-sweep scan: {summary}; removable {freed_mb} MB; report {out}")
    return 0


def remove_one(
    root: Path, item: dict[str, Any]
) -> tuple[bool, str, int, str]:
    raw_path = item.get("path")
    if not isinstance(raw_path, str):
        return False, "item has no path", 0, ""
    path = Path(raw_path)
    if path.parent.resolve() != root.resolve():
        return False, "path is not a direct child of the root", 0, ""
    if not path.is_dir():
        return False, "path missing", 0, ""
    if inside(Path.cwd(), path):
        return False, "current directory is inside it", 0, ""
    try:
        repo, admin = common_repo(path)
    except OSError as exc:
        return False, f".git unreadable: {exc.strerror or exc}", 0, ""
    if repo is None or admin is None:
        return False, "not a linked worktree", 0, ""
    try:
        status = git(path, "status", "--porcelain")
        head = git(path, "rev-parse", "HEAD")
    except RuntimeError as exc:
        return False, str(exc), 0, ""
    if status.returncode != 0 or status.stdout.strip():
        return False, "changed since scan", 0, ""
    if head.returncode != 0:
        return False, "git could not read the worktree", 0, ""
    if head.stdout.strip() != item.get("head"):
        return False, "HEAD moved since scan", 0, ""
    if any((admin / marker).exists() for marker in cleanup.IN_PROGRESS):
        return False, "git operation in progress", 0, ""
    locked = (admin / "locked").exists()
    if locked and not is_quarantine(path.name):
        return False, "locked outside this workflow", 0, ""
    try:
        freed = int(item.get("size_kb", 0))
    except (TypeError, ValueError):
        freed = 0
    try:
        if locked:
            git(repo, "worktree", "unlock", str(path))
        removed = git(
            repo, "worktree", "remove", str(path), timeout=REMOVE_TIMEOUT_SECONDS
        )
    except RuntimeError as exc:
        if locked:
            with contextlib.suppress(RuntimeError):
                git(repo, "worktree", "lock", str(path))
        return False, str(exc), 0, ""
    if removed.returncode != 0:
        if locked:
            with contextlib.suppress(RuntimeError):
                git(repo, "worktree", "lock", str(path))
        return False, removed.stderr.strip()[:200], 0, ""
    return True, "", freed, str(repo)


def apply(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    try:
        report = json.loads(Path(args.report).read_text())
        report_root = Path(str(report["root"])).resolve()
        items = [i for i in report["items"] if i.get("category") == "removable"]
    except (OSError, KeyError, TypeError, AttributeError, json.JSONDecodeError) as exc:
        print(f"worktree-sweep: unreadable report: {exc}", file=sys.stderr)
        return 2
    if report_root != root:
        print(
            f"worktree-sweep: report root {report_root} does not match --root {root}",
            file=sys.stderr,
        )
        return 2
    removed = 0
    freed_kb = 0
    skipped: list[tuple[str, str]] = []
    repos: set[str] = set()
    for item in items:
        ok, why, freed, repo = remove_one(root, item)
        if ok:
            removed += 1
            freed_kb += freed
            if repo:
                repos.add(repo)
        else:
            skipped.append((str(item.get("name", item.get("path", "?"))), why))
    for repo in sorted(repos):
        try:
            pruned = git(Path(repo), "worktree", "prune")
        except RuntimeError as exc:
            print(f"  WARN prune {repo} - {exc}", file=sys.stderr)
            continue
        if pruned.returncode != 0:
            detail = pruned.stderr.strip() or f"exit {pruned.returncode}"
            print(f"  WARN prune {repo} - {detail}", file=sys.stderr)
    print(
        f"worktree-sweep apply: removed {removed}, skipped {len(skipped)}, "
        f"freed {freed_kb // 1024} MB"
    )
    for name, why in skipped[:LISTED_SKIPS]:
        print(f"  SKIP {name} - {why}")
    if len(skipped) > LISTED_SKIPS:
        print(f"  ... {len(skipped) - LISTED_SKIPS} more")
    return 0


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    sub = top.add_subparsers(dest="command", required=True)
    scan_p = sub.add_parser("scan", help="classify worktrees, read-only")
    scan_p.add_argument("--root", default=str(DEFAULT_ROOT))
    scan_p.add_argument("--out", required=True, help="where to write the JSON report")
    scan_p.set_defaults(func=scan)
    apply_p = sub.add_parser("apply", help="remove the report's removable items")
    apply_p.add_argument("--root", default=str(DEFAULT_ROOT))
    apply_p.add_argument("--report", required=True)
    apply_p.set_defaults(func=apply)
    return top


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
