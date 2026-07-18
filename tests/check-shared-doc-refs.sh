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

# NUL-delimited filenames (-Z) so paths containing `:` parse safely.
pairs=$({ grep -rZoE '(\.claude/docs|workspace/skills/docs)/[a-zA-Z0-9_-]+\.md' "${existing_scan_paths[@]}" 2>/dev/null || true; } \
  | awk -F '\0' 'NF==2 {print $1 "\t" $2}' \
  | sort -u)

missing=0
while IFS=$'\t' read -r src ref; do
  [[ -z "$src" || -z "$ref" ]] && continue
  if [[ "$ref" == workspace/skills/docs/* && "$src" != workspace/skills/* ]]; then
    continue
  fi
  if [[ ! -f "$ref" ]]; then
    printf 'MISSING  %s -> %s\n' "$src" "$ref"
    missing=$((missing+1))
  fi
done <<< "$pairs"

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
        refs = re.findall(r"(?:\.claude/docs|workspace/skills/docs)/[A-Za-z0-9_-]+\.md", text)
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
