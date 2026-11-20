#!/usr/bin/env python3
"""Print the few lessons that match the task at hand.

workspace/tasks/lessons.md grows without bound, so a skill cannot read it whole. This script
matches each entry against the skill name, repo name, touched paths and extra terms, and prints
the best few. It informs and never gates, so every lookup outcome exits 0. A missing file or
no usable term prints one note on stderr and nothing on stdout. Bad arguments exit 2.

Usage: lessons-lookup.py [--root ROOT] [--skill NAME] [--repo NAME] [--path P ...]
                         [--term T ...] [--limit N]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from dataclasses import dataclass

import nase_git
from command_catalog import truncate

ENTRY_HEADER = re.compile(
    r"^## (?P<category>[a-z]+) -- (?P<date>\d{4}-\d{2}-\d{2}) -- (?P<title>.+)$"
)
ENTRY_END = re.compile(r"^(?:#{1,6} |- \d{4}-\d{2}-\d{2} )")
FIELD_LABEL = re.compile(r"^\*\*(?P<label>[^*]+?)(?::\*\*|\*\*:)")
FIELD_BREAK = re.compile(r"^(?:```|[-*] |\d+\. )")
RULE_LABELS = ("Do", "Rule", "Lesson", "Pattern", "Mitigation", "Apply")
SKIPPED_CATEGORIES = {"calibration", "style"}
SKIPPED_TITLE = re.compile(
    r"(?:->|→) (?:applied to .+|rejected(?: on \d{4}-\d{2}-\d{2})?)$"
)
GENERIC_NAMES = {
    "index.ts",
    "index.js",
    "readme.md",
    "package.json",
    "package-lock.json",
    "tsconfig.json",
    "program.cs",
}
MIN_TERM_LENGTH = 3
FIELD_CHARS = 300
TITLE_POINTS = 3
BODY_POINTS = 1


@dataclass
class Entry:
    category: str
    date: str
    title: str
    lines: list[str]


def parse_entries(text: str) -> list[Entry]:
    entries: list[Entry] = []
    current: Entry | None = None
    in_fence = False
    for line in text.splitlines():
        header = ENTRY_HEADER.match(line)
        if header:
            in_fence = False
        elif line.startswith("```"):
            in_fence = not in_fence
        if header:
            current = Entry(header["category"], header["date"], header["title"], [])
            entries.append(current)
        elif not in_fence and ENTRY_END.match(line):
            current = None
        elif current is not None:
            current.lines.append(line)
    return entries


def build_terms(args: argparse.Namespace) -> list[re.Pattern[str]]:
    values = [args.skill, args.repo, *args.term]
    for raw in args.path:
        path = raw.replace("\\", "/")
        name = pathlib.PurePosixPath(path).name
        generic = name.lower() in GENERIC_NAMES
        if not (generic and path == name):
            values.append(path)
        if not generic:
            values.append(name)
    unique = {
        value.strip().lower()
        for value in values
        if len(value.strip()) >= MIN_TERM_LENGTH
    }
    return [
        re.compile(rf"(?<![A-Za-z0-9]){re.escape(term)}(?![A-Za-z0-9])", re.IGNORECASE)
        for term in sorted(unique)
    ]


def score(entry: Entry, terms: list[re.Pattern[str]]) -> int:
    body = "\n".join(entry.lines)
    total = 0
    for term in terms:
        if term.search(entry.title):
            total += TITLE_POINTS
        elif term.search(body):
            total += BODY_POINTS
    return total


def labelled_fields(entry: Entry) -> list[tuple[str, str]]:
    """Return each `**Label:**` field with its wrapped prose continuation lines."""
    fields: list[tuple[str, list[str]]] = []
    open_field = False
    for line in entry.lines:
        label = FIELD_LABEL.match(line)
        if label:
            fields.append((label["label"], [line.strip()]))
            open_field = True
        elif open_field and line.strip() and not FIELD_BREAK.match(line):
            fields[-1][1].append(line.strip())
        else:
            open_field = False
    return [(label, truncate(" ".join(parts), FIELD_CHARS)) for label, parts in fields]


def first_line(entry: Entry) -> str:
    return next(
        (truncate(line.strip(), FIELD_CHARS) for line in entry.lines if line.strip()),
        "",
    )


def render(entry: Entry) -> str:
    """Show the situation and the rule. The rule is the first of RULE_LABELS, else the first field after `When`."""
    parts = [f"## {entry.category} -- {entry.date} -- {entry.title}"]
    fields = labelled_fields(entry)

    def find(label: str) -> str:
        return next((text for name, text in fields if name == label), "")

    when = find("When")
    rule = next((text for text in map(find, RULE_LABELS) if text), "")
    rule = rule or next((text for name, text in fields if name != "When"), "")
    shown = [text for text in (when, rule) if text]
    parts.extend(shown or [first_line(entry)])
    return "\n".join(part for part in parts if part)


def main() -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    parser.add_argument("--root")
    parser.add_argument("--skill", default="")
    parser.add_argument("--repo", default="")
    parser.add_argument("--path", action="append", default=[])
    parser.add_argument("--term", action="append", default=[])
    parser.add_argument("--limit", type=int, default=5)
    args = parser.parse_args()

    terms = build_terms(args)
    lessons = nase_git.resolve_root(args.root) / "workspace" / "tasks" / "lessons.md"
    if not terms:
        print(
            f"[lessons] no usable term; each term needs {MIN_TERM_LENGTH} or more characters",
            file=sys.stderr,
        )
        return 0
    try:
        text = lessons.read_text(encoding="utf-8-sig", errors="replace")
    except OSError:
        print(
            f"[lessons] no file at {lessons}; pass --root or set NASE_ROOT",
            file=sys.stderr,
        )
        return 0

    scored = (
        (score(entry, terms), entry)
        for entry in parse_entries(text)
        if entry.category not in SKIPPED_CATEGORIES
        and not SKIPPED_TITLE.search(entry.title)
    )
    ranked = sorted(
        (pair for pair in scored if pair[0] > 0),
        key=lambda pair: (pair[0], pair[1].date),
        reverse=True,
    )
    matched = [entry for _, entry in ranked[: max(args.limit, 0)]]
    if not matched:
        return 0

    print(
        f"[lessons] {len(matched)} entries match; they are past notes, so check each against the repo before relying on it."
    )
    print("\n\n".join(render(entry) for entry in matched))
    return 0


if __name__ == "__main__":
    sys.exit(main())
