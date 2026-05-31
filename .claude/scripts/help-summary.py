#!/usr/bin/env python3
"""Render compact or verbose `/nase:help` output from repo sources.

The command list stays sourced from README.md, but the extraction/capping work is
deterministic so Claude does not need to read and trim the full README in chat.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


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


def split_markdown_row(line: str) -> list[str]:
    line = line.strip()
    if not line.startswith("|") or not line.endswith("|"):
        return []
    cells: list[str] = []
    current: list[str] = []
    escaped = False
    in_code = False
    for char in line[1:-1]:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\":
            escaped = True
            continue
        if char == "`":
            in_code = not in_code
            current.append(char)
            continue
        if char == "|" and not in_code:
            cells.append("".join(current).strip())
            current = []
            continue
        current.append(char)
    cells.append("".join(current).strip())
    return cells


def strip_cell_markup(text: str) -> str:
    text = re.sub(r"`([^`]+)`", r"`\1`", text)
    text = text.replace("**", "")
    return re.sub(r"\s+", " ", text).strip()


def truncate(text: str, limit: int) -> str:
    if limit <= 0 or len(text) <= limit:
        return text
    truncated = text[: max(limit - 3, 1)].rstrip()
    if truncated.count("`") % 2:
        truncated = truncated[:-1].rstrip() if truncated.endswith("`") else f"{truncated}`"
    return truncated + "..."


def parse_command_groups(section: str) -> list[tuple[str, list[tuple[str, str]]]]:
    groups: list[tuple[str, list[tuple[str, str]]]] = []
    current_name = ""
    current_rows: list[tuple[str, str]] = []
    for raw_line in section.splitlines():
        line = raw_line.strip()
        if line.startswith("### "):
            if current_name:
                groups.append((current_name, current_rows))
            current_name = line.removeprefix("### ").strip()
            current_rows = []
            continue
        if not line.startswith("|") or "---" in line:
            continue
        cells = split_markdown_row(line)
        if len(cells) < 2 or cells[0].lower() == "command":
            continue
        command = strip_cell_markup(cells[0])
        purpose = strip_cell_markup(cells[1])
        if command.startswith("`/nase:"):
            current_rows.append((command, purpose))
    if current_name:
        groups.append((current_name, current_rows))
    return groups


def render_commands(groups: list[tuple[str, list[tuple[str, str]]]], limit: int, purpose_chars: int) -> str:
    lines = ["## Commands"]
    for group, rows in groups:
        lines.append(f"### {group}")
        shown = rows if limit <= 0 else rows[:limit]
        for command, purpose in shown:
            lines.append(f"- {command} - {truncate(purpose, purpose_chars)}")
        remaining = len(rows) - len(shown)
        if remaining > 0:
            lines.append(f"- (+{remaining} more; run `/nase:help --verbose`)")
        lines.append("")
    return "\n".join(lines).rstrip()


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
    if not readme.is_file():
        command_files = sorted((root / ".claude" / "commands" / "nase").glob("*.md"))
        print("## Commands")
        for path in command_files:
            print(f"- `/nase:{path.stem}`")
        return 0

    text = read_text(readme)
    intro = extract_intro(text)
    available = extract_section(text, "Available commands")
    hooks = extract_section(text, "Hooks at a glance")

    print("# nase help")
    print()
    print(intro)
    print()

    if args.verbose:
        if available:
            print(available)
            print()
        if hooks:
            print(hooks)
            print()
    else:
        print(render_commands(parse_command_groups(available), max(args.command_limit, 0), max(args.purpose_chars, 0)))
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
