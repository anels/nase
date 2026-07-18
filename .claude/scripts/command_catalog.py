#!/usr/bin/env python3
"""Render and validate the core /nase command catalog.

Claude Code derives custom command names from the command file path. This helper
therefore treats `.claude/commands/nase/<name>.md` as `/nase:<name>` and uses
frontmatter only for docs/help metadata such as category, order, and description.
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


CATEGORY_ORDER = [
    "Setup & health",
    "Knowledge base",
    "Learning & reflection",
    "Design & implementation",
    "Git workflow",
    "Reporting",
    "Security & maintenance",
    "Backup & restore",
]

README_START = "## Available commands"


@dataclass(frozen=True)
class Command:
    command: str
    file: str
    category: str
    description: str
    pattern: str
    order: int | None
    argument_hint: str
    when_to_use: str
    model: str
    effort: str
    context: str
    agent: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render or validate the /nase command catalog.")
    parser.add_argument("--root", default=".", help="nase workspace root")
    parser.add_argument(
        "--format",
        choices=("readme", "help-compact", "help-verbose", "json"),
        default="readme",
        help="output format",
    )
    parser.add_argument("--command-limit", type=int, default=5, help="compact commands per category; 0 = unlimited")
    parser.add_argument("--purpose-chars", type=int, default=180, help="compact description width; 0 = unlimited")
    readme_mode = parser.add_mutually_exclusive_group()
    readme_mode.add_argument("--check-readme", action="store_true", help="fail when README Available commands drift")
    readme_mode.add_argument("--write-readme", action="store_true", help="replace the generated README command section")
    return parser.parse_args()


def unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] == '"':
        return value[1:-1].replace(r"\"", '"').replace(r"\\", "\\")
    if len(value) >= 2 and value[0] == value[-1] and value[0] == "'":
        return value[1:-1]
    return value


def parse_frontmatter(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    match = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not match:
        raise ValueError(f"{path}: missing YAML frontmatter")

    fields: dict[str, str] = {}
    for lineno, raw_line in enumerate(match.group(1).splitlines(), 2):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            raise ValueError(f"{path}:{lineno}: frontmatter line has no ':'")
        key, value = line.split(":", 1)
        fields[key.strip()] = unquote(value)
    return fields


def load_catalog(root: Path) -> list[Command]:
    command_dir = root / ".claude" / "commands" / "nase"
    if not command_dir.is_dir():
        return []

    commands: list[Command] = []
    errors: list[str] = []
    for path in sorted(command_dir.glob("*.md")):
        try:
            fields = parse_frontmatter(path)
        except ValueError as exc:
            errors.append(str(exc))
            continue

        missing = [field for field in ("description", "pattern", "category") if not fields.get(field)]
        if missing:
            errors.append(f"{path}: missing frontmatter field(s): {', '.join(missing)}")
            continue
        if fields["category"] not in CATEGORY_ORDER:
            errors.append(f"{path}: unknown category: {fields['category']}")
            continue

        order: int | None = None
        if fields.get("order"):
            try:
                order = int(fields["order"])
            except ValueError:
                errors.append(f"{path}: order must be an integer")
                continue

        commands.append(
            Command(
                command=f"/nase:{path.stem}",
                file=path.relative_to(root).as_posix(),
                category=fields["category"],
                description=fields["description"],
                pattern=fields["pattern"],
                order=order,
                argument_hint=fields.get("argument-hint", ""),
                when_to_use=fields.get("when_to_use") or fields["description"],
                model=fields.get("model", ""),
                effort=fields.get("effort", ""),
                context=fields.get("context", ""),
                agent=fields.get("agent", ""),
            )
        )

    if errors:
        raise ValueError("\n".join(errors))
    return sorted(commands, key=sort_key)


def sort_key(command: Command) -> tuple[int, str, int, str]:
    return (
        CATEGORY_ORDER.index(command.category),
        command.category.lower(),
        command.order if command.order is not None else 10_000,
        command.command,
    )


def grouped(commands: list[Command]) -> list[tuple[str, list[Command]]]:
    groups: list[tuple[str, list[Command]]] = []
    for command in commands:
        if not groups or groups[-1][0] != command.category:
            groups.append((command.category, []))
        groups[-1][1].append(command)
    return groups


def escape_table_cell(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().replace("|", r"\|")


def truncate(text: str, limit: int) -> str:
    if limit <= 0 or len(text) <= limit:
        return text
    truncated = text[: max(limit - 3, 1)].rstrip()
    if truncated.count("`") % 2:
        truncated = f"{truncated}`"
    return f"{truncated}..."


def render_readme(commands: list[Command]) -> str:
    lines = [
        README_START,
        "",
        "<!-- This section is generated from `.claude/commands/nase/*.md` frontmatter. -->",
        "<!-- Run: `python3 .claude/scripts/command_catalog.py --root . --format readme` -->",
        "",
    ]
    for category, rows in grouped(commands):
        lines.extend(
            [
                f"### {category}",
                "",
                "| Command | Purpose |",
                "|---------|---------|",
            ]
        )
        for row in rows:
            lines.append(f"| `{row.command}` | {escape_table_cell(row.description)} |")
        lines.append("")
    lines.append("---")
    return "\n".join(lines).rstrip()


def render_help_compact(commands: list[Command], command_limit: int, purpose_chars: int) -> str:
    lines = ["## Commands"]
    for category, rows in grouped(commands):
        lines.append(f"### {category}")
        shown = rows if command_limit <= 0 else rows[:command_limit]
        for row in shown:
            lines.append(f"- `{row.command}` - {truncate(row.description, purpose_chars)}")
        remaining = len(rows) - len(shown)
        if remaining > 0:
            lines.append(f"- (+{remaining} more; run `/nase:help --verbose`)")
        lines.append("")
    return "\n".join(lines).rstrip()


def render_json(commands: list[Command]) -> str:
    rows = []
    for command in commands:
        row = dict(command.__dict__)
        row["argument-hint"] = row["argument_hint"]
        rows.append(row)
    return json.dumps(rows, indent=2, ensure_ascii=False)


def extract_readme_catalog(readme_text: str) -> str:
    start = readme_text.find(f"{README_START}\n")
    if start < 0:
        return ""
    rest = readme_text[start:]
    next_header = re.search(r"\n## [^\n]+", rest[len(README_START) :])
    if next_header:
        end = len(README_START) + next_header.start()
        return rest[:end].strip()
    return rest.strip()


def check_readme(root: Path, expected: str) -> int:
    readme = root / "README.md"
    if not readme.is_file():
        print("README.md missing", file=sys.stderr)
        return 1

    actual = extract_readme_catalog(readme.read_text(encoding="utf-8", errors="replace"))
    if actual == expected:
        return 0

    diff = difflib.unified_diff(
        actual.splitlines(),
        expected.splitlines(),
        fromfile="README.md",
        tofile="generated command catalog",
        lineterm="",
    )
    print("README Available commands drift:", file=sys.stderr)
    print("\n".join(diff), file=sys.stderr)
    return 1


def write_readme(root: Path, expected: str) -> int:
    readme = root / "README.md"
    if not readme.is_file():
        print("README.md missing", file=sys.stderr)
        return 1

    text = readme.read_text(encoding="utf-8", errors="replace")
    start = text.find(f"{README_START}\n")
    if start < 0:
        print("README Available commands section missing", file=sys.stderr)
        return 1
    rest = text[start:]
    next_header = re.search(r"\n## [^\n]+", rest[len(README_START) :])
    end = start + len(README_START) + next_header.start() if next_header else len(text)
    readme.write_text(f"{text[:start]}{expected}{text[end:]}", encoding="utf-8")
    return 0


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    try:
        commands = load_catalog(root)
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1

    readme_output = render_readme(commands)
    if args.check_readme:
        return check_readme(root, readme_output)
    if args.write_readme:
        return write_readme(root, readme_output)

    if args.format == "readme":
        print(readme_output)
    elif args.format == "help-compact":
        print(render_help_compact(commands, max(args.command_limit, 0), max(args.purpose_chars, 0)))
    elif args.format == "help-verbose":
        print(readme_output)
    elif args.format == "json":
        print(render_json(commands))
    else:
        raise AssertionError(args.format)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
