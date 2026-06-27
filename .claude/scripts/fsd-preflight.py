#!/usr/bin/env python3
"""Emit compact deterministic preflight context for /nase:fsd."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


def run_git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def lines(text: str) -> list[str]:
    return [line for line in text.splitlines() if line.strip()]


def default_branch(repo: Path) -> dict[str, Any]:
    sym = run_git(repo, "symbolic-ref", "refs/remotes/origin/HEAD", "--short")
    if sym.returncode == 0 and sym.stdout.strip().startswith("origin/"):
        return {"branch": sym.stdout.strip().removeprefix("origin/"), "source": "origin/HEAD"}
    remote = run_git(repo, "remote", "show", "origin")
    match = re.search(r"HEAD branch:\s*(\S+)", remote.stdout)
    if match:
        return {"branch": match.group(1), "source": "remote show origin"}
    return {"branch": None, "source": "unavailable"}


def repo_state(repo: Path) -> dict[str, Any]:
    branch = run_git(repo, "branch", "--show-current")
    status = run_git(repo, "status", "--short")
    head = run_git(repo, "rev-parse", "--short", "HEAD")
    return {
        "path": str(repo),
        "branch": branch.stdout.strip() if branch.returncode == 0 else None,
        "head": head.stdout.strip() if head.returncode == 0 else None,
        "dirty": bool(status.stdout.strip()),
        "statusShort": lines(status.stdout),
        "defaultBranch": default_branch(repo),
    }


def git_files(repo: Path) -> list[str]:
    result = run_git(repo, "ls-files")
    if result.returncode != 0:
        return []
    return lines(result.stdout)


def module_inventory(repo: Path, max_items: int) -> list[str]:
    files = git_files(repo)
    top_dirs = sorted({path.split("/", 1)[0] for path in files if "/" in path})
    interesting = [
        path
        for path in files
        if re.search(r"(helper|service|util|client|controller|handler|module)", path, re.I)
    ]
    inventory = [f"dir:{item}" for item in top_dirs[:max_items]]
    remaining = max(0, max_items - len(inventory))
    inventory.extend(f"file:{item}" for item in interesting[:remaining])
    return inventory


def task_terms(task: str) -> list[str]:
    seen: set[str] = set()
    terms: list[str] = []
    for token in re.findall(r"[A-Za-z0-9_./-]{4,}", task):
        cleaned = token.strip("./-").lower()
        if cleaned and cleaned not in seen:
            terms.append(cleaned)
            seen.add(cleaned)
    return terms[:20]


def kb_candidates(kb_file: Path | None, task: str, max_lines: int) -> list[dict[str, Any]]:
    if not kb_file or not kb_file.is_file():
        return []
    terms = task_terms(task)
    if not terms:
        return []
    matches: list[dict[str, Any]] = []
    for idx, line in enumerate(kb_file.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        lowered = line.lower()
        if any(term in lowered for term in terms):
            matches.append({"line": idx, "text": line.strip()[:240]})
            if len(matches) >= max_lines:
                break
    return matches


def tool_availability(root: Path) -> list[dict[str, Any]]:
    script = root / ".claude" / "scripts" / "tool-availability.py"
    if not script.is_file():
        return []
    result = subprocess.run(
        [
            sys.executable,
            str(script),
            "--group",
            "baseline",
            "--group",
            "ci",
            "--group",
            "review",
            "--group",
            "security",
            "--format",
            "json",
        ],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        return []
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return []


def frontmatter_field(text: str, field: str) -> str:
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        return ""
    for line in match.group(1).splitlines():
        if line.startswith(f"{field}:"):
            value = line.split(":", 1)[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                if value[0] == '"':
                    try:
                        value = json.loads(value)
                    except json.JSONDecodeError:
                        value = value[1:-1]
                else:
                    value = value[1:-1]
            return re.sub(r"\s+", " ", value).strip()
    return ""


def claude_run_skills(repo: Path) -> dict[str, Any]:
    recipes: list[dict[str, str]] = []
    skills_dir = repo / ".claude" / "skills"
    if skills_dir.is_dir():
        for skill_file in sorted(skills_dir.glob("run-*/SKILL.md")):
            text = skill_file.read_text(encoding="utf-8", errors="replace")
            recipes.append(
                {
                    "name": skill_file.parent.name,
                    "path": skill_file.relative_to(repo).as_posix(),
                    "description": frontmatter_field(text, "description")[:240],
                }
            )
    return {"recipes": recipes}


def build_payload(args: argparse.Namespace) -> dict[str, Any]:
    repo = Path(args.repo).resolve()
    root = Path(__file__).resolve().parents[2]
    kb_file = Path(args.kb_file).resolve() if args.kb_file else None
    return {
        "task": args.task,
        "repo": repo_state(repo),
        "moduleInventory": module_inventory(repo, args.max_inventory_items),
        "kbMentionCandidates": kb_candidates(kb_file, args.task, args.max_kb_lines),
        "toolAvailability": tool_availability(root),
        "claudeRunSkills": claude_run_skills(repo),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--kb-file")
    parser.add_argument("--json", action="store_true", help="Emit JSON; retained for command readability")
    parser.add_argument("--max-inventory-items", type=int, default=15)
    parser.add_argument("--max-kb-lines", type=int, default=10)
    args = parser.parse_args(argv)
    print(json.dumps(build_payload(args), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
