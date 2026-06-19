#!/usr/bin/env python3
"""Render compact or verbose `/nase:help` output from repo sources.

The command list is sourced from `.claude/commands/nase/*.md` frontmatter via
`command_catalog.py`. README.md supplies only the intro and hook prose.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from command_catalog import load_catalog, render_help_compact, render_readme


DEFAULT_COMMAND_LIMIT = 5
DEFAULT_SKILL_LIMIT = 10
DEFAULT_PURPOSE_CHARS = 180


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render nase help from README.md and workspace dirs.")
    parser.add_argument("--root", default=".", help="nase workspace root")
    parser.add_argument("--verbose", action="store_true", help="Emit full README sections")
    parser.add_argument("--command-limit", type=int, default=DEFAULT_COMMAND_LIMIT)
    parser.add_argument("--skill-limit", type=int, default=DEFAULT_SKILL_LIMIT)
    parser.add_argument("--purpose-chars", type=int, default=DEFAULT_PURPOSE_CHARS)
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def extract_section(text: str, header: str) -> str:
    pattern = re.compile(rf"^## {re.escape(header)}\s*$", re.M)
    match = pattern.search(text)
    if not match:
        return ""
    next_match = re.search(r"^## .+$", text[match.end() :], re.M)
    end = match.end() + next_match.start() if next_match else len(text)
    return text[match.start() : end].strip()


def extract_intro(text: str) -> str:
    # First paragraph after the logo block.
    blocks = re.split(r"\n\s*\n", text)
    for block in blocks:
        stripped = block.strip()
        if not stripped or stripped.startswith(("#", "```", ">", "---")):
            continue
        if "Claude Code" in stripped or "workspace" in stripped:
            return stripped.replace("\n", " ")
    return "A personal AI engineering workspace for Claude Code."


def count_md_files(path: Path) -> int:
    if not path.is_dir():
        return 0
    return sum(1 for item in path.rglob("*.md") if item.is_file())


def render_workspace_layout(root: Path, verbose: bool) -> str:
    workspace = root / "workspace"
    lines = ["## KB Layout"]
    paths = [
        ("workspace/kb/general", "general KB"),
        ("workspace/kb/projects", "project KB"),
        ("workspace/kb/ops", "ops KB"),
        ("workspace/kb/cross-project", "cross-project KB"),
        ("workspace/tasks", "tasks and lessons"),
        ("workspace/logs", "daily logs"),
    ]
    for rel, label in paths:
        path = root / rel
        if path.exists():
            lines.append(f"- `{rel}/` - {label}, {count_md_files(path)} md file(s)")
    if verbose and (workspace / "kb").is_dir():
        for path in sorted((workspace / "kb").iterdir()):
            if path.is_dir() and f"workspace/kb/{path.name}" not in {rel for rel, _ in paths}:
                rel = path.relative_to(root).as_posix()
                lines.append(f"- `{rel}/` - {count_md_files(path)} md file(s)")
    if len(lines) == 1:
        lines.append("- workspace not initialized")
    return "\n".join(lines)


def render_workspace_skills(root: Path, limit: int) -> str:
    skill_dir = root / "workspace" / "skills"
    names = sorted(path.stem for path in skill_dir.glob("*.md")) if skill_dir.is_dir() else []
    lines = ["## Workspace Skills"]
    if not names:
        lines.append("- none")
        return "\n".join(lines)
    shown = names if limit <= 0 else names[:limit]
    for name in shown:
        lines.append(f"- `/nase:workspace:{name}`")
    remaining = len(names) - len(shown)
    if remaining > 0:
        lines.append(f"- (+{remaining} more; run `/nase:help --verbose`)")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    readme = root / "README.md"
    text = read_text(readme) if readme.is_file() else ""

    intro = extract_intro(text) if text else "A personal AI engineering workspace for Claude Code."
    hooks = extract_section(text, "Hooks at a glance")

    try:
        commands = load_catalog(root)
    except ValueError as exc:
        print(exc)
        return 1

    print("# nase help")
    print()
    print(intro)
    print()

    if args.verbose:
        print(render_readme(commands))
        print()
        if hooks:
            print(hooks)
            print()
    else:
        print(render_help_compact(commands, max(args.command_limit, 0), max(args.purpose_chars, 0)))
        print()
        print("## Hooks")
        print("- Lifecycle hooks, safety guards, backup/logging, and validation helpers are wired in `.claude/settings.json`.")
        print("- Run `/nase:doctor` for a health check or `/nase:help --verbose` for the full hook table.")
        print()

    skill_limit = 0 if args.verbose else max(args.skill_limit, 0)
    print(render_workspace_layout(root, args.verbose))
    print()
    print(render_workspace_skills(root, skill_limit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
