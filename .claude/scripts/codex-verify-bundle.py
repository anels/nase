#!/usr/bin/env python3
"""Build the markdown bundle used by the Codex pre-push verification gate."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path


GENERATED_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".pdf", ".zip", ".lock")


def run_git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise SystemExit(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout


def changed_lines(repo: Path, base: str) -> tuple[int, list[tuple[int, str]]]:
    total = 0
    per_file: list[tuple[int, str]] = []
    for line in run_git(repo, "diff", "--numstat", base).splitlines():
        parts = line.split("\t")
        if len(parts) < 3 or parts[0] == "-" or parts[1] == "-":
            continue
        count = int(parts[0]) + int(parts[1])
        total += count
        per_file.append((count, parts[2]))
    per_file.sort(reverse=True)
    return total, per_file


def fenced(label: str, content: str, language: str = "") -> str:
    content = content.rstrip("\n")
    return f"### {label}\n\n```{language}\n{content}\n```\n"


def should_inline(path: str) -> bool:
    return not path.lower().endswith(GENERATED_SUFFIXES)


def build_bundle(args: argparse.Namespace) -> str:
    repo = Path(args.repo).resolve()
    base = args.base
    total, per_file = changed_lines(repo, base)
    stat = run_git(repo, "diff", "--stat", base)
    name_status = run_git(repo, "diff", "--name-status", base)
    untracked = run_git(repo, "ls-files", "--others", "--exclude-standard")

    lines = [
        "# Codex Verification Bundle",
        "",
        f"Repo: `{repo}`",
        f"Base: `{base}`",
        f"Changed lines: {total}",
        "",
        "## Task Spec",
        "",
        args.task.strip() or "(no task spec provided)",
        "",
        "## Diff Stat",
        "",
        "```",
        stat.rstrip("\n"),
        "```",
        "",
        "## Name Status",
        "",
        "```",
        name_status.rstrip("\n"),
        "```",
        "",
        "## Untracked Files",
        "",
        "```",
        untracked.rstrip("\n") or "(none)",
        "```",
        "",
    ]

    if total <= args.max_full_diff_lines:
        lines.append("## Full Diff")
        lines.append("")
        lines.append("```diff")
        lines.append(run_git(repo, "diff", "--no-ext-diff", base).rstrip("\n"))
        lines.append("```")
        lines.append("")
    else:
        lines.append("## Large Diff Sample")
        lines.append("")
        lines.append(
            "Full diff omitted because it exceeds the inline threshold. "
            "The most changed non-generated files are included below."
        )
        lines.append("")
        for _count, path in [item for item in per_file if should_inline(item[1])][: args.max_files]:
            lines.append(fenced(path, run_git(repo, "diff", "--no-ext-diff", base, "--", path), "diff"))

    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--task", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-full-diff-lines", type=int, default=2000)
    parser.add_argument("--max-files", type=int, default=5)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(build_bundle(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
