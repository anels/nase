#!/usr/bin/env bash
# Verify shared doc references in skill / CLAUDE.md / README files point at an
# existing file. It also keeps reference files navigable and bounded.
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
