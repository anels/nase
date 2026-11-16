#!/usr/bin/env bash
# Verify shared doc references in skill / CLAUDE.md / README files point at an
# existing file, and that every CLAUDE.md section citation names a heading that exists.
# It also keeps reference files navigable and bounded.
# `workspace/` is local and ignored, so workspace doc references are only
# required to resolve from workspace-owned files.
#
# Run from repo root:  bash tests/check-shared-doc-refs.sh
# Exit 0 = all references resolve, exit 1 = at least one missing reference.

set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT"

scan_paths=(
  ".claude/commands/nase"
  ".claude/docs"
  "workspace/skills"
  "CLAUDE.md"
  "README.md"
)

existing_scan_paths=()
for path in "${scan_paths[@]}"; do
  [[ -e "$path" ]] && existing_scan_paths+=("$path")
done

if [[ "${#existing_scan_paths[@]}" -eq 0 ]]; then
  echo "OK: no scan paths found"
  exit 0
fi

# Scanned in Python, not grep: BSD grep (macOS) reads `-Z` as "decompress", so a
# `grep -Z | awk` pipeline found zero pairs there and the gate passed on a dead
# reference. Python is a required dependency and behaves the same everywhere.
missing_lines=$(python3 - "${existing_scan_paths[@]}" <<'PY'
import os
import re
import sys

REF = re.compile(r"(?:\.claude/docs|workspace/skills/docs)/[a-zA-Z0-9_-]+\.md")

def sources(paths):
    for path in paths:
        if os.path.isdir(path):
            for dirpath, _dirs, names in os.walk(path):
                for name in names:
                    yield os.path.join(dirpath, name)
        else:
            yield path

pairs = set()
for src in sources(sys.argv[1:]):
    try:
        with open(src, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"WARN: skipped unreadable {src}: {exc}", file=sys.stderr)
        continue
    for ref in REF.findall(text):
        pairs.add((src, ref))

for src, ref in sorted(pairs):
    if ref.startswith("workspace/skills/docs/") and not src.startswith("workspace/skills/"):
        continue
    if not os.path.isfile(ref):
        print(f"MISSING  {src} -> {ref}")
PY
)
missing=0
if [[ -n "$missing_lines" ]]; then
  printf '%s\n' "$missing_lines"
  missing=$(printf '%s\n' "$missing_lines" | wc -l | tr -d ' ')
fi

# Section citations into CLAUDE.md. A file path reference above is checked for existence,
# but "CLAUDE.md" followed by a section sign, an arrow, or "->" and a heading name used to
# be taken on trust, so moving or renaming a heading left dangling pointers that read as
# ordinary prose. Each cited heading must exist in CLAUDE.md or in .claude/rules/*.md,
# where CLAUDE.md text is moved when it is path-scoped.
#
# The narrowest rule that stays free of false positives on prose:
#   - a quoted citation must equal a heading exactly;
#   - an unquoted citation runs to the first backtick, quote, period, comma, semicolon or
#     parenthesis, and passes when it STARTS WITH an existing heading, so trailing words
#     ("... Code Review and the verifier") are not read as part of the name;
#   - a token that starts with a path (".claude/...") is not a heading citation. That is
#     the shape of this gate's own MISSING output line.
# Files are the working tree (tracked plus untracked, minus ignored), so a fixture repo
# that was never staged is scanned the same as a clean checkout.
citation_lines=$(python3 - <<'PY'
import glob
import os
import re
import subprocess

HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$")
# \x60 is a backtick: a literal one in a heredoc inside $(...) breaks bash 3.2 (macOS).
QUOTED = re.compile(r"(?<![\w/.-])CLAUDE\.md\x60?\s*(?:§|→|->)\s*\"([^\"\n]+)\"")
BARE = re.compile(
    r"(?<![\w/.-])CLAUDE\.md\x60?\s*(?:§|→|->)[ \t]*(?:#+[ \t]+)?([A-Za-z][^\n\x60\".;,()]*)"
)

headings = set()
for path in ["CLAUDE.md", *sorted(glob.glob(".claude/rules/*.md"))]:
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8", errors="replace") as fh:
        in_fence = False
        for line in fh:
            if line.startswith("\x60\x60\x60"):
                in_fence = not in_fence
            m = None if in_fence else HEADING.match(line)
            if m:
                headings.add(m.group(1))

listing = subprocess.run(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
    capture_output=True,
    text=True,
    check=False,
).stdout
for path in sorted(set(p for p in listing.split("\0") if p.endswith((".md", ".sh")))):
    if not os.path.isfile(path):
        continue
    with open(path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            for m in QUOTED.finditer(line):
                if m.group(1) not in headings:
                    print(f'DANGLING  {path}:{lineno} -> CLAUDE.md "{m.group(1)}"')
            for m in BARE.finditer(line):
                cited = m.group(1).strip()
                if not any(cited.startswith(h) for h in headings):
                    print(f"DANGLING  {path}:{lineno} -> CLAUDE.md {cited}")
PY
)
if [[ -n "$citation_lines" ]]; then
  printf '%s\n' "$citation_lines"
  missing=$((missing + $(printf '%s\n' "$citation_lines" | wc -l | tr -d ' ')))
fi

quality_failures=$(python3 - <<'PY'
from pathlib import Path
import re

failures = []
for base in (Path(".claude/docs"), Path("workspace/skills/docs")):
    if not base.is_dir():
        continue
    for path in sorted(base.glob("*.md")):
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = len(text.splitlines())
        if lines > 500:
            failures.append(f"OVERSIZE {path}: {lines} lines > 500")
        if lines > 100 and "## Contents" not in text:
            failures.append(f"NO_TOC   {path}: {lines} lines without ## Contents")
        # A <canonical-block> declares the exact pointer consumers copy, so it
        # legitimately names its own file; exclude it from the self-ref scan.
        scanned = re.sub(
            r"<canonical-block name=\"[^\"]+\">.*?</canonical-block>",
            "",
            text,
            flags=re.DOTALL,
        )
        refs = re.findall(r"(?:\.claude/docs|workspace/skills/docs)/[A-Za-z0-9_-]+\.md", scanned)
        if path.as_posix() in refs and path.as_posix() != ".claude/docs/external-mutation-policy.md":
            failures.append(f"SELF_REF {path} -> {path}")

print("\n".join(failures))
PY
)
if [[ -n "$quality_failures" ]]; then
  printf '%s\n' "$quality_failures"
  missing=$((missing + $(printf '%s\n' "$quality_failures" | wc -l | tr -d ' ')))
fi

if [[ "$missing" -eq 0 ]]; then
  echo "OK: shared doc references resolve and stay within navigation budgets"
  exit 0
fi

printf '\n%d missing reference(s)\n' "$missing" >&2
exit 1
