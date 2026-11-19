#!/usr/bin/env python3
"""Section-level access to a KB Markdown file.

Subcommands:
  outline <file> [--depth N]            heading tree with line ranges and token estimates
  get <file> <heading>                  print one section (heading line through its end)
  replace <file> <heading> --content-file F --out OUT
  append-under <file> <heading> --content-file F --out OUT

`replace` and `append-under` never modify <file>. They write the complete proposed file to
--out, which feeds `workspace-write-guard.py stage --content-file`, so the guard still sees,
diffs and hash-checks the full file. The point is that the caller reads and edits one section,
not the whole file.

Exit 0 ok. Exit 1 on an I/O error. Exit 2 when a heading is not found (argparse also
exits 2 on a usage error). Exit 3 when the heading is ambiguous.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
FENCE_RE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
CHARS_PER_TOKEN = 4


def parse_sections(lines: list[str]) -> list[dict]:
    """Headings outside fenced code, each with a 1-based inclusive line range."""
    heads: list[tuple[int, int, str]] = []
    fence = ""
    for idx, line in enumerate(lines, start=1):
        m = FENCE_RE.match(line)
        if m:
            marker = m.group(1)
            if not fence:
                fence = marker[0] * 3
            elif marker.startswith(fence):
                fence = ""
            continue
        if fence:
            continue
        h = HEADING_RE.match(line)
        if h:
            heads.append((idx, len(h.group(1)), h.group(2)))
    sections = []
    for pos, (start, level, title) in enumerate(heads):
        end = len(lines)
        for nxt_start, nxt_level, _ in heads[pos + 1 :]:
            if nxt_level <= level:
                end = nxt_start - 1
                break
        sections.append({"start": start, "end": end, "level": level, "title": title})
    return sections


def find_section(sections: list[dict], query: str) -> dict:
    exact = [s for s in sections if s["title"] == query]
    if len(exact) == 1:
        return exact[0]
    pool = exact or [s for s in sections if query.lower() in s["title"].lower()]
    if not pool:
        raise LookupError(f"no heading matches: {query}")
    if len(pool) > 1:
        listing = "; ".join(f"L{s['start']} {s['title']}" for s in pool[:8])
        raise ValueError(f"{len(pool)} headings match {query!r}: {listing}")
    return pool[0]


def read_lines(path: str) -> list[str]:
    try:
        return pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        print(f"kb-section: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


def cmd_outline(args: argparse.Namespace) -> int:
    lines = read_lines(args.file)
    for s in parse_sections(lines):
        if s["level"] > args.depth:
            continue
        chars = sum(len(x) + 1 for x in lines[s["start"] - 1 : s["end"]])
        tokens = chars // CHARS_PER_TOKEN
        print(f"L{s['start']}-{s['end']}\t~{tokens}tok\t{'#' * s['level']} {s['title']}")
    return 0


def pick(args: argparse.Namespace, lines: list[str]) -> dict:
    try:
        return find_section(parse_sections(lines), args.heading)
    except LookupError as exc:
        print(f"kb-section: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
    except ValueError as exc:
        print(f"kb-section: {exc}", file=sys.stderr)
        raise SystemExit(3) from exc


def write_out(out: str, lines: list[str], had_trailing_newline: bool) -> None:
    text = "\n".join(lines) + ("\n" if had_trailing_newline else "")
    try:
        pathlib.Path(out).write_text(text, encoding="utf-8")
    except OSError as exc:
        print(f"kb-section: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


def cmd_edit(args: argparse.Namespace) -> int:
    source = pathlib.Path(args.file)
    if not source.is_file():
        print(f"kb-section: not a file: {args.file}", file=sys.stderr)
        return 1
    try:
        raw = source.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"kb-section: {exc}", file=sys.stderr)
        return 1
    if pathlib.Path(args.out).resolve() == source.resolve():
        print("kb-section: --out must not be the same file as <file>", file=sys.stderr)
        return 1
    lines = raw.splitlines()
    s = pick(args, lines)
    new = read_lines(args.content_file)
    if args.cmd == "replace":
        out_lines = lines[: s["start"] - 1] + new + lines[s["end"] :]
    else:
        out_lines = lines[: s["end"]] + new + lines[s["end"] :]
    write_out(args.out, out_lines, raw.endswith("\n"))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    o = sub.add_parser("outline")
    o.add_argument("file")
    o.add_argument("--depth", type=int, default=3)
    o.set_defaults(fn=cmd_outline)
    g = sub.add_parser("get")
    g.add_argument("file")
    g.add_argument("heading")
    g.set_defaults(fn=cmd_get)
    for name in ("replace", "append-under"):
        e = sub.add_parser(name)
        e.add_argument("file")
        e.add_argument("heading")
        e.add_argument("--content-file", required=True)
        e.add_argument("--out", required=True)
        e.set_defaults(fn=cmd_edit)
    return p


def cmd_get(args: argparse.Namespace) -> int:
    lines = read_lines(args.file)
    s = pick(args, lines)
    print("\n".join(lines[s["start"] - 1 : s["end"]]))
    return 0


def main() -> int:
    args = build_parser().parse_args()
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
