#!/usr/bin/env python3
"""Read `workspace/config.md` with one set of parse rules.

Every lookup returns a `Lookup` whose status is one of `found`, `absent`,
`ambiguous`, `unavailable`, so a caller can tell a missing key from a
conflicting one or an unreadable file. The module knows no keys, defaults, or
meanings. Each caller decides what a value means and whether to fail open or
closed.

Usage:
    python3 .claude/scripts/nase_config.py get [--root DIR] [--section NAME] KEY

On `found` the value goes to stdout as UTF-8 bytes followed by `\\n`. Any other
status prints `status: reason` to stderr.

Exit codes: 0 found, 3 absent, 4 ambiguous, 5 unavailable, 6 absent because the
key sits in another scope (`misplaced`). Any other exit means the module itself
is broken, and a hook should use its default and warn.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

FOUND = "found"
ABSENT = "absent"
AMBIGUOUS = "ambiguous"
UNAVAILABLE = "unavailable"

EXIT_CODES = {FOUND: 0, ABSENT: 3, AMBIGUOUS: 4, UNAVAILABLE: 5}
EXIT_MISPLACED = 6

COMMENT_RE = re.compile(r"<!--.*?(?:(-->)|\Z)", re.DOTALL)
FENCE_RE = re.compile(r"^\s*(```|~~~)")
BLANK_RE = re.compile(r"[^\n]")


@dataclass(frozen=True)
class Lookup:
    status: str
    value: str = ""
    reason: str = ""


@dataclass(frozen=True)
class Entry:
    scope: str | None
    key: str
    value: str


@dataclass(frozen=True)
class Config:
    entries: tuple[Entry, ...] = ()
    headings: tuple[str, ...] = ()
    unterminated: bool = False
    unavailable: str = ""

    def get(self, key: str, section: str | None = None) -> Lookup:
        if self.unavailable:
            return Lookup(UNAVAILABLE, reason=self.unavailable)
        if self.unterminated:
            return Lookup(AMBIGUOUS, reason="unterminated-block")
        if section is not None and self.headings.count(section) > 1:
            return Lookup(AMBIGUOUS, reason="duplicate-section")

        mine = [e.value for e in self.entries if e.key == key and e.scope == section]
        values = {v for v in mine if v}
        if len(values) == 1:
            return Lookup(FOUND, value=values.pop())
        if len(values) > 1:
            return Lookup(AMBIGUOUS, reason="conflicting-values")

        if any(e.key == key and e.scope != section and e.value for e in self.entries):
            return Lookup(ABSENT, reason="misplaced")
        if section is not None and section not in self.headings:
            return Lookup(ABSENT, reason="no-section")
        if mine:
            return Lookup(ABSENT, reason="empty-value")
        return Lookup(ABSENT, reason="no-key")


def _live_lines(text: str) -> tuple[list[str], bool]:
    """Blank HTML comments and fenced code, keeping the line count.

    Returns the lines and whether a comment or fence is still open at the end,
    because everything after it is then hidden.
    """
    unterminated = False

    def blank(match: re.Match[str]) -> str:
        nonlocal unterminated
        if match.group(1) is None:
            unterminated = True
        return BLANK_RE.sub("", match.group())

    text = COMMENT_RE.sub(blank, text)
    lines: list[str] = []
    fence: str | None = None
    for raw in text.split("\n"):
        line = raw.removesuffix("\r")
        marker = FENCE_RE.match(line)
        if fence is None and marker:
            fence = marker.group(1)
            lines.append("")
        elif fence is not None:
            if marker and marker.group(1) == fence:
                fence = None
            lines.append("")
        else:
            lines.append(line)
    return lines, unterminated or fence is not None


def _heading(line: str) -> str | None:
    if line.startswith("##") and len(line) > 2 and line[2].isspace():
        return line[2:].strip() or None
    return None


def _entry(line: str) -> tuple[str, str] | None:
    if not line or line[0].isspace():
        return None
    rest = line
    if line[0] in "-*" and len(line) > 1 and line[1].isspace():
        rest = line[1:].lstrip()
    key, colon, value = rest.partition(":")
    key = key.rstrip()
    if not colon or not key:
        return None
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return key, value


def parse(text: str) -> Config:
    """Parse config text. Pure: no I/O."""
    lines, unterminated = _live_lines(text.removeprefix("﻿"))
    entries: list[Entry] = []
    headings: list[str] = []
    scope: str | None = None
    for line in lines:
        name = _heading(line)
        if name is not None:
            headings.append(name)
            scope = name
            continue
        parsed = _entry(line)
        if parsed is not None:
            entries.append(Entry(scope, parsed[0], parsed[1]))
    return Config(tuple(entries), tuple(headings), unterminated)


def load(root: Path) -> Config:
    """Read `root/workspace/config.md`; an unreadable file becomes `unavailable`."""
    path = Path(root) / "workspace" / "config.md"
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return Config(unavailable="no-file")
    except OSError as exc:
        return Config(unavailable=f"unreadable:{exc.__class__.__name__}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return Config(unavailable="undecodable")
    return parse(text)


def exit_code(result: Lookup) -> int:
    if result.status == ABSENT and result.reason == "misplaced":
        return EXIT_MISPLACED
    return EXIT_CODES[result.status]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    get = commands.add_parser("get", help="look up one key")
    get.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[2]),
        help="nase repo root (default: the repo this script lives in)",
    )
    get.add_argument("--section", help="read this `## ` section instead of the top-level scope")
    get.add_argument("key")
    args = parser.parse_args(argv)

    result = load(Path(args.root)).get(args.key, args.section)
    if result.status == FOUND:
        sys.stdout.buffer.write(result.value.encode("utf-8") + b"\n")
        sys.stdout.buffer.flush()
    else:
        sys.stderr.write(f"{result.status}: {result.reason}\n")
    return exit_code(result)


if __name__ == "__main__":
    sys.exit(main())
